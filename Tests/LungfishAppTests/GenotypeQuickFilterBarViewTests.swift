import XCTest
import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeQuickFilterBarViewTests: XCTestCase {
    func testSearchContentTypographyUpdatesLiveAndRecoversWithoutEmittingFilterState() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()

        let view = GenotypeQuickFilterBarView()
        var publicationCount = 0
        view.onStateChanged = { _ in publicationCount += 1 }
        let baselineFont = view.testingSearchFontPointSize
        let baselineHeight = view.intrinsicContentSize.height

        settings.contentTextSizePreference = .custom(200)
        settings.save()

        XCTAssertEqual(view.testingSearchFontPointSize, baselineFont * 2, accuracy: 0.01)
        XCTAssertGreaterThan(view.intrinsicContentSize.height, baselineHeight)
        XCTAssertEqual(publicationCount, 0)

        settings.contentTextSizePreference = .custom(100)
        settings.save()

        XCTAssertEqual(view.testingSearchFontPointSize, baselineFont, accuracy: 0.01)
        XCTAssertEqual(view.intrinsicContentSize.height, baselineHeight, accuracy: 0.01)
        XCTAssertEqual(publicationCount, 0)
    }

    func testRendersWithoutCrash() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        XCTAssertGreaterThan(view.frame.height, 0)
    }

    func testFilterBarDoesNotRenderSmartPillChips() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        XCTAssertFalse(view.testingVisibleButtonTitles.contains("Has errors"))
        XCTAssertFalse(view.testingVisibleButtonTitles.contains("Homozygous"))
        XCTAssertFalse(view.testingVisibleButtonTitles.contains("Recombinant"))
        XCTAssertFalse(view.testingVisibleButtonTitles.contains("Bw6+"))
    }

    func testSearchTextEmitsUnifiedFilterStateWithoutPillPredicate() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        var emitted: GenotypeQuickFilterBarView.FilterState?
        view.onStateChanged = { emitted = $0 }
        view.setSearchText("Bw6+")
        XCTAssertEqual(emitted?.searchText, "Bw6+")
        XCTAssertNil(emitted?.pillPredicate)
    }

    func testParseSearchTextCreatesMetadataPredicateForFieldQueries() {
        let predicate = GenotypeQuickFilterBarView.parseSearchText("Cohort=Kenyon20")
        XCTAssertEqual(predicate, .metadataFieldContains(field: "Cohort", value: "Kenyon20"))
    }

    func testParseSearchTextPreservesBroadTextFiltersForSaving() {
        let predicate = GenotypeQuickFilterBarView.parseSearchText("MHC-B")
        XCTAssertEqual(predicate, .textContains("MHC-B"))
    }

    func testSavedCohortChipIsVisibleAndClearable() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        var didClear = false
        view.onSavedCohortCleared = { didClear = true }

        view.setSavedCohortName("Needs review")
        XCTAssertEqual(view.testingSavedCohortChipTitle, "Saved: Needs review")

        view.testingClearSavedCohort()
        XCTAssertTrue(didClear)
        XCTAssertNil(view.testingSavedCohortChipTitle)
    }

    func testHaplotypeDefinitionsSidecarSectionIsCollapsible() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultDocumentSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var isHaplotypeDefinitionsExpanded"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Haplotype Definitions\", isExpanded: $isHaplotypeDefinitionsExpanded)"))
        XCTAssertFalse(source.contains("DisclosureGroup(\"Haplotype Definitions\", isExpanded: .constant(true))"))
    }
}
