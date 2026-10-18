// BAMImportHelperRouteConformanceTests.swift - Pins the bundle and the record the BAM import service writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1 (K4 p12). The Import Center's BAM import launched the app executable in
// `--bam-import-helper` mode (`BAMImportHelper`), which calls `BAMImportService.importBAM` with the file's
// name and the default `sortAndIndex` materialization. These cases run that call on the real samtools and
// pin what the route to `import bam` must keep or declare as differences: the track the bundle's manifest
// gains, the files it writes, and the record, whose command names the `import bam` leaf since 2.12 lane 12.06 (the
// helper flag before) unless the caller passes
// the command the record names (`provenanceCommand`). `import bam` passes its own command, which
// `BAMImportCLIGUIParityReplayTests` declares. The class needs the real samtools, so its name ends in
// Conformance and it never runs in the unit tier.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class BAMImportHelperRouteConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bam-helper-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheHelperImportAttachesOneTrackNamedForTheFileAndRecordsTheImportBamCommand() async throws {
        let imported = try await importFixture(provenanceCommand: nil)
        let result = imported.result
        let bundleURL = imported.bundleURL
        let fileName = imported.fixtureBAM.lastPathComponent

        // The track.
        XCTAssertTrue(result.wasSorted, "the default materialization sorts into the bundle")
        XCTAssertTrue(result.indexWasCreated, "and indexes the copy")
        XCTAssertGreaterThan(result.mappedReads, 0)
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.alignments.map(\.name), [fileName])
        XCTAssertEqual(manifest.alignments.first?.id, result.trackInfo.id)
        XCTAssertEqual(manifest.alignments.first?.format, .bam)

        // The files.
        let trackBAM = bundleURL.appendingPathComponent(result.trackInfo.sourcePath)
        let trackBAI = bundleURL.appendingPathComponent(result.trackInfo.indexPath)
        XCTAssertTrue(trackBAM.path.hasPrefix(bundleURL.appendingPathComponent("alignments").path), "the copy lives in alignments/")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackBAM.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackBAI.path))

        // The record. Since 2.12 lane 12.06 a call that passes no command records the `import bam` leaf, which
        // `lungfish-cli` runs, where it named the helper flag before.
        let record = try recordedImport(in: bundleURL)
        XCTAssertTrue(record.completed)
        XCTAssertTrue(
            record.commands.contains { $0.contains("import") && $0.contains("bam") && $0.contains("--output-dir") },
            "the record names the import bam leaf: \(record.commands)"
        )
        XCTAssertFalse(record.commands.contains { $0.contains("--bam-import-helper") }, "\(record.commands)")
        XCTAssertTrue(
            record.commands.contains { $0.contains("--name") && $0.contains(fileName) },
            "and the track name the helper was given: \(record.commands)"
        )
    }

    func testAGivenProvenanceCommandIsTheCommandTheRecordNames() async throws {
        let argv = ["lungfish-cli", "import", "bam", "/in/sample.bam", "--output-dir", "/out/Reference.lungfishref", "--name", "sample.bam"]
        let imported = try await importFixture(provenanceCommand: argv)

        let record = try recordedImport(in: imported.bundleURL)
        XCTAssertTrue(record.completed)
        XCTAssertTrue(
            record.commands.contains { $0.contains("lungfish-cli") && $0.contains("import") && $0.contains("bam") && $0.contains("--output-dir") },
            "the record names the command the caller gave: \(record.commands)"
        )
        XCTAssertFalse(
            record.commands.contains { $0.contains("--bam-import-helper") },
            "and no longer the helper flag: \(record.commands)"
        )
        let manifest = try BundleManifest.load(from: imported.bundleURL)
        XCTAssertEqual(manifest.alignments.map(\.name), [imported.fixtureBAM.lastPathComponent], "the track is the same")
    }

    // MARK: - Fixture

    private struct Imported {
        let bundleURL: URL
        let fixtureBAM: URL
        let result: BAMImportService.ImportResult
    }

    /// Imports the sarscov2 BAM into a fresh bundle the way the helper did, with the file's name as the track name.
    private func importFixture(provenanceCommand: [String]?) async throws -> Imported {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            throw XCTSkip("samtools is not installed in the managed conda root")
        }
        let fixtureBAM = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: fixtureBAM.path) else {
            throw XCTSkip("sarscov2 BAM fixture missing")
        }
        let bundleURL = root.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundleURL)

        // The helper passes the file's name as the track name (AppDelegate.performBAMImport).
        let result = try await BAMImportService.importBAM(
            bamURL: fixtureBAM,
            bundleURL: bundleURL,
            name: fixtureBAM.lastPathComponent,
            provenanceCommand: provenanceCommand
        )
        return Imported(bundleURL: bundleURL, fixtureBAM: fixtureBAM, result: result)
    }

    /// The one import record in the bundle: whether it completed and the command of each step.
    private func recordedImport(in bundleURL: URL) throws -> (completed: Bool, commands: [[String]]) {
        let sidecars = try FileManager.default.subpathsOfDirectory(atPath: bundleURL.path)
            .filter { $0.hasSuffix(".json") && $0.lowercased().contains("provenance") }
        XCTAssertEqual(sidecars.count, 1, "one import record: \(sidecars)")
        let sidecar = bundleURL.appendingPathComponent(try XCTUnwrap(sidecars.first))
        let data = PortablePath.resolveJSON(try Data(contentsOf: sidecar), forFileAt: sidecar)
        let run = try ProvenanceEnvelopeReader.decodeCanonical(data).legacyWorkflowRun()
        return (run.status == .completed, run.steps.map(\.command))
    }
}
