// FASTQImportBarcodeRecipeBinningTests.swift - The ONT barcode recipes keep every score, and the sheet says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// Lane C2-ONTBIN. The two ONT barcode recipes (Fluidigm sample split and PacBio barcode demultiplex) write their
/// reads with every quality score kept. While one is chosen the Quality Binning popup reads None and is off, the
/// recipe's description says why, and the configuration hands `none` to the route. Turning the recipe off gives the
/// popup back with the choice it held. The assertions read the popup, the description label and the configuration.
@MainActor
final class FASTQImportBarcodeRecipeBinningTests: XCTestCase {

    func testABarcodeRecipeTurnsQualityBinningOffAndSaysSo() throws {
        for recipe in [FASTQImportSheetRecipeOption.ontPacBioBarcodeDemux, .ontFluidigmSampleSplit] {
            var captured: FASTQImportConfiguration?
            let sheet = FASTQImportConfigSheet(
                pairs: [FASTQFilePair(r1: URL(fileURLWithPath: "/data/run/fastq_pass", isDirectory: true), r2: nil)],
                detectedPlatform: .oxfordNanopore,
                recipeOptions: [.ontFluidigmSampleSplit, .ontPacBioBarcodeDemux],
                barcodeDefinitionCandidates: [URL(fileURLWithPath: "/data/run/samples.csv")],
                onImport: { captured = $0 }
            )
            sheet.loadViewIfNeeded()
            let views = Self.descendants(of: sheet.view)
            let binning = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
                $0.itemTitles.contains(QualityBinningScheme.fiveStep.displayName)
            })
            let recipes = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains(recipe.name) })
            let recipeCheckbox = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
                $0.title == "Apply processing recipe after import"
            })
            XCTAssertTrue(binning.isEnabled, "\(recipe.name)")
            XCTAssertEqual(
                binning.titleOfSelectedItem, IngestionPlatform.defaultQualityBinning(for: .oxfordNanopore).displayName,
                "an ONT sheet opens on its platform default"
            )
            // A choice other than None, so the test shows that the recipe turns the popup off and gives the choice back.
            binning.selectItem(withTitle: QualityBinningScheme.fiveStep.displayName)

            recipeCheckbox.performClick(nil)
            recipes.selectItem(withTitle: recipe.name)
            recipes.sendAction(recipes.action, to: recipes.target)

            XCTAssertFalse(binning.isEnabled, "\(recipe.name) turns the popup off")
            XCTAssertEqual(binning.titleOfSelectedItem, QualityBinningScheme.none.displayName, "\(recipe.name)")
            XCTAssertTrue(
                views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Quality Binning is off") },
                "\(recipe.name) says why the popup is off"
            )
            let importButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Import" })
            importButton.performClick(nil)
            XCTAssertEqual(captured?.recipeName, recipe.id)
            XCTAssertEqual(captured?.qualityBinning, QualityBinningScheme.none, "\(recipe.name)")

            recipeCheckbox.performClick(nil)
            XCTAssertTrue(binning.isEnabled, "turning the recipe off gives the popup back")
            XCTAssertEqual(binning.titleOfSelectedItem, QualityBinningScheme.fiveStep.displayName)
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
