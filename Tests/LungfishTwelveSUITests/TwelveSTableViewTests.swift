import XCTest
import AppKit
import LungfishIO
import LungfishKit
@testable import LungfishTwelveSUI

@MainActor
final class TwelveSTableViewTests: XCTestCase {

    private func makeAggregateRow(
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

    private func makeSampleRow(
        name: String,
        sampleID: String = "s1",
        sampleName: String = "Sample One",
        reads: Int = 10,
        total: Int = 100,
        taxids: [String] = [],
        targetIDs: [String] = ["t1"]
    ) -> TwelveSTargetSampleRow {
        TwelveSTargetSampleRow(
            source: makeAggregateRow(
                name: name,
                taxids: taxids,
                sampleCounts: [sampleID: reads],
                totals: [sampleID: total],
                targetIDs: targetIDs
            ),
            sampleID: sampleID,
            sampleDisplayName: sampleName,
            exactReads: reads,
            sampleExactReadTotal: total
        )
    }

    func testTargetColumnsAndCellText() {
        let table = TwelveSTargetTableView()
        let row = makeSampleRow(
            name: "Homo sapiens",
            sampleName: "Sample A",
            reads: 42,
            total: 100,
            taxids: ["9606"]
        )

        XCTAssertEqual(table.cellContent(for: .init("sampleName"), row: row).text, "Sample A")
        XCTAssertEqual(table.cellContent(for: .init("scientificName"), row: row).text, "Homo sapiens")
        XCTAssertEqual(table.cellContent(for: .init("totalExactReads"), row: row).text, "42")
        XCTAssertEqual(table.cellContent(for: .init("samplePercent"), row: row).text, "42.0%")
        XCTAssertEqual(table.cellContent(for: .init("referenceTargets"), row: row).text, "1")
        XCTAssertEqual(table.cellContent(for: .init("taxids"), row: row).text, "9606")
        XCTAssertEqual(table.columnTypeHints["totalExactReads"], true)
        XCTAssertEqual(table.columnTypeHints["samplePercent"], true)
        XCTAssertEqual(table.columnTypeHints["scientificName"], nil)
    }

    func testTargetSortByExactReadsDescending() {
        let table = TwelveSTargetTableView()
        let low = makeSampleRow(name: "Low", reads: 5)
        let high = makeSampleRow(name: "High", reads: 50)

        XCTAssertTrue(table.compareRows(high, low, by: "totalExactReads", ascending: false))
        XCTAssertFalse(table.compareRows(low, high, by: "totalExactReads", ascending: false))
    }

    func testTargetFreeTextFilterMatchesNameAndSample() {
        let table = TwelveSTargetTableView()
        let row = makeSampleRow(name: "Gallus gallus", sampleName: "Blank Control")

        XCTAssertTrue(table.rowMatchesFilter(row, filterText: "gallus"))
        XCTAssertTrue(table.rowMatchesFilter(row, filterText: "blank"))
        XCTAssertFalse(table.rowMatchesFilter(row, filterText: "salmon"))
    }

    func testSampleMetadataColumnsAreRowScoped() throws {
        let table = TwelveSTargetTableView()
        let csv = "sample_id,site\nSampleA,Hilo\nSampleB,Kona\n"
        let store = try SampleMetadataStore(csvData: Data(csv.utf8), knownSampleIds: ["SampleA", "SampleB"])

        table.setSampleColumns(
            sampleIDs: ["SampleA", "SampleB"],
            displayNames: ["SampleA": "Sample A", "SampleB": "Sample B"],
            showReads: true,
            showPercent: true,
            store: store,
            metadataFields: ["site"]
        )

        let ids = table.tableView.tableColumns.map { $0.identifier.rawValue }
        XCTAssertTrue(ids.contains("sampleMeta::site"))
        XCTAssertFalse(ids.contains { $0.hasSuffix("::reads") })

        let row = makeSampleRow(name: "X", sampleID: "SampleB", sampleName: "Sample B")
        XCTAssertEqual(table.cellContent(for: .init("sampleMeta::site"), row: row).text, "Kona")
    }

    func testSettingSampleColumnsReplacesPreviousMetadataColumns() throws {
        let table = TwelveSTargetTableView()
        let store = try SampleMetadataStore(csvData: Data("sample_id,site,plate\nSampleA,Hilo,A1\n".utf8),
                                            knownSampleIds: ["SampleA"])

        table.setSampleColumns(sampleIDs: ["SampleA"], displayNames: [:], showReads: true,
                               showPercent: true, store: store, metadataFields: ["site"])
        XCTAssertTrue(table.tableView.tableColumns.map { $0.identifier.rawValue }.contains("sampleMeta::site"))

        table.setSampleColumns(sampleIDs: ["SampleA"], displayNames: [:], showReads: true,
                               showPercent: true, store: store, metadataFields: ["plate"])
        let metadataIDs = table.tableView.tableColumns.map { $0.identifier.rawValue }.filter { $0.hasPrefix("sampleMeta::") }
        XCTAssertEqual(metadataIDs, ["sampleMeta::plate"])
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
        XCTAssertEqual(table.cellContent(for: .init("sampleCount"), row: row).text, "1")
        XCTAssertEqual(table.cellContent(for: .init("sequence"), row: row).text, "ACGTAC")
        XCTAssertEqual(table.columnTypeHints["readCount"], true)
    }

    func testUnresolvedSortByReadsDescending() {
        let table = TwelveSUnresolvedTableView()
        let a = makeUnresolved(id: "a", reads: 3)
        let b = makeUnresolved(id: "b", reads: 30)
        XCTAssertTrue(table.compareRows(b, a, by: "readCount", ascending: false))
    }

    // MARK: - Multi-sample comparison

    func testSelectingSampleSubsetReaggregatesTargetRows() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map {
            TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
        }
        let state = ClassifierSamplePickerState(allSamples: Set(entries.map(\.id)))
        vc.configureSamples(entries, state: state)

        XCTAssertEqual(vc.testingActiveTableRowCount, 3)

        vc.testingSetSelectedSamples(["SampleA"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 1)
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "totalExactReads"), "40")

