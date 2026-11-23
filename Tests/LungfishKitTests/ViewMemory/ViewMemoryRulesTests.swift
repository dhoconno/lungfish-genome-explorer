import XCTest
@testable import LungfishKit

/// The shared rules of view memory, VS B2 to B5 and the selection cap of VS A9.
final class ViewMemoryRulesTests: XCTestCase {
    private let sequences = [
        ViewMemorySequence(name: "chr1", length: 1_000),
        ViewMemorySequence(name: "chr2", length: 500),
    ]

    private func locus(
        name: String = "chr1",
        length: Int = 1_000,
        start: Double,
        end: Double
    ) -> ViewMemoryLocus {
        ViewMemoryLocus(sequenceName: name, sequenceLength: length, start: start, end: end)
    }

    private func key(_ value: String?) -> ViewMemoryDataKey {
        ViewMemoryDataKey(family: "analysis", parts: [.init(name: "files", value: value)])
    }

    // MARK: - Locus (VS B2)

    func testALocusOnTheSameSequenceRestoresUnchangedAndIsNotMarkedClamped() {
        let saved = locus(start: 100, end: 400)
        XCTAssertEqual(
            ViewMemoryRules.resolveLocus(saved, in: sequences),
            .restored(saved, wasClamped: false)
        )
    }

    func testAStartPastTheEndOfTheSequenceClampsToTheLastBase() {
        let outcome = ViewMemoryRules.resolveLocus(locus(start: 1_200, end: 1_300), in: sequences)
        XCTAssertEqual(
            outcome,
            .restored(locus(start: 999, end: 1_000), wasClamped: true),
            "the start clamps to length - 1 and the end to the length"
        )
    }

    func testAStartBelowZeroClampsToZero() {
        let outcome = ViewMemoryRules.resolveLocus(locus(start: -50, end: 200), in: sequences)
        XCTAssertEqual(outcome, .restored(locus(start: 0, end: 200), wasClamped: true))
    }

    func testAnEndPastTheLengthClampsToTheLength() {
        let outcome = ViewMemoryRules.resolveLocus(locus(start: 800, end: 5_000), in: sequences)
        XCTAssertEqual(outcome, .restored(locus(start: 800, end: 1_000), wasClamped: true))
    }

    func testAnEndAtOrBeforeTheStartBecomesOneBaseWide() {
        let outcome = ViewMemoryRules.resolveLocus(locus(start: 500, end: 400), in: sequences)
        XCTAssertEqual(outcome, .restored(locus(start: 500, end: 501), wasClamped: true))
    }

