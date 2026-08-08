// InspectorSampleSectionTests.swift - Tests for SampleSection inspector view model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

// MARK: - SampleSectionViewModelTests

@MainActor
final class SampleSectionViewModelTests: XCTestCase {

    private func makeViewModel() -> SampleSectionViewModel {
        SampleSectionViewModel()
    }

    private let testSampleNames = ["Sample1", "Sample2", "Sample3", "Sample4", "Sample5"]

    // MARK: - Initial State

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.sampleCount, 0)
        XCTAssertTrue(vm.sampleNames.isEmpty)
        XCTAssertTrue(vm.metadataFields.isEmpty)
        XCTAssertFalse(vm.hasVariantData)
        XCTAssertTrue(vm.isExpanded)
        XCTAssertTrue(vm.displayState.showGenotypeRows)
        XCTAssertEqual(vm.displayState.rowHeight, 12)
        XCTAssertTrue(vm.displayState.hiddenSamples.isEmpty)
        XCTAssertTrue(vm.displayState.sortFields.isEmpty)
        XCTAssertTrue(vm.displayState.filters.isEmpty)
    }

    // MARK: - Update

    func testUpdateWithSampleData() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: ["sex", "population"])

        XCTAssertEqual(vm.sampleCount, 5)
        XCTAssertEqual(vm.sampleNames, testSampleNames)
        XCTAssertEqual(vm.metadataFields, ["sex", "population"])
        XCTAssertTrue(vm.hasVariantData)
    }

    func testUpdateWithZeroSamples() {
        let vm = makeViewModel()
        vm.update(sampleCount: 0, sampleNames: [], metadataFields: [])

        XCTAssertEqual(vm.sampleCount, 0)
        XCTAssertFalse(vm.hasVariantData)
    }

    func testClear() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: ["sex"])
        XCTAssertTrue(vm.hasVariantData)

        vm.clear()
        XCTAssertEqual(vm.sampleCount, 0)
        XCTAssertTrue(vm.sampleNames.isEmpty)
        XCTAssertTrue(vm.metadataFields.isEmpty)
        XCTAssertFalse(vm.hasVariantData)
        XCTAssertTrue(vm.displayState.showGenotypeRows)
        XCTAssertEqual(vm.displayState.rowHeight, 12)
    }

    // MARK: - Genotype Row Toggle

    func testToggleGenotypeRows() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.displayState.showGenotypeRows)

        vm.toggleGenotypeRows()
        XCTAssertFalse(vm.displayState.showGenotypeRows)

        vm.toggleGenotypeRows()
        XCTAssertTrue(vm.displayState.showGenotypeRows)
    }

    func testToggleGenotypeRowsFiresCallback() {
        let vm = makeViewModel()
        var callbackFired = false
        vm.onDisplayStateChanged = { _ in callbackFired = true }

        vm.toggleGenotypeRows()
        XCTAssertTrue(callbackFired)
    }

    // MARK: - Row Height

    func testSetRowHeight() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.displayState.rowHeight, 12)

        vm.setRowHeight(2)
        XCTAssertEqual(vm.displayState.rowHeight, 2)

        vm.setRowHeight(30)
        XCTAssertEqual(vm.displayState.rowHeight, 30)

        vm.setRowHeight(12)
        XCTAssertEqual(vm.displayState.rowHeight, 12)
    }

    func testSetRowHeightClampsRange() {
        let vm = makeViewModel()

        vm.setRowHeight(0)
        XCTAssertEqual(vm.displayState.rowHeight, 2)

        vm.setRowHeight(100)
        XCTAssertEqual(vm.displayState.rowHeight, 30)
    }

    func testSetRowHeightFiresCallback() {
        let vm = makeViewModel()
        var receivedState: SampleDisplayState?
        vm.onDisplayStateChanged = { state in receivedState = state }

        vm.setRowHeight(5)
        XCTAssertEqual(receivedState?.rowHeight, 5)
    }

    func testSetSummaryBarHeight() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.displayState.summaryBarHeight, 20)

        vm.setSummaryBarHeight(40)
        XCTAssertEqual(vm.displayState.summaryBarHeight, 40)
    }

    func testSetSummaryBarHeightClampsRange() {
        let vm = makeViewModel()

        vm.setSummaryBarHeight(5)
        XCTAssertEqual(vm.displayState.summaryBarHeight, 10)

        vm.setSummaryBarHeight(100)
        XCTAssertEqual(vm.displayState.summaryBarHeight, 60)
    }

    // MARK: - Sample Visibility

    func testVisibleSampleCount() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: [])

        XCTAssertEqual(vm.visibleSampleCount, 5)
        XCTAssertFalse(vm.hasHiddenSamples)
    }

    func testToggleSampleVisibility() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: [])

        vm.toggleSampleVisibility("Sample1")
        XCTAssertTrue(vm.displayState.hiddenSamples.contains("Sample1"))
        XCTAssertEqual(vm.visibleSampleCount, 4)
        XCTAssertTrue(vm.hasHiddenSamples)

        // Toggle again to show
        vm.toggleSampleVisibility("Sample1")
        XCTAssertFalse(vm.displayState.hiddenSamples.contains("Sample1"))
        XCTAssertEqual(vm.visibleSampleCount, 5)
        XCTAssertFalse(vm.hasHiddenSamples)
    }

    func testHideAllSamples() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: [])

        vm.hideAllSamples()
        XCTAssertEqual(vm.visibleSampleCount, 0)
        XCTAssertEqual(vm.displayState.hiddenSamples.count, 5)
    }

    func testShowAllSamples() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: [])
        vm.hideAllSamples()
        XCTAssertEqual(vm.visibleSampleCount, 0)

        vm.showAllSamples()
        XCTAssertEqual(vm.visibleSampleCount, 5)
        XCTAssertTrue(vm.displayState.hiddenSamples.isEmpty)
    }

    func testToggleSampleVisibilityFiresCallback() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: [])

        var callbackCount = 0
        vm.onDisplayStateChanged = { _ in callbackCount += 1 }

        vm.toggleSampleVisibility("Sample1")
        vm.toggleSampleVisibility("Sample2")
        XCTAssertEqual(callbackCount, 2)
    }

    // MARK: - Sort Fields

    func testAddSortField() {
        let vm = makeViewModel()

        vm.addSortField("sex", ascending: true)
        XCTAssertEqual(vm.displayState.sortFields.count, 1)
        XCTAssertEqual(vm.displayState.sortFields[0].field, "sex")
        XCTAssertTrue(vm.displayState.sortFields[0].ascending)
    }

    func testAddSortFieldReplacesDuplicate() {
        let vm = makeViewModel()

        vm.addSortField("sex", ascending: true)
        vm.addSortField("sex", ascending: false)
        XCTAssertEqual(vm.displayState.sortFields.count, 1)
        XCTAssertFalse(vm.displayState.sortFields[0].ascending)
    }

    func testAddMultipleSortFields() {
        let vm = makeViewModel()

        vm.addSortField("sex")
        vm.addSortField("population")
        XCTAssertEqual(vm.displayState.sortFields.count, 2)
        XCTAssertEqual(vm.displayState.sortFields[0].field, "sex")
        XCTAssertEqual(vm.displayState.sortFields[1].field, "population")
    }

    func testRemoveSortField() {
        let vm = makeViewModel()

        vm.addSortField("sex")
        vm.addSortField("population")
        vm.removeSortField(at: 0)
        XCTAssertEqual(vm.displayState.sortFields.count, 1)
        XCTAssertEqual(vm.displayState.sortFields[0].field, "population")
    }

    func testRemoveSortFieldOutOfBounds() {
        let vm = makeViewModel()
        vm.addSortField("sex")

        // Should not crash
        vm.removeSortField(at: 5)
        XCTAssertEqual(vm.displayState.sortFields.count, 1)
    }

    func testClearSortFields() {
        let vm = makeViewModel()

        vm.addSortField("sex")
        vm.addSortField("population")
        vm.clearSortFields()
        XCTAssertTrue(vm.displayState.sortFields.isEmpty)
    }

    func testSortFieldFiresCallback() {
        let vm = makeViewModel()
        var callbackCount = 0
        vm.onDisplayStateChanged = { _ in callbackCount += 1 }

        vm.addSortField("sex")
        vm.removeSortField(at: 0)
        vm.addSortField("pop")
        vm.clearSortFields()
        XCTAssertEqual(callbackCount, 4)
    }

    // MARK: - Filters

    func testAddFilter() {
        let vm = makeViewModel()

        vm.addFilter(field: "sex", op: .equals, value: "male")
        XCTAssertEqual(vm.displayState.filters.count, 1)
        XCTAssertEqual(vm.displayState.filters[0].field, "sex")
        XCTAssertEqual(vm.displayState.filters[0].op, .equals)
        XCTAssertEqual(vm.displayState.filters[0].value, "male")
    }

    func testAddMultipleFilters() {
        let vm = makeViewModel()

        vm.addFilter(field: "sex", op: .equals, value: "male")
        vm.addFilter(field: "population", op: .contains, value: "EUR")
        XCTAssertEqual(vm.displayState.filters.count, 2)
    }

    func testRemoveFilter() {
        let vm = makeViewModel()

        vm.addFilter(field: "sex", op: .equals, value: "male")
        vm.addFilter(field: "population", op: .contains, value: "EUR")
        vm.removeFilter(at: 0)
        XCTAssertEqual(vm.displayState.filters.count, 1)
        XCTAssertEqual(vm.displayState.filters[0].field, "population")
    }

    func testRemoveFilterOutOfBounds() {
        let vm = makeViewModel()
        vm.addFilter(field: "sex", op: .equals, value: "male")

        // Should not crash
        vm.removeFilter(at: 10)
        XCTAssertEqual(vm.displayState.filters.count, 1)
    }

    func testClearFilters() {
        let vm = makeViewModel()

        vm.addFilter(field: "sex", op: .equals, value: "male")
        vm.addFilter(field: "population", op: .contains, value: "EUR")
        vm.clearFilters()
        XCTAssertTrue(vm.displayState.filters.isEmpty)
    }

    func testFilterFiresCallback() {
        let vm = makeViewModel()
        var callbackCount = 0
        vm.onDisplayStateChanged = { _ in callbackCount += 1 }

        vm.addFilter(field: "sex", op: .equals, value: "male")
        vm.removeFilter(at: 0)
        XCTAssertEqual(callbackCount, 2)
    }

    // MARK: - Reset to Defaults

    func testResetToDefaults() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: ["sex"])

        // Modify state
        vm.toggleGenotypeRows()
        vm.setRowHeight(2)
        vm.hideAllSamples()
        vm.addSortField("sex")
        vm.addFilter(field: "sex", op: .equals, value: "male")

        XCTAssertFalse(vm.displayState.showGenotypeRows)
        XCTAssertEqual(vm.displayState.rowHeight, 2)
        XCTAssertEqual(vm.displayState.hiddenSamples.count, 5)
        XCTAssertEqual(vm.displayState.sortFields.count, 1)
        XCTAssertEqual(vm.displayState.filters.count, 1)

        vm.resetToDefaults()

        XCTAssertTrue(vm.displayState.showGenotypeRows)
        XCTAssertEqual(vm.displayState.rowHeight, 12)
        XCTAssertTrue(vm.displayState.hiddenSamples.isEmpty)
        XCTAssertTrue(vm.displayState.sortFields.isEmpty)
        XCTAssertTrue(vm.displayState.filters.isEmpty)
    }

    // MARK: - Metadata Edit Save/Rollback (AS13)

    /// Regression test for AS13: saveMetadataEdits() used to write the
    /// edited metadata into sampleMetadata and dismiss the editing sheet
    /// unconditionally, THEN fire onSaveMetadata -- so a denied write
    /// (locked/read-only project) or a persistence throw left the
    /// Inspector showing the new value while the underlying database was
    /// never touched. onSaveMetadata now reports success/failure and a
    /// failed save must roll back the optimistic write and keep the sheet
    /// open (editingSample non-nil) so the user's edits aren't silently
    /// lost.
    func testSaveMetadataEditsAppliesOptimisticUpdateOnSuccess() {
        let vm = makeViewModel()
        vm.update(sampleCount: 1, sampleNames: ["Sample1"], metadataFields: [])
        var savedCalls: [(String, [String: String])] = []
        vm.onSaveMetadata = { sampleName, metadata in
            savedCalls.append((sampleName, metadata))
            return true
        }

        vm.beginEditingMetadata(for: "Sample1")
        vm.editingMetadata = [(key: "sex", value: "F")]
        vm.saveMetadataEdits()

        XCTAssertEqual(vm.sampleMetadata["Sample1"], ["sex": "F"])
        XCTAssertNil(vm.editingSample, "A successful save must close the editing sheet")
        XCTAssertEqual(savedCalls.count, 1)
        XCTAssertEqual(savedCalls.first?.0, "Sample1")
    }

    func testSaveMetadataEditsRollsBackOptimisticUpdateOnFailure() {
        let vm = makeViewModel()
        vm.update(
            sampleCount: 1,
            sampleNames: ["Sample1"],
            metadataFields: ["sex"],
            sampleMetadata: ["Sample1": ["sex": "M"]]
        )
        vm.onSaveMetadata = { _, _ in false }

        vm.beginEditingMetadata(for: "Sample1")
        vm.editingMetadata = [(key: "sex", value: "F")]
        vm.saveMetadataEdits()

        XCTAssertEqual(
            vm.sampleMetadata["Sample1"],
            ["sex": "M"],
            "A failed save must roll back to the pre-edit metadata rather than leaving the optimistic write in place"
        )
        XCTAssertNotNil(vm.editingSample, "A failed save must keep the editing sheet open so edits aren't lost")
        XCTAssertEqual(vm.editingSample, "Sample1")
        XCTAssertTrue(vm.lastSaveFailed, "A failed save must be discoverable so the UI can show an error")
    }

    func testSaveMetadataEditsWithNoCallbackStillAppliesOptimisticUpdate() {
        // No onSaveMetadata wired at all (e.g. UI not yet wired to a
        // persistence backend) must not be treated as a failure -- there's
        // nothing to roll back against.
        let vm = makeViewModel()
        vm.update(sampleCount: 1, sampleNames: ["Sample1"], metadataFields: [])

        vm.beginEditingMetadata(for: "Sample1")
        vm.editingMetadata = [(key: "sex", value: "F")]
        vm.saveMetadataEdits()

        XCTAssertEqual(vm.sampleMetadata["Sample1"], ["sex": "F"])
        XCTAssertNil(vm.editingSample)
    }

    func testResetPreservesSampleData() {
        let vm = makeViewModel()
        vm.update(sampleCount: 5, sampleNames: testSampleNames, metadataFields: ["sex"])

        vm.resetToDefaults()

        // Sample data should be preserved
        XCTAssertEqual(vm.sampleCount, 5)
        XCTAssertEqual(vm.sampleNames, testSampleNames)
        XCTAssertTrue(vm.hasVariantData)
    }

    // MARK: - Notification Fallback

    func testNotificationFiredWhenNoCallback() {
        let vm = makeViewModel()
        XCTAssertNil(vm.onDisplayStateChanged)

        let expectation = expectation(forNotification: .sampleDisplayStateChanged, object: vm) { notification in
            let state = notification.userInfo?[NotificationUserInfoKey.sampleDisplayState] as? SampleDisplayState
            return state?.showGenotypeRows == false
        }

        vm.toggleGenotypeRows()
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Expansion State

    func testExpansionState() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.isExpanded)

        vm.isExpanded = false
        XCTAssertFalse(vm.isExpanded)
    }
}

