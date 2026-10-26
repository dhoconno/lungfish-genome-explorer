import Foundation

enum LungfishFixtureCatalog {
    static let repoRoot: URL = {
        fixturesRoot.deletingLastPathComponent().deletingLastPathComponent()
    }()

    static let fixturesRoot: URL = {
        let fileManager = FileManager.default
        // The release smoke gate copies the fixtures it needs out of the checkout, since the
        // sandboxed runner would need a privacy grant to read a checkout under ~/Documents.
        if let copied = ProcessInfo.processInfo.environment["LUNGFISH_RELEASE_SMOKE_FIXTURES"], !copied.isEmpty {
            return URL(fileURLWithPath: copied, isDirectory: true)
        }
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
        let environment = ProcessInfo.processInfo.environment
        for key in ["LUNGFISH_TEST_CLI", "LUNGFISH_CLI", "LUNGFISH_CLI_PATH", "LUNGFISH_CLI_BINARY"] {
            guard let environmentPath = environment[key], !environmentPath.isEmpty else {
                continue
            }
            let binary = URL(fileURLWithPath: environmentPath)
            return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
        }
        return nil
    }
}
