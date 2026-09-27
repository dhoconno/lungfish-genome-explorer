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

    func testTitleAndDetail() {
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .reroot), "Re-root Tree")
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .extractSubtree), "Extract Subtree")
    }
}
