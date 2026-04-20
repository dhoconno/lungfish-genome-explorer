import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore

final class AssemblySubsetBundleMetadataTests: XCTestCase {
    func testMakeGroupsIncludesAssemblerAndSelectedContigs() throws {
        let groups = AssemblySubsetBundleMetadata.makeGroups(
            assembler: "SPAdes 4.2.0",
            sourceAssemblyName: "pilot-assembly",
            selectedContigs: ["contig_7", "contig_2"],
            selectionSummary: AssemblyContigSelectionSummary(
                selectedContigCount: 2,
                totalSelectedBP: 1543,
                longestContigBP: 1000,
                shortestContigBP: 543,
                lengthWeightedGCPercent: 48.75
            )
        )

        let derived = try XCTUnwrap(groups.first(where: { $0.name == "Derived Subset" }))
        XCTAssertEqual(itemValue("Assembler", in: derived), "SPAdes 4.2.0")
        XCTAssertEqual(itemValue("Source Assembly", in: derived), "pilot-assembly")
        XCTAssertEqual(itemValue("Selected Contigs", in: derived), "contig_7, contig_2")
        XCTAssertEqual(itemValue("Contigs", in: derived), "2")
        XCTAssertEqual(itemValue("Total Length", in: derived), "1,543 bp")
        XCTAssertEqual(itemValue("GC Content", in: derived), "48.8%")
    }

    private func itemValue(_ label: String, in group: MetadataGroup) -> String? {
        group.items.first(where: { $0.label == label })?.value
    }
}
