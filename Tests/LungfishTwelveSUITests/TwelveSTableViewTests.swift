import XCTest
import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSTableViewTests: XCTestCase {

    private func makeTargetRow(
        name: String,
        taxids: [String] = [],
        sampleCounts: [String: Int] = ["s1": 10],
        totals: [String: Int] = ["s1": 100],
        targetIDs: [String] = ["t1"]
    ) -> TwelveSScientificNameCountRow {
        TwelveSScientificNameCountRow(
            scientificName: name,
            commonNames: [],
            targetIDs: targetIDs,
            sampleCounts: sampleCounts,
            sampleExactReadTotals: totals,
            taxids: taxids
        )
    }

    func testTargetColumnsAndCellText() {
        let table = TwelveSTargetTableView()
        let row = makeTargetRow(name: "Homo sapiens", taxids: ["9606"],
                                sampleCounts: ["s1": 42], totals: ["s1": 100])
        XCTAssertEqual(
            table.cellContent(for: .init("scientificName"), row: row).text,
            "Homo sapiens"
        )
        XCTAssertEqual(table.cellContent(for: .init("totalExactReads"), row: row).text, "42")
        XCTAssertEqual(table.cellContent(for: .init("referenceTargets"), row: row).text, "1")
        XCTAssertEqual(table.cellContent(for: .init("taxids"), row: row).text, "9606")
        // numeric columns declared numeric for the kernel filter menus
        XCTAssertEqual(table.columnTypeHints["totalExactReads"], true)
        XCTAssertEqual(table.columnTypeHints["scientificName"], nil)
    }

    func testTargetSortByExactReadsDescending() {
        let table = TwelveSTargetTableView()
        let low = makeTargetRow(name: "Low", sampleCounts: ["s1": 5])
        let high = makeTargetRow(name: "High", sampleCounts: ["s1": 50])
        // ascending == false means higher first
        XCTAssertTrue(table.compareRows(high, low, by: "totalExactReads", ascending: false))
        XCTAssertFalse(table.compareRows(low, high, by: "totalExactReads", ascending: false))
    }

    func testTargetFreeTextFilterMatchesName() {
        let table = TwelveSTargetTableView()
        let row = makeTargetRow(name: "Gallus gallus")
        XCTAssertTrue(table.rowMatchesFilter(row, filterText: "gallus"))
        XCTAssertFalse(table.rowMatchesFilter(row, filterText: "salmon"))
    }

    // MARK: - Unresolved

    private func makeUnresolved(
        id: String, reads: Int, sequence: String = "ACGT",
        sampleCounts: [String: Int] = ["s1": 1],
        chimera: TwelveSChimeraStatus = .notReviewed
    ) -> TwelveSUnresolvedSequence {
        TwelveSUnresolvedSequence(sequenceID: id, sequence: sequence, readCount: reads,
                                  sampleCounts: sampleCounts, chimeraStatus: chimera)
    }

    func testUnresolvedColumnsAndCellText() {
        let table = TwelveSUnresolvedTableView()
        let row = makeUnresolved(id: "cluster-1", reads: 7, sequence: "ACGTAC",
                                 sampleCounts: ["s1": 4, "s2": 0])
        XCTAssertEqual(table.cellContent(for: .init("sequenceID"), row: row).text, "cluster-1")
        XCTAssertEqual(table.cellContent(for: .init("readCount"), row: row).text, "7")
        XCTAssertEqual(table.cellContent(for: .init("sampleCount"), row: row).text, "1") // s2 == 0 excluded
        XCTAssertEqual(table.cellContent(for: .init("sequence"), row: row).text, "ACGTAC")
        XCTAssertEqual(table.columnTypeHints["readCount"], true)
    }

    func testUnresolvedSortByReadsDescending() {
        let table = TwelveSUnresolvedTableView()
        let a = makeUnresolved(id: "a", reads: 3)
        let b = makeUnresolved(id: "b", reads: 30)
        XCTAssertTrue(table.compareRows(b, a, by: "readCount", ascending: false))
    }

    func testTargetTableAddsPerSampleReadsColumns() {
        let table = TwelveSTargetTableView()
        table.setSampleColumns(sampleIDs: ["SampleA", "SampleB"],
                               displayNames: ["SampleA": "Sample A", "SampleB": "Sample B"],
                               showReads: true, store: nil, metadataFields: [])
        let ids = table.tableView.tableColumns.map { $0.identifier.rawValue }
        XCTAssertTrue(ids.contains("sample::SampleA::reads"))
        XCTAssertTrue(ids.contains("sample::SampleB::reads"))
        let row = makeTargetRow(name: "X", sampleCounts: ["SampleA": 9], totals: ["SampleA": 100])
        XCTAssertEqual(table.cellContent(for: .init("sample::SampleA::reads"), row: row).text, "9")
        XCTAssertEqual(table.columnTypeHints["sample::SampleA::reads"], true)
        // reads column compare is numeric/descending
        let hi = makeTargetRow(name: "Hi", sampleCounts: ["SampleA": 50], totals: ["SampleA": 100])
        let lo = makeTargetRow(name: "Lo", sampleCounts: ["SampleA": 5], totals: ["SampleA": 100])
        XCTAssertTrue(table.compareRows(hi, lo, by: "sample::SampleA::reads", ascending: false))
    }

    func testSettingSampleColumnsReplacesPreviousMatrixColumns() {
        let table = TwelveSTargetTableView()
        table.setSampleColumns(sampleIDs: ["SampleA"], displayNames: [:], showReads: true, store: nil, metadataFields: [])
        XCTAssertEqual(table.tableView.tableColumns.filter { $0.identifier.rawValue.hasPrefix("sample::") }.count, 1)
        // Switching to a different sample set replaces, not appends.
        table.setSampleColumns(sampleIDs: ["SampleB", "SampleC"], displayNames: [:], showReads: true, store: nil, metadataFields: [])
        let matrixIDs = table.tableView.tableColumns.map { $0.identifier.rawValue }.filter { $0.hasPrefix("sample::") }
        XCTAssertEqual(Set(matrixIDs), ["sample::SampleB::reads", "sample::SampleC::reads"])
    }

    // MARK: - Multi-sample comparison

    func testSelectingSampleSubsetReaggregatesTargetRows() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult() // human(both) + chicken(SampleB only)
        vc.configure(result: bundle)
        let entries = bundle.samples.map {
            TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
        }
        let state = ClassifierSamplePickerState(allSamples: Set(entries.map(\.id)))
        vc.configureSamples(entries, state: state)

        // Both species visible with all samples.
        XCTAssertEqual(vc.testingActiveTableRowCount, 2)

        // Restrict to SampleA: chicken (SampleA == 0 reads) drops out.
        vc.testingSetSelectedSamples(["SampleA"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 1)
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")

        // Back to all samples → both species again.
        vc.testingSetSelectedSamples(["SampleA", "SampleB"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 2)
    }

    func testSelectingSpeciesLoadsReferenceSequencesIntoPayload() throws {
        // Write a reference FASTA with records for the fixture's target IDs.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("twelve-s-vcref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let refURL = dir.appendingPathComponent("reference.fasta")
        try ">human\nACGTACGTAC\n>chicken\nTTTTGGGGCC\n".write(to: refURL, atomically: true, encoding: .utf8)

        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult(referenceURL: refURL)

        let gotSequences = expectation(description: "reference sequences populated")
        gotSequences.assertForOverFulfill = false // selection may emit more than once
        vc.onSelectedRowDetailChanged = { payload in
            if case let .target(detail)? = payload?.kind, !detail.referenceSequences.isEmpty {
                XCTAssertEqual(detail.referenceSequences.first?.sequence, "ACGTACGTAC")
                gotSequences.fulfill()
            }
        }
        vc.configure(result: bundle)
        vc.selectTargetForTesting(row: 0) // Homo sapiens (targetID "human")
        wait(for: [gotSequences], timeout: 2.0)
    }

    func testReadsColumnsAutoShowForSmallCohortAndToggle() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map {
            TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
        }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))
        // 2 samples ≤ 8 → reads columns auto-shown.
        XCTAssertTrue(vc.testingTargetColumnIDs.contains("sample::SampleA::reads"))
        XCTAssertTrue(vc.testingTargetColumnIDs.contains("sample::SampleB::reads"))

        // Force off.
        vc.testingSetSampleColumnsForced(showReads: false)
        XCTAssertFalse(vc.testingTargetColumnIDs.contains { $0.hasPrefix("sample::") })
    }

    func testSingleSampleBundleHidesSampleFilterButton() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let oneEntry = [TwelveSSampleEntry(id: "SampleA", displayName: "Sample A", exactReads: 45)]
        let state = ClassifierSamplePickerState(allSamples: ["SampleA"])
        vc.configureSamples(oneEntry, state: state)
        XCTAssertTrue(vc.testingSampleFilterButtonHidden)
    }
}
