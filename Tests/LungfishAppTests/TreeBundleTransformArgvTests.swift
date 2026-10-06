import XCTest
@testable import LungfishApp
import LungfishPhylogeneticsUI

final class TreeBundleTransformArgvTests: XCTestCase {
    private func request(
        operation: PhylogeneticTreeViewController.TreeBundleOperation,
        nodeID: String = "node-7",
        nodeLabel: String = "Clade A",
        tipLabels: [String] = []
    ) -> PhylogeneticTreeViewController.TreeBundleOperationRequest {
        PhylogeneticTreeViewController.TreeBundleOperationRequest(
            operation: operation,
            bundleURL: URL(fileURLWithPath: "/proj/Phylogenetic Trees/source.lungfishtree", isDirectory: true),
            nodeID: nodeID,
            nodeLabel: nodeLabel,
            tipLabels: tipLabels
        )
    }

    func testRerootArguments() {
        let out = URL(fileURLWithPath: "/proj/Phylogenetic Trees/source-rerooted.lungfishtree", isDirectory: true)
        let argv = TreeBundleTransformCommand.arguments(
            for: request(operation: .reroot),
            outputURL: out
        )
        XCTAssertEqual(argv, [
            "tree", "reroot",
            "--bundle", "/proj/Phylogenetic Trees/source.lungfishtree",
            "--on", "node-7",
            "--output", "/proj/Phylogenetic Trees/source-rerooted.lungfishtree",
            "--format", "json",
        ])
    }

    func testExtractSubtreeArguments() {
        let out = URL(fileURLWithPath: "/proj/Phylogenetic Trees/Clade A-subtree.lungfishtree", isDirectory: true)
        let argv = TreeBundleTransformCommand.arguments(
            for: request(operation: .extractSubtree),
            outputURL: out
        )
        XCTAssertEqual(argv, [
            "tree", "extract-subtree",
            "--bundle", "/proj/Phylogenetic Trees/source.lungfishtree",
            "--node", "node-7",
            "--output", "/proj/Phylogenetic Trees/Clade A-subtree.lungfishtree",
            "--format", "json",
        ])
    }

    func testCollapseHasNoArguments() {
        XCTAssertNil(TreeBundleTransformCommand.arguments(
            for: request(operation: .collapse),
            outputURL: URL(fileURLWithPath: "/x", isDirectory: true)
        ))
    }

    func testOutputStemReroot() {
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(operation: .reroot)),
            "source-rerooted"
        )
    }

    func testOutputStemExtractSubtreeUsesTipLabelsNotSupportValue() {
        // An unlabeled internal node's display label is its support value ("100"); the bundle
        // must be named from the tips it contains instead.
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(
                operation: .extractSubtree,
                nodeLabel: "100",
                tipLabels: ["RhesusMacaque_NC_005943.1", "CynomolgusMacaque_NC_012670.1"]
            )),
            "RhesusMacaque_NC_005943.1+CynomolgusMacaque_NC_012670.1-subtree"
        )
    }

    func testOutputStemExtractSubtreeSummarisesLargeClades() {
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(
                operation: .extractSubtree,
                nodeLabel: "95",
                tipLabels: ["A", "B", "C", "D", "E"]
            )),
            "A+4-more-subtree"
        )
    }

    func testOutputStemExtractSubtreeFallsBackToNodeLabelWithoutTips() {
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(operation: .extractSubtree, nodeLabel: "Clade A")),
            "Clade A-subtree"
        )
    }

    func testSubtreeNameStemSanitisesPathCharacters() {
        XCTAssertEqual(
            TreeBundleTransformCommand.subtreeNameStem(tipLabels: ["hCoV-19/USA/1:2020", "B"], fallback: "x"),
            "hCoV-19_USA_1_2020+B"
        )
        XCTAssertEqual(TreeBundleTransformCommand.subtreeNameStem(tipLabels: [], fallback: "  "), "clade")
    }

    private static let longTipA = "NC_076998_Human_CSF-associated_densovirus_putative_nonstructural_protein_NS1_QKT79_gp1_nonstructural_protein_NS2_QKT79_gp2_nonstructural_protein_NS3_QKT79_gp3_and_structural_protein_VP_QKT79_gp4_genes_complete_cds."
    private static let longTipB = "OQ835745_Densovirinae_sp._strain_Cameroon_U172329_2017_complete_genome."

    func testOutputStemExtractSubtreeWithTwoLongTipLabelsFitsFilenameLimit() throws {
        let stem = try XCTUnwrap(TreeBundleTransformCommand.outputStem(
            for: request(operation: .extractSubtree, tipLabels: [Self.longTipA, Self.longTipB])
        ))
        XCTAssertLessThanOrEqual((stem + "-99.lungfishtree").utf8.count, 255)
        XCTAssertTrue(stem.hasSuffix("-subtree"))
        XCTAssertTrue(stem.hasPrefix("NC_076998"))
    }

    @MainActor func testNextAvailableBundleURLBoundsLongSuggestedName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TreeNames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "\(Self.longTipA)-\(Self.longTipB)-subtree.lungfishtree"
        let url = ViewerViewController.nextAvailableBundleURL(suggestedName: name, pathExtension: "lungfishtree", in: dir)
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false))
    }

    @MainActor func testOutputStemRerootOfLongSourceStemFitsFilenameLimit() throws {
        let longRequest = PhylogeneticTreeViewController.TreeBundleOperationRequest(
            operation: .reroot,
            bundleURL: URL(fileURLWithPath: "/proj/\(String(repeating: "x", count: 240)).lungfishtree", isDirectory: true),
            nodeID: "n",
            nodeLabel: "n",
            tipLabels: []
        )
        let stem = try XCTUnwrap(TreeBundleTransformCommand.outputStem(for: longRequest))
        let url = ViewerViewController.nextAvailableBundleURL(
            suggestedName: "\(stem).lungfishtree",
            pathExtension: "lungfishtree",
            in: FileManager.default.temporaryDirectory
        )
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("xxxx"))
    }

    @MainActor func testTreeOutputURLIsUnderAnalysesAndUnique() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("P-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let first = ViewerViewController.treeOutputURL(projectURL: project, suggestedName: "X.lungfishtree")
        XCTAssertEqual(first.path, project.appendingPathComponent("Analyses/Phylogenetic Trees/X.lungfishtree").path)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = ViewerViewController.treeOutputURL(projectURL: project, suggestedName: "X.lungfishtree")
        XCTAssertNotEqual(first.path, second.path)
    }

    func testTitleAndDetail() {
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .reroot), "Re-root Tree")
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .extractSubtree), "Extract Subtree")
    }
}
