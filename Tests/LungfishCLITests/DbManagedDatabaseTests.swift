// DbManagedDatabaseTests.swift - `conda db info` and `conda db update` for a database the lock pins as one hosted file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishCLI

/// The command layer of the pinned ribokmers index (CHTC lane C2-RIBOPIN, review fixes 3 and 4). The registry tests
/// call the registry, so they do not see the `--yes` gate, the run record, the exit codes, the events or the cancel
/// path. Each test here runs `execute(eventsOn:quiet:emit:)` against a registry in a scratch folder whose downloader
/// copies a local file, so none touches the network or the user's databases.
final class DbManagedDatabaseTests: XCTestCase {
    private static let databaseID = "deacon-ribokmers"
    private static let buildArgv = [
        "deacon", "index", "build", "-k", "31", "-w", "15", "ribokmers.fa.gz", "-o", "ribokmers.k31w15.idx", "-t", "1",
    ]

    private var root: URL!
    private var preferencesSuite: TestDefaultsSuite!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "db-managed-database")
        CondaCommand.storageRootOverride = root
        preferencesSuite = makeTestDefaultsSuite(prefix: "DbManagedDatabaseTests")
    }

    override func tearDownWithError() throws {
        CondaCommand.storageRootOverride = nil
        DbCommand.managedRegistryOverride = nil
        DbCommand.DbUpdateSubcommand.registryOverride = nil
        TestTempDirectory.cleanup(root)
    }

    // MARK: db info

    /// An index that differs from the pinned build is reported as differing, with the installed digest and the lock's.
    func testInfoReportsADifferingManagedIndexWithBothDigests() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        _ = try await installEarlier(hostBuilt)
        DbCommand.managedRegistryOverride = try registry(pinning: pinned)

        let text = try await DbCommand.DbInfoSubcommand.managedStatusText(
            Self.databaseID, formatter: TerminalFormatter(useColors: false)
        )

        XCTAssertTrue(text.contains("differs from the pinned build"), text)
        XCTAssertTrue(text.contains(Self.sha256(hostBuilt)), text)
        XCTAssertTrue(text.contains(Self.sha256(pinned)), text)
    }

    // MARK: db update

    /// An update replaces a differing index with the pinned file, exits 0 and records the run with the digests before
    /// and after, the lock's digest and the outcome.
    func testUpdateReplacesADifferingIndexExitsZeroAndRecordsTheRun() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let installed = try await installEarlier(hostBuilt)
        let requests = ManagedDownloadLog()
        DbCommand.managedRegistryOverride = try registry(pinning: pinned, requests: requests)

        let run = await runUpdate()

        XCTAssertEqual(run.exit, 0)
        XCTAssertEqual(try Data(contentsOf: installed), pinned)
        XCTAssertEqual(requests.values.count, 1)
        guard case .complete(let outputs, let message)? = run.events.last else { return XCTFail("ends with complete: \(run.events)") }
        XCTAssertEqual(message, "Updated deacon-ribokmers")
        XCTAssertEqual(outputs.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, [installed.standardizedFileURL.path])
        let record = try latestRecord()
        XCTAssertEqual(record.workflowName, "conda-database-update")
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.options.explicit["outcome"], .string("replaced"))
        XCTAssertEqual(record.options.explicit["installedSHA256Before"], .string(Self.sha256(hostBuilt)))
        XCTAssertEqual(record.options.explicit["installedSHA256After"], .string(Self.sha256(pinned)))
        XCTAssertEqual(record.options.explicit["pinnedSHA256"], .string(Self.sha256(pinned)))
        XCTAssertEqual(record.steps.first?.toolVersion, "bbmap-ribokmers-k31w15", "The step names the pinned version")
    }

    /// An index that already is the pinned file is left alone, nothing is downloaded and the record says so.
    func testUpdateLeavesAMatchingIndexAloneAndDownloadsNothing() async throws {
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let installed = try await installEarlier(pinned)
        let requests = ManagedDownloadLog()
        DbCommand.managedRegistryOverride = try registry(pinning: pinned, requests: requests)

        let run = await runUpdate()

        XCTAssertEqual(run.exit, 0)
        XCTAssertEqual(requests.values, [], "A matching index needs no download")
        XCTAssertEqual(try Data(contentsOf: installed), pinned)
        let record = try latestRecord()
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.options.explicit["outcome"], .string("already matched"))
        XCTAssertEqual(record.options.explicit["installedSHA256Before"], .string(Self.sha256(pinned)))
        XCTAssertEqual(record.options.explicit["installedSHA256After"], .string(Self.sha256(pinned)))
        XCTAssertEqual(record.options.explicit["pinnedSHA256"], .string(Self.sha256(pinned)))
    }

    /// A download that is not the pinned file is refused, the command exits 1 and the installed index stays.
    func testUpdateWithAWrongDownloadExitsOneAndKeepsTheIndex() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let installed = try await installEarlier(hostBuilt)
        DbCommand.managedRegistryOverride = try registry(pinning: pinned, serving: Data("PINNED-RIBOKMERS-INDEX\n".utf8))

        let run = await runUpdate()

        XCTAssertEqual(run.exit, CLIExitCode.failure.rawValue)
        XCTAssertEqual(try Data(contentsOf: installed), hostBuilt, "A refused update leaves the installed index")
        let record = try latestRecord()
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue((record.stderr ?? "").contains("the bundled lock pins \(Self.sha256(pinned))"), "\(record.stderr ?? "nil")")
        XCTAssertEqual(record.options.explicit["outcome"], .string("refused"))
        XCTAssertEqual(record.options.explicit["installedSHA256Before"], .string(Self.sha256(hostBuilt)))
        XCTAssertEqual(record.options.explicit["installedSHA256After"], .string(Self.sha256(hostBuilt)))
        guard case .failed(let message, _)? = run.events.last else { return XCTFail("ends with failed: \(run.events)") }
        XCTAssertTrue(message.contains("Failed 'deacon-ribokmers'"), message)
    }

    /// A cancelled update records the run as cancelled, exits 125 and keeps the installed index. The app's Cancel is
    /// SIGTERM, which the command turns into a cancel of the registry's task.
    func testUpdateCancelledExitsCancelledAndKeepsTheIndex() async throws {
        let hostBuilt = Data("host-built-ribokmers-index\n".utf8)
        let pinned = Data("pinned-ribokmers-index\n".utf8)
        let installed = try await installEarlier(hostBuilt)
        DbCommand.managedRegistryOverride = try registry(pinning: pinned, downloader: { _, _ in throw CancellationError() })

        let run = await runUpdate()

        XCTAssertEqual(run.exit, CLIExitCode.cancelled.rawValue)
        XCTAssertEqual(try Data(contentsOf: installed), hostBuilt, "A cancelled update leaves the installed index")
        let record = try latestRecord()
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.options.explicit["outcome"], .string("cancelled"))
        XCTAssertEqual(record.options.explicit["installedSHA256After"], .string(Self.sha256(hostBuilt)))
        guard case .failed(let message, _)? = run.events.last else { return XCTFail("ends with failed: \(run.events)") }
        XCTAssertEqual(message, "Update cancelled. The installed database was left as it was.")
    }

    // MARK: - Helpers

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func serve(_ data: Data, as name: String) throws -> URL {
        let directory = root.appendingPathComponent("served", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The lock entry of a hosted ribokmers build that pins `payload` and names `url` as its download.
    private func spec(pinning payload: Data, url: URL) throws -> DatabaseSpec {
        let json: [String: Any] = [
            "id": Self.databaseID, "sourcePolicy": "pinnedArchive", "tool": "deacon",
            "displayName": "Ribosomal RNA Removal Data", "version": "bbmap-ribokmers-k31w15",
            "filename": "ribokmers.k31w15.idx", "indexFormat": 3, "url": url.absoluteString,
            "sizeBytes": payload.count, "sha256": Self.sha256(payload),
            "build": [
                "tool": "deacon", "toolVersion": "0.16.0", "sourceUrl": "https://bbmap.org/resources/ribokmers.fa.gz",
                "sourceSha256": String(repeating: "a", count: 64), "sourceSizeBytes": 12, "argv": Self.buildArgv,
            ] as [String: Any],
        ]
        return try JSONDecoder().decode(DatabaseSpec.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A registry in the scratch folder whose lock pins `pinned`. Its download seam copies a local file holding
    /// `served` (the pinned bytes unless a test says otherwise) and logs the URL, or is `downloader` when given.
    private func registry(
        pinning pinned: Data,
        serving served: Data? = nil,
        requests: ManagedDownloadLog? = nil,
        downloader: ManagedDatabaseDownloader? = nil
    ) throws -> DatabaseRegistry {
        let lock = try spec(pinning: pinned, url: try serve(served ?? pinned, as: "served-\(UUID().uuidString).idx"))
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        let fileDownloader: ManagedDatabaseDownloader = { url, progress in
            requests?.append(url)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let output = downloads.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: output)
            let size = Int64(try Data(contentsOf: output).count)
            progress(1.0, size, size)
            return ManagedDatabaseDownloadResult(fileURL: output, wallTime: 0.125)
        }
        // No tool may run. At the base of fix 4 a run for `deacon-panhuman` reached the real deacon and fetched 3.2 GB.
        let toolRunner: ManagedDatabaseToolRunner = { _, _, _, _, _ in
            ManagedDatabaseToolResult(stdout: "", stderr: "no tool may run", exitCode: 1, wallTime: 0)
        }
        return DatabaseRegistry(
            bundledDatabasesRoot: root.appendingPathComponent("bundled-databases", isDirectory: true),
            userDatabasesRoot: root.appendingPathComponent("databases", isDirectory: true),
            managedDatabaseDownloader: downloader ?? fileDownloader,
            managedDatabaseToolRunner: toolRunner,
            managedDatabaseLockLookup: { $0 == Self.databaseID ? lock : nil },
            preferences: preferencesSuite.makeDefaults()
        )
    }

    /// Installs `payload` through a registry whose lock pins it, as an earlier build would have, and returns the file.
    private func installEarlier(_ payload: Data) async throws -> URL {
        try await registry(pinning: payload).installManagedDatabase(Self.databaseID, reinstall: true)
    }

    private func runUpdate(_ id: String = databaseID) async -> (exit: Int32, events: [CLIEvent]) {
        let lines = ManagedToolLeafFixtures.Lines()
        do {
            let command = try DbCommand.DbUpdateSubcommand.parse([id, "--format", "json", "--yes"])
            try await command.execute(eventsOn: true, quiet: true, emit: lines.append)
            return (0, lines.events)
        } catch let exit as ExitCode {
            return (exit.rawValue, lines.events)
        } catch {
            XCTFail("unexpected error \(error)")
            return (-1, lines.events)
        }
    }

    /// The record the run wrote under `<storage root>/provenance/databases`.
    private func latestRecord() throws -> ProvenanceEnvelope {
        let directory = ManagedToolLeaf.recordDirectory(storageRoot: root, folder: "databases")
        let names = ManagedToolLeaf.recordNames(storageRoot: root, folder: "databases").sorted()
        let name = try XCTUnwrap(names.last, "the run wrote no record")
        return try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: directory.appendingPathComponent(name)))
    }
}

/// The URLs a download seam was asked for, readable after the run.
private final class ManagedDownloadLog: Sendable {
    private let storage = Mutex<[URL]>([])
    func append(_ value: URL) { storage.withLock { $0.append(value) } }
    var values: [URL] { storage.withLock { $0 } }
}
