// FASTQImportPairingChoiceTests.swift - The Import sheet's Pairing and Compression Tool popups reach the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// The Import FASTQ sheet stored its Pairing choice but nothing read it, and
/// the SRA download path dropped the Compression Tool choice. Both now flow
/// through `lungfish-cli import fastq` so the GUI, the CLI, and Copy CLI
/// Command agree.
final class FASTQImportPairingChoiceTests: XCTestCase {

    private let r1 = URL(fileURLWithPath: "/data/sample_R1.fastq.gz")
    private let r2 = URL(fileURLWithPath: "/data/sample_R2.fastq.gz")
    private let project = URL(fileURLWithPath: "/projects/demo.lungfish")

    private func makeConfig(
        pairingMode: FASTQIngestionConfig.PairingMode,
        pairingModeIsUserChoice: Bool = true,
        clumpingTool: ClumpingTool = .auto,
        skipClumpify: Bool = false
    ) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [r1, r2],
            detectedPlatform: .illumina,
            confirmedPlatform: .illumina,
            pairingMode: pairingMode,
            pairingModeIsUserChoice: pairingModeIsUserChoice,
            qualityBinning: .none,
            skipClumpify: skipClumpify,
            clumpingTool: clumpingTool,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: nil,
            compressionLevel: .fast
        )
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - Argument building

    func testBuildCLIArgumentsForwardsPairingAndClumpingTool() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: r1, r2: r2, projectDirectory: project, platform: "illumina",
            recipeName: nil, qualityBinning: "none", optimizeStorage: true,
            clumpingTool: .trimGalore, pairingMode: .interleaved, compressionLevel: "fast"
        )
        XCTAssertEqual(value(after: "--pairing", in: args), "interleaved")
        XCTAssertEqual(value(after: "--clumping-tool", in: args), "trim-galore")

        let withoutPairing = CLIImportRunner.buildCLIArguments(
            r1: r1, r2: nil, projectDirectory: project, platform: "illumina",
            recipeName: nil, qualityBinning: "none", optimizeStorage: true, compressionLevel: "fast"
        )
        XCTAssertFalse(withoutPairing.contains("--pairing"), "No choice leaves name-based detection in charge")
        XCTAssertEqual(CLIImportRunner.pairingArgument(for: .singleEnd), "single")
        XCTAssertEqual(CLIImportRunner.pairingArgument(for: .pairedEnd), "paired")
    }

    func testSheetPairingChoiceReachesTheCLIAndCopyCLICommand() {
        let pair = FASTQFilePair(r1: r1, r2: nil)
        for (mode, expected) in [
            (FASTQIngestionConfig.PairingMode.singleEnd, "single"),
            (.pairedEnd, "paired"),
            (.interleaved, "interleaved"),
        ] {
            let args = FASTQIngestionService.cliImportArguments(
                pair: pair, projectDirectory: project, importConfig: makeConfig(pairingMode: mode)
            )
            XCTAssertEqual(value(after: "--pairing", in: args), expected)
            let preview = FASTQIngestionService.cliImportCommandPreview(
                pair: pair, projectDirectory: project, importConfig: makeConfig(pairingMode: mode)
            )
            XCTAssertTrue(preview.contains("--pairing \(expected)"), preview)
        }
    }

    func testAnUntouchedPairingProposalRunsTheCLIInAutoMode() {
        // The popup's preselection is a proposal. Left alone, the CLI reads a
        // lone file's records and records the pairing as detected; only a
        // pick the user made becomes an explicit (final) choice.
        let pair = FASTQFilePair(r1: r1, r2: nil)
        for mode in [FASTQIngestionConfig.PairingMode.singleEnd, .interleaved] {
            let config = makeConfig(pairingMode: mode, pairingModeIsUserChoice: false)
            XCTAssertNil(config.cliPairingMode)
            let args = FASTQIngestionService.cliImportArguments(
                pair: pair, projectDirectory: project, importConfig: config
            )
            XCTAssertFalse(args.contains("--pairing"), "\(mode): \(args)")
            let sra = DatabaseBrowserViewModel.sraImportCLIArguments(
                importConfig: config, r1: r1, r2: nil, projectDirectory: project
            )
            XCTAssertFalse(sra.contains("--pairing"), "\(mode): \(sra)")
        }
        let legacyPreview = FASTQIngestionService.cliImportCommandPreview(
            sourceURL: r1, projectDirectory: project
        )
        XCTAssertFalse(legacyPreview.contains("--pairing"), legacyPreview)
    }

    @MainActor
    func testSheetProposesInterleavedForALoneFileWhoseRecordsAlternateMates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-proposal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let interleaved = dir.appendingPathComponent("MHC-pairs.fastq")
        try "@f0/1\nACGT\n+\nIIII\n@f0/2\nACGT\n+\nIIII\n@f1/1\nACGT\n+\nIIII\n@f1/2\nACGT\n+\nIIII\n"
            .write(to: interleaved, atomically: true, encoding: .utf8)
        let single = dir.appendingPathComponent("single.fastq")
        try "@a\nACGT\n+\nIIII\n@b\nACGT\n+\nIIII\n".write(to: single, atomically: true, encoding: .utf8)

        XCTAssertEqual(FASTQImportConfigSheet.proposedPairingIndex(for: [FASTQFilePair(r1: interleaved, r2: nil)]), 2)
        XCTAssertEqual(FASTQImportConfigSheet.proposedPairingIndex(for: [FASTQFilePair(r1: single, r2: nil)]), 0)
        XCTAssertEqual(
            FASTQImportConfigSheet.proposedPairingIndex(for: [
                FASTQFilePair(r1: interleaved, r2: nil), FASTQFilePair(r1: single, r2: nil),
            ]),
            0
        )
        XCTAssertEqual(FASTQImportConfigSheet.proposedPairingIndex(for: [FASTQFilePair(r1: r1, r2: r2)]), 1)

        var captured: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: interleaved, r2: nil)],
            detectedPlatform: .illumina,
            onImport: { captured = $0 }
        )
        sheet.loadViewIfNeeded()
        let pairingPopup = sheet.view.pairingTestDescendants(of: NSPopUpButton.self)
            .first { popup in (0..<popup.numberOfItems).contains { popup.item(at: $0)?.title == "Interleaved" } }
        XCTAssertEqual(pairingPopup?.selectedItem?.title, "Interleaved")
        sheet.view.pairingTestDescendants(of: NSButton.self).first { $0.title == "Import" }?.performClick(nil)
        XCTAssertEqual(captured?.pairingMode, .interleaved)
        XCTAssertEqual(captured?.pairingModeIsUserChoice, false)
        XCTAssertNil(captured?.cliPairingMode)
    }

    // MARK: - Splitting detected pairs in the GUI

    func testSingleEndAndInterleavedSplitDetectedPairsWithDistinctNames() {
        let detected = [
            FASTQFilePair(r1: r1, r2: r2, metadata: ["lane": "1"]),
            FASTQFilePair(r1: URL(fileURLWithPath: "/data/alone.fq"), r2: nil),
        ]
        for mode in [FASTQIngestionConfig.PairingMode.singleEnd, .interleaved] {
            let split = FASTQFilePair.applying(pairingMode: mode, to: detected)
            XCTAssertEqual(split.map(\.sampleName), ["sample_R1", "sample_R2", "alone"], "\(mode)")
            XCTAssertTrue(split.allSatisfy { $0.r2 == nil })
            XCTAssertEqual(split[1].r1, r2)
            XCTAssertEqual(split[0].metadata, ["lane": "1"])
        }

        let kept = FASTQFilePair.applying(pairingMode: .pairedEnd, to: detected)
        XCTAssertEqual(kept.map(\.sampleName), ["sample", "alone"])
        XCTAssertEqual(kept[0].r2, r2)
    }

    // MARK: - SRA download path

    func testSRADownloadArgumentsHonourTheCompressionToolPopup() {
        let trimGalore = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: makeConfig(pairingMode: .pairedEnd, clumpingTool: .trimGalore),
            r1: r1, r2: r2, projectDirectory: project
        )
        XCTAssertEqual(value(after: "--clumping-tool", in: trimGalore), "trim-galore")
        XCTAssertFalse(trimGalore.contains("--no-optimize-storage"))
        XCTAssertEqual(value(after: "--compression", in: trimGalore), "fast")
        XCTAssertEqual(value(after: "--pairing", in: trimGalore), "paired")

        let none = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: makeConfig(pairingMode: .pairedEnd, clumpingTool: .none, skipClumpify: true),
            r1: r1, r2: r2, projectDirectory: project
        )
        XCTAssertTrue(none.contains("--no-optimize-storage"))
        XCTAssertFalse(none.contains("--clumping-tool"))

        let bbtools = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: makeConfig(pairingMode: .pairedEnd, clumpingTool: .bbtools),
            r1: r1, r2: r2, projectDirectory: project
        )
        XCTAssertEqual(value(after: "--clumping-tool", in: bbtools), "bbtools")
    }

    func testSRADownloadPairingFollowsTheSheetForSingleFileRuns() {
        let interleaved = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: makeConfig(pairingMode: .interleaved),
            r1: r1, r2: nil, projectDirectory: project
        )
        XCTAssertEqual(value(after: "--pairing", in: interleaved), "interleaved")

        // A run that arrived as R1/R2 is one paired sample regardless.
        let paired = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: makeConfig(pairingMode: .singleEnd),
            r1: r1, r2: r2, projectDirectory: project
        )
        XCTAssertEqual(value(after: "--pairing", in: paired), "paired")
    }
}

private extension NSView {
    func pairingTestDescendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + subview.pairingTestDescendants(of: type)
        }
    }
}
