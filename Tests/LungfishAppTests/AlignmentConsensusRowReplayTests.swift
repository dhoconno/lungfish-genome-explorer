// AlignmentConsensusRowReplayTests.swift - What the viewer's Generate Consensus row shows, from the action itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M2, the row table of the consensus route (U-a, UX 1), which the publication pin
// does not hold. Each case runs the viewer's own `presentAlignmentConsensusGeneration()` in a window
// on the sarscov2 BAM, picks a destination in the destination sheet and presses its button, answers
// the save panel, the all-N sheet and the failure sheet through the viewer's seams, and records the
// row's title, end, detail, error, outputs and scope line, each sheet it showed and the files it left.
// Clipboard and share are left out, because they write the user's pasteboard or open a share picker.
//
// The route runs `lungfish-cli` from the build products, so the name ends in ReplayTests and the
// class runs in the integration tier.

import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentConsensusRowReplayTests: XCTestCase {
    /// The save panel, which answers with `url` and keeps the name it suggested.
    private final class SavePanel: SavePanelPresenting {
        let url: URL?
        var suggestedNames: [String] = []
        init(url: URL?) { self.url = url }
        func present(suggestedName: String, on window: NSWindow) async -> URL? {
            suggestedNames.append(suggestedName)
            return url
        }
    }

    private enum Choice {
        case cancelTheDialog
        case destination(DialogDestination)
    }

    private static let contig = "MT192765.1"
    private static let contigLength = 29829

    private var scratch: URL!
    private var viewer: ViewerViewController!
    private var window: NSWindow!
    private var sheets: [String] = []

    override func setUp() async throws {
        scratch = try TestTempDirectory.make(prefix: "consensus-row")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("out"), withIntermediateDirectories: true)
        _ = NSApplication.shared
        OperationCenter.shared.clearCompleted()
        viewer = ViewerViewController()
        window = NSWindow(contentViewController: viewer)
        _ = viewer.view
        viewer.extractionFailureAlertPresenter = { [weak self] title, message in
            self?.sheets.append("failure \(title): \(message)")
        }
    }

    override func tearDown() async throws {
        if let sheet = window?.attachedSheet { window.endSheet(sheet) }
        window?.contentViewController = nil
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
    }

    /// The evidence the viewer shows, the sarscov2 BAM with every filter off but the depth.
    private func context(minimumDepth: Int) throws -> AlignmentActionContext {
        let bam = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let index = URL(fileURLWithPath: bam.path + ".bai")
        func snapshot(_ url: URL) throws -> AlignmentEvidenceFileSnapshot {
            .init(url: url, byteCount: try ProvenanceFileHasher.fileSize(of: url), sha256: try ProvenanceFileHasher.sha256(of: url))
        }
        return try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: Self.contig),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: Self.contig, contigLength: Self.contigLength,
            alignmentSnapshot: try snapshot(bam), indexSnapshot: try snapshot(index), decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: minimumDepth, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback, presentationLabel: "S1 \(Self.contig)"
        )
    }

    private var dialog: NSHostingController<FASTASequenceExtractionDialog>? {
        window.attachedSheet?.contentViewController as? NSHostingController<FASTASequenceExtractionDialog>
    }

    private func rows(after known: Set<UUID>) -> [OperationCenter.Item] {
        OperationCenter.shared.items.filter { !known.contains($0.id) && $0.title == "Generate Alignment Consensus" }
    }

    /// Runs Generate Consensus once and returns what the row and the sheets showed.
    private func run(
        _ choice: Choice,
        savePanelAnswer: String? = "S1.fasta",
        minimumDepth: Int = 1,
        acceptAllN: Bool = true,
        expectRow: Bool = true
    ) async throws -> [String] {
        let known = Set(OperationCenter.shared.items.map(\.id))
        let savePanel = SavePanel(url: savePanelAnswer.map { scratch.appendingPathComponent("out/\($0)") })
        viewer.alignmentExtractionSavePanelPresenter = savePanel
        viewer.alignmentConsensusAllLowDepthConfirmation = { [weak self] message, _ in
            self?.sheets.append("all-N \(message)")
            return acceptAllN
        }
        viewer.alignmentActionContext = try context(minimumDepth: minimumDepth)

        viewer.presentAlignmentConsensusGeneration()

        await waitUntil(timeout: .seconds(60)) { self.dialog != nil || self.rows(after: known).contains { !$0.state.isActive } }
        if let host = dialog {
            switch choice {
            case .cancelTheDialog:
                host.rootView.onCancel()
            case .destination(let destination):
                host.rootView.model.destination = destination
                host.rootView.onPrimary()
            }
        }
        if expectRow {
            await waitUntil(timeout: .seconds(60)) { self.rows(after: known).contains { !$0.state.isActive } }
        } else {
            await waitUntil(timeout: .seconds(10)) { self.window.attachedSheet == nil }
            try await Task.sleep(for: .milliseconds(500))
        }
        return describe(rows(after: known), savePanel: savePanel)
    }

    private func describe(_ rows: [OperationCenter.Item], savePanel: SavePanel) -> [String] {
        let root = scratch.standardizedFileURL.path
        func masked(_ text: String) -> String {
            text.replacingOccurrences(of: "/private" + root, with: "<root>").replacingOccurrences(of: root, with: "<root>")
        }
        var lines = rows.isEmpty ? ["no row"] : []
        for row in rows {
            lines += ["row \(row.title)", "end \(row.state) \(row.detail)"]
            if let error = row.errorMessage { lines.append("error \(masked(error))") }
            lines += row.outputURLs.map { "output \(masked($0.path))" }
            lines += row.bundleURLs.map { "bundle \(masked($0.path))" }
            lines += row.logEntries.map(\.message).filter { $0.hasPrefix("Consensus scope") }.map { "log \($0)" }
        }
        lines += savePanel.suggestedNames.map { "save panel \($0)" }
        lines += sheets.map(masked)
        let out = scratch.appendingPathComponent("out")
        let enumerator = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(masked(url.standardizedFileURL.path))
            }
        }
        return lines + files.sorted().map { "file \($0)" }
    }

    private static let scopeLine = "log Consensus scope wholeContig, region \(contig):0-\(contigLength), reference fill never"
    private static let allNSheet = "all-N Every position in the requested region is below the minimum depth of 100000."
        + " The consensus will contain only N characters. You can continue without filling from the reference."

    // MARK: - Cases

    func testAFASTADestinationSavesTheFASTAAndItsRecord() async throws {
        let lines = try await run(.destination(.file))
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end completed Consensus FASTA saved",
            "output <root>/out/S1.fasta",
            "output <root>/out/S1.fasta.lungfish-provenance.json",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            "file <root>/out/S1.fasta",
            "file <root>/out/S1.fasta.lungfish-provenance.json",
        ])
    }

    func testABundleDestinationCreatesTheReferenceBundle() async throws {
        let lines = try await run(.destination(.bundle), savePanelAnswer: "S1.lungfishref")
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end completed Consensus reference bundle created",
            "bundle <root>/out/S1.lungfishref",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.lungfishref",
            "file <root>/out/S1.lungfishref/.lungfish-provenance.json",
            "file <root>/out/S1.lungfishref/genome/consensus.fasta",
            "file <root>/out/S1.lungfishref/genome/consensus.fasta.fai",
            "file <root>/out/S1.lungfishref/manifest.json",
        ])
    }

    func testAnAcceptedAllNConsensusIsSaved() async throws {
        let lines = try await run(.destination(.file), minimumDepth: 100_000)
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end completed Consensus FASTA saved",
            "output <root>/out/S1.fasta",
            "output <root>/out/S1.fasta.lungfish-provenance.json",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            Self.allNSheet,
            "file <root>/out/S1.fasta",
            "file <root>/out/S1.fasta.lungfish-provenance.json",
        ])
        let fasta = try String(contentsOf: scratch.appendingPathComponent("out/S1.fasta"), encoding: .utf8)
        XCTAssertEqual(fasta, ">S1 MT192765.1 consensus\n\(String(repeating: "N", count: Self.contigLength))\n")
    }

    func testADeclinedAllNConsensusEndsCancelledAndWritesNothing() async throws {
        let lines = try await run(.destination(.file), minimumDepth: 100_000, acceptAllN: false)
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end cancelled Cancelled by user",
            Self.scopeLine,
            Self.allNSheet,
        ])
    }

    func testAnExistingDestinationFailsTheRowWithItsSheet() async throws {
        try Data("kept".utf8).write(to: scratch.appendingPathComponent("out/S1.fasta"))
        let lines = try await run(.destination(.file))
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end failed Consensus publication failed",
            "error A file already exists at <root>/out/S1.fasta.",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
            "failure Publish Consensus Failed: A file already exists at <root>/out/S1.fasta.",
            "file <root>/out/S1.fasta",
        ])
    }

    func testCancellingTheDestinationSheetWritesNothing() async throws {
        let lines = try await run(.cancelTheDialog)
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end cancelled Cancelled by user",
            Self.scopeLine,
        ])
    }

    func testCancellingTheSavePanelWritesNothing() async throws {
        let lines = try await run(.destination(.file), savePanelAnswer: nil)
        XCTAssertEqual(lines, [
            "row Generate Alignment Consensus",
            "end cancelled Cancelled by user",
            Self.scopeLine,
            "save panel S1-MT192765.1-consensus.fasta",
        ])
    }
}
