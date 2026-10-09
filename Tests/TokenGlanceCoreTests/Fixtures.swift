import Foundation
@testable import TokenGlanceCore

/// Loads files from `Tests/Fixtures`, located relative to this source file.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TokenGlanceCoreTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// `T0` used by all fixtures: 2026-10-08T01:00:00Z.
    static let t0 = Date(timeIntervalSince1970: 1_791_421_200)

    /// An in-memory file tree: fixture name -> virtual path under `root`.
    static func source(root: String, _ layout: [String: String]) throws -> InMemoryFileSource {
        var files: [String: Data] = [:]
        for (virtualPath, fixture) in layout {
            files[root + "/" + virtualPath] = try data(fixture)
        }
        return InMemoryFileSource(files: files)
    }
}
