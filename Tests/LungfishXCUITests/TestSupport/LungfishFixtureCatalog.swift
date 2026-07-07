import Foundation

enum LungfishFixtureCatalog {
    static let repoRoot: URL = {
        fixturesRoot.deletingLastPathComponent().deletingLastPathComponent()
    }()

    static let fixturesRoot: URL = {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent("Tests/Fixtures", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }

        fatalError("Cannot locate Tests/Fixtures directory.")
    }()

    static let sarscov2 = fixturesRoot.appendingPathComponent("sarscov2", isDirectory: true)
    static let analyses = fixturesRoot.appendingPathComponent("analyses", isDirectory: true)
    static let assemblyUI = fixturesRoot.appendingPathComponent("assembly-ui", isDirectory: true)

    static var cliBinaryURL: URL? {
        var candidates: [URL] = []
        if let environmentPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"], !environmentPath.isEmpty {
            candidates.append(URL(fileURLWithPath: environmentPath))
        }
        if let environmentPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_BINARY"], !environmentPath.isEmpty {
            candidates.append(URL(fileURLWithPath: environmentPath))
        }
        if let binPath = swiftPMBinPath(packageRoot: repoRoot) {
            candidates.append(binPath.appendingPathComponent("lungfish-cli"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func swiftPMBinPath(packageRoot: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--package-path", packageRoot.path,
            "--show-bin-path",
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let path = stdoutText
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch {
            return nil
        }
    }
}
