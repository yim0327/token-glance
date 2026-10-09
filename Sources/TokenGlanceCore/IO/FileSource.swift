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
