// ExportItemPinTests.swift - pins the Export button and the export failure alert before lane 13.40 changes them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.40 M1 (QA 1). At the base the Export button of NAO-MGS and NVD is enabled while a result shows
// its cached rows, the Export button of NVD is enabled with no sample picked, and the Export button of EsViritu is
// enabled with an empty batch picker. Each press then ends silently or in a refusal alert that carries the leaf's
// CLI words. M2 of the lane moves the button state (the four tests below flip to disabled) and M3 moves the alert.

import AppKit
import XCTest
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishKit
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI
import LungfishTestSupport

/// Records the alerts a viewer hands to its failure presenter, instead of showing a sheet.
@MainActor
final class RecordingExportFailurePresenter: ExportFailurePresenting {
    private(set) var alerts: [(title: String, message: String)] = []

    func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        alerts.append((title, message))
    }
}

private struct LeafRefusalStub: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@MainActor
final class ExportItemPinTests: XCTestCase {
    private let resultExportHelp = LungfishHelpContent.resultExport.summary

    func testNaoMgsExportButtonIsEnabledWhileCachedRowsShow() throws {
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [],
            manifest: NaoMgsManifest(
                sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 0, taxonCount: 0,
                topTaxon: nil, topTaxonId: nil
            )
        )
        XCTAssertTrue(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, resultExportHelp)
    }

    func testNvdExportButtonIsEnabledWhileCachedRowsShowAndNoSampleIsPicked() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride = makeTestDefaultsSuite(prefix: "ExportItemPinTests").defaults
        addTeardownBlock { NvdResultViewController.testMetadataUserDefaultsOverride = nil }
        let vc = NvdResultViewController()
        _ = vc.view
        vc.configureWithCachedRows(
            [],
            manifest: NvdManifest(
                experiment: "pin", sampleCount: 0, contigCount: 0, hitCount: 0, blastDbVersion: "db",
                snakemakeRunId: "run", sourceDirectoryPath: "/tmp", samples: [], cachedTopContigs: nil
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/nvd-export-item-pin-\(UUID().uuidString)", isDirectory: true)
        )
        XCTAssertTrue(vc.selectedSamples.isEmpty)
        XCTAssertTrue(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, resultExportHelp)
    }

    func testEsVirituExportButtonIsEnabledWithAnEmptyBatchPicker() throws {
        let vc = EsVirituResultViewController()
        _ = vc.view
        vc.isBatchMode = true
        vc.samplePickerState = ClassifierSamplePickerState(allSamples: Set(["sample-A", "sample-B"]))
        vc.samplePickerState.selectedSamples = []
        vc.applyBatchSampleFilter()
        XCTAssertNil(vc.esVirituResult)
        XCTAssertTrue(vc.actionBar.exportButton.isEnabled)
        XCTAssertEqual(vc.actionBar.exportButton.toolTip, resultExportHelp)
    }

    /// The alert a refused export shows today is "Export Failed" and the file name with the leaf's CLI words.
    func testRefusedExportAlertCarriesTheLeafWords() throws {
        let leafText = "No NAO-MGS database at /result/hits.sqlite. Pass the NAO-MGS result folder the app opens."
        let presenter = RecordingExportFailurePresenter()
        ResultExportCoordinator.reportFailure(
            fileName: "naomgs_summary.tsv", error: LeafRefusalStub(text: leafText), window: nil, presenter: presenter
        )
        XCTAssertEqual(presenter.alerts.count, 1)
        XCTAssertEqual(presenter.alerts.first?.title, "Export Failed")
        XCTAssertEqual(presenter.alerts.first?.message, "Could not write naomgs_summary.tsv: \(leafText)")
    }
}
