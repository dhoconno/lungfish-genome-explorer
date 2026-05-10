import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

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

    func testMigrateSynthesizesLegacyBrowserSummaryWithBackupAndProvenance() async throws {
        let projectURL = try makeProject()
        let bundleURL = try makeLegacyReferenceBundleWithoutBrowserSummary(named: "LegacySummary", under: projectURL)
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try #"{"run":"creation-provenance","outputs":["payload"]}"#
            .write(to: provenanceURL, atomically: true, encoding: .utf8)
        let originalManifest = try Data(contentsOf: manifestURL)
        let originalProvenance = try Data(contentsOf: provenanceURL)

        let command = try ProjectCommand.MigrateSubcommand.parse([
            projectURL.path,
            "--quiet",
        ])
        try await command.run()

        let migratedManifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(migratedManifest.formatVersion, "1.0")
        XCTAssertEqual(migratedManifest.browserSummary?.schemaVersion, 1)
        XCTAssertEqual(migratedManifest.browserSummary?.sequences.map(\.name), ["chr1"])
        XCTAssertEqual(migratedManifest.browserSummary?.aggregate.annotationTrackCount, 0)
        XCTAssertNotEqual(try Data(contentsOf: manifestURL), originalManifest)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), originalProvenance)

        let migrationDirectory = bundleURL.appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("migrations", isDirectory: true)
        let migrationFiles = try FileManager.default.contentsOfDirectory(
            at: migrationDirectory,
            includingPropertiesForKeys: nil
        )
        let backupURL = try XCTUnwrap(migrationFiles.first { $0.lastPathComponent.hasSuffix(".manifest.json.backup") })
        let migrationProvenanceURL = try XCTUnwrap(migrationFiles.first { $0.lastPathComponent.hasSuffix(".project-migrate-provenance.json") })
        XCTAssertEqual(try Data(contentsOf: backupURL), originalManifest)

        let provenance = try jsonObject(at: migrationProvenanceURL)
        XCTAssertEqual(provenance["name"] as? String, "lungfish project migrate browser-summary")
        XCTAssertEqual(provenance["status"] as? String, "completed")
        let parameters = try XCTUnwrap(provenance["parameters"] as? [String: Any])
        XCTAssertEqual((parameters["dryRun"] as? [String: Any])?["value"] as? Bool, false)
        XCTAssertEqual((parameters["sourceManifest"] as? [String: Any])?["value"] as? String, manifestURL.path)
        XCTAssertEqual((parameters["targetManifest"] as? [String: Any])?["value"] as? String, manifestURL.path)

        let steps = try XCTUnwrap(provenance["steps"] as? [[String: Any]])
        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(step["toolName"] as? String, "lungfish project migrate")
        XCTAssertEqual(step["exitCode"] as? Int, 0)
        XCTAssertGreaterThan(step["wallTime"] as? Double ?? -1, 0)
        XCTAssertEqual(step["command"] as? [String], ["lungfish", "project", "migrate", projectURL.path])

        let inputs = try XCTUnwrap(step["inputs"] as? [[String: Any]])
        XCTAssertTrue(inputs.contains { $0["path"] as? String == manifestURL.path && $0["sha256"] != nil && $0["sizeBytes"] != nil })
        let outputs = try XCTUnwrap(step["outputs"] as? [[String: Any]])
        XCTAssertTrue(outputs.contains { $0["path"] as? String == manifestURL.path && $0["sha256"] != nil && $0["sizeBytes"] != nil })
        XCTAssertTrue(outputs.contains {
            guard let path = $0["path"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL == backupURL.standardizedFileURL
                && $0["sha256"] != nil
                && $0["sizeBytes"] != nil
        })
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

    private func makeLegacyReferenceBundleWithoutBrowserSummary(
        named name: String,
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
            formatVersion: "1.0",
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent(BundleManifest.filename), options: .atomic)
        let rawJSON = try String(contentsOf: bundleURL.appendingPathComponent(BundleManifest.filename), encoding: .utf8)
        XCTAssertFalse(rawJSON.contains("browser_summary"))
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

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func currentUserName() -> String {
        NSUserName().isEmpty ? (ProcessInfo.processInfo.environment["USER"] ?? "unknown") : NSUserName()
    }
}
