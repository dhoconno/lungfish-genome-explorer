import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerToolPortableLauncherTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Primer launcher tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testPreparedLaunchersUseMovedEnvironmentPythonAndPreservedEntrypoint() throws {
        for toolID in ["olivar", "varvamp", "primalscheme3"] {
            let sourceRoot = temporaryRoot.appendingPathComponent("source root \(toolID)", isDirectory: true)
            let sourceEnvironment = sourceRoot.appendingPathComponent("envs/\(toolID)", isDirectory: true)
            let logURL = temporaryRoot.appendingPathComponent("\(toolID)-argv.log")
            try makeFixture(toolID: toolID, environmentURL: sourceEnvironment, logURL: logURL)

            try PrimerToolPortableLauncher.prepare(toolID: toolID, environmentURL: sourceEnvironment)
            try PrimerToolPortableLauncher.prepare(toolID: toolID, environmentURL: sourceEnvironment)
            XCTAssertNoThrow(try PrimerToolPortableLauncher.validate(toolID: toolID, environmentURL: sourceEnvironment))

            let movedRoot = temporaryRoot.appendingPathComponent("moved root \(toolID)", isDirectory: true)
            try FileManager.default.moveItem(at: sourceRoot, to: movedRoot)
            let movedEnvironment = movedRoot.appendingPathComponent("envs/\(toolID)", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEnvironment.path))
            XCTAssertEqual(try run(movedEnvironment.appendingPathComponent("bin/\(toolID)"), ["--help", "argument with spaces"]), 0)

            let fields = try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields[0], movedEnvironment.appendingPathComponent("bin/python").path)
            XCTAssertEqual(fields[1], movedEnvironment.appendingPathComponent("share/lungfish/managed-tools/primer-launchers/\(toolID)-upstream.py").path)
            XCTAssertEqual(Array(fields[2...3]), ["--help", "argument with spaces"])
            XCTAssertEqual(fields[4], toolID == "olivar" ? movedEnvironment.appendingPathComponent("libexec/mafft").path : "")
            XCTAssertEqual(
                fields[5],
                movedEnvironment.appendingPathComponent("bin/lungfish-primer-child").path
            )
            XCTAssertNoThrow(try PrimerToolPortableLauncher.validate(toolID: toolID, environmentURL: movedEnvironment))
        }
    }

    func testCorruptLauncherIsRejected() throws {
        let environment = temporaryRoot.appendingPathComponent("envs/varvamp", isDirectory: true)
        try makeFixture(
            toolID: "varvamp",
            environmentURL: environment,
            logURL: temporaryRoot.appendingPathComponent("varvamp.log")
        )
        try PrimerToolPortableLauncher.prepare(toolID: "varvamp", environmentURL: environment)
        try "#!/bin/sh\nexit 0\n".write(
            to: environment.appendingPathComponent("bin/varvamp"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try PrimerToolPortableLauncher.validate(toolID: "varvamp", environmentURL: environment)
        )
    }

    func testArchivePermissionNormalizationPreservesValidatedLauncherIdentity() throws {
        let environment = temporaryRoot.appendingPathComponent("envs/varvamp", isDirectory: true)
        try makeFixture(
            toolID: "varvamp",
            environmentURL: environment,
            logURL: temporaryRoot.appendingPathComponent("varvamp-permissions.log")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775],
            ofItemAtPath: environment.appendingPathComponent("bin/varvamp").path
        )
        try PrimerToolPortableLauncher.prepare(toolID: "varvamp", environmentURL: environment)
        let artifacts = try PrimerToolPortableLauncher.artifacts(
            toolID: "varvamp", environmentURL: environment)
        for artifact in artifacts where !artifact.relativePath.hasSuffix("-launcher.json") {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: environment.appendingPathComponent(artifact.relativePath).path
            )
        }

        XCTAssertNoThrow(
            try PrimerToolPortableLauncher.validate(
                toolID: "varvamp", environmentURL: environment)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: environment.appendingPathComponent("bin/varvamp").path
        )
        XCTAssertThrowsError(
            try PrimerToolPortableLauncher.validate(
                toolID: "varvamp", environmentURL: environment)
        )
    }

    func testUnknownToolDoesNotMutateEnvironment() throws {
        let environment = temporaryRoot.appendingPathComponent("envs/unknown", isDirectory: true)
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try PrimerToolPortableLauncher.prepare(toolID: "unknown", environmentURL: environment)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: environment.path), [])
    }

    private func makeFixture(toolID: String, environmentURL: URL, logURL: URL) throws {
        let bin = environmentURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        let pythonScript = """
        #!/bin/sh
        {
          printf '%s\\n' "$0"
          for value in "$@"; do printf '%s\\n' "$value"; done
          printf '%s\\n' "${MAFFT_BINARIES-}"
          command -v lungfish-primer-child
        } > '\(logURL.path.replacingOccurrences(of: "'", with: "'\\''"))'
        """
        try pythonScript.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let entrypoint = bin.appendingPathComponent(toolID)
        try "#!/old/prefix/bin/python\nprint('upstream')\n".write(
            to: entrypoint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)
        let child = bin.appendingPathComponent("lungfish-primer-child")
        try "#!/bin/sh\nexit 0\n".write(
            to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
        if toolID == "olivar" {
            try FileManager.default.createDirectory(
                at: environmentURL.appendingPathComponent("libexec/mafft", isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
