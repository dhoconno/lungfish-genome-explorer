// AlignmentReadRowReplayTests.swift - The viewer's region and selected-read rows run extract reads on the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M3 (census row 22, gaps alignment-region-reads and alignment-selected-reads).
// The destination is chosen first, then the row begins with the `lungfish-cli extract reads` command
// that publishes it, and the L3 runner runs that command. Selected read names go into a file beside the
// bundle before the row begins, which the command and the record name, so the copied command replays.
// Each case drives the real viewer route on the sarscov2 BAM with the built lungfish-cli, so its name
// ends in ReplayTests and it runs in the integration tier.

import AppKit
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentReadRowReplayTests: XCTestCase {
    /// The save panel, which answers with `url`.
    private final class SavePanel: SavePanelPresenting {
        let url: URL?
        init(url: URL?) { self.url = url }
        func present(suggestedName: String, on window: NSWindow) async -> URL? { url }
    }

    private static let contig = "MT192765.1"

    private var scratch: URL!
    private var viewer: ViewerViewController!
    private var window: NSWindow!
    private var priorCLIPath: String?

    override func setUp() async throws {
        // The route finds lungfish-cli through CLIBinaryLocator, which takes LUNGFISH_CLI_PATH first.
        // The run's own value comes back in tearDown (review A51, fix 3).
        priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products), "no lungfish-cli beside \(products.path)")
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        OperationCenter.useTemporaryFailureReportsForTesting()
        scratch = try TestTempDirectory.make(prefix: "alignment-read-row")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("out"), withIntermediateDirectories: true)
        _ = NSApplication.shared
        OperationCenter.shared.clearCompleted()
        viewer = ViewerViewController()
        window = NSWindow(contentViewController: viewer)
        _ = viewer.view
    }

    override func tearDown() async throws {
        window?.contentViewController = nil
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        if let priorCLIPath {
            setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
    }

    /// The evidence the viewer shows, the sarscov2 BAM copied into the scratch folder, with a map
    /// quality filter and the viewer's excluded flags.
    private func context() throws -> AlignmentActionContext {
        let fixture = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let evidence = scratch.appendingPathComponent("evidence", isDirectory: true)
        let bam = evidence.appendingPathComponent("S1.bam")
        let index = evidence.appendingPathComponent("S1.bam.bai")
        if !FileManager.default.fileExists(atPath: bam.path) {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: bam)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture.path + ".bai"), to: index)
        }
        func snapshot(_ url: URL) throws -> AlignmentEvidenceFileSnapshot {
            .init(url: url, byteCount: try ProvenanceFileHasher.fileSize(of: url), sha256: try ProvenanceFileHasher.sha256(of: url))
        }
        return try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: Self.contig),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: Self.contig, contigLength: 29829,
            alignmentSnapshot: try snapshot(bam), indexSnapshot: try snapshot(index), decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 1, minimumMapQ: 1, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback, presentationLabel: "S1 \(Self.contig)"
        )
    }

    /// `evidence` as the viewer holds it after the BAM was replaced: the alignment digest it hashed
    /// when it showed the BAM is no longer the file's.
    private func staleContext(_ evidence: AlignmentActionContext) throws -> AlignmentActionContext {
        try AlignmentActionContext(
            identity: evidence.identity,
            alignmentURL: evidence.alignmentURL, indexURL: evidence.indexURL, decodingReferenceURL: evidence.decodingReferenceURL,
            contig: evidence.contig, contigLength: evidence.contigLength,
            alignmentSnapshot: .init(url: evidence.alignmentURL, byteCount: evidence.alignmentSnapshot.byteCount, sha256: String(repeating: "0", count: 64)),
            indexSnapshot: evidence.indexSnapshot, decodingReferenceSnapshot: evidence.decodingReferenceSnapshot,
            filters: evidence.filters, outputCapability: evidence.outputCapability, sourceReads: evidence.sourceReads,
            presentationLabel: evidence.presentationLabel
        )
    }

    /// Runs `launch` and returns the row titled `title` it began, once the row ended.
    private func endedRow(titled title: String, _ launch: () -> Void) async throws -> OperationCenter.Item {
        let known = Set(OperationCenter.shared.items.map(\.id))
        launch()
        await waitUntil(budget: .lookup) {
            OperationCenter.shared.items.contains { !known.contains($0.id) && $0.title == title && !$0.state.isActive }
        }
        return try XCTUnwrap(OperationCenter.shared.items.first { !known.contains($0.id) && $0.title == title }, "no row \(title)")
    }

    private func record(of bundle: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: bundle.appendingPathComponent(".lungfish-provenance.json")))
    }

    func testTheRegionRowRunsTheExtractReadsCommandItRecordsAndPublishesItsBundle() async throws {
        let bundle = scratch.appendingPathComponent("out/region.lungfishfastq")
        let evidence = try context()
        viewer.alignmentExtractionSavePanelPresenter = SavePanel(url: bundle)
        viewer.alignmentActionContext = evidence
        viewer.setExplicitAlignmentSelection(contig: Self.contig, start: 0, end: 3000)

        let item = try await endedRow(titled: "Extract Reads in Selected Region") { viewer.extractReadsInSelectedAlignmentRegion() }

        XCTAssertEqual(item.state, .completed, item.detail)
        XCTAssertEqual(item.detail, "Alignment read extraction published")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertEqual(command.indexFile, evidence.indexURL.path)
        XCTAssertEqual(command.regions, ["\(Self.contig):1-3000"])
        XCTAssertEqual(command.minimumMapQ, 1)
        XCTAssertEqual(command.excludedFlags, 0x904)
        XCTAssertEqual(command.output, bundle.path)
        let arguments = try RecordedCLICommand.arguments(of: item.cliCommand)
        XCTAssertEqual(try record(of: bundle).argv, [CLICommandIdentity.executableName] + arguments.dropLast(2), "the record names the row's command")
    }

    func testTheSelectedReadsRowWritesTheNamesBesideTheBundleAndRunsTheCommandThatNamesThem() async throws {
        let bundle = scratch.appendingPathComponent("out/selected.lungfishfastq")
        viewer.alignmentExtractionSavePanelPresenter = SavePanel(url: bundle)
        viewer.alignmentActionContext = try context()
        let reads = [
            AlignedRead(name: "ERR5069949.29668", flag: 163, chromosome: Self.contig, position: 120, mapq: 60, cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30]),
            AlignedRead(name: "ERR5069949.114870", flag: 99, chromosome: Self.contig, position: 642, mapq: 60, cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30]),
            AlignedRead(name: "ERR5069949.114870", flag: 2147, chromosome: Self.contig, position: 700, mapq: 0, cigar: [], sequence: "*", qualities: []),
        ]

        let item = try await endedRow(titled: "Extract Selected Reads") { viewer.extractSelectedReads(reads) }

        XCTAssertEqual(item.state, .completed, item.detail)
        let names = scratch.appendingPathComponent("out/selected.read-names.txt")
        XCTAssertEqual(try String(contentsOf: names, encoding: .utf8), "ERR5069949.114870\nERR5069949.29668\n")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertEqual(command.idsFile, names.path, "the command names the durable names file, no scratch file")
        XCTAssertEqual(command.recordsWithoutSequence, 1)
        XCTAssertEqual(command.output, bundle.path)
        let record = try record(of: bundle)
        XCTAssertTrue(record.files.contains { $0.role == .input && $0.path == names.path }, "the record names the names file")
        XCTAssertEqual(record.options.resolvedDefaults["recordsWithoutSequence"], .integer(1))
    }

    /// The viewer hashed the BAM when it showed it, and the file was replaced before the user extracted.
    /// The coordinator checked those digests before it staged anything, and the row on the CLI must too
    /// (review A51, B1): the row fails with the stale-evidence error, the leaf never runs, and nothing is
    /// published.
    func testARegionWhoseEvidenceChangedSinceItWasShownFailsBeforeTheLeaf() async throws {
        let bundle = scratch.appendingPathComponent("out/region.lungfishfastq")
        let shown = try staleContext(try context())
        viewer.alignmentExtractionSavePanelPresenter = SavePanel(url: bundle)
        viewer.alignmentActionContext = shown
        viewer.setExplicitAlignmentSelection(contig: Self.contig, start: 0, end: 3000)

        let item = try await endedRow(titled: "Extract Reads in Selected Region") { viewer.extractReadsInSelectedAlignmentRegion() }

        XCTAssertEqual(item.state, .failed, item.detail)
        XCTAssertEqual(item.detail, "Alignment read extraction failed")
        XCTAssertEqual(item.errorMessage, AlignmentActionContext.EvidenceError.staleEvidence(shown.alignmentURL).localizedDescription)
        XCTAssertTrue(item.errorMessage?.contains(shown.alignmentURL.lastPathComponent) == true, item.errorMessage ?? "no error message")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.deletingLastPathComponent().path), [], "nothing was published")
    }

    /// The coordinator refused a region whose contig was not the evidence's or whose end lay past the
    /// contig, and the guard went with the in-process route. The leaf refuses both now (review A51, F2),
    /// so the row begins with the command it records, the leaf fails before it stages, and the row
    /// ends failed with the leaf's own sentence. Nothing is published, and the leaf records nothing.
    private func assertRegionRowRefused(
        contig: String, end: Int, message: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let bundle = scratch.appendingPathComponent("out/region.lungfishfastq")
        viewer.alignmentExtractionSavePanelPresenter = SavePanel(url: bundle)
        viewer.alignmentActionContext = try context()
        viewer.setExplicitAlignmentSelection(contig: contig, start: 0, end: end)

        let item = try await endedRow(titled: "Extract Reads in Selected Region") { viewer.extractReadsInSelectedAlignmentRegion() }

        XCTAssertEqual(item.state, .failed, item.detail, file: file, line: line)
        XCTAssertEqual(item.detail, "Alignment read extraction failed", file: file, line: line)
        XCTAssertEqual(item.errorMessage, message, "the row shows the leaf's refusal", file: file, line: line)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ExtractReadsSubcommand.self)
        XCTAssertEqual(command.regions, ["\(contig):1-\(end)"], "the row records the region the user selected", file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: bundle.deletingLastPathComponent().path), [],
            "nothing was published and nothing was recorded", file: file, line: line
        )
    }

    func testARegionOnAContigTheBAMDoesNotNameFailsTheRowWithTheLeafsRefusal() async throws {
        try await assertRegionRowRefused(
            contig: "NC_045512.2", end: 3000,
            message: "The alignment has no contig named NC_045512.2. Name one of its contigs in --region."
        )
    }

    func testARegionThatEndsPastTheContigFailsTheRowWithTheLeafsRefusal() async throws {
        try await assertRegionRowRefused(
            contig: Self.contig, end: 30000,
            message: "The region ends at 30000, past the end of \(Self.contig) at 29829."
        )
    }
}
