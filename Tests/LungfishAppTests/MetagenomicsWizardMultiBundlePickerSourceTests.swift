// MetagenomicsWizardMultiBundlePickerSourceTests.swift - Source pins for the
// Kraken2 and EsViritu wizards
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ClassificationWizardSheet (Kraken2) and EsVirituWizardSheet used to render a
// MultiBundleRunModePicker locked to per-bundle. The selection was never read
// and the locked "combine" option only confused people, so the picker was
// removed. Both wizards now state in one caption that every sample runs and
// all results are saved together in one batch result. Execution is untouched
// (MetagenomicsSampleGrouper-driven fan-out), and both wizards scan read
// layouts incrementally through SampleReadPlanScan.
//
// Mirrors the source-scanning test idiom established by
// FASTQOperationToolPanesSourceTests rather than rendering SwiftUI views.

import XCTest
import LungfishTestSupport

final class MetagenomicsWizardMultiBundlePickerSourceTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        return try readRepositorySource(url)
    }

    private var classificationWizardSource: String {
        get throws { try source("Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift") }
    }

    private var esVirituWizardSource: String {
        get throws { try source("Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift") }
    }

    // MARK: - ClassificationWizardSheet (Kraken2)

    func testClassificationWizardHasNoRunModePickerAndStatesBatchResult() throws {
        let src = try classificationWizardSource

        XCTAssertFalse(src.contains("MultiBundleRunModePicker("))
        XCTAssertFalse(src.contains("MultiBundleRunPolicy("))
        XCTAssertTrue(src.contains(
            "LGE runs Kraken2 and Bracken on each sample and saves all results together in one batch result."
        ))
    }

    func testClassificationWizardExecutionPathUnchangedBySamplesMap() throws {
        let src = try classificationWizardSource

        XCTAssertTrue(src.contains("let samples = groupedSamples"))
        XCTAssertTrue(src.contains("let configs = samples.map { sample in"))
    }

    func testClassificationWizardScansReadLayoutsIncrementally() throws {
        let src = try classificationWizardSource

        XCTAssertTrue(src.contains("SampleReadPlanScan.stream"))
        XCTAssertTrue(src.contains("Checking read layouts ("))
    }

    // MARK: - EsVirituWizardSheet

    func testEsVirituWizardHasNoRunModePickerAndStatesBatchResult() throws {
        let src = try esVirituWizardSource

        XCTAssertFalse(src.contains("MultiBundleRunModePicker("))
        XCTAssertFalse(src.contains("MultiBundleRunPolicy("))
        XCTAssertTrue(src.contains(
            "LGE runs EsViritu on each sample and saves all results together in one batch result."
        ))
    }

    func testEsVirituWizardExecutionPathUnchangedBySamplesMap() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("let samples = groupedSamples"))
        XCTAssertTrue(src.contains("let configs = samples.map { sample in"))
    }

    func testEsVirituWizardScansReadLayoutsIncrementally() throws {
        let src = try esVirituWizardSource

        XCTAssertTrue(src.contains("SampleReadPlanScan.stream"))
        XCTAssertTrue(src.contains("Checking read layouts ("))
    }
}
