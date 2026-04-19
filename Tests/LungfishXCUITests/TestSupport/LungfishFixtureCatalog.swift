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
}
