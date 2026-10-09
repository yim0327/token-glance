import Foundation

/// Identity and size of a file, enough to tell "appended" from "replaced or truncated".
public struct FileStat: Equatable, Sendable {
    public var inode: UInt64
    public var size: Int

    public init(inode: UInt64, size: Int) {
        self.inode = inode
        self.size = size
    }
}

/// File access for incremental reading.
public protocol TailSource: FileSource {
    func stat(_ url: URL) -> FileStat?
    /// Up to `maxLength` bytes starting at `offset` (fewer at end of file).
    func read(_ url: URL, from offset: Int, maxLength: Int) throws -> Data
}

/// `stat(2)` of a regular file (symlinks followed). Outside the extension so `stat` is not shadowed.
private func regularFileStat(_ path: String) -> FileStat? {
    var info = Darwin.stat()
    guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    return FileStat(inode: UInt64(info.st_ino), size: Int(info.st_size))
}

extension LocalFileSource: TailSource {
    public func stat(_ url: URL) -> FileStat? {
        regularFileStat(url.path)
    }

    public func read(_ url: URL, from offset: Int, maxLength: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: maxLength) ?? Data()
    }
}

extension InMemoryFileSource: TailSource {
    public func stat(_ url: URL) -> FileStat? {
        let path = url.standardizedFileURL.path
        guard let data = files[path] else { return nil }
        return FileStat(inode: inodes[path] ?? 1, size: data.count)
    }

    public func read(_ url: URL, from offset: Int, maxLength: Int) throws -> Data {
        let data = try contents(of: url)
        guard offset < data.count else { return Data() }
        return Data(data[data.startIndex + offset ..< data.startIndex + min(data.count, offset + maxLength)])
    }
}

/// Something that consumes a log one complete line at a time.
public protocol LineConsumer {
    init()
    mutating func consume(line: Data)
}

/// Follows a set of append-only log files, feeding only newly appended complete lines to a
/// per-file `State`.
///
/// For each file it remembers the inode and the offset just past the last newline consumed.
/// A trailing line without a newline is left for the next sync (it may still be being written).
/// If a file shrinks below that offset or its inode changes, its state is discarded and the file is
/// read again from the start. Files that disappear from the list are dropped.
public struct TailedFiles<State: LineConsumer> {
    public struct Tracked {
        public var inode: UInt64
        public var offset: Int
        public var state: State
    }

    public private(set) var files: [String: Tracked] = [:]
    /// Total bytes read so far (for measurements).
    public private(set) var bytesRead = 0

    /// Bytes read per call; bounds memory when a large file is read for the first time.
    public static var chunkSize: Int { 1024 * 1024 }

    public init() {}

    /// Brings the tracked set in line with `urls`. Returns whether any state changed.
    @discardableResult
    /// `onRead` is called with the number of bytes after each chunk (for progress display).
    public mutating func sync(_ urls: [URL], source: any TailSource, onRead: ((Int) -> Void)? = nil) -> Bool {
        var changed = false
        let current = Set(urls.map(\.path))
        for path in files.keys where !current.contains(path) {
            files[path] = nil
            changed = true
        }
        for url in urls {
            guard let stat = source.stat(url) else {
                if files.removeValue(forKey: url.path) != nil { changed = true }
                continue
            }
            var tracked = files[url.path] ?? Tracked(inode: stat.inode, offset: 0, state: State())
            if tracked.inode != stat.inode || stat.size < tracked.offset {
                tracked = Tracked(inode: stat.inode, offset: 0, state: State())
                changed = true
            }
            if stat.size > tracked.offset, consumeNewLines(url, size: stat.size, into: &tracked, source: source, onRead: onRead) {
                changed = true
            }
            files[url.path] = tracked
        }
        return changed
    }

    /// Mutates every tracked state (e.g. pruning).
    public mutating func updateStates(_ body: (inout State) -> Void) {
        for path in files.keys { body(&files[path]!.state) }
    }

    /// Reads from the file's offset to `size` in chunks, consuming complete lines only.
    private mutating func consumeNewLines(_ url: URL, size: Int, into tracked: inout Tracked, source: any TailSource,
                                          onRead: ((Int) -> Void)?) -> Bool {
        var consumedAny = false
        var pending = Data()
        var position = tracked.offset
        while position < size {
            // FileHandle reads and JSON decoding return autoreleased Foundation objects. Without a
            // pool per chunk (there is no run loop on this thread) every chunk stays alive until the
            // scan ends, so a first full scan would hold all bytes read at once.
            let keepGoing: Bool = autoreleasepool {
                guard let chunk = try? source.read(url, from: position, maxLength: Self.chunkSize), !chunk.isEmpty else { return false }
                position += chunk.count
                bytesRead += chunk.count
                onRead?(chunk.count)
                pending.append(chunk)
                guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return true }
                let complete = pending[pending.startIndex ... lastNewline]
                for line in JSONLines.lines(in: Data(complete)) { tracked.state.consume(line: line) }
                tracked.offset += complete.count
                pending = Data(pending[(lastNewline + 1)...])
                consumedAny = true
                return true
            }
            if !keepGoing { break }
        }
        return consumedAny
    }
}
