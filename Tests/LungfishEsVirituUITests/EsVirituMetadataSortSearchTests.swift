import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishEsVirituUI
@testable import LungfishKit
import LungfishIO

@MainActor
final class EsVirituMetadataSortSearchTests: XCTestCase {
    func testOutlineMetadataSortUsesSampleIdentityNaturalOrderingAndPreservesSelection() throws {
        let table = makeTable()
        table.metadataColumns.visibleColumns = ["Group", "Count"]
        table.metadataColumns.update(store: try metadataStore(), sampleId: nil)

        table.testOutlineView.sortDescriptors = [
            NSSortDescriptor(key: "metadata_Group", ascending: true),
        ]
        XCTAssertEqual(table.testingDisplayedSampleIDs, ["D", "B", "C", "A"])

        table.testOutlineView.sortDescriptors = [
            NSSortDescriptor(key: "metadata_Count", ascending: true),
        ]
        XCTAssertEqual(table.testingDisplayedSampleIDs, ["D", "B", "A", "C"])

        table.testOutlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(table.selectedSampleIDs(), ["B"])
        table.testOutlineView.sortDescriptors = [
            NSSortDescriptor(key: "metadata_Group", ascending: false),
        ]
        XCTAssertEqual(table.testingDisplayedSampleIDs, ["A", "B", "C", "D"])
        XCTAssertEqual(table.selectedSampleIDs(), ["B"])
    }

    func testOutlineMetadataSearchScopesTrackVisibleColumnsAndResetWhenRemoved() throws {
        let table = makeTable()
        table.metadataColumns.visibleColumns = ["Collection Date", "sample", "lab_name"]
        let store = try metadataStore()
        table.metadataColumns.update(store: store, sampleId: nil)
        table.metadataColumns.update(store: store, sampleId: nil)

        let menu = try XCTUnwrap(table.testingSearchField.searchMenuTemplate)
        XCTAssertEqual(
            menu.items.compactMap { $0.representedObject as? String },
            ["metadata_Collection Date", "metadata_sample", "metadata_lab_name"]
        )

        table.testingSubmitSearchTextImmediately("NorthCampus")
        XCTAssertEqual(table.testingDisplayedSampleIDs, ["A"])

        let labScope = try XCTUnwrap(menu.items.first {
            ($0.representedObject as? String) == "metadata_lab_name"
        })
        NSApp.sendAction(try XCTUnwrap(labScope.action), to: labScope.target, from: labScope)
        table.testingSubmitSearchTextImmediately("alias-A")
        XCTAssertTrue(table.testingDisplayedSampleIDs.isEmpty)

        table.testingSubmitSearchTextImmediately("NorthCampus")
        table.testingSetColumnFilter(
            ColumnFilter(columnId: "metadata_sample", op: .contains, value: "alias-B")
        )
        XCTAssertTrue(table.testingDisplayedSampleIDs.isEmpty)

        table.testingSubmitSearchTextImmediately("alias-B")
        table.metadataColumns.visibleColumns = ["Collection Date", "sample"]
        table.metadataColumns.update(store: store, sampleId: nil)
        XCTAssertNil(table.testingSearchField.searchMenuTemplate?.items.first {
            ($0.representedObject as? String) == "metadata_lab_name"
        })
        XCTAssertEqual(table.testingDisplayedSampleIDs, ["B"])
    }

    private func makeTable() -> ViralDetectionTableView {
        let table = ViralDetectionTableView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
        let assemblies = [
            assembly(sample: "A", name: "Zeta virus", reads: 10),
            assembly(sample: "B", name: "Beta virus", reads: 40),
            assembly(sample: "C", name: "Gamma virus", reads: 30),
            assembly(sample: "D", name: "Delta virus", reads: 20),
        ]
        table.result = EsVirituResult(
            sampleId: "metadata-tests",
            detections: assemblies.flatMap(\.contigs),
            assemblies: assemblies,
            taxProfile: [],
            coverageWindows: [],
            totalFilteredReads: 1_000,
            detectedFamilyCount: 1,
            detectedSpeciesCount: assemblies.count,
            runtime: nil,
            toolVersion: nil
        )
        return table
    }

    private func metadataStore() throws -> SampleMetadataStore {
        let tsv = """
        ID\tGroup\tCount\tCollection Date\tsample\tlab_name
        A\tZebra\t10\t2026-01-02\talias-A\tNorthCampus
        B\talpha\t2\t2026-01-01\talias-B\tSouthCampus
        C\talpha\t100\t2026-01-03\talias-C\tEastCampus
        D\t\t\t\talias-D\tWestCampus

        """
        return try SampleMetadataStore(
            csvData: Data(tsv.utf8),
            knownSampleIds: ["A", "B", "C", "D"]
        )
    }

    private func assembly(sample: String, name: String, reads: Int) -> ViralAssembly {
        let detection = ViralDetection(
            sampleId: sample,
            name: name,
            description: name,
            length: 100,
            segment: nil,
            accession: "NC_DUPLICATE",
            assembly: "GCF_DUPLICATE",
            assemblyLength: 100,
            kingdom: "Viruses",
            phylum: nil,
            tclass: nil,
            order: nil,
            family: "Testviridae",
            genus: nil,
            species: name,
            subspecies: nil,
            rpkmf: Double(reads),
            readCount: reads,
            coveredBases: 100,
            meanCoverage: 1,
            avgReadIdentity: 0.99,
            pi: 0,
            filteredReadsInSample: 1_000
        )
        return ViralAssembly(
            assembly: "GCF_DUPLICATE",
            assemblyLength: 100,
            name: name,
            family: "Testviridae",
            genus: nil,
            species: name,
            totalReads: reads,
            rpkmf: Double(reads),
            meanCoverage: 1,
            avgReadIdentity: 0.99,
            contigs: [detection]
        )
    }
}
