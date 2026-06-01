import XCTest
@testable import LungfishApp
import LungfishPhylogeneticsUI

final class TreeBundleTransformArgvTests: XCTestCase {
    private func request(
        operation: PhylogeneticTreeViewController.TreeBundleOperation,
        nodeID: String = "node-7",
        nodeLabel: String = "Clade A"
    ) -> PhylogeneticTreeViewController.TreeBundleOperationRequest {
        PhylogeneticTreeViewController.TreeBundleOperationRequest(
            operation: operation,
            bundleURL: URL(fileURLWithPath: "/proj/Phylogenetic Trees/source.lungfishtree", isDirectory: true),
            nodeID: nodeID,
            nodeLabel: nodeLabel
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

    func testOutputStemExtractSubtreeUsesNodeLabel() {
        XCTAssertEqual(
            TreeBundleTransformCommand.outputStem(for: request(operation: .extractSubtree, nodeLabel: "Clade A")),
            "Clade A-subtree"
        )
    }

    func testTitleAndDetail() {
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .reroot), "Re-root Tree")
        XCTAssertEqual(TreeBundleTransformCommand.title(for: .extractSubtree), "Extract Subtree")
    }
}
