import Foundation
import XCTest
@testable import LungfishIO

final class PhylogeneticTreeBundleTests: XCTestCase {
    private var workspaceURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/tree-bundle-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceURL, FileManager.default.fileExists(atPath: workspaceURL.path) {
            try FileManager.default.removeItem(at: workspaceURL)
        }
        try super.tearDownWithError()
    }

    func testNewickImportCreatesBundleManifestNormalizedTreeIndexAndProvenance() throws {
        let sourceURL = try writeSource(
            name: "simple.nwk",
            contents: "((A:0.1,B:0.2)90:0.3,C:0.4);"
        )
        let bundleURL = workspaceURL.appendingPathComponent("Simple.lungfishtree", isDirectory: true)

        let bundle = try PhylogeneticTreeBundleImporter.importTree(
            from: sourceURL,
            to: bundleURL,
            options: .init(
                name: "Simple Tree",
                argv: ["lungfish", "import", "tree", sourceURL.path, "--project", workspaceURL.path],
                command: "lungfish import tree \(sourceURL.path) --project \(workspaceURL.path)"
            )
        )

        XCTAssertEqual(bundle.manifest.bundleKind, "phylogenetic-tree")
        XCTAssertEqual(bundle.manifest.name, "Simple Tree")
        XCTAssertEqual(bundle.manifest.sourceFormat, "newick")
        XCTAssertEqual(bundle.manifest.sourceFileName, "simple.nwk")
        XCTAssertEqual(bundle.manifest.treeCount, 1)
        XCTAssertEqual(bundle.manifest.tipCount, 3)
        XCTAssertEqual(bundle.manifest.internalNodeCount, 2)
        XCTAssertTrue(bundle.manifest.isRooted)
        XCTAssertEqual(bundle.manifest.primaryTreeID, "tree-1")
        XCTAssertEqual(bundle.manifest.capabilities, ["rectangular-phylogram", "metadata-inspector", "subtree-export"])
        XCTAssertTrue(bundle.manifest.warnings.isEmpty)

        assertBundleFilesExist(at: bundleURL)
        XCTAssertEqual(
            try String(contentsOf: bundleURL.appendingPathComponent("tree/source.original"), encoding: .utf8),
            "((A:0.1,B:0.2)90:0.3,C:0.4);"
        )

        let normalized = try decodedNormalizedTree(at: bundleURL)
        XCTAssertEqual(normalized.treeID, "tree-1")
        XCTAssertEqual(Set(normalized.nodes.filter(\.isTip).map(\.displayLabel)), ["A", "B", "C"])
        XCTAssertTrue(normalized.nodes.allSatisfy { !$0.id.isEmpty })
        XCTAssertEqual(normalized.nodes.first(where: { $0.displayLabel == "A" })?.descendantTipCount, 1)
        XCTAssertEqual(normalized.nodes.first(where: { $0.rawLabel == "90" })?.support?.rawValue, "90")
        XCTAssertEqual(normalized.nodes.first(where: { $0.rawLabel == "90" })?.support?.interpretation, "bootstrap")

        let manifestJSON = try jsonObject(at: bundleURL.appendingPathComponent("manifest.json"))
        let provenanceJSON = try jsonObject(at: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertNotNil(manifestJSON["checksums"])
        XCTAssertEqual(provenanceJSON["exitStatus"] as? Int, 0)
        XCTAssertEqual(provenanceJSON["toolName"] as? String, "lungfish import tree")
        XCTAssertEqual(provenanceJSON["toolVersion"] as? String, PhylogeneticTreeBundleImporter.toolVersion)
        XCTAssertEqual((provenanceJSON["argv"] as? [String])?.first, "lungfish")
        XCTAssertEqual(provenanceJSON["command"] as? String, "lungfish import tree \(sourceURL.path) --project \(workspaceURL.path)")
        XCTAssertEqual((provenanceJSON["input"] as? [String: Any])?["path"] as? String, sourceURL.path)
        XCTAssertEqual((provenanceJSON["output"] as? [String: Any])?["path"] as? String, bundleURL.path)
        XCTAssertNotNil((provenanceJSON["input"] as? [String: Any])?["sha256"])
        XCTAssertNotNil((provenanceJSON["output"] as? [String: Any])?["fileSizeBytes"])
        XCTAssertNotNil(provenanceJSON["wallTimeSeconds"])
        XCTAssertEqual((provenanceJSON["warnings"] as? [String]) ?? ["unexpected"], [])
        XCTAssertFalse(
            try String(
                contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"),
                encoding: .utf8
            ).contains("/tmp")
        )
    }

    func testNexusTranslateImportUsesTranslatedTipLabels() throws {
        let sourceURL = try writeSource(
            name: "translated.nex",
            contents: """
            #NEXUS
            begin trees;
              translate
                1 Alpha,
                2 Beta,
                3 Gamma
              ;
              tree best = [&R] ((1:0.1,2:0.2):0.3,3:0.4);
            end;
            """
        )
        let bundleURL = workspaceURL.appendingPathComponent("Translated.lungfishtree", isDirectory: true)

        let bundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        XCTAssertEqual(bundle.manifest.sourceFormat, "nexus")
        XCTAssertTrue(bundle.manifest.isRooted)
        let normalized = try decodedNormalizedTree(at: bundleURL)
        XCTAssertEqual(Set(normalized.nodes.filter(\.isTip).map(\.displayLabel)), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(normalized.nodes.first(where: { $0.displayLabel == "Alpha" })?.rawLabel, "1")
    }

    func testBeastStyleCommentsArePreservedAsNodeMetadata() throws {
        let sourceURL = try writeSource(
            name: "beast.tree",
            contents: "(A[&date=2020.5,host=\"lungfish\"]:0.1,B:0.2)[&posterior=0.98,height=1.2]:0.0;"
        )
        let bundleURL = workspaceURL.appendingPathComponent("Beast.lungfishtree", isDirectory: true)

        let bundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        XCTAssertEqual(bundle.manifest.sourceFormat, "newick")
        let normalized = try decodedNormalizedTree(at: bundleURL)
        let tipA = try XCTUnwrap(normalized.nodes.first(where: { $0.displayLabel == "A" }))
        XCTAssertEqual(tipA.metadata["date"], "2020.5")
        XCTAssertEqual(tipA.metadata["host"], "lungfish")

        let root = try XCTUnwrap(normalized.nodes.first(where: { $0.parentID == nil }))
        XCTAssertEqual(root.metadata["posterior"], "0.98")
        XCTAssertEqual(root.metadata["height"], "1.2")
        XCTAssertEqual(root.support?.rawValue, "0.98")
        XCTAssertEqual(root.support?.interpretation, "posterior")
    }

    func testMalformedTreeIsRejectedWithoutPartialBundle() throws {
        let sourceURL = try writeSource(name: "bad.nwk", contents: "((A:0.1,B:0.2);")
        let bundleURL = workspaceURL.appendingPathComponent("Bad.lungfishtree", isDirectory: true)

        XCTAssertThrowsError(try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)) { error in
            guard case PhylogeneticTreeBundleError.parseFailed = error else {
                XCTFail("wrong error: \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.path))
    }

    func testBranchLengthWarningsAreWrittenToManifestAndProvenance() throws {
        let sourceURL = try writeSource(name: "warnings.nwk", contents: "((A,B)0.51,C);")
        let bundleURL = workspaceURL.appendingPathComponent("Warnings.lungfishtree", isDirectory: true)

        let bundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        XCTAssertTrue(bundle.manifest.warnings.contains("Tree contains one or more edges without branch lengths."))
        XCTAssertTrue(bundle.manifest.warnings.contains("Internal support value '0.51' was interpreted as posterior probability."))
        let provenanceJSON = try jsonObject(at: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(provenanceJSON["warnings"] as? [String], bundle.manifest.warnings)
    }

    func testSubtreeNewickByLabelPreservesDescendantsAndBranchLengths() throws {
        let sourceURL = try writeSource(
            name: "subtree.nwk",
            contents: "((A:0.1,B:0.2)Clade:0.3,C:0.4);"
        )
        let bundleURL = workspaceURL.appendingPathComponent("Subtree.lungfishtree", isDirectory: true)
        let bundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        let subtree = try bundle.subtreeNewick(label: "Clade")

        XCTAssertEqual(subtree, "(A:0.1,B:0.2)Clade:0.3;")
    }

    private func writeSource(name: String, contents: String) throws -> URL {
        let url = workspaceURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func assertBundleFilesExist(at bundleURL: URL) {
        let paths = [
            "manifest.json",
            "tree/source.original",
            "tree/primary.nwk",
            "tree/primary.normalized.json",
            "cache/tree-index.sqlite",
            ".viewstate.json",
            ".lungfish-provenance.json"
        ]
        for path in paths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(path).path), path)
        }
    }

    private func decodedNormalizedTree(at bundleURL: URL) throws -> PhylogeneticTreeNormalizedTree {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("tree/primary.normalized.json"))
        let decoder = JSONDecoder()
        return try decoder.decode(PhylogeneticTreeNormalizedTree.self, from: data)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
