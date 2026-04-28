import XCTest
@testable import LungfishApp

final class SelectionIdentityStoreTests: XCTestCase {
    func testSelectionSurvivesReorderByIdentity() {
        var store = SelectionIdentityStore<String>()
        store.select(["taxon:S1:9606"])

        let rows = ["taxon:S2:9606", "taxon:S1:9606", "taxon:S3:9606"]
        let indexes = store.visibleIndexes(in: rows)

        XCTAssertEqual(indexes, IndexSet(integer: 1))
    }

    func testSelectionClearsWhenIdentityNoLongerVisible() {
        var store = SelectionIdentityStore<String>()
        store.select(["virus:S1:NC_1"])

        let rows = ["virus:S2:NC_1"]
        store.removeSelectionsNotVisible(in: rows)

        XCTAssertTrue(store.selectedIDs.isEmpty)
    }
}
