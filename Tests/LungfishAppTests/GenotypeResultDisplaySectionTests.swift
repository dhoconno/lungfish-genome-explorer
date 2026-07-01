import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import AppKit
import LungfishCore
import LungfishIO
import SwiftUI

@MainActor
final class GenotypeResultDisplaySectionTests: XCTestCase {
    func testDisplayViewModelEmitsLayoutAndThresholdChanges() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        var receivedStates: [GenotypeResultDisplayState] = []
        viewModel.onDisplayStateChanged = { receivedStates.append($0) }

        viewModel.setLayout(.listTrailing)
        viewModel.setViewportLens(.review)
        viewModel.setMinimumSupportPercent(1.5)
        viewModel.setSupportDenominator(.sampleRetained)
        viewModel.setHideFilteredHighlights(false)

        XCTAssertEqual(receivedStates.map(\.layout).first, .listTrailing)
        XCTAssertTrue(receivedStates.contains { $0.viewportLens == .review })
        XCTAssertEqual(receivedStates.last?.minimumSupportPercent, 1.5)
        XCTAssertEqual(receivedStates.last?.supportDenominator, .sampleRetained)
        XCTAssertEqual(receivedStates.last?.hideFilteredHighlights, false)
    }

    func testDisplayStateDefaultsToListOverDetailLayout() {
        XCTAssertEqual(GenotypeResultDisplayState().layout, .listTop)
        XCTAssertEqual(GenotypeResultDisplaySectionViewModel().displayState.layout, .listTop)
        XCTAssertFalse(GenotypeResultDisplayState().hideLowSupport)
        XCTAssertEqual(GenotypeResultDisplayState().minimumSupportPercent, 0)
    }

    func testGenotypeSectionSetMinimumReadsUpdatesStateAndNotifies() {
        let vm = GenotypeResultDisplaySectionViewModel()
        var fired = 0
        vm.onDisplayStateChanged = { _ in fired += 1 }
        vm.setMinimumReads(5_000)
        XCTAssertEqual(vm.displayState.minimumReads, 5_000)
        XCTAssertEqual(fired, 1)
    }

    func testGenotypeSectionSetMinimumReadsClampsNegativeValues() {
        let vm = GenotypeResultDisplaySectionViewModel()
        vm.setMinimumReads(-10)
        XCTAssertEqual(vm.displayState.minimumReads, 0)
    }

    func testGenotypeReadThresholdsAreTwoIndependentEditableFields() {
        var s = GenotypeResultDisplayState()
        XCTAssertEqual(s.minimumReads, 0)            // row filter off by default
        XCTAssertEqual(s.activeMinimumReads, 0)
        XCTAssertEqual(s.cohortFlagThreshold, 5_000) // historical unreliable-below flag preserved, now editable
        s.minimumReads = 3_000
        XCTAssertEqual(s.activeMinimumReads, 3_000)
        XCTAssertEqual(s.cohortFlagThreshold, 5_000, "cohort flag must not alias the row filter")
    }

    func testSamplesBelowFilterUsesActiveMinimumReads() {
        var s = GenotypeResultDisplayState()
        // Row filter off by default => never hides anything.
        XCTAssertEqual(s.samplesBelowFilter([("a", 6_000), ("b", 4_000)]), [])

        s.minimumReads = 5_000
        XCTAssertEqual(s.samplesBelowFilter([("a", 6_000), ("b", 4_000)]), ["b"])
    }

    func testSamplesBelowCohortFlagUsesCohortThreshold() {
        let s = GenotypeResultDisplayState()
        XCTAssertEqual(s.samplesBelowCohortFlag([("a", 6_000), ("b", 4_000)]), ["b"])
    }

    func testLayoutControlUsesSharedTwoPaneRadioGroupStyle() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var layoutControls"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "private var thresholdGuidance"))
        let layoutSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(layoutSource.contains("Label(\"Detail | List\""))
        XCTAssertTrue(layoutSource.contains("Label(\"List | Detail\""))
        XCTAssertTrue(layoutSource.contains("Label(\"List Over Detail\""))
        XCTAssertTrue(layoutSource.contains(".pickerStyle(.radioGroup)"))
    }

    func testGenotypeDisplaySectionDoesNotExposeLiveReadThresholdControls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Hide Low Support"))
        XCTAssertFalse(source.contains("Minimum Reads"))
        XCTAssertFalse(source.contains("Slider("))
        XCTAssertTrue(source.contains("Thresholds are fixed by the genotyping run"))
        XCTAssertTrue(source.contains("Re-run miSeq amplicon MHC genotyping"))
    }

    func testGenotypeDisplaySectionKeepsThresholdGuidanceSeparateFromColorControls() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var thresholdGuidance"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "private var matrixFilterControls"))
        let thresholdSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(thresholdSource.contains("Haplotype thresholds"))
        XCTAssertFalse(thresholdSource.contains("TextField("))
        XCTAssertFalse(thresholdSource.contains("Stepper("))
    }

    func testGenotypeViewSectionExposesHaplotypeViewportControl() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("setViewportLens"))
        XCTAssertTrue(source.contains("GenotypeResultViewportLens.allCases"))
    }

    func testGenotypeSummaryModesAreOnlyOutlineAndMatrix() {
        XCTAssertEqual(GenotypeSummaryViewMode.allCases, [.outline, .matrix])
        XCTAssertEqual(GenotypeSummaryViewMode.allCases.map(\.displayName), ["Outline", "Matrix"])
    }

    func testSelectingSummaryViewModeReturnsViewportToSummary() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.setViewportLens(.review)

        viewModel.setSummaryViewMode(.matrix)

        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .matrix)
    }

    func testHaplotypeGenotypeToggleSwitchesSummaryViewModes() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true, hasHaplotypingResult: true)
        var states: [GenotypeResultDisplayState] = []
        viewModel.onDisplayStateChanged = { states.append($0) }

        viewModel.toggleHaplotypeGenotypeSummaryView()
        viewModel.toggleHaplotypeGenotypeSummaryView()

        XCTAssertTrue(viewModel.hasHaplotypingResult)
        XCTAssertEqual(states.map(\.summaryViewMode), [.matrix, .outline])
        XCTAssertEqual(states.map(\.viewportLens), [.summary, .summary])
    }

    func testGenotypeViewSectionOwnsHighlightColorControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let displaySource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift"),
            encoding: .utf8
        )
        let selectionSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift"),
            encoding: .utf8
        )
        let selectionStart = try XCTUnwrap(selectionSource.range(of: "private func genotypeResultSelectionView"))
        let selectionEnd = try XCTUnwrap(selectionSource[selectionStart.lowerBound...].range(of: "private func genotypeHighlightControls"))
        let selectedItemSource = String(selectionSource[selectionStart.lowerBound..<selectionEnd.lowerBound])

        XCTAssertTrue(displaySource.contains("private var highlightControls"))
        XCTAssertTrue(displaySource.contains("ContinuousColorWell("))
        XCTAssertTrue(displaySource.contains("Clear Fill"))
        XCTAssertTrue(displaySource.contains("Clear Border"))
        XCTAssertFalse(selectedItemSource.contains("genotypeHighlightControls(target:"))
    }

    func testDisplayViewModelAutoAppliesSelectedHighlightColorChanges() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let target = GenotypeResultHighlightTarget(
            genotype: "01_Mafa_A1_001_01",
            locus: "MHC-A",
            sample: "AnimalA"
        )
        var receivedRequests: [GenotypeResultHighlightRequest] = []
        viewModel.onGenotypeHighlightRequested = { receivedRequests.append($0) }

        viewModel.updateSelection(GenotypeResultSelectionState(
            title: target.genotype,
            subtitle: "MHC-A - 1 sample",
            detailRows: [],
            highlightTarget: target,
            highlightStyle: .default
        ))
        viewModel.setGenotypeHighlightChannel(.fill)
        viewModel.setGenotypeHighlightColor(NSColor(
            srgbRed: 0.2,
            green: 0.5,
            blue: 0.7,
            alpha: 1.0
        ))
        viewModel.setGenotypeHighlightChannel(.border)
        viewModel.setGenotypeHighlightColor(NSColor(
            srgbRed: 0.9,
            green: 0.3,
            blue: 0.1,
            alpha: 1.0
        ))

        XCTAssertEqual(receivedRequests.map(\.channel), [.fill, .border])
        XCTAssertEqual(receivedRequests.first?.target, target)
        XCTAssertEqual(receivedRequests.first?.scope, .selectedCell)
        XCTAssertEqual(receivedRequests.first?.color, AnnotationColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1.0))
        XCTAssertEqual(receivedRequests.last?.color, AnnotationColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1.0))
    }

    func testMatrixSupportedCellHelperRequiresRowOrCellSelection() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        var helperInvocations: [Int] = []
        viewModel.onSupportedCellSelectionRequested = { helperInvocations.append($0) }

        viewModel.updateSelection(GenotypeResultSelectionState(
            title: "AnimalA",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [.column(sample: "AnimalA")]
        ))
        XCTAssertTrue(viewModel.hasMatrixSelection)
        XCTAssertFalse(viewModel.canSelectSupportedCellsInCurrentRow)
        viewModel.selectSupportedCellsInCurrentRow()
        XCTAssertTrue(helperInvocations.isEmpty)

        viewModel.updateSelection(GenotypeResultSelectionState(
            title: "01_Mafa_A1_001_01",
            subtitle: "MHC-A",
            detailRows: [],
            matrixTargets: [.row(locus: "MHC-A", genotype: "01_Mafa_A1_001_01")]
        ))
        XCTAssertTrue(viewModel.canSelectSupportedCellsInCurrentRow)
        viewModel.selectSupportedCellsInCurrentRow()
        XCTAssertEqual(helperInvocations, [1])
    }

    func testMatrixQuickPalettesExposeMCMAndGenericColors() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let mcm = viewModel.matrixMCMQuickPaletteColors
        let generic = viewModel.matrixGenericQuickPaletteColors

        XCTAssertEqual(mcm.count, 8)
        XCTAssertEqual(generic.count, 64)
        XCTAssertEqual(Set(mcm.map(\.hexString)).count, 8)
        XCTAssertEqual(Set(generic.map(\.hexString)).count, 64)
        XCTAssertEqual(mcm.first?.hexString, HaplotypeColorToken.canonicalBudde2010Tokens.first?.fillColor.hexString)
        XCTAssertEqual(generic.first?.hexString, "#AD274D")
    }

    func testMatrixQuickPaletteAppliesToSelectedStyleTarget() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        viewModel.updateSelection(GenotypeResultSelectionState(
            title: "01_Mafa_A1_001_01",
            subtitle: "MHC-A",
            detailRows: [],
            matrixTargets: [target]
        ))
        var requests: [GenotypeMatrixStyleRequest] = []
        viewModel.onMatrixStyleRequested = { requests.append($0) }
        let color = AnnotationColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1.0)

        viewModel.matrixPaletteTarget = .fill
        viewModel.applyMatrixPaletteColor(color)
        viewModel.matrixPaletteTarget = .text
        viewModel.applyMatrixPaletteColor(color)
        viewModel.matrixPaletteTarget = .border
        viewModel.applyMatrixPaletteColor(color)

        XCTAssertEqual(requests.map(\.targets), [[target], [target], [target]])
        XCTAssertEqual(requests.map(\.field), [
            .fillColor(color),
            .textColor(color),
            .borderColor(color),
        ])
    }

    func testSelectionViewModelEmitsGenotypeHighlightRequests() {
        let viewModel = SelectionSectionViewModel()
        let target = GenotypeResultHighlightTarget(
            genotype: "01_Mafa_A1_001_01",
            locus: "MHC-A",
            sample: "AnimalA"
        )
        var receivedRequest: GenotypeResultHighlightRequest?
        viewModel.onGenotypeHighlightRequested = { receivedRequest = $0 }

        viewModel.select(genotypeResultSelection: GenotypeResultSelectionState(
            title: target.genotype,
            subtitle: "MHC-A - 1 sample",
            detailRows: [],
            highlightTarget: target,
            highlightColor: nil
        ))
        viewModel.genotypeHighlightColor = ColorBridge.color(
            from: AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0)
        )
        viewModel.applyGenotypeHighlight()

        XCTAssertEqual(receivedRequest?.target, target)
        XCTAssertEqual(receivedRequest?.scope, .selectedCell)
        XCTAssertEqual(receivedRequest?.channel, .fill)
        XCTAssertNotNil(receivedRequest?.color)
    }

    func testSelectionViewModelAutoAppliesGenotypeFillAndBorderChanges() {
        let viewModel = SelectionSectionViewModel()
        let target = GenotypeResultHighlightTarget(
            genotype: "01_Mafa_A1_001_01",
            locus: "MHC-A",
            sample: "AnimalA"
        )
        var receivedRequests: [GenotypeResultHighlightRequest] = []
        viewModel.onGenotypeHighlightRequested = { receivedRequests.append($0) }

        viewModel.select(genotypeResultSelection: GenotypeResultSelectionState(
            title: target.genotype,
            subtitle: "MHC-A - 1 sample",
            detailRows: [],
            highlightTarget: target,
            highlightStyle: .default
        ))
        viewModel.setGenotypeHighlightChannel(.border)
        viewModel.setGenotypeHighlightColor(ColorBridge.color(
            from: AnnotationColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0)
        ))
        viewModel.clearGenotypeHighlight(.border)

        XCTAssertEqual(receivedRequests.count, 2)
        XCTAssertEqual(receivedRequests.first?.scope, .selectedCell)
        XCTAssertEqual(receivedRequests.first?.channel, .border)
        XCTAssertNotNil(receivedRequests.first?.color)
        XCTAssertEqual(receivedRequests.last?.channel, .border)
        XCTAssertNil(receivedRequests.last?.color)
    }

    func testSelectionViewModelAutoAppliesContinuousColorWellChanges() {
        let viewModel = SelectionSectionViewModel()
        let target = GenotypeResultHighlightTarget(
            genotype: "01_Mafa_A1_001_01",
            locus: "MHC-A",
            sample: "AnimalA"
        )
        var receivedRequests: [GenotypeResultHighlightRequest] = []
        viewModel.onGenotypeHighlightRequested = { receivedRequests.append($0) }

        viewModel.select(genotypeResultSelection: GenotypeResultSelectionState(
            title: target.genotype,
            subtitle: "MHC-A - 1 sample",
            detailRows: [],
            highlightTarget: target,
            highlightStyle: .default
        ))
        viewModel.setGenotypeHighlightChannel(.fill)
        viewModel.setGenotypeHighlightColor(NSColor(
            srgbRed: 0.2,
            green: 0.5,
            blue: 0.7,
            alpha: 1.0
        ))
        viewModel.setGenotypeHighlightChannel(.border)
        viewModel.setGenotypeHighlightColor(NSColor(
            srgbRed: 0.9,
            green: 0.3,
            blue: 0.1,
            alpha: 1.0
        ))

        XCTAssertEqual(receivedRequests.map(\.channel), [.fill, .border])
        XCTAssertEqual(receivedRequests.first?.color, AnnotationColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1.0))
        XCTAssertEqual(receivedRequests.last?.color, AnnotationColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1.0))
    }
}

private enum ColorBridge {
    static func color(from annotationColor: AnnotationColor) -> Color {
        Color(
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }
}
