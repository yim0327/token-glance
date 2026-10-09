import Foundation

/// File access used by providers, abstracted so tests can inject fixtures.
public protocol FileSource: Sendable {
    /// Regular files under `root` (recursively) whose file name satisfies `include`.
    /// A missing root yields an empty list.
    func files(under root: URL, where include: @Sendable (String) -> Bool) -> [URL]
    func contents(of url: URL) throws -> Data
}

public struct LocalFileSource: FileSource {
    public init() {}

    public func files(under root: URL, where include: @Sendable (String) -> Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where include(url.lastPathComponent) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    public func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// In-memory files keyed by absolute path. Intended for tests.
public struct InMemoryFileSource: FileSource {
    public var files: [String: Data]
    /// Simulated inode numbers (default 1); change one to simulate a replaced file.
    public var inodes: [String: UInt64] = [:]

    public init(files: [String: Data]) {
        self.files = files
    }

    public func files(under root: URL, where include: @Sendable (String) -> Bool) -> [URL] {
        let prefix = root.standardizedFileURL.path + "/"
        return files.keys
            .filter { $0.hasPrefix(prefix) && include(($0 as NSString).lastPathComponent) }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
    }

    public func contents(of url: URL) throws -> Data {
        guard let data = files[url.standardizedFileURL.path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }
}

/// A cheap fingerprint of a set of files (count, total size, newest modification), used to skip
/// re-parsing logs that have not changed since the last refresh.
public struct FilesSignature: Equatable, Sendable {
    public var count: Int
    public var totalSize: Int
    public var newestModification: Date?

    public init(count: Int, totalSize: Int, newestModification: Date?) {
        self.count = count
        self.totalSize = totalSize
        self.newestModification = newestModification
    }

    public static func of(_ urls: [URL]) -> FilesSignature {
        var size = 0
        var newest: Date?
        for url in urls {
            // stat each time; URL resource values are cached per URL instance and would go stale.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            size += (attributes[.size] as? Int) ?? 0
            if let modified = attributes[.modificationDate] as? Date, modified > (newest ?? .distantPast) { newest = modified }
        }
        return FilesSignature(count: urls.count, totalSize: size, newestModification: newest)
    }
}
