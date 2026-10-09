// GenotypeHaplotypeBandCharacterizationTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Byte-level characterization of the haplotype-band disclosure before Phase
// 4a moves it out of GenotypeResultViewController and
// GenotypeComparisonMatrixView (Phase 2.3, REVIEW.md R6). A guarded
// controller walks the band through expand, an override, a move, a hide,
// included loci, a locus filter, collapse and recreation with the same
// window-owned disclosure store, once over effective MiSeq calls and once
// over manual assignments. After every step the whole band model is recorded
// without frames, widths, colours or URLs, and compared with
// haplotype-band.effective.json and haplotype-band.manual.json under
// Tests/Fixtures/golden/genotype-gui. The tests pin current behaviour, the
// stored but never restored expansion of the effective band included.
// Decision D5a of the follow-up made an ambiguous call draw its tokens and a
// locus with no haplotype or no assay draw those words, recaptured here.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishGenotypeUI

/// The band model after one step. The canonical encoder walks it through Mirror.
private struct BandStep {
    let label: String
    let mode: String
    let disclosure: BandDisclosure
    let expandedInMatrix: Bool
    let expandedInDisplayState: Bool
    let expandedInStore: Bool?
    let includedLoci: Set<String>?
    let loci: [String]
    let expandedRowCount: Int
    let sampleColumnTitles: [String]
    let activeSampleNames: [String]
    let locusFilterTitles: [String]
    let selectedSample: String?
    let selectedCallEvidenceSample: String?
    let samples: [BandSample]
    let export: BandExport
}

private struct BandDisclosure {
    let title: String
    let label: String
    let identifier: String
    let accessibilityLabel: String?
    let accessibilityHelp: String?
    let toolTip: String?
    let isOn: Bool
    let isAccessibilityExpanded: Bool
}

private struct BandSample {
    let sample: String
    let headerAccessibilityLabel: String?
    let loci: [BandLocus]
}

private struct BandLocus {
    let locus: String
    /// The compact locus text the snapshot renders.
    let rendered: String?
    /// The text the band view draws for the locus row.
    let drawn: String?
    let tooltip: String?
    let registeredTooltip: String?
    let slots: [BandSlot]
}

private struct BandSlot {
    let slot: String
    let value: GenotypeHaplotypeCallBandSlotValue?
    let hitTarget: BandHitTarget?
}

private struct BandHitTarget {
    let toolTip: String?
    let accessibilityLabel: String?
    let accessibilityHelp: String?
    let accessibilityIdentifier: String
}

/// The band inputs the Excel capture reads through the matrix's export
/// snapshot: the sample columns, the locus filter and the band's locus scope.
private struct BandExport {
    let sampleNames: [String]
    let locusFilter: String?
    let haplotypeLocusScope: [String]?
}

@MainActor
final class GenotypeHaplotypeBandCharacterizationTests: GenotypeResultViewportTestCase {
    // MARK: B1, effective MiSeq calls

    func testEffectiveMiSeqBandDisclosureCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "haplotype-band.effective") {
            var scenario = try makeEffectiveBandScenario()
            defer { scenario.cleanup() }
            var steps: [BandStep] = []
            @MainActor func record(_ label: String) throws {
                steps.append(try recordStep(label, scenario: scenario))
            }
            try record("configured")
            try toggleDisclosure(scenario.controller)
            try record("expanded through the disclosure button")

            // The override goes through the band's own hit target and the Inspector seam.
            let matrix = scenario.controller.testingComparisonMatrix
            let target = GenotypeHaplotypeBandTarget(sample: "Sample-A", locus: "MHC-A", slot: .h1)
            try XCTUnwrap(matrix.testingHaplotypeBandHitTarget(target)).performClick(nil)
            try record("Sample-A MHC-A H1 selected through its hit target")
            let overrideError = scenario.controller.testingApplyOverridesFromInspectorWithoutPresentingError([
                .init(slot: .h1, haplotypeName: "A9"),
            ])
            XCTAssertNil(overrideError, "The override must apply without an error")
            try record("Sample-A MHC-A H1 overridden to A9")

            matrix.testingMoveSampleColumn(sample: "Sample-B", to: 0)
            try record("Sample-B moved first")
            matrix.testingHideSamples(["Sample-B"])
            try record("Sample-B hidden")
            try applyDisplayState(scenario.controller) { $0.includedLoci = ["MHC-B"] }
            try record("includedLoci MHC-B")
            scenario.controller.testingSetComparisonLocusFilter("MHC-A")
            try record("locus filter MHC-A with includedLoci MHC-B")
            scenario.controller.testingSetComparisonLocusFilter(nil)
            try applyDisplayState(scenario.controller) { $0.includedLoci = nil }
            try record("includedLoci and locus filter cleared")
            try toggleDisclosure(scenario.controller)
            try record("collapsed through the disclosure button")
            recreateBandController(&scenario)
            try record("recreated with the same store after a collapse")
            try toggleDisclosure(scenario.controller)
            try record("recreated controller expanded")
            recreateBandController(&scenario)
            try record("recreated again with the store holding expanded")
            return ["haplotype-band.effective.json": try GenotypeCharacterizationCanonicalizer(root: scenario.root).encode(steps)]
        }
    }

    // MARK: B2, manual assignments

    func testManualAssignmentBandDisclosureCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "haplotype-band.manual") {
            var scenario = try makeManualBandScenario()
            defer { scenario.cleanup() }
            var steps: [BandStep] = []
            @MainActor func record(_ label: String) throws {
                steps.append(try recordStep(label, scenario: scenario))
            }
            try record("configured")
            try toggleDisclosure(scenario.controller)
            try record("expanded through the disclosure button")
            let matrix = scenario.controller.testingComparisonMatrix
            matrix.testingMoveSampleColumn(sample: "AnimalC", to: 0)
            try record("AnimalC moved first")
            matrix.testingHideSamples(["AnimalB"])
            try record("AnimalB hidden")
            scenario.controller.testingSetComparisonLocusFilter("MHC-A")
            try record("locus filter MHC-A")
            scenario.controller.testingSetComparisonLocusFilter("MHC-DQA1")
            try record("locus filter MHC-DQA1")
            scenario.controller.testingSetComparisonLocusFilter(nil)
            try record("locus filter cleared")
            try toggleDisclosure(scenario.controller)
            try record("collapsed through the disclosure button")
            recreateBandController(&scenario)
            try record("recreated with the same store after a collapse")
            try toggleDisclosure(scenario.controller)
            try record("recreated controller expanded")
            recreateBandController(&scenario)
            try record("recreated again with the store holding expanded")
            return ["haplotype-band.manual.json": try GenotypeCharacterizationCanonicalizer(root: scenario.root).encode(steps)]
        }
    }

    // MARK: Steps

    /// Clicks the real disclosure button of the pinned band.
    private func toggleDisclosure(_ controller: GenotypeResultViewController) throws {
        try XCTUnwrap(disclosureButton(in: controller), "The band has no disclosure button").performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
    }

    private func disclosureButton(in controller: GenotypeResultViewController) -> NSButton? {
        descendants(of: controller.testingComparisonMatrix).compactMap { $0 as? NSButton }.first {
            let identifier = $0.accessibilityIdentifier()
            return identifier == "haplotype-call-band-disclosure" || identifier == "manual-haplotype-band-disclosure"
        }
    }

    private func applyDisplayState(
        _ controller: GenotypeResultViewController,
        _ mutate: (inout GenotypeResultDisplayState) -> Void
    ) throws {
        var state = controller.testingDisplayState
        mutate(&state)
        controller.testingApplyDisplayStateImmediately(state)
        controller.view.layoutSubtreeIfNeeded()
    }

    private func recordStep(_ label: String, scenario: GenotypeBandScenario) throws -> BandStep {
        let controller = scenario.controller
        let matrix = controller.testingComparisonMatrix
        controller.view.layoutSubtreeIfNeeded()
        _ = matrix.testingManualHaplotypeBandColumnFrames
        let band = try XCTUnwrap(
            descendants(of: matrix).compactMap { $0 as? GenotypeManualHaplotypeSampleBandView }.first,
            "The matrix has no sample band"
        )
        let button = try XCTUnwrap(disclosureButton(in: controller), "The band has no disclosure button")
        let mode = matrix.testingHaplotypeBandMode
        let loci = matrix.testingHaplotypeBandLoci
        let sampleColumns = matrix.testingVisibleSampleColumnTitles
        let samples = sampleColumns.map { sample in
            BandSample(
                sample: sample,
                headerAccessibilityLabel: matrix.testingColumnAccessibilityLabel(sample: sample),
                loci: loci.enumerated().map { index, locus in
                    recordLocus(locus, index: index, sample: sample, mode: mode, matrix: matrix, band: band)
                }
            )
        }
        let snapshot = matrix.exportSnapshot(
            bundleURL: scenario.bundleURL,
            analysisName: scenario.result.manifest.analysisName,
            lens: "summary"
        )
        return BandStep(
            label: label,
            mode: String(describing: mode),
            disclosure: BandDisclosure(
                title: button.title,
                label: matrix.testingManualHaplotypeBandDisclosureLabel,
                identifier: button.accessibilityIdentifier(),
                accessibilityLabel: button.accessibilityLabel(),
                accessibilityHelp: button.accessibilityHelp(),
                toolTip: button.toolTip,
                isOn: button.state == .on,
                isAccessibilityExpanded: button.isAccessibilityExpanded()
            ),
            expandedInMatrix: matrix.testingManualHaplotypeBandIsExpanded,
            expandedInDisplayState: controller.testingDisplayState.manualHaplotypeBandExpanded,
            expandedInStore: scenario.store.expansion(for: scenario.bundleURL),
            includedLoci: controller.testingDisplayState.includedLoci,
            loci: loci,
            expandedRowCount: matrix.testingHaplotypeBandExpandedRowCount,
            sampleColumnTitles: sampleColumns,
            activeSampleNames: matrix.testingActiveSampleNames,
            locusFilterTitles: matrix.testingLocusFilterTitles,
            selectedSample: controller.testingCurrentSelectedSample,
            selectedCallEvidenceSample: controller.testingCurrentCallEvidenceSample,
            samples: samples,
            export: BandExport(
                sampleNames: snapshot.sampleNames,
                locusFilter: snapshot.filters["locus"],
                haplotypeLocusScope: snapshot.haplotypeLocusScope
            )
        )
    }

    private func recordLocus(
        _ locus: String,
        index: Int,
        sample: String,
        mode: GenotypeHaplotypeBandMode,
        matrix: GenotypeComparisonMatrixView,
        band: GenotypeManualHaplotypeSampleBandView
    ) -> BandLocus {
        switch mode {
        case .effectiveMiSeqCalls:
            return BandLocus(
                locus: locus,
                rendered: matrix.testingHaplotypeBandRenderedValue(sample: sample, locus: locus),
                drawn: band.effectiveValueLayout(sample: sample, locus: locus)?.value,
                tooltip: nil,
                registeredTooltip: nil,
                slots: HaplotypeSlot.allCases.map { slot in
                    let target = GenotypeHaplotypeBandTarget(sample: sample, locus: locus, slot: slot)
                    let hit = matrix.testingHaplotypeBandHitTarget(target)
                    return BandSlot(
                        slot: slot.rawValue,
                        value: matrix.testingHaplotypeBandValue(sample: sample, locus: locus, slot: slot),
                        hitTarget: hit.map {
                            BandHitTarget(
                                toolTip: $0.toolTip,
                                accessibilityLabel: $0.accessibilityLabel(),
                                accessibilityHelp: $0.accessibilityHelp(),
                                accessibilityIdentifier: $0.accessibilityIdentifier()
                            )
                        }
                    )
                }
            )
        case .manualAssignments:
            let values = matrix.testingManualHaplotypeBandValues(sample: sample)
            return BandLocus(
                locus: locus,
                rendered: values.indices.contains(index) ? values[index] : nil,
                drawn: band.valueLayout(sample: sample, locusIndex: index)?.value,
                tooltip: matrix.testingManualHaplotypeBandTooltip(sample: sample, locus: locus),
                registeredTooltip: matrix.testingRegisteredManualHaplotypeBandTooltip(sample: sample, locus: locus),
                slots: []
            )
        case .none:
            return BandLocus(locus: locus, rendered: nil, drawn: nil, tooltip: nil, registeredTooltip: nil, slots: [])
        }
    }
}
