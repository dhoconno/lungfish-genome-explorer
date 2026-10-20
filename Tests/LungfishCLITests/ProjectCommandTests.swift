import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

final class ProjectCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testProjectCommandIsRegistered() {
        let names = LungfishCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("project"))
    }

    /// The clock seam of `project copy-item` (BIO ruling on T5, S1) stays a seam. A debug build reads the time
    /// from its variable and falls back to the clock for a text that does not parse, and a release build ignores
    /// the variable. The environment is a parameter, so the test sets nothing in its own process.
    func testCopiedAtReadsItsVariableOnlyInADebugBuild() {
        let variable = "LUNGFISH_TEST_COPIED_AT"
        let text = "2026-10-18T12:00:00Z"
        #if DEBUG
        XCTAssertEqual(
            ProjectCopyItemSubcommand.copiedAt(environment: [variable: text]),
            ISO8601DateFormatter().date(from: text)
        )
        let unparsed = ProjectCopyItemSubcommand.copiedAt(environment: [variable: "not a time"])
        XCTAssertLessThan(abs(unparsed.timeIntervalSinceNow), 5, "a text that does not parse falls back to the clock")
        #else
        let ignored = ProjectCopyItemSubcommand.copiedAt(environment: [variable: text])
        XCTAssertLessThan(abs(ignored.timeIntervalSinceNow), 5, "a release build ignores the variable")
        #endif
        XCTAssertEqual(ProjectCopyItemSubcommand.copiedAtVariable, variable)
    }

    func testLockCreatesMachineReadableRecord() async throws {
        let projectURL = try makeProject()

        let command = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--mode", "exclusive",
            "--quiet",
        ])
        try await command.run()

        let record = try loadLockRecord(from: projectURL)
        XCTAssertEqual(record["schemaVersion"] as? Int, 1)
        XCTAssertEqual(record["toolName"] as? String, "lungfish project lock")
        XCTAssertEqual(record["appVersion"] as? String, "lungfish-cli \(LungfishCLI.configuration.version)")
        XCTAssertEqual(record["projectPath"] as? String, projectURL.standardizedFileURL.path)
        XCTAssertEqual(record["mode"] as? String, "exclusive")
        XCTAssertEqual(record["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse((record["user"] as? String ?? "").isEmpty)
        XCTAssertFalse((record["host"] as? String ?? "").isEmpty)
        XCTAssertFalse((record["cwd"] as? String ?? "").isEmpty)
        XCTAssertFalse((record["createdAt"] as? String ?? "").isEmpty)
        XCTAssertFalse((record["processStartTime"] as? String ?? "").isEmpty)
    }

    func testLockRefusesActiveLockAndLeavesRecordUntouched() async throws {
        let projectURL = try makeProject()

        let firstLock = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        try await firstLock.run()
        let originalData = try Data(contentsOf: lockURL(for: projectURL))

        let secondLock = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])

        do {
            try await secondLock.run()
            XCTFail("Expected active lock to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Project is already locked"))
        }

        XCTAssertEqual(try Data(contentsOf: lockURL(for: projectURL)), originalData)
    }

    func testLockRefusesRemoteLockWithoutForce() async throws {
        let projectURL = try makeProject()
        try writeLockRecord(
            [
                "schemaVersion": 1,
                "toolName": "lungfish project lock",
                "appVersion": "lungfish-cli 0.0.0-test",
                "projectPath": projectURL.standardizedFileURL.path,
                "mode": "exclusive",
                "user": "remote-user",
                "host": "remote-host-\(UUID().uuidString)",
                "pid": 999_999_937,
                "processStartTime": "2000-01-01T00:00:00Z",
                "cwd": "/shared/project",
                "createdAt": "2000-01-01T00:00:00Z",
            ],
            to: projectURL
        )
        let originalData = try Data(contentsOf: lockURL(for: projectURL))

        let command = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])

        do {
            try await command.run()
            XCTFail("Expected remote lock to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Project is already locked"))
        }

        XCTAssertEqual(try Data(contentsOf: lockURL(for: projectURL)), originalData)
    }

    func testLockRefusesCorruptedLockWithoutForceAndLeavesFileUntouched() async throws {
        let projectURL = try makeProject()
        let lockURL = lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-json".write(to: lockURL, atomically: true, encoding: .utf8)
        let originalData = try Data(contentsOf: lockURL)

        let command = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])

        do {
            try await command.run()
            XCTFail("Expected corrupted lock to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Project lock file is corrupted"))
        }

        XCTAssertEqual(try Data(contentsOf: lockURL), originalData)
    }

    func testLockForceReplacesCorruptedLock() async throws {
        let projectURL = try makeProject()
        let lockURL = lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-json".write(to: lockURL, atomically: true, encoding: .utf8)

        let command = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--mode", "maintenance",
            "--force",
            "--quiet",
        ])
        try await command.run()

        let record = try loadLockRecord(from: projectURL)
        XCTAssertEqual(record["mode"] as? String, "maintenance")
        XCTAssertEqual(record["toolName"] as? String, "lungfish project lock")
    }

    func testLockReplacesStaleLocalLock() async throws {
        let projectURL = try makeProject()
        try writeLockRecord(
            [
                "schemaVersion": 1,
                "toolName": "lungfish project lock",
                "appVersion": "lungfish-cli 0.0.0-test",
                "projectPath": projectURL.standardizedFileURL.path,
                "mode": "exclusive",
                "user": currentUserName(),
                "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                "pid": 999_999_937,
                "processStartTime": "2000-01-01T00:00:00Z",
                "cwd": "/tmp/old-cwd",
                "createdAt": "2000-01-01T00:00:00Z",
            ],
            to: projectURL
        )

        let command = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--mode", "maintenance",
            "--quiet",
        ])
        try await command.run()

        let record = try loadLockRecord(from: projectURL)
        XCTAssertEqual(record["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(record["mode"] as? String, "maintenance")
        XCTAssertEqual(record["appVersion"] as? String, "lungfish-cli \(LungfishCLI.configuration.version)")
    }

    func testConcurrentStaleLockReplacementAllowsOnlyOneWinner() async throws {
        let projectURL = try makeProject()
        try writeLockRecord(
            [
                "schemaVersion": 1,
                "toolName": "lungfish project lock",
                "appVersion": "lungfish-cli 0.0.0-test",
                "projectPath": projectURL.standardizedFileURL.path,
                "mode": "exclusive",
                "user": currentUserName(),
                "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                "pid": 999_999_937,
                "processStartTime": "2000-01-01T00:00:00Z",
                "cwd": "/tmp/old-cwd",
                "createdAt": "2000-01-01T00:00:00Z",
            ],
            to: projectURL
        )

        let outcomes = await withTaskGroup(of: ProjectLockCommandOutcome.self) { group in
            for index in 0..<20 {
                let mode = "contender-\(index)"
                let path = projectURL.path
                group.addTask {
                    do {
                        let command = try ProjectCommand.LockSubcommand.parse([
                            path,
                            "--mode", mode,
                            "--quiet",
                        ])
                        try await command.run()
                        return .success(mode)
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            }

            var collected: [ProjectLockCommandOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let successes = outcomes.compactMap { outcome -> String? in
            if case .success(let mode) = outcome { return mode }
            return nil
        }
        XCTAssertEqual(successes.count, 1, "Expected exactly one winning lock command, got \(outcomes)")
        let record = try loadLockRecord(from: projectURL)
        XCTAssertEqual(record["mode"] as? String, successes.first)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ProjectLockManager.replacementLockURL(forLockAt: lockURL(for: projectURL)).path
            )
        )
    }

    func testUnlockRemovesOwnLock() async throws {
        let projectURL = try makeProject()

        let lock = try ProjectCommand.LockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        try await lock.run()

        let unlock = try ProjectCommand.UnlockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        try await unlock.run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(for: projectURL).path))
    }

    func testUnlockRemovesStaleLocalLockCreatedByEarlierCLIProcess() async throws {
        let projectURL = try makeProject()
        try writeLockRecord(
            [
                "schemaVersion": 1,
                "toolName": "lungfish project lock",
                "appVersion": "lungfish-cli 0.0.0-test",
                "projectPath": projectURL.standardizedFileURL.path,
                "mode": "exclusive",
                "user": currentUserName(),
                "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                "pid": 999_999_937,
                "processStartTime": "2000-01-01T00:00:00Z",
                "cwd": "/tmp/old-cli-process",
                "createdAt": "2000-01-01T00:00:00Z",
            ],
            to: projectURL
        )

        let unlock = try ProjectCommand.UnlockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        try await unlock.run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(for: projectURL).path))
    }

    func testUnlockRefusesCorruptedLockUnlessForced() async throws {
        let projectURL = try makeProject()
        let lockURL = lockURL(for: projectURL)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not-json".write(to: lockURL, atomically: true, encoding: .utf8)

        let unlock = try ProjectCommand.UnlockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        do {
            try await unlock.run()
            XCTFail("Expected unlock to refuse a corrupted lock")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Project lock file is corrupted"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))

        let forcedUnlock = try ProjectCommand.UnlockSubcommand.parse([
            projectURL.path,
            "--force",
            "--quiet",
        ])
        try await forcedUnlock.run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testUnlockRefusesForeignLockUnlessForced() async throws {
        let projectURL = try makeProject()
        try writeLockRecord(
            [
                "schemaVersion": 1,
                "toolName": "lungfish project lock",
                "appVersion": "lungfish-cli 0.0.0-test",
                "projectPath": projectURL.standardizedFileURL.path,
                "mode": "exclusive",
                "user": "different-user-\(UUID().uuidString)",
                "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "processStartTime": "2000-01-01T00:00:00Z",
                "cwd": "/tmp/foreign-cwd",
                "createdAt": "2000-01-01T00:00:00Z",
            ],
            to: projectURL
        )

        let unlock = try ProjectCommand.UnlockSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        do {
            try await unlock.run()
            XCTFail("Expected unlock to refuse a foreign lock")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Refusing to remove lock"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL(for: projectURL).path))

        let forcedUnlock = try ProjectCommand.UnlockSubcommand.parse([
            projectURL.path,
            "--force",
            "--quiet",
        ])
        try await forcedUnlock.run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(for: projectURL).path))
    }

    func testMigrateLeavesCurrentVersionBundleAndProvenanceUntouched() async throws {
        let projectURL = try makeProject()
        let bundleURL = try makeReferenceBundle(named: "Current", formatVersion: "1.0", under: projectURL)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try #"{"run":"existing-provenance","outputs":["payload"]}"#
            .write(to: provenanceURL, atomically: true, encoding: .utf8)
        let originalManifest = try Data(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename))
        let originalProvenance = try Data(contentsOf: provenanceURL)

        let command = try ProjectCommand.MigrateSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Current.lungfishref.v1.0").path))
        XCTAssertEqual(try Data(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename)), originalManifest)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), originalProvenance)
    }

    func testMigrateReportsUnsupportedLegacyVersionWithoutMutating() async throws {
        let projectURL = try makeProject()
        let bundleURL = try makeReferenceBundle(named: "Legacy", formatVersion: "0.9", under: projectURL)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try #"{"run":"legacy-provenance","outputs":["payload"]}"#
            .write(to: provenanceURL, atomically: true, encoding: .utf8)
        let originalManifest = try Data(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename))
        let originalProvenance = try Data(contentsOf: provenanceURL)

        let command = try ProjectCommand.MigrateSubcommand.parse([
            projectURL.path,
            "--dry-run",
            "--quiet",
        ])
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("Legacy.lungfishref.v0.9").path))
        XCTAssertEqual(try Data(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename)), originalManifest)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), originalProvenance)
    }

    func testMigrateStagesManifestAndWritesProvenanceBeforePublishing() throws {
        let source = try readRepositorySource(projectCommandSourceURL())
        let start = try XCTUnwrap(source.range(of: "private func migrateLegacyBrowserSummary"))
        let end = try XCTUnwrap(
            source.range(of: "\n    private func migrationInputRecords", range: start.upperBound..<source.endIndex)
        )
        let method = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(method.contains("migratedManifest.save(to: bundleURL)"))
        let provenanceWrite = try XCTUnwrap(method.range(of: "try writeMigrationProvenance"))
        let manifestPublish = try XCTUnwrap(method.range(of: "replaceItemAt"))
        XCTAssertTrue(
            provenanceWrite.lowerBound < manifestPublish.lowerBound,
            "Migration provenance must be durable before the final manifest is published."
        )
        // Review of M3, Fix 2. With a key set the record has `.signature.json` and `.pub` beside it, so the rollback
        // removes the record with its pair, and not the record alone.
        XCTAssertTrue(method.contains("try? ProvenancePublicationArtifacts.removeSidecarArtifacts(for: provenanceURL)"))
    }

    private func makeProject() throws -> URL {
        let projectURL = tempDir.appendingPathComponent("Shared.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    private func makeReferenceBundle(
        named name: String,
        formatVersion: String,
        under projectURL: URL
    ) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ">chr1\nACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "chr1\t4\t6\t4\t5\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            formatVersion: formatVersion,
            name: name,
            identifier: "org.lungfish.test.\(name.lowercased())",
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func lockURL(for projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("project.lock", isDirectory: false)
    }

    private func loadLockRecord(from projectURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: lockURL(for: projectURL))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeLockRecord(_ record: [String: Any], to projectURL: URL) throws {
        let lockURL = lockURL(for: projectURL)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: lockURL, options: .atomic)
    }

    private func projectCommandSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishCLI/Commands/ProjectCommand.swift")
    }

    private func currentUserName() -> String {
        NSUserName().isEmpty ? (ProcessInfo.processInfo.environment["USER"] ?? "unknown") : NSUserName()
    }
}

private enum ProjectLockCommandOutcome: Sendable, CustomStringConvertible {
    case success(String)
    case failure(String)

    var description: String {
        switch self {
        case .success(let mode):
            return "success(\(mode))"
        case .failure(let message):
            return "failure(\(message))"
        }
    }
}
