import Foundation

enum GzipTestHelper {
    static func writeGzip(_ content: String, to gzipURL: URL) throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gzip-source-\(UUID().uuidString).txt")
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", sourceURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let compressed = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? "gzip failed"
            throw NSError(
                domain: "GzipTestHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        try compressed.write(to: gzipURL)
    }

    static func runningGzipProcessCount(matching path: String) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? "ps failed"
            throw NSError(
                domain: "GzipTestHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .filter { line in
                line.contains("/usr/bin/gzip")
                    && line.contains("-dc")
                    && line.contains(path)
            }
            .count
    }

    static func terminateGzipProcesses(matching path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "/usr/bin/gzip -dc \(path)"]
        try? process.run()
        process.waitUntilExit()
    }
}
