import XCTest
import ViewInspector
@testable import LungfishApp
@testable import LungfishGenotypeUI
import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI
import LungfishTestSupport

@MainActor
final class GenotypeResultDisplaySectionTests: XCTestCase {
    func testCandidateDocumentSchemaFiveIsSupported() {
        XCTAssertTrue(isSupportedMHCCandidateDocumentSchemaVersion(5))
        XCTAssertFalse(isSupportedMHCCandidateDocumentSchemaVersion(6))
    }

    func testMatrixVisibilityCapabilityPresentsExactScopeAndActiveStatus() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let empty = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: []),
            visibility: .init()
        )

        viewModel.updateMatrixVisibilityCapability(empty)

        XCTAssertEqual(viewModel.matrixVisibilityScopeSummary, "Scope: Entire matrix")
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "No manual visibility restrictions."
        )
        XCTAssertFalse(viewModel.canResetMatrixVisibility)

        let targets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .cell(locus: "MHC-A", genotype: "A1", sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: "A1", sample: "AnimalB"),
        ]
        let active = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: targets),
            visibility: GenotypeMatrixVisibilityState()
                .hidingRows([.known(locus: "MHC-B", genotype: "B1")])
                .hidingSamples(["AnimalC"])
        )

        viewModel.updateMatrixVisibilityCapability(active)

        XCTAssertEqual(
            viewModel.matrixVisibilityScopeSummary,
            "Selected: 2 cells (1 row × 2 columns)"
        )
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "Manual allele-row and sample-column visibility are active."
        )
        XCTAssertTrue(viewModel.canResetMatrixVisibility)

        viewModel.updateMatrixVisibilityCapability(
            GenotypeMatrixVisibilityCapabilitySnapshot(
                selection: .init(targets: []),
                visibility: GenotypeMatrixVisibilityState()
                    .hidingRows([.known(locus: "MHC-B", genotype: "B1")])
            )
        )
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "Manual allele-row visibility is active."
        )

        viewModel.updateMatrixVisibilityCapability(
            GenotypeMatrixVisibilityCapabilitySnapshot(
                selection: .init(targets: []),
                visibility: GenotypeMatrixVisibilityState()
                    .hidingSamples(["AnimalC"])
            )
        )
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "Manual sample-column visibility is active."
        )
    }

    func testMatrixVisibilityActionsRouteOnlyEnabledImmutableCommands() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        var commands: [GenotypeMatrixVisibilityCommand] = []
        viewModel.onMatrixVisibilityCommandRequested = { commands.append($0) }
        viewModel.updateMatrixVisibilityCapability(
            GenotypeMatrixVisibilityCapabilitySnapshot(
                selection: .init(targets: [
                    .row(locus: "MHC-A", genotype: "A1"),
                ]),
                visibility: .init()
            )
        )

        viewModel.hideSelectedMatrixRows()
        viewModel.showOnlySelectedMatrixRows()
        viewModel.hideSelectedMatrixColumns()
        viewModel.showAllMatrixRows()
        viewModel.resetMatrixVisibility()

        XCTAssertEqual(commands, [.hideSelectedRows, .showOnlySelectedRows])

        viewModel.updateMatrixVisibilityCapability(
            GenotypeMatrixVisibilityCapabilitySnapshot(
                selection: .init(targets: []),
                visibility: GenotypeMatrixVisibilityState()
                    .hidingRows([.known(locus: "MHC-A", genotype: "A1")])
            )
        )
        viewModel.showAllMatrixRows()
        viewModel.resetMatrixVisibility()

        XCTAssertEqual(
            commands,
            [
                .hideSelectedRows,
                .showOnlySelectedRows,
                .showAllRows,
                .reset,
            ]
        )
    }

    func testMatrixVisibilitySnapshotClearsWithInspectorDocumentState() {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let active = GenotypeMatrixVisibilityCapabilitySnapshot(
            selection: .init(targets: [
                .column(sample: "AnimalA"),
            ]),
            visibility: GenotypeMatrixVisibilityState()
                .hidingSamples(["AnimalB"])
        )
        viewModel.updateMatrixVisibilityCapability(active)

        viewModel.update(isAvailable: true)

        XCTAssertEqual(viewModel.matrixVisibilityScopeSummary, "Scope: Entire matrix")
        XCTAssertFalse(viewModel.canResetMatrixVisibility)

        viewModel.updateMatrixVisibilityCapability(
            GenotypeMatrixVisibilityCapabilitySnapshot(
                selection: .init(targets: [
                    .column(sample: "AnimalA"),
                ]),
                visibility: GenotypeMatrixVisibilityState()
                    .hidingSamples(["AnimalB"])
            )
        )

        viewModel.clear()

        XCTAssertEqual(viewModel.matrixVisibilityScopeSummary, "Scope: Entire matrix")
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "No manual visibility restrictions."
        )
        XCTAssertFalse(viewModel.canResetMatrixVisibility)
    }

    func testMatrixVisibilityInspectorUsesApprovedGuidanceAndStableIdentifiers() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from source-text grep to behavioral assertions: every heading,
        // guidance string, and stable accessibility identifier below is proven to
        // actually render in the live tree, not merely appear as a substring of the
        // view's source file.
        _ = try inspected.find(text: "Search and Support Filters")
        _ = try inspected.find(text: "Selected Rows and Columns")
        _ = try inspected.find(text:
            "Select allele row markers or sample column headers to change visibility. "
                + "Visibility actions use the selection. Search and support filters always "
                + "apply to the currently visible matrix."
        )
        for title in [
            "Hide Selected Rows",
            "Show Only Selected Rows",
            "Show All Rows",
            "Hide Selected Columns",
            "Show Only Selected Columns",
            "Show All Columns",
            "Reset Visibility",
        ] {
            _ = try inspected.find(text: title)
        }
        for identifier in [
            InspectorAccessibilityID.genotypeVisibilityGroup,
            InspectorAccessibilityID.genotypeVisibilityScope,
            InspectorAccessibilityID.genotypeVisibilityStatus,
            InspectorAccessibilityID.genotypeVisibilityGuidance,
            InspectorAccessibilityID.genotypeRowVisibilityMenu,
            InspectorAccessibilityID.genotypeHideSelectedRows,
            InspectorAccessibilityID.genotypeShowOnlySelectedRows,
            InspectorAccessibilityID.genotypeShowAllRows,
            InspectorAccessibilityID.genotypeColumnVisibilityMenu,
            InspectorAccessibilityID.genotypeHideSelectedColumns,
            InspectorAccessibilityID.genotypeShowOnlySelectedColumns,
            InspectorAccessibilityID.genotypeShowAllColumns,
            InspectorAccessibilityID.genotypeResetVisibility,
        ] {
            _ = try inspected.find(viewWithAccessibilityIdentifier: identifier)
        }
    }

    func testMatrixVisibilityMainSplitWiringUsesActiveControllerAndInspectorCleanup() {
        let mainSplitSource = combinedMainSplitViewControllerSource()
        let inspectorSource = combinedInspectorViewControllerSource()

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // The end-to-end *effect* of this MainSplitViewController wiring (capability
        // flowing from GenotypeResultViewController into
        // genotypeResultDisplaySectionViewModel.matrixVisibilityCapability, and commands
        // routing back) IS already exercised behaviorally in
        // MappingViewportRoutingTests.testGenotypeMatrixVisibilityBridgePublishesInitialCapabilityAndRoutesViewCommand.
        // This assertion instead targets the specific closure-assignment source lines
        // themselves (e.g. that cleanup nils the closure via source inspection rather
        // than by re-running the same bridge test), which has no separate runtime seam.
        XCTAssertTrue(mainSplitSource.contains(
            "controller.onMatrixVisibilityCapabilityChanged = { [weak self, weak controller] capability in"
        ))
        XCTAssertTrue(mainSplitSource.contains(
            "self.viewerController.genotypeResultViewController === controller"
        ))
        XCTAssertTrue(mainSplitSource.contains(
            "onMatrixVisibilityCommandRequested = { [weak self, weak controller] command in"
        ))
        XCTAssertTrue(mainSplitSource.contains(
            "controller?.performMatrixVisibilityCommand(command)"
        ))
        XCTAssertTrue(mainSplitSource.contains(
            "controller.notifyMatrixVisibilityCapabilityIfAvailable()"
        ))
        XCTAssertTrue(inspectorSource.contains(
            "onMatrixVisibilityCommandRequested = nil"
        ))
        XCTAssertFalse(inspectorSource.contains(
            "onClearMatrixSelectionFilterRequested = nil"
        ))
    }

    /// Reported 2026-09-03: the "Export Filtered Pivot" action added the day
    /// before lived in the viewport's Audit lens, which is hidden for MiSeq
    /// results, so the analyst who asked for it could not find it. The export
    /// now sits in the Inspector beside the filters it applies, and it is the
    /// only export offered there: the workbook copy it writes already carries
    /// every sheet of the result workbook.
    func testFilteredPivotExportRendersInGenotypeDisplayOnlyWhenAViewportIsBound() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let unbound = try GenotypeResultDisplaySection(viewModel: viewModel).inspect()
        XCTAssertThrowsError(
            try unbound.find(viewWithAccessibilityIdentifier: "genotype-inspector-export"),
            "no viewport bound, so no export can be offered"
        )

        var requests = 0
        viewModel.onFilteredPivotExportRequested = { requests += 1 }
        let bound = try GenotypeResultDisplaySection(viewModel: viewModel).inspect()
        _ = try bound.find(text: "Export")
        _ = try bound.find(viewWithAccessibilityIdentifier: "genotype-inspector-export")
        try bound.find(viewWithAccessibilityIdentifier: "genotype-inspector-export-filtered-pivot")
            .button().tap()
        XCTAssertEqual(requests, 1)
        _ = try bound.find(text: "Filtered Pivot\u{2026}")
        XCTAssertThrowsError(
            try bound.find(text: "Excel View\u{2026}"),
            "the plain Excel view export is not offered from the Inspector"
        )
    }

    func testFilteredPivotExportMainSplitWiringUsesActiveControllerAndInspectorCleanup() {
        let mainSplitSource = combinedMainSplitViewControllerSource()
        let inspectorSource = combinedInspectorViewControllerSource()

        // source-text: same seam as the visibility wiring test above.
        XCTAssertTrue(mainSplitSource.contains(
            "onFilteredPivotExportRequested = { [weak self, weak controller] in"
        ))
        XCTAssertTrue(mainSplitSource.contains(
            "controller?.exportFilteredPivotFromInspector()"
        ))
        XCTAssertTrue(inspectorSource.contains(
            "onFilteredPivotExportRequested = nil"
        ))
    }

    func testContentTextSizeActionsUseGlobalPreferenceWithoutPublishingDisplayState() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()

        let announcements = RecordingContentTextSizeAnnouncements()
        let viewModel = GenotypeResultDisplaySectionViewModel(
            contentTextSizeAnnouncementPoster: announcements
        )
        var displayStatePublicationCount = 0
        viewModel.onDisplayStateChanged = { _ in displayStatePublicationCount += 1 }

        XCTAssertEqual(viewModel.contentTextSizeLabel, "100%")
        XCTAssertTrue(viewModel.canDecreaseContentTextSize)
        XCTAssertTrue(viewModel.canIncreaseContentTextSize)

        viewModel.increaseContentTextSize()

        XCTAssertEqual(settings.contentTextSizePreference, .custom(125))
        XCTAssertEqual(viewModel.contentTextSizeLabel, "125%")
        XCTAssertEqual(announcements.messages, ["Content text size 125 percent"])
        XCTAssertEqual(displayStatePublicationCount, 0)

        viewModel.restoreSystemContentTextSize()

        XCTAssertEqual(settings.contentTextSizePreference, .system)
        XCTAssertEqual(viewModel.contentTextSizeLabel, "System")
        XCTAssertEqual(
            announcements.messages,
            ["Content text size 125 percent", "Content text size System"]
        )
        XCTAssertEqual(displayStatePublicationCount, 0)
    }

    func testContentTextSizeActionsRespectSupportedBoundsAndDoNotAnnounceNoOp() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        let announcements = RecordingContentTextSizeAnnouncements()
        let viewModel = GenotypeResultDisplaySectionViewModel(
            contentTextSizeAnnouncementPoster: announcements
        )

        settings.contentTextSizePreference = .custom(90)
        settings.save()
        XCTAssertFalse(viewModel.canDecreaseContentTextSize)
        viewModel.decreaseContentTextSize()
        XCTAssertEqual(settings.contentTextSizePreference, .custom(90))
        XCTAssertTrue(announcements.messages.isEmpty)

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        XCTAssertFalse(viewModel.canIncreaseContentTextSize)
        viewModel.increaseContentTextSize()
        XCTAssertEqual(settings.contentTextSizePreference, .custom(200))
        XCTAssertTrue(announcements.messages.isEmpty)
    }

    func testContentTextSizeInspectorUsesStableAccessibleControls() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()

        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from source-text grep to behavioral assertions: each control
        // actually renders with the stable accessibility identifier/label pair that
        // downstream XCUI relies on, not merely present somewhere in source text.
        // The throw IS the assertion: find(text:) fails the test if the heading
        // isn't actually rendered, so no captured/inspected result is needed.
        _ = try inspected.find(text: "Content Text Size")

        let decreaseButton = try inspected.find(viewWithAccessibilityIdentifier: "genotype-view-content-text-size-decrease")
        XCTAssertEqual(try decreaseButton.accessibilityLabel().string(), "Decrease content text size")

        let valueText = try inspected.find(viewWithAccessibilityIdentifier: "genotype-view-content-text-size-value")
        XCTAssertEqual(try valueText.accessibilityLabel().string(), "Content text size")

        let increaseButton = try inspected.find(viewWithAccessibilityIdentifier: "genotype-view-content-text-size-increase")
        XCTAssertEqual(try increaseButton.accessibilityLabel().string(), "Increase content text size")

        let defaultButton = try inspected.find(viewWithAccessibilityIdentifier: "genotype-view-content-text-size-default")
        XCTAssertEqual(try defaultButton.accessibilityLabel().string(), "Use system content text size")
    }

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
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from source-text grep to a behavioral assertion: the rendered
        // Layout picker's selection is genuinely bound to `viewModel.setLayout`, and
        // it offers exactly the three documented panel layouts, each labeled as
        // expected. (ViewInspector does not expose picker *style* tokens like
        // `.radioGroup` for inspection -- that half of the original assertion was
        // presentational, not behavioral, so it has no runtime-observable
        // equivalent and is dropped rather than converted.)
        let picker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Layout"
        })

        let expectedLabels: [GenotypeResultPanelLayout: String] = [
            .listTrailing: "Detail | List",
            .listLeading: "List | Detail",
            .listTop: "List Over Detail",
        ]
        for layout in expectedLabels.keys {
            try picker.select(value: layout)
            XCTAssertEqual(viewModel.displayState.layout, layout)
        }

        let labelTexts = Set(picker.findAll(ViewType.Label.self).compactMap { try? $0.title().text().string() })
        XCTAssertEqual(labelTexts, Set(expectedLabels.values))
    }

    func testViewportAndLayoutControlsAreGuardedForGenotypeOnlyResults() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true, isGenotypeOnlyResult: true)
        let genotypeOnlyInspected = try GenotypeResultDisplaySection(viewModel: viewModel).inspect()

        // Converted from a source-range/brace-matching extraction to a behavioral
        // assertion: for a genotype-only result, neither the Viewport nor the Layout
        // picker renders at all -- proving the `if viewModel.showsViewportAndLayoutControls`
        // guard actually suppresses both controls at runtime, not merely that the
        // guard's source text mentions their view-builder names.
        XCTAssertTrue(genotypeOnlyInspected.findAll(ViewType.Picker.self).allSatisfy { picker in
            (try? picker.labelView().text().string()) != "Viewport"
                && (try? picker.labelView().text().string()) != "Layout"
        })

        let fullViewModel = GenotypeResultDisplaySectionViewModel()
        fullViewModel.update(isAvailable: true, isGenotypeOnlyResult: false)
        let fullInspected = try GenotypeResultDisplaySection(viewModel: fullViewModel).inspect()

        // When the guard is satisfied, both pickers render with their documented
        // options/labels. (ViewInspector cannot read picker *style* tokens like
        // `.radioGroup` for inspection, matching the established limitation
        // documented in testLayoutControlUsesSharedTwoPaneRadioGroupStyle above, so
        // that half of the original assertion has no runtime-observable equivalent
        // and is not converted.)
        let viewportPicker = try fullInspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Viewport"
        })
        let viewportLabels = Set(viewportPicker.findAll(ViewType.Label.self).compactMap {
            try? $0.title().text().string()
        })
        XCTAssertEqual(
            viewportLabels,
            Set(GenotypeResultViewportLens.allCases.map(\.displayName))
        )

        _ = try fullInspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Layout"
        })
    }

    func testGenotypeDisplaySectionDoesNotExposeLiveReadThresholdControls() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from source-text grep to behavioral assertions on the actual
        // rendered tree: no live Slider control exists anywhere in the rendered
        // section, no "Hide Low Support"/"Minimum Reads" text renders, and the
        // fixed-thresholds guidance copy does render.
        XCTAssertTrue(inspected.findAll(ViewType.Slider.self).isEmpty)

        let renderedText = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertFalse(renderedText.contains(where: { $0.contains("Hide Low Support") }))
        XCTAssertFalse(renderedText.contains(where: { $0.contains("Minimum Reads") }))
        XCTAssertTrue(renderedText.contains(where: { $0.contains("Genotype calls and haplotype thresholds are fixed") }))
        XCTAssertTrue(renderedText.contains(where: { $0.contains("Re-run the original genotyping workflow") }))
    }

    func testGenotypeDisplaySectionKeepsThresholdGuidanceSeparateFromColorControls() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from a source-range extraction (text between the
        // `thresholdGuidance` and `matrixFilterControls` property declarations) to a
        // behavioral assertion on the actual rendered group: the VStack that renders
        // the "Run and Calling Thresholds" heading has no TextField/Stepper
        // descendants of its own -- those controls live in sibling groups instead.
        let thresholdGroup = try inspected.find(ViewType.VStack.self, where: { group in
            // Match on the group's own direct first child being the heading (rather
            // than `findAll`, which matches transitively and would also match the
            // outer DisclosureGroup content VStack that contains everything).
            (try? group.text(0).string()) == "Run and Calling Thresholds"
        })
        XCTAssertTrue(thresholdGroup.findAll(ViewType.TextField.self).isEmpty)
        XCTAssertTrue(thresholdGroup.findAll(ViewType.Stepper.self).isEmpty)
    }

    func testMatrixThresholdControlsUseEditableFieldsHiddenLabelSteppersAndOffGuidance() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from a source-range extraction to behavioral assertions on the
        // actual rendered controls: both threshold fields render as real, editable
        // TextFields (not static "Min reads: N" labels) with their stable
        // accessibility identifiers, and the "%"/"0 = Off." guidance text renders
        // too. The hidden-label stepper alongside each field is NOT a SwiftUI
        // `Stepper` -- it is `GenotypeNumericFilterStepper`, a `private`
        // `NSViewRepresentable` wrapping a real `NSStepper` (see
        // GenotypeResultDisplaySection.swift). `find(ViewType.Stepper.self)` cannot
        // match it (wrong ViewType -- it isn't a SwiftUI Stepper at all), and its
        // type being file-`private` means no test-file code can even name
        // `GenotypeNumericFilterStepper` to search for it via
        // `find(ViewType.View<T>.self)`, the pattern used for other custom views in
        // this suite (batch 2's `PrimerSchemePickerView`, which is merely
        // `internal`). ViewInspector has no generic `ViewType` for an arbitrary
        // `NSViewRepresentable`. The stepper's effect IS exercised behaviorally
        // below via `viewModel.setMatrixMinimumReadsFromStepper`/
        // `setMatrixMinimumPercentFromStepper` (the same callback the real
        // `NSStepper`'s `onChange` invokes), which is the closest verifiable
        // proxy for its behavior without introducing a new `ViewHosting`-based
        // real-AppKit-hierarchy test pattern (no precedent for that in this repo).
        let readsField = try inspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "Min reads"
        })
        XCTAssertEqual(
            try readsField.accessibilityIdentifier(),
            "genotype-view-minimum-reads-field"
        )

        let percentField = try inspected.find(ViewType.TextField.self, where: { tf in
            (try? tf.labelView().text().string()) == "Min percent"
        })
        XCTAssertEqual(
            try percentField.accessibilityIdentifier(),
            "genotype-view-minimum-percent-field"
        )

        _ = try inspected.find(text: "%")
        _ = try inspected.find(text: "0 = Off.")

        let renderedText = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertFalse(renderedText.contains(where: { $0.hasPrefix("Min reads: ") }))
        XCTAssertFalse(renderedText.contains(where: { $0.hasPrefix("Min percent: ") }))

        viewModel.setMatrixMinimumReadsFromStepper(42)
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 42)
        viewModel.setMatrixMinimumPercentFromStepper(12.5)
        XCTAssertEqual(viewModel.displayState.matrixMinimumPercent, 12.5)
    }

    func testGenotypeViewSectionExposesHaplotypeViewportControl() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from source-text grep to a behavioral assertion: the rendered
        // Viewport picker's selection is genuinely bound to
        // `viewModel.setViewportLens`, and it offers exactly the full
        // `GenotypeResultViewportLens.allCases` set of options -- proven by actually
        // selecting each lens through ViewInspector and observing the view model's
        // display state update, not by finding the symbol name in source text.
        let picker = try inspected.find(ViewType.Picker.self, where: { picker in
            (try? picker.labelView().text().string()) == "Viewport"
        })

        for lens in GenotypeResultViewportLens.allCases {
            try picker.select(value: lens)
            XCTAssertEqual(viewModel.displayState.viewportLens, lens)
        }
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
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.update(isAvailable: true)
        let target = GenotypeResultHighlightTarget(
            genotype: "01_Mafa_A1_001_01",
            locus: "MHC-A",
            sample: "AnimalA"
        )
        viewModel.updateSelection(GenotypeResultSelectionState(
            title: target.genotype,
            subtitle: "MHC-A - 1 sample",
            detailRows: [],
            highlightTarget: target,
            highlightStyle: .default
        ))
        let view = GenotypeResultDisplaySection(viewModel: viewModel)
        let inspected = try view.inspect()

        // Converted from source-text grep to a behavioral assertion: once a highlight
        // target is selected, GenotypeResultDisplaySection itself (not a separate
        // Inspector-side view) renders the "Clear Fill"/"Clear Border" buttons.
        _ = try inspected.find(button: "Clear Fill")
        _ = try inspected.find(button: "Clear Border")

        // The SelectionSection sidebar view is a different SUT that this file cannot
        // instantiate standalone (it needs a full InspectorViewModel); its source is
        // checked separately to confirm genotypeResultSelectionView doesn't call
        // genotypeHighlightControls(target:) as one of its own view-builder children
        // (scoped to that one function's body, not the whole file, since the file also
        // contains genotypeHighlightControls's own declaration line).
        let selectionSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/SelectionSection.swift"),
            encoding: .utf8
        )
        let selectionViewStart = try XCTUnwrap(
            selectionSource.range(of: "private func genotypeResultSelectionView")
        )
        let selectionViewEnd = try XCTUnwrap(
            selectionSource[selectionViewStart.lowerBound...]
                .range(of: "private func genotypeHighlightControls")
        )
        let selectionViewBody = String(
            selectionSource[selectionViewStart.lowerBound..<selectionViewEnd.lowerBound]
        )
        XCTAssertFalse(selectionViewBody.contains("genotypeHighlightControls(target:"))
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

    func testAnnotationInspectorSummarizesRowColumnAndMixedTargetCountsAndTypes() {
        let rowA = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01"
        )
        let rowB = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-B",
            genotype: "02_Mafa_B1_001_01"
        )
        let column = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let cell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        func update(_ targets: [GenotypeAnnotationSidecar.MatrixTarget]) {
            viewModel.updateSelection(.init(
                title: "Matrix selection",
                subtitle: "Annotations",
                detailRows: [],
                matrixTargets: targets
            ))
            viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
                selection: targets,
                evidence: .init(),
                reviews: [],
                comments: [],
                isWritable: true
            ))
        }

        update([rowA, rowB])
        XCTAssertEqual(viewModel.matrixReviewCapability.selectionShape, .rows)
        XCTAssertEqual(viewModel.matrixSelectionSummary, "2 allele rows selected")

        update([column])
        XCTAssertEqual(viewModel.matrixReviewCapability.selectionShape, .columns)
        XCTAssertEqual(viewModel.matrixSelectionSummary, "1 sample column selected")

        update([rowA, column, cell])
        XCTAssertEqual(viewModel.matrixReviewCapability.selectionShape, .mixed)
        XCTAssertEqual(viewModel.matrixSelectionSummary, "3 mixed matrix targets selected")
    }

    func testAnnotationIdentitySectionReportsSavingIdentityAndInvokesSettingsCallback() {
        var settingsOpenCount = 0
        let section = GenotypeAnnotationIdentitySection(
            analystIdentity: "Dr. Test",
            openSettings: { settingsOpenCount += 1 }
        )

        XCTAssertEqual(section.savingAsText, "Saving as: Dr. Test")
        section.openSettingsPane()

        XCTAssertEqual(settingsOpenCount, 1)
    }

    func testAnnotationCommentDraftSurvivesCapabilityRefreshAndRehydratesSavedChanges() throws {
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Cell",
            subtitle: "Annotations",
            detailRows: [],
            matrixTargets: [target]
        ))

        func capability(comment: String) -> GenotypeMatrixReviewCapabilityState {
            GenotypeMatrixReviewCapability.evaluate(
                selection: [target],
                evidence: .init([target: 8]),
                reviews: [],
                comments: [
                    .init(
                        target: target,
                        body: comment,
                        author: "Analyst",
                        timestamp: "2026-07-24T12:00:00Z"
                    ),
                ],
                isWritable: true
            )
        }

        viewModel.updateMatrixReviewCapability(capability(comment: "Saved"))
        XCTAssertEqual(viewModel.matrixCommentDraft(scope: .cell), "Saved")

        viewModel.setMatrixCommentDraft("Unsaved edit", scope: .cell)
        viewModel.updateMatrixReviewCapability(capability(comment: "Saved"))
        XCTAssertEqual(viewModel.matrixCommentDraft(scope: .cell), "Unsaved edit")

        viewModel.setMatrixCommentDraft("Saved", scope: .cell)
        viewModel.updateMatrixReviewCapability(capability(comment: "Changed elsewhere"))
        XCTAssertEqual(viewModel.matrixCommentDraft(scope: .cell), "Changed elsewhere")
    }

    func testReadOnlyAnnotationCapabilityGatesEditorAndMutationCallbacks() {
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01",
            sample: "AnimalA"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Cell",
            subtitle: "Annotations",
            detailRows: [],
            matrixTargets: [target]
        ))
        viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [target],
            evidence: .init([target: 8]),
            reviews: [],
            comments: [],
            isWritable: false
        ))
        var reviewRequests: [GenotypeMatrixReviewRequest] = []
        var commentRequests: [GenotypeMatrixCommentEditRequest] = []
        viewModel.onMatrixReviewRequested = { reviewRequests.append($0) }
        viewModel.onMatrixCommentRequested = { commentRequests.append($0) }
        viewModel.setMatrixCommentDraft("Blocked", scope: .cell)

        XCTAssertFalse(viewModel.isMatrixCommentEditorEnabled)
        viewModel.markMatrixFalsePositive()
        viewModel.markMatrixFalseNegative()
        viewModel.clearMatrixReview()
        viewModel.saveMatrixComment(scope: .cell)
        viewModel.removeMatrixComment(scope: .cell)

        XCTAssertEqual(reviewRequests, [])
        XCTAssertEqual(commentRequests, [])
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

        // The DisclosureGroup/comment-card ordering (Review, then Comments, then
        // Appearance) is a structural property of the source itself, not something
        // ViewInspector's top-down find() can observe independently of that source
        // (there's no "which section comes first" API) -- kept as a source check.
        let review = try XCTUnwrap(source.range(of: "private var reviewControls"))
        let comments = try XCTUnwrap(source.range(of: "private var commentCards"))
        let appearance = try XCTUnwrap(source.range(of: "private var appearanceControls"))
        XCTAssertLessThan(review.lowerBound, comments.lowerBound)
        XCTAssertLessThan(comments.lowerBound, appearance.lowerBound)

        // Converted from source-text grep to behavioral assertions: build a fixture
        // that forces one cell-scoped comment card into its "bulk replace" state
        // (mixed comment bodies across two targets) and a read-only capability so the
        // disabled-reason row also renders, then prove every identifier below is a
        // real accessibility identifier on the rendered tree, not merely a substring
        // of the view's source file.
        let first = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AnimalA"
        )
        let second = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AnimalB"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        viewModel.updateSelection(.init(
            title: "Two cells",
            subtitle: "Matrix annotations",
            detailRows: [],
            matrixTargets: [first, second]
        ))
        viewModel.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [first, second],
            evidence: .init([first: 9, second: 4]),
            reviews: [],
            comments: [
                .init(target: first, body: "Note A", author: "Analyst", timestamp: "2026-07-24T12:00:00Z"),
                .init(target: second, body: "Note B", author: "Analyst", timestamp: "2026-07-24T12:01:00Z"),
            ],
            isWritable: false
        ))
        let view = GenotypeMatrixAnnotationSection(viewModel: viewModel)
        let inspected = try view.inspect()

        _ = try inspected.find(text: "Appearance")
        _ = try inspected.find(button: "False Positive")
        _ = try inspected.find(button: "False Negative")
        for identifier in [
            "genotype-annotation-review-false-positive-button",
            "genotype-annotation-review-false-negative-button",
            "genotype-annotation-comment-card-cell",
            "genotype-annotation-comment-bulk-replace-cell",
            "genotype-annotation-comment-remove-cell",
            "genotype-annotation-comment-disabled-reason-cell",
            "genotype-annotation-appearance-disclosure",
        ] {
            _ = try inspected.find(viewWithAccessibilityIdentifier: identifier)
        }
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

@MainActor
private final class RecordingContentTextSizeAnnouncements: AccessibilityAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(
        _ message: String,
        priority: ContentAccessibilityAnnouncementPriority
    ) {
        messages.append(message)
    }
}
