import Foundation

public enum AtomicFile {
    /// Writes `data` to a temporary file in the destination directory, then `rename(2)`s it into
    /// place, so readers never observe a partially written file. Creates missing directories.
    public static func write(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        do {
            try data.write(to: temporary)
            if let permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
