import XCTest
import AppKit
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeQuickFilterBarViewTests: XCTestCase {
    func testRendersWithoutCrash() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        XCTAssertGreaterThan(view.frame.height, 0)
    }

    func testSingleActivePillEmitsPredicateDirectly() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        var emitted: SmartCohortPredicate??
        view.onFilterChanged = { emitted = $0 }
        view.setActivePills([.hasErrors])
        XCTAssertEqual(emitted, .some(.some(.hasErrorAtAnyLocus)))
    }

    func testTwoActivePillsCombineWithAll() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        var emitted: SmartCohortPredicate??
        view.onFilterChanged = { emitted = $0 }
        view.setActivePills([.hasErrors, .recombinant])
        guard case .some(.some(.all(let children))) = emitted else {
            return XCTFail("Expected .all([...]) predicate; got \(String(describing: emitted))")
        }
        let kinds = Set(children.map { String(describing: $0) })
        XCTAssertEqual(kinds.count, 2)
    }

    func testClearingAllPillsAndSearchEmitsNil() {
        let view = GenotypeQuickFilterBarView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
        var emitted: SmartCohortPredicate??
        view.onFilterChanged = { emitted = $0 }
        view.setActivePills([.hasErrors])
        view.setActivePills([])
        XCTAssertEqual(emitted, .some(.none))
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
}
