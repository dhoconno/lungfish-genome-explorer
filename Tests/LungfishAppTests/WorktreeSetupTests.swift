import Foundation
import Testing

@Suite("Worktree Setup")
struct WorktreeSetupTests {

    @Test("Xcode GUI builds hydrate worktree resources before building")
    func xcodeGUIBuildsHydrateWorktreeResourcesBeforeBuilding() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Lungfish.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        #expect(project.contains("Hydrate worktree resources"))
        #expect(project.contains("scripts/setup-worktree.sh"))
        #expect(project.contains("${SRCROOT}"))
    }

    @Test("setup-worktree copies ignored dylibs and links ignored database payloads")
    func setupWorktreeCopiesIgnoredDylibsAndLinksIgnoredDatabasePayloads() throws {
        let repositoryRoot = Self.repositoryRoot()
        let scriptURL = repositoryRoot.appendingPathComponent("scripts/setup-worktree.sh")
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try Self.initializeGitRepo(at: sourceRoot)
        try """
        *.dylib
        Sources/LungfishWorkflow/Resources/Databases/**/*.db
        Sources/LungfishWorkflow/Resources/Databases/**/*.db.*
        """.write(
            to: sourceRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let sourceLibURL = sourceRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/jre/lib/libjli.dylib")
        try FileManager.default.createDirectory(
            at: sourceLibURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "synthetic-dylib".write(to: sourceLibURL, atomically: true, encoding: .utf8)

        let sourceDBURL = sourceRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/human-scrubber/human_filter.db.20250916v2")
        try FileManager.default.createDirectory(
            at: sourceDBURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "db".write(to: sourceDBURL, atomically: true, encoding: .utf8)

        let result = try Self.runScript(
            scriptURL,
            arguments: ["--source-root", sourceRoot.path, targetRoot.path]
        )

        #expect(result.status == 0, "script failed: \(result.stderr)")

        let targetLibURL = targetRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/jre/lib/libjli.dylib")
        let targetDBURL = targetRoot
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/human-scrubber/human_filter.db.20250916v2")

        #expect(FileManager.default.fileExists(atPath: targetLibURL.path))
        #expect(FileManager.default.fileExists(atPath: targetDBURL.path))
        #expect(Self.symbolicLinkDestination(at: targetLibURL) == nil)
        #expect(Self.symbolicLinkDestination(at: targetDBURL) == sourceDBURL.path)
        #expect(try Data(contentsOf: targetLibURL) == Data(contentsOf: sourceLibURL))
        #expect(result.stdout.contains("Copied 1 runtime file(s)"))
        #expect(result.stdout.contains("Linked 1 runtime file(s)"))
    }

    private static func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let package = candidate.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: package.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        fatalError("Cannot locate repository root from \(#filePath)")
    }

    private static func initializeGitRepo(at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", root.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "git init failed: \(stderrString)")
    }

    private static func runScript(_ scriptURL: URL, arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ScriptResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func symbolicLinkDestination(at url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