        vc.testingSetSelectedSamples(["SampleA", "SampleB"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 3)
    }

    func testSelectingSpeciesLoadsReferenceSequencesIntoPayload() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("twelve-s-vcref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let refURL = dir.appendingPathComponent("reference.fasta")
        try ">human\nACGTACGTAC\n>chicken\nTTTTGGGGCC\n".write(to: refURL, atomically: true, encoding: .utf8)

        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult(referenceURL: refURL)

        let gotSequences = expectation(description: "reference sequences populated")
        gotSequences.assertForOverFulfill = false
        vc.onSelectedRowDetailChanged = { payload in
            if case let .target(detail)? = payload?.kind, !detail.referenceSequences.isEmpty {
                XCTAssertEqual(detail.referenceSequences.first?.sequence, "ACGTACGTAC")
                XCTAssertEqual(detail.sampleEvidence.map(\.sampleID), ["SampleA"])
                gotSequences.fulfill()
            }
        }
        vc.configure(result: bundle)
        vc.selectTargetForTesting(row: 0)
        wait(for: [gotSequences], timeout: 2.0)
    }

    func testReadColumnsAreFixedSampleRowsNotWideMatrix() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map {
            TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
        }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))

        XCTAssertTrue(vc.testingTargetColumnIDs.contains("sampleName"))
        XCTAssertTrue(vc.testingTargetColumnIDs.contains("totalExactReads"))
        XCTAssertTrue(vc.testingTargetColumnIDs.contains("samplePercent"))
        XCTAssertFalse(vc.testingTargetColumnIDs.contains { $0.hasPrefix("sample::") })
    }

    func testApplyMetadataStoreAddsRowScopedMetadataColumns() throws {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map {
            TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
        }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))

        let csv = "sample_id,site\nSampleA,Hilo\nSampleB,Kona\n"
        let store = try SampleMetadataStore(csvData: Data(csv.utf8), knownSampleIds: ["SampleA", "SampleB"])
        vc.applyMetadataStore(store)

        XCTAssertTrue(vc.testingTargetColumnIDs.contains("sampleMeta::site"))
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "sampleMeta::site"), "Hilo")
        XCTAssertEqual(vc.testingTargetText(row: 1, column: "sampleMeta::site"), "Kona")
    }

    func testImportMetadataAffordanceFiresCallback() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        var fired = false
        vc.onMetadataImportRequested = { fired = true }
        vc.testingTriggerMetadataImport()
        XCTAssertTrue(fired)
    }

    func testDefaultSortAlwaysReadsDescendingOnConfigure() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        vc.configure(result: TwelveSFixtures.twoSampleResult())
        vc.testingSetTargetSort(key: "scientificName", ascending: true)

        vc.configure(result: TwelveSFixtures.twoSampleResult())
        XCTAssertEqual(vc.testingTargetSortDescriptor?.key, "totalExactReads")
        XCTAssertEqual(vc.testingTargetSortDescriptor?.ascending, false)
    }

    func testRowsWithZeroReadsInShownSamplesAreHidden() {
        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        let bundle = TwelveSFixtures.twoSampleResult()
        vc.configure(result: bundle)
        let entries = bundle.samples.map {
            TwelveSSampleEntry(id: $0.sampleID, displayName: $0.displayName, exactReads: $0.exactMatchReads)
        }
        vc.configureSamples(entries, state: ClassifierSamplePickerState(allSamples: Set(entries.map(\.id))))

        vc.testingSetSelectedSamples(["SampleA"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 1)
        XCTAssertEqual(vc.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")

        vc.testingSetSelectedSamples(["SampleB"])
        XCTAssertEqual(vc.testingActiveTableRowCount, 2)
    }

    func testReassignmentDonorSpeciesNotHiddenDespiteZeroReads() {
        let base = TwelveSFixtures.twoSampleResult()
        let panTarget = TwelveSAmpliconTarget(
            targetID: "pan", displayName: "chimpanzee (Pan troglodytes)",
            scientificName: "Pan troglodytes", commonName: "chimpanzee",
            taxid: "9598", taxonGroup: "Mammal")
        let bundle = TwelveSAmpliconResultBundleData(
            bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts,
            samples: base.samples,
            targets: base.targets + [panTarget],
            countRows: base.countRows.merging(["pan": ["SampleA": 0, "SampleB": 0]]) { a, _ in a },
            readFate: base.readFate,
            unresolvedSequences: base.unresolvedSequences,
            reassignments: [
                TwelveSReassignmentRecord(
                    sequenceID: "seq1", sampleID: "SampleA", toSpecies: "Homo sapiens",
                    toTargetID: "human", reads: 1000, decidedBy: "perSample",
                    candidateSpecies: ["Homo sapiens", "Pan troglodytes"])
            ])

        let vc = TwelveSAmpliconResultViewController()
        vc.loadViewIfNeeded()
        vc.configure(result: bundle)

        let names = (0..<vc.testingActiveTableRowCount).map { vc.testingTargetText(row: $0, column: "scientificName") }
        XCTAssertTrue(names.contains("Pan troglodytes"), "donor species should remain visible; got \(names)")
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
