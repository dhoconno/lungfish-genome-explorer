// FASTQImportQualityBinningDefaultTests.swift - The app's import routes take the platform's binning default unless the user picks another
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

/// BIO-BIN (Phase 3.0 lane BIN), narrowing lane C2-BINNING. The Import FASTQ sheet opens with the detected platform's
/// default, `fiveStep` for Illumina and `none` for ONT, PacBio and unknown reads, and the ONT route the window runs
/// without the sheet launches the CLI with the value named. The assertions read the configuration the sheet hands
/// back and the command the coordinator launches.
@MainActor
final class FASTQImportQualityBinningDefaultTests: XCTestCase {

    func testQualityBinningDefaultIsTheSheetsConfiguration() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        )
        for platform: LungfishIO.SequencingPlatform in [.illumina, .oxfordNanopore, .pacbio, .unknown] {
            var captured: FASTQImportConfiguration?
            let sheet = FASTQImportConfigSheet(pairs: [pair], detectedPlatform: platform, onImport: { captured = $0 })
            sheet.loadViewIfNeeded()
            let importButton = Self.descendants(of: sheet.view).compactMap { $0 as? NSButton }.first { $0.title == "Import" }
            importButton?.performClick(nil)
            XCTAssertEqual(captured?.qualityBinning, platform == .illumina ? .fiveStep : QualityBinningScheme.none, "\(platform)")
        }
    }

    func testQualityBinningDefaultReachesTheONTCoordinatorsCommand() throws {
        let arguments = ONTImportOperationCoordinator.cliArgs(
            sourceURL: URL(fileURLWithPath: "/tmp/run/fastq_pass", isDirectory: true),
            outputURL: URL(fileURLWithPath: "/tmp/P.lungfish/Imports/run", isDirectory: true),
            includeUnclassified: false,
            concurrency: 4
        )
        let command = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "fastq import-ont", args: arguments),
            as: FastqImportONTSubcommand.self
        )
        XCTAssertEqual(command.qualityBinning, QualityBinningScheme.none, "an ONT import keeps every score")
        XCTAssertTrue(zip(arguments, arguments.dropFirst()).contains { $0 == "--quality-binning" && $1 == "none" },
                      "\(arguments)")
    }

    /// A user who picks a binning scheme and then corrects the Platform popup keeps that scheme. Before the fix the
    /// platform change put the popup back on the import default, which turned lossy binning on again for a user who
    /// had chosen None, and binning cannot be undone once the originals are removed.
    func testQualityBinningChoiceSurvivesAPlatformChange() throws {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        )
        var captured: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(pairs: [pair], detectedPlatform: .illumina, onImport: { captured = $0 })
        sheet.loadViewIfNeeded()
        let popups = Self.descendants(of: sheet.view).compactMap { $0 as? NSPopUpButton }
        let binningTitles = Set([QualityBinningScheme.fiveStep, .eightLevel, .none].map(\.displayName))
        let nanopore = try XCTUnwrap(FASTQImportConfigSheet.platformChoices.first { $0.platform == .oxfordNanopore })
        let binningPopup = try XCTUnwrap(popups.first { Set($0.itemTitles) == binningTitles })
        let platformPopup = try XCTUnwrap(popups.first { $0.itemTitles.contains(nanopore.title) })

        binningPopup.selectItem(withTitle: QualityBinningScheme.none.displayName)
        platformPopup.selectItem(withTitle: nanopore.title)
        XCTAssertTrue(platformPopup.sendAction(platformPopup.action, to: platformPopup.target))
        let importButton = Self.descendants(of: sheet.view).compactMap { $0 as? NSButton }.first { $0.title == "Import" }
        importButton?.performClick(nil)

        XCTAssertEqual(captured?.qualityBinning, QualityBinningScheme.none)
    }

    /// A popup the user left on the detected platform's default follows the Platform popup to the new platform's
    /// default, so reads corrected from Illumina to Nanopore keep every score, and back again bin in steps of five.
    func testQualityBinningDefaultFollowsAPlatformChange() throws {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        )
        var captured: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(pairs: [pair], detectedPlatform: .illumina, onImport: { captured = $0 })
        sheet.loadViewIfNeeded()
        let popups = Self.descendants(of: sheet.view).compactMap { $0 as? NSPopUpButton }
        let binningTitles = Set([QualityBinningScheme.fiveStep, .eightLevel, .none].map(\.displayName))
        let binningPopup = try XCTUnwrap(popups.first { Set($0.itemTitles) == binningTitles })
        let nanopore = try XCTUnwrap(FASTQImportConfigSheet.platformChoices.first { $0.platform == .oxfordNanopore })
        let illumina = try XCTUnwrap(FASTQImportConfigSheet.platformChoices.first { $0.platform == .illumina })
        let platformPopup = try XCTUnwrap(popups.first { $0.itemTitles.contains(nanopore.title) })
        XCTAssertEqual(binningPopup.titleOfSelectedItem, QualityBinningScheme.fiveStep.displayName)

        platformPopup.selectItem(withTitle: nanopore.title)
        XCTAssertTrue(platformPopup.sendAction(platformPopup.action, to: platformPopup.target))
        XCTAssertEqual(binningPopup.titleOfSelectedItem, QualityBinningScheme.none.displayName)
        platformPopup.selectItem(withTitle: illumina.title)
        XCTAssertTrue(platformPopup.sendAction(platformPopup.action, to: platformPopup.target))
        let importButton = Self.descendants(of: sheet.view).compactMap { $0 as? NSButton }.first { $0.title == "Import" }
        importButton?.performClick(nil)

        XCTAssertEqual(captured?.qualityBinning, .fiveStep)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
