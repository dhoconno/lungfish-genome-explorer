import Foundation

enum FASTQAtomicFileWriter {
    static func write(to url: URL, body: (FileHandle) throws -> Void) throws {
        let fm = FileManager.default
        let tmpURL = try createUniqueTemporaryFile(for: url, fileManager: fm)
        let legacyTmpURL = url.appendingPathExtension("tmp")
        let handle = try FileHandle(forWritingTo: tmpURL)
        do {
            try body(handle)
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmpURL)
            throw error
        }
        if rename(tmpURL.path, url.path) != 0 {
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmpURL, to: url)
        }
        if legacyTmpURL.standardizedFileURL != tmpURL.standardizedFileURL {
            try? fm.removeItem(at: legacyTmpURL)
        }
    }

    private static func createUniqueTemporaryFile(for url: URL, fileManager fm: FileManager) throws -> URL {
        let directory = url.deletingLastPathComponent()
        for _ in 0..<10 {
            let tmpURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            if fm.createFile(atPath: tmpURL.path, contents: nil) {
                return tmpURL
            }
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}