// MARK: - InspectorViewModelIntegrationTests

@MainActor
final class InspectorViewModelIntegrationTests: XCTestCase {

    func testViewModelHasVariantSection() {
        let vm = InspectorViewModel()
        XCTAssertNotNil(vm.variantSectionViewModel)
        XCTAssertFalse(vm.variantSectionViewModel.hasVariant)
    }

    func testViewModelHasSampleSection() {
        let vm = InspectorViewModel()
        XCTAssertNotNil(vm.sampleSectionViewModel)
        XCTAssertFalse(vm.sampleSectionViewModel.hasVariantData)
    }

    func testSampleSectionUpdateShowsInModel() {
        let vm = InspectorViewModel()
        vm.sampleSectionViewModel.update(sampleCount: 10, sampleNames: ["S1", "S2"], metadataFields: ["sex"])

        XCTAssertTrue(vm.sampleSectionViewModel.hasVariantData)
        XCTAssertEqual(vm.sampleSectionViewModel.sampleCount, 10)
    }

    func testVariantSectionSelectShowsInModel() {
        let vm = InspectorViewModel()
        let variant = AnnotationSearchIndex.SearchResult(
            name: "rs999",
            chromosome: "chr1",
            start: 1000,
            end: 1001,
            trackId: "variants",
            type: "SNP",
            strand: ".",
            ref: "A",
            alt: "G"
        )

        vm.variantSectionViewModel.select(variant: variant)
        XCTAssertTrue(vm.variantSectionViewModel.hasVariant)
        XCTAssertEqual(vm.variantSectionViewModel.selectedVariant?.name, "rs999")
    }
}
