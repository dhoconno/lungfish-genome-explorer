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

    func testGenotypeOnlyDisplayStateNormalizesToSummaryMatrixAndListOverDetail() {
        let state = GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing,
            hideLowSupport: true,
            minimumSupportPercent: 12.5,
            supportDenominator: .sampleRetained,
            cellColorMode: .highlights,
            hideFilteredHighlights: false,
            showsAncillaryLoci: true,
            includedLoci: ["MHC-A"],
            minimumReads: 500,
            matrixMinimumReads: 10,
            matrixMinimumPercent: 20,
            matrixPercentDenominator: .sampleRetained,
            matrixRowFilterText: "MHC-A",
            matrixSampleFilterText: "AnimalA",
            cohortFlagThreshold: 4_000
        )

        let normalized = state.normalized(forGenotypeOnlyResult: true)
        var expected = state
        expected.viewportLens = .summary
        expected.summaryViewMode = .matrix
        expected.layout = .listTop

        XCTAssertEqual(normalized, expected)
    }

    func testNonGenotypeOnlyDisplayStateNormalizationReturnsExactInput() {
        let state = GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing,
            hideLowSupport: true,
            minimumSupportPercent: 12.5,
            supportDenominator: .sampleRetained,
            cellColorMode: .highlights,
            hideFilteredHighlights: false,
            showsAncillaryLoci: true,
            includedLoci: ["MHC-A"],
            minimumReads: 500,
            matrixMinimumReads: 10,
            matrixMinimumPercent: 20,
            matrixPercentDenominator: .sampleRetained,
            matrixRowFilterText: "MHC-A",
            matrixSampleFilterText: "AnimalA",
            cohortFlagThreshold: 4_000
        )

        XCTAssertEqual(state.normalized(forGenotypeOnlyResult: false), state)
    }

    func testGenotypeOnlyViewModelHidesControlsAndEnforcesNormalizedState() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let state = GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing
        )

        viewModel.update(isAvailable: true, state: state, isGenotypeOnlyResult: true)

        XCTAssertTrue(viewModel.isGenotypeOnlyResult)
        XCTAssertFalse(viewModel.showsViewportAndLayoutControls)
        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .matrix)
        XCTAssertEqual(viewModel.displayState.layout, .listTop)

        viewModel.setViewportLens(.review)
        viewModel.setLayout(.listLeading)

        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .matrix)
        XCTAssertEqual(viewModel.displayState.layout, .listTop)

        viewModel.clear()

        XCTAssertFalse(viewModel.isGenotypeOnlyResult)
        XCTAssertTrue(viewModel.showsViewportAndLayoutControls)
    }

    func testHaplotypedViewModelShowsViewportAndLayoutControls() {
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.update(isAvailable: true, hasHaplotypingResult: true)

        XCTAssertFalse(viewModel.isGenotypeOnlyResult)
        XCTAssertTrue(viewModel.showsViewportAndLayoutControls)
    }

    func testGenotypeOnlyViewModelNormalizesInboundDisplayStateSynchronization() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true, isGenotypeOnlyResult: true)

        viewModel.updateDisplayState(GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing
        ))

        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .matrix)
        XCTAssertEqual(viewModel.displayState.layout, .listTop)
    }

    func testGenotypeOnlyViewModelRejectsOutlineSummaryModeMutation() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true, isGenotypeOnlyResult: true)

        viewModel.setSummaryViewMode(.outline)

        XCTAssertEqual(viewModel.displayState.viewportLens, .summary)
        XCTAssertEqual(viewModel.displayState.summaryViewMode, .matrix)
        XCTAssertEqual(viewModel.displayState.layout, .listTop)
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

    func testViewportAndLayoutControlsAreGuardedForGenotypeOnlyResults() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let bodyStart = try XCTUnwrap(source.range(of: "public var body: some View"))
        let bodyEnd = try XCTUnwrap(source[bodyStart.lowerBound...].range(of: "private var haplotypeGenotypeToggle"))
        let bodySource = String(source[bodyStart.lowerBound..<bodyEnd.lowerBound])
        let guardedSource = try bracedBody(
            following: "if viewModel.showsViewportAndLayoutControls",
            in: bodySource
        )

        XCTAssertTrue(guardedSource.contains("viewControls"))
        XCTAssertTrue(guardedSource.contains("layoutControls"))
        XCTAssertTrue(source.contains("Label(lens.displayName, systemImage: lens.inspectorSystemImage)"))
        XCTAssertTrue(source.contains("Label(\"Detail | List\""))
        XCTAssertTrue(source.contains("Label(\"List | Detail\""))
        XCTAssertTrue(source.contains("Label(\"List Over Detail\""))
        XCTAssertTrue(source.contains(".pickerStyle(.radioGroup)"))
    }

    private func bracedBody(following marker: String, in source: String) throws -> String {
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(source[markerRange.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = openingBrace

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let bodyStart = source.index(after: openingBrace)
                    return String(source[bodyStart..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        throw NSError(domain: "GenotypeResultDisplaySectionTests", code: 1)
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

    func testMatrixSupportedReadThresholdAppliesToRowsAndColumns() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        var previewValues: [Int] = []
        var requests: [GenotypeMatrixStyleRequest] = []
        viewModel.onSupportSelectionPreviewChanged = { previewValues.append($0) }
        viewModel.onMatrixStyleRequested = { requests.append($0) }

        viewModel.updateSelection(GenotypeResultSelectionState(
            title: "AnimalA",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [.column(sample: "AnimalA")]
        ))
        XCTAssertTrue(viewModel.hasMatrixSelection)
        XCTAssertTrue(viewModel.canUseSupportedCellThreshold)
        viewModel.setSupportedCellMinimumReads(5)
        viewModel.setMatrixFillColor(NSColor.systemPink)
        XCTAssertEqual(previewValues, [5])
        XCTAssertEqual(requests.last?.targets, [.column(sample: "AnimalA")])
        XCTAssertEqual(requests.last?.minimumReads, 5)

        viewModel.updateSelection(GenotypeResultSelectionState(
            title: "01_Mafa_A1_001_01",
            subtitle: "MHC-A",
            detailRows: [],
            matrixTargets: [.row(locus: "MHC-A", genotype: "01_Mafa_A1_001_01")]
        ))
        XCTAssertTrue(viewModel.canUseSupportedCellThreshold)
        viewModel.setMatrixFillColor(NSColor.systemBlue)
        XCTAssertEqual(requests.last?.minimumReads, 5)

        viewModel.updateSelection(GenotypeResultSelectionState(
            title: "AnimalA MHC-A 01_Mafa_A1_001_01",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [.cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AnimalA")]
        ))
        XCTAssertFalse(viewModel.canUseSupportedCellThreshold)
        viewModel.setMatrixFillColor(NSColor.systemGreen)
        XCTAssertNil(requests.last?.minimumReads)
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
        XCTAssertEqual(requests.map(\.minimumReads), [nil, nil, nil])
    }

    func testAnnotationInspectorUsesSharedCapabilityForReviewPresentationAndRequests() throws {
        let first = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let second = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalB"
        )
        let capability = GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 9, second: 4]),
            reviews: [
                .init(
                    target: first,
                    disposition: .falsePositive,
                    author: "Analyst",
                    timestamp: "2026-07-24T12:00:00Z"
                ),
                .init(
                    target: second,
                    disposition: .falsePositive,
                    author: "Analyst",
                    timestamp: "2026-07-24T12:00:00Z"
                ),
            ],
            comments: [],
            isWritable: true
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Two cells",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [first, second]
        ))
        viewModel.updateMatrixReviewCapability(capability)
        var requests: [GenotypeMatrixReviewRequest] = []
        viewModel.onMatrixReviewRequested = { requests.append($0) }

        XCTAssertEqual(viewModel.matrixSelectionSummary, "2 genotype cells selected")
        XCTAssertEqual(viewModel.matrixEvidenceSummary, "All have read support.")
        XCTAssertEqual(viewModel.matrixCurrentReviewSummary, "False positive")
        XCTAssertEqual(viewModel.matrixFalsePositiveAvailability, capability.falsePositive)
        XCTAssertEqual(viewModel.matrixFalseNegativeAvailability, capability.falseNegative)
        XCTAssertEqual(viewModel.matrixClearReviewAvailability, capability.clearReview)

        viewModel.markMatrixFalsePositive()
        viewModel.markMatrixFalseNegative()
        viewModel.clearMatrixReview()

        XCTAssertEqual(requests, [
            .init(targets: [first, second], intent: .set(.falsePositive)),
            .init(targets: [first, second], intent: .clear),
        ])

        let mixed = GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 9]),
            reviews: [],
            comments: [],
            isWritable: true
        )
        viewModel.updateMatrixReviewCapability(mixed)

        XCTAssertEqual(
            viewModel.matrixEvidenceSummary,
            "Selection contains cells with and without read support."
        )
        XCTAssertEqual(
            viewModel.matrixReviewDisabledReason,
            mixed.falsePositive.disabledReason
        )

        let unsupported = GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: true
        )
        viewModel.updateMatrixReviewCapability(unsupported)
        XCTAssertEqual(viewModel.matrixEvidenceSummary, "No read support.")
        XCTAssertFalse(viewModel.matrixFalsePositiveAvailability.isEnabled)
        XCTAssertTrue(viewModel.matrixFalseNegativeAvailability.isEnabled)
        XCTAssertEqual(viewModel.matrixCurrentReviewSummary, "None")

        let mixedReviews = GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 9, second: 4]),
            reviews: [
                .init(
                    target: first,
                    disposition: .falsePositive,
                    author: "Analyst",
                    timestamp: "2026-07-24T12:00:00Z"
                ),
                .init(
                    target: second,
                    disposition: .falseNegative,
                    author: "Analyst",
                    timestamp: "2026-07-24T12:01:00Z"
                ),
            ],
            comments: [],
            isWritable: true
        )
        viewModel.updateMatrixReviewCapability(mixedReviews)
        XCTAssertEqual(viewModel.matrixCurrentReviewSummary, "Multiple review states")
        XCTAssertTrue(viewModel.matrixClearReviewAvailability.isEnabled)

        let readOnly = GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 9, second: 4]),
            reviews: [],
            comments: [],
            isWritable: false
        )
        viewModel.updateMatrixReviewCapability(readOnly)
        XCTAssertEqual(viewModel.matrixReviewDisabledReason, "This bundle is read-only.")
        XCTAssertEqual(
            viewModel.matrixCommentMutationDisabledReason,
            "This bundle is read-only."
        )
        XCTAssertEqual(
            viewModel.matrixCommentRemovalAvailability(scope: .cell),
            .disabled(reason: "This bundle is read-only.")
        )
        XCTAssertTrue(readOnly.allCommands.allSatisfy { !$0.isEnabled })
    }

    func testScopedCommentCardsKeepCellRowAndColumnValuesAndMetadataDistinct() throws {
        let cell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let row = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01"
        )
        let column = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let comments = [
            GenotypeAnnotationSidecar.MatrixComment(
                target: cell,
                body: "Cell note",
                author: "Cell analyst",
                timestamp: "2026-07-24T12:00:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: row,
                body: "Allele note",
                author: "Row analyst",
                timestamp: "2026-07-24T11:00:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: column,
                body: "Sample note",
                author: "Column analyst",
                timestamp: "2026-07-24T10:00:00Z"
            ),
        ]
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Cell",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [cell]
        ))
        viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [cell],
            evidence: .init([cell: 9]),
            reviews: [],
            comments: comments,
            isWritable: true
        ))

        XCTAssertEqual(viewModel.matrixCommentCards.map(\.scope), [.cell, .alleleRow, .sampleColumn])
        XCTAssertEqual(viewModel.matrixCommentCards.map(\.displayBody), [
            "Cell note",
            "Allele note",
            "Sample note",
        ])
        XCTAssertEqual(viewModel.matrixCommentCards.map(\.currentComment?.author), [
            "Cell analyst",
            "Row analyst",
            "Column analyst",
        ])
        XCTAssertEqual(
            viewModel.matrixCommentRemovalAvailability(scope: .cell),
            .enabled
        )
        XCTAssertEqual(
            viewModel.matrixCommentRemovalAvailability(scope: .alleleRow),
            .enabled
        )
        XCTAssertEqual(
            viewModel.matrixCommentRemovalAvailability(scope: .sampleColumn),
            .enabled
        )
        XCTAssertEqual(viewModel.matrixCommentCards.map(\.actionTitle), [
            "Save Changes",
            "Save Changes",
            "Save Changes",
        ])

        var requests: [GenotypeMatrixCommentEditRequest] = []
        viewModel.onMatrixCommentRequested = { requests.append($0) }
        viewModel.setMatrixCommentDraft("Updated cell note", scope: .cell)
        viewModel.saveMatrixComment(scope: .cell)
        viewModel.removeMatrixComment(scope: .alleleRow)

        XCTAssertEqual(requests, [
            .init(targets: [cell], intent: .upsert(body: "Updated cell note")),
            .init(targets: [row], intent: .remove),
        ])
    }

    func testBulkCommentCardsRequireExplicitReplaceForUniformMixedOrExistingValues() throws {
        let first = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let second = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalB"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Cells",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [first, second]
        ))
        viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 4, second: 5]),
            reviews: [],
            comments: [],
            isWritable: true
        ))

        var cellCard = try XCTUnwrap(
            viewModel.matrixCommentCards.first { $0.scope == .cell }
        )
        XCTAssertEqual(cellCard.valueState, .none)
        XCTAssertEqual(cellCard.actionTitle, "Add Comment")

        let uniformComments = [
            GenotypeAnnotationSidecar.MatrixComment(
                target: first,
                body: "Uniform note",
                author: "Analyst A",
                timestamp: "2026-07-24T10:00:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: second,
                body: "Uniform note",
                author: "Analyst B",
                timestamp: "2026-07-24T11:00:00Z"
            ),
        ]
        viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 4, second: 5]),
            reviews: [],
            comments: uniformComments,
            isWritable: true
        ))
        cellCard = try XCTUnwrap(viewModel.matrixCommentCards.first { $0.scope == .cell })
        XCTAssertEqual(cellCard.valueState, .uniform("Uniform note"))
        XCTAssertEqual(cellCard.displayBody, "Uniform note")
        XCTAssertEqual(cellCard.currentComments.map(\.author), ["Analyst A", "Analyst B"])
        XCTAssertEqual(cellCard.currentComments.map(\.timestamp), [
            "2026-07-24T10:00:00Z",
            "2026-07-24T11:00:00Z",
        ])
        XCTAssertEqual(cellCard.metadataSummary, "Multiple authors · Multiple timestamps")
        XCTAssertEqual(cellCard.actionTitle, "Replace Comments on 2 Targets")

        let mixedComments = [
            uniformComments[0],
            .init(
                target: second,
                body: "Different note",
                author: "Analyst B",
                timestamp: "2026-07-24T12:00:00Z"
            ),
        ]
        viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 4, second: 5]),
            reviews: [],
            comments: mixedComments,
            isWritable: true
        ))
        cellCard = try XCTUnwrap(viewModel.matrixCommentCards.first { $0.scope == .cell })
        XCTAssertEqual(cellCard.valueState, .mixed)
        XCTAssertEqual(cellCard.currentValueSummary, "Multiple comments")
        XCTAssertEqual(viewModel.matrixCommentDraft(scope: .cell), "")
        XCTAssertEqual(cellCard.actionTitle, "Replace Comments on 2 Targets")

        var request: GenotypeMatrixCommentEditRequest?
        viewModel.onMatrixCommentRequested = { request = $0 }
        viewModel.setMatrixCommentDraft("One replacement", scope: .cell)
        viewModel.saveMatrixComment(scope: .cell)

        XCTAssertEqual(
            request,
            .init(targets: [first, second], intent: .replace(body: "One replacement"))
        )
    }

    func testScopedCommentRemovalUsesSharedCapabilityForApplicableTargets() throws {
        let cell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let row = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01"
        )
        let capability = GenotypeMatrixReviewCapability.evaluate(
            selection: [cell],
            evidence: .init([cell: 3]),
            reviews: [],
            comments: [
                .init(
                    target: row,
                    body: "Applicable row note",
                    author: "Analyst",
                    timestamp: "2026-07-24T10:00:00Z"
                ),
            ],
            isWritable: true
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Cell",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [cell]
        ))
        viewModel.updateMatrixReviewCapability(capability)

        XCTAssertFalse(capability.removeComments.isEnabled)
        XCTAssertEqual(
            capability.removeCommentsAvailability(for: [cell]),
            .disabled(reason: "No comments to remove.")
        )
        XCTAssertEqual(
            capability.removeCommentsAvailability(for: [row]),
            .enabled
        )
        XCTAssertEqual(
            viewModel.matrixCommentRemovalAvailability(scope: .cell),
            .disabled(reason: "No comments to remove.")
        )
        XCTAssertEqual(
            viewModel.matrixCommentRemovalAvailability(scope: .alleleRow),
            .enabled
        )

        var requests: [GenotypeMatrixCommentEditRequest] = []
        viewModel.onMatrixCommentRequested = { requests.append($0) }
        viewModel.removeMatrixComment(scope: .cell)
        viewModel.removeMatrixComment(scope: .alleleRow)

        XCTAssertEqual(requests, [
            .init(targets: [row], intent: .remove),
        ])
    }

    func testAnnotationInspectorSourceOrdersReviewCommentsAndAppearanceAndUsesStableIDs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishGenotypeUI/GenotypeMatrixAnnotationSection.swift"
            ),
            encoding: .utf8
        )
        let identifiers = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift"
            ),
            encoding: .utf8
        )

        let review = try XCTUnwrap(source.range(of: "private var reviewControls"))
        let comments = try XCTUnwrap(source.range(of: "private var commentCards"))
        let appearance = try XCTUnwrap(source.range(of: "private var appearanceControls"))
        XCTAssertLessThan(review.lowerBound, comments.lowerBound)
        XCTAssertLessThan(comments.lowerBound, appearance.lowerBound)
        XCTAssertTrue(source.contains("DisclosureGroup(\"Appearance\""))
        XCTAssertTrue(source.contains("genotype-annotation-review-false-positive-button"))
        XCTAssertTrue(source.contains("genotype-annotation-review-false-negative-button"))
        XCTAssertTrue(source.contains("genotype-annotation-comment-card-cell"))
        XCTAssertTrue(source.contains("genotype-annotation-comment-card-allele-row"))
        XCTAssertTrue(source.contains("genotype-annotation-comment-card-sample-column"))
        XCTAssertTrue(source.contains("genotype-annotation-comment-bulk-replace-cell"))
        XCTAssertTrue(source.contains("genotype-annotation-comment-remove-cell"))
        XCTAssertTrue(source.contains("genotype-annotation-comment-disabled-reason-cell"))
        XCTAssertTrue(source.contains(
            ".disabled(!viewModel.matrixReviewCapability.upsertComment.isEnabled)"
        ))
        XCTAssertTrue(source.contains("genotype-annotation-appearance-disclosure"))
        XCTAssertTrue(identifiers.contains("reviewFalsePositiveButton"))
        XCTAssertTrue(identifiers.contains("commentCellCard"))
        XCTAssertTrue(identifiers.contains("commentCellBulkReplaceButton"))
        XCTAssertTrue(identifiers.contains("commentCellRemoveButton"))
        XCTAssertTrue(identifiers.contains("commentCellDisabledReason"))
        XCTAssertTrue(identifiers.contains("appearanceDisclosure"))
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