    func testAShorterSequenceOfTheSameNameIsTreatedAsGoneEvenWhenTheOldStartWasInside() {
        // chr1 was 2,000 long when the person left. It is 1,000 long now, so a start of
        // 1,500 is past its end and the view must not keep any coordinate.
        let saved = locus(length: 2_000, start: 1_500, end: 1_800)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(saved, in: sequences), .reset)
    }

    func testASequenceOfTheSameNameAndAnotherLengthIsTreatedAsGone() {
        let saved = locus(length: 1_001, start: 10, end: 20)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(saved, in: sequences), .reset)
        let longer = locus(name: "chr2", length: 100, start: 10, end: 20)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(longer, in: sequences), .reset)
    }

    func testAGoneSequenceResetsToTheFirstSequence() {
        let saved = locus(name: "chrZ", length: 1_000, start: 10, end: 20)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(saved, in: sequences), .reset)
    }

    func testALocusResetsWhenThereAreNoSequencesOrTheCoordinatesAreNotFinite() {
        XCTAssertEqual(ViewMemoryRules.resolveLocus(locus(start: 1, end: 2), in: []), .reset)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(locus(start: .nan, end: 2), in: sequences), .reset)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(locus(start: 1, end: .infinity), in: sequences), .reset)
        XCTAssertEqual(ViewMemoryRules.resolveLocus(locus(length: 0, start: 0, end: 0), in: sequences), .reset)
    }

    // MARK: - Coordinate selection (VS B3)

    func testACoordinateSelectionOnAChangedKeyIsDroppedAndNeverClamped() {
        let region = locus(start: 100, end: 200)
        let outcome = ViewMemoryRules.coordinateSelection(
            region,
            savedKey: key("before"),
            currentKey: key("after")
        )
        XCTAssertEqual(outcome, .dropped)
        XCTAssertNil(outcome.value, "a changed key leaves no region to clamp")
        XCTAssertTrue(outcome.wasDropped)
    }

    func testACoordinateSelectionOnAnEqualKeyIsKeptAsSaved() {
        let region = locus(start: 100, end: 200)
        let outcome = ViewMemoryRules.coordinateSelection(
            region,
            savedKey: key("same"),
            currentKey: key("same")
        )
        XCTAssertEqual(outcome, .kept(region))
    }

    func testACoordinateSelectionIsDroppedWhileAKeyPartIsNotReadYet() {
        let region = locus(start: 100, end: 200)
        XCTAssertEqual(
            ViewMemoryRules.coordinateSelection(region, savedKey: key("same"), currentKey: key(nil)),
            .dropped
        )
        XCTAssertEqual(
            ViewMemoryRules.coordinateSelection(region, savedKey: key(nil), currentKey: key(nil)),
            .dropped,
            "two unread keys are not equal"
        )
        XCTAssertEqual(
            ViewMemoryRules.coordinateSelection(region, savedKey: nil, currentKey: key("same")),
            .dropped,
            "a record with no key proves nothing"
        )
    }

    func testNothingSavedIsAbsentAndEarnsNoPhrase() {
        let outcome: ViewMemoryFieldOutcome<ViewMemoryLocus> = ViewMemoryRules.coordinateSelection(
            nil,
            savedKey: key("same"),
            currentKey: key("other")
        )
        XCTAssertEqual(outcome, .absent)
        XCTAssertFalse(outcome.wasDropped)
    }

    // MARK: - Row identities (VS B4)

    func testIdentitiesPartlyGoneKeepTheOnesThatStillExistInTheSavedOrder() {
        let restore = ViewMemoryRules.keepIdentities(
            ["c", "a", "gone", "b"],
            existing: ["a", "b", "c", "d"]
        )
        XCTAssertEqual(restore.kept, ["c", "a", "b"])
        XCTAssertEqual(restore.droppedCount, 1)
        XCTAssertTrue(restore.lostAny)
        XCTAssertFalse(restore.isEmpty)
    }

    func testIdentitiesAllGoneGiveAnEmptySelectionAndNeverRowZero() {
        let restore = ViewMemoryRules.keepIdentities(["x", "y"], existing: ["a", "b"])
        XCTAssertEqual(restore.kept, [])
        XCTAssertTrue(restore.isEmpty)
        XCTAssertEqual(restore.droppedCount, 2)
    }

    func testABatchIdentityThatCarriesTheSampleNeverMatchesTheSameTaxonInAnotherSample() {
        // The same taxon is one row in each sample. Restoring "taxon 562 in sample A" must not
        // select the row of taxon 562 in sample B.
        let savedInSampleA = "result-1|sample-A|taxid:562"
        let existing: Set<String> = ["result-1|sample-B|taxid:562", "result-1|sample-A|taxid:7"]
        let restore = ViewMemoryRules.keepIdentities([savedInSampleA], existing: existing)
        XCTAssertTrue(restore.isEmpty)
        XCTAssertEqual(restore.droppedCount, 1)

        let both = ViewMemoryRules.keepIdentities(
            [savedInSampleA],
            existing: existing.union([savedInSampleA])
        )
        XCTAssertEqual(both.kept, [savedInSampleA])
    }

    func testEmptyAndRepeatedIdentitiesAreNeverKeptTwice() {
        let restore = ViewMemoryRules.keepIdentities(["a", "", "a", "b"], existing: ["a", "b", ""])
        XCTAssertEqual(restore.kept, ["a", "b"])
        XCTAssertEqual(restore.droppedCount, 1, "only the empty identity counts as dropped")
    }

    // MARK: - Samples (VS B5)

    func testSamplesPartlyGoneKeepTheIntersectionAndReportASubset() {
        let restore = ViewMemoryRules.restoreSamples(
            saved: ["S1", "S2", "S9"],
            savedWasAllSamples: false,
            current: ["S1", "S2", "S3"]
        )
        XCTAssertEqual(restore.selected, ["S1", "S2"])
        XCTAssertEqual(restore.droppedCount, 1)
        XCTAssertFalse(restore.fellBackToAll)
        XCTAssertTrue(restore.isSubset, "S3 is left out, so the picker acts as a filter")
    }

    func testSamplesAllGoneFallBackToAllSamplesNeverToAnEmptySet() {
        let restore = ViewMemoryRules.restoreSamples(
            saved: ["S8", "S9"],
            savedWasAllSamples: false,
            current: ["S1", "S2"]
        )
        XCTAssertEqual(restore.selected, ["S1", "S2"])
        XCTAssertTrue(restore.fellBackToAll)
        XCTAssertFalse(restore.isSubset)
        XCTAssertEqual(restore.droppedCount, 2)
    }

    func testASavedChoiceOfEverySampleFollowsTheSamplesThatExistNow() {
        let restore = ViewMemoryRules.restoreSamples(
            saved: ["S1", "S2"],
            savedWasAllSamples: true,
            current: ["S1", "S2", "S3"]
        )
        XCTAssertEqual(restore.selected, ["S1", "S2", "S3"], "a sample that arrived later is not hidden")
        XCTAssertFalse(restore.isSubset)
    }

    func testAnEmptySavedChoiceRestoresEverySample() {
        let restore = ViewMemoryRules.restoreSamples(saved: [], savedWasAllSamples: false, current: ["S1"])
        XCTAssertEqual(restore.selected, ["S1"])
        XCTAssertFalse(restore.fellBackToAll, "nothing was saved, so nothing was refused")
    }

    func testASubsetThatEqualsEveryCurrentSampleIsNotAFilter() {
        let restore = ViewMemoryRules.restoreSamples(
            saved: ["S1", "S2"],
            savedWasAllSamples: false,
            current: ["S1", "S2"]
        )
        XCTAssertEqual(restore.selected, ["S1", "S2"])
        XCTAssertFalse(restore.isSubset)
    }

    func testNoCurrentSamplesRestoreNothingAndRefuseNothing() {
        let restore = ViewMemoryRules.restoreSamples(saved: ["S1"], savedWasAllSamples: false, current: [])
        XCTAssertEqual(restore.selected, [])
        XCTAssertFalse(restore.fellBackToAll)
    }

    // MARK: - Selection cap (VS A9)

    func testAnEmptySelectionIsEmpty() {
        XCTAssertEqual(ViewMemoryRules.capSelection([]), .empty)
    }

    func testASelectionOfExactlyTheIdentityLimitIsKeptWhole() {
        let identities = (0..<ViewMemoryRules.selectionIdentityLimit).map { "id-\($0)" }
        XCTAssertEqual(ViewMemoryRules.capSelection(identities), .kept(identities))
    }

    func testASelectionPastTheIdentityLimitIsDroppedWholeAndNeverCutShort() {
        let identities = (0...ViewMemoryRules.selectionIdentityLimit).map { "id-\($0)" }
        XCTAssertEqual(identities.count, 1_001)
        XCTAssertEqual(ViewMemoryRules.capSelection(identities), .tooLarge)
    }

    func testASelectionPastTheEncodedByteLimitIsDroppedWhole() {
        let long = String(repeating: "x", count: 4_000)
        let underTheLimit = (0..<7).map { "\($0)\(long)" }
        let overTheLimit = (0..<9).map { "\($0)\(long)" }
        XCTAssertEqual(ViewMemoryRules.capSelection(underTheLimit), .kept(underTheLimit))
        XCTAssertEqual(ViewMemoryRules.capSelection(overTheLimit), .tooLarge)
    }

    func testTheCapsAreInjectable() {
        let identities = ["a", "b", "c"]
        XCTAssertEqual(ViewMemoryRules.capSelection(identities, maxIdentities: 2), .tooLarge)
        XCTAssertEqual(ViewMemoryRules.capSelection(identities, maxIdentities: 3), .kept(identities))
        XCTAssertEqual(ViewMemoryRules.capSelection(identities, maxEncodedBytes: 5), .tooLarge)
        XCTAssertEqual(ViewMemoryRules.capSelection(identities, maxEncodedBytes: 1_000), .kept(identities))
    }
}
