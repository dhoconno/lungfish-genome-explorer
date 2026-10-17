// BAMImportHelperRoutePinTests.swift - Pins the bundle and the record the BAM helper writes at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1 (K4 p12). The Import Center's BAM import launches the app executable in
// `--bam-import-helper` mode (`BAMImportHelper`), which calls `BAMImportService.importBAM` with the file's
// name and the default `sortAndIndex` materialization. This case runs that call on the real samtools and
// pins the three things the route to `import bam` must keep or declare as differences: the track the
// bundle's manifest gains, the files it writes, and the record, whose command still names the helper flag
// (a run of `import bam` writes the CLI's own command, a difference the parity class declares).

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class BAMImportHelperRoutePinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bam-helper-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheHelperImportAttachesOneTrackNamedForTheFileAndRecordsTheHelperCommand() async throws {
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
            name: fixtureBAM.lastPathComponent
        )

        // The track.
        XCTAssertTrue(result.wasSorted, "the default materialization sorts into the bundle")
        XCTAssertTrue(result.indexWasCreated, "and indexes the copy")
        XCTAssertGreaterThan(result.mappedReads, 0)
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.alignments.map(\.name), [fixtureBAM.lastPathComponent])
        XCTAssertEqual(manifest.alignments.first?.id, result.trackInfo.id)
        XCTAssertEqual(manifest.alignments.first?.format, .bam)

        // The files.
        let trackBAM = bundleURL.appendingPathComponent(result.trackInfo.sourcePath)
        let trackBAI = bundleURL.appendingPathComponent(result.trackInfo.indexPath)
        XCTAssertTrue(trackBAM.path.hasPrefix(bundleURL.appendingPathComponent("alignments").path), "the copy lives in alignments/")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackBAM.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackBAI.path))

        // The record. Its command is the helper's, which `lungfish-cli` cannot run.
        let sidecars = try FileManager.default.subpathsOfDirectory(atPath: bundleURL.path)
            .filter { $0.hasSuffix(".json") && $0.lowercased().contains("provenance") }
        XCTAssertEqual(sidecars.count, 1, "one import record: \(sidecars)")
        let sidecar = bundleURL.appendingPathComponent(try XCTUnwrap(sidecars.first))
        let data = PortablePath.resolveJSON(try Data(contentsOf: sidecar), forFileAt: sidecar)
        let run = try ProvenanceEnvelopeReader.decodeCanonical(data).legacyWorkflowRun()
        XCTAssertEqual(run.status, .completed)
        let commands = run.steps.map(\.command)
        XCTAssertTrue(
            commands.contains { $0.contains("--bam-import-helper") && $0.contains("--bam-path") && $0.contains("--bundle-path") },
            "the record names the helper flag: \(commands)"
        )
        XCTAssertTrue(
            commands.contains { $0.contains("--name") && $0.contains(fixtureBAM.lastPathComponent) },
            "and the track name the helper was given: \(commands)"
        )
    }
}
