// BAMImportCallerRecordSpellingTests.swift - The command the records of the three in-process BAM imports name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.06 (A63-M3, BIO 4, QA 1). Three callers run `BAMImportService.importBAM` in process and
// pass no `provenanceCommand`. They are the workflow operation's importer (`DefaultWorkflowOperationBAMImporter`),
// the Viral Recon viewer publication (`ViralReconViewerPublication.publish`, name `Viral Recon Alignment`) and
// the mapping viewer layout (`MappingResultLayoutService`, which adopts the mapper's sorted, indexed BAM).
// Their records named `<executable> --bam-import-helper --bam-path <bam> --bundle-path <bundle> --name <name>`,
// the spelling of the helper flag that the lane deletes, and these cases pinned it at the lane base. Since M2
// a record whose caller passes no command names the runnable `lungfish-cli import bam <bam> --output-dir
// <bundle> --name <name>` (`importProvenanceArgv`), and no stored record is rewritten.
//
// They run the managed samtools and skip without it.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class BAMImportCallerRecordSpellingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-caller-records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testTheWorkflowOperationImporterRecordsTheImportBamCommand() async throws {
        let (bam, bundle) = try await fixture(withIndex: false)
        try await DefaultWorkflowOperationBAMImporter().importBAM(
            bamURL: bam,
            bundleURL: bundle,
            name: "Workflow Track",
            progressHandler: nil
        )
        try assertImportBamCommand(in: bundle, bam: bam, name: "Workflow Track")
    }

    /// The arguments `ViralReconViewerPublication.publish` passes.
    func testTheViralReconPublicationArgumentsRecordTheImportBamCommand() async throws {
        let (bam, bundle) = try await fixture(withIndex: false)
        _ = try await BAMImportService.importBAM(bamURL: bam, bundleURL: bundle, name: "Viral Recon Alignment")
        try assertImportBamCommand(in: bundle, bam: bam, name: "Viral Recon Alignment")
    }

    /// The arguments `MappingResultLayoutService` passes, which clone the mapper's BAM and index.
    func testTheMappingLayoutArgumentsRecordTheImportBamCommand() async throws {
        let (bam, bundle) = try await fixture(withIndex: true)
        _ = try await BAMImportService.importBAM(
            bamURL: bam,
            bundleURL: bundle,
            name: "Mapped Reads",
            materialization: .adoptCoordinateSorted
        )
        try assertImportBamCommand(in: bundle, bam: bam, name: "Mapped Reads")
    }

    // MARK: - Fixture and record

    /// A copy of the sarscov2 BAM, with its index when `withIndex`, and a reference bundle with no alignment.
    private func fixture(withIndex: Bool) async throws -> (bam: URL, bundle: URL) {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            throw XCTSkip("samtools is not installed in the managed conda root")
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("sarscov2 BAM fixture missing")
        }
        let bam = root.appendingPathComponent("sample.sorted.bam")
        try FileManager.default.copyItem(at: source, to: bam)
        if withIndex {
            try FileManager.default.copyItem(at: source.appendingPathExtension("bai"), to: bam.appendingPathExtension("bai"))
        }
        let bundle = root.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundle)
        return (bam, bundle)
    }

    /// The one import record in the bundle names `lungfish-cli import bam` with the BAM, the bundle as the output
    /// folder and the track name, a command the CLI runs, and no helper flag.
    private func assertImportBamCommand(in bundle: URL, bam: URL, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let sidecars = try FileManager.default.subpathsOfDirectory(atPath: bundle.path)
            .filter { $0.hasSuffix(".json") && $0.lowercased().contains("provenance") }
        XCTAssertEqual(sidecars.count, 1, "one import record: \(sidecars)", file: file, line: line)
        let sidecar = bundle.appendingPathComponent(try XCTUnwrap(sidecars.first, file: file, line: line))
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: sidecar), sidecarURL: sidecar)
        let argv = envelope.argv
        XCTAssertEqual(Array(argv.prefix(3)), [CLICommandIdentity.executableName, "import", "bam"], "\(argv)", file: file, line: line)
        XCTAssertEqual(argv.filter { $0.hasPrefix("--") }, ["--output-dir", "--name"], "\(argv)", file: file, line: line)
        XCTAssertEqual(argv.count, 8, "\(argv)", file: file, line: line)
        guard argv.count == 8 else { return }
        XCTAssertEqual(URL(fileURLWithPath: argv[3]).resolvingSymlinksInPath(), bam.resolvingSymlinksInPath(), file: file, line: line)
        XCTAssertEqual(URL(fileURLWithPath: argv[5]).resolvingSymlinksInPath(), bundle.resolvingSymlinksInPath(), file: file, line: line)
        XCTAssertEqual(argv.last, name, "\(argv)", file: file, line: line)
    }
}
