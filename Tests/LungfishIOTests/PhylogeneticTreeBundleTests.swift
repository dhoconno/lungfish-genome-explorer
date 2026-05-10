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

    func testKnownSarcopterygianFixtureImportsWithExpectedClades() throws {
        let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/phylogenetics/known-sarcopterygian/expected.nwk")
        let bundleURL = workspaceURL.appendingPathComponent("KnownSarcopterygian.lungfishtree", isDirectory: true)

        let bundle = try PhylogeneticTreeBundleImporter.importTree(
            from: fixtureURL,
            to: bundleURL,
            options: .init(name: "Known Sarcopterygian Tree")
        )

        XCTAssertEqual(
            Set(bundle.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)),
            [
                "Zebrafish_outgroup",
                "Coelacanth",
                "Australian_lungfish",
                "African_lungfish",
                "Human",
                "Frog",
            ]
        )
        XCTAssertTrue(bundleContainsClade(bundle, labels: ["Australian_lungfish", "African_lungfish"]))
        XCTAssertTrue(bundleContainsClade(bundle, labels: ["Human", "Frog"]))
        XCTAssertTrue(bundleContainsClade(bundle, labels: ["Australian_lungfish", "African_lungfish", "Human", "Frog"]))
        XCTAssertTrue(bundleContainsClade(bundle, labels: ["Coelacanth", "Australian_lungfish", "African_lungfish", "Human", "Frog"]))
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

    func testExtractSubtreeWritesNewBundleWithSourceBundleProvenance() throws {
        let sourceURL = try writeSource(
            name: "extract-source.nwk",
            contents: "((A:0.1,B:0.2)Clade:0.3,C:0.4);"
        )
        let sourceBundleURL = workspaceURL.appendingPathComponent("ExtractSource.lungfishtree", isDirectory: true)
        let sourceBundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: sourceBundleURL)
        let cladeID = try XCTUnwrap(sourceBundle.normalizedTree.nodes.first { $0.displayLabel == "Clade" }?.id)
        let outputURL = workspaceURL.appendingPathComponent("Extracted.lungfishtree", isDirectory: true)

        let extracted = try sourceBundle.extractSubtreeBundle(
            nodeID: cladeID,
            to: outputURL,
            provenance: .init(
                toolName: "lungfish tree extract-subtree",
                argv: ["lungfish", "tree", "extract-subtree", "--bundle", sourceBundleURL.path, "--node", cladeID, "--output", outputURL.path],
                options: ["node": cladeID]
            )
        )

        XCTAssertEqual(Set(extracted.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)), ["A", "B"])
        XCTAssertEqual(try String(contentsOf: outputURL.appendingPathComponent("tree/primary.nwk"), encoding: .utf8), "(A:0.1,B:0.2)Clade:0.3;\n")
        let provenanceJSON = try jsonObject(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(provenanceJSON["workflowName"] as? String, "phylogenetic-tree-extract-subtree")
        XCTAssertEqual(provenanceJSON["toolName"] as? String, "lungfish tree extract-subtree")
        XCTAssertEqual((provenanceJSON["input"] as? [String: Any])?["path"] as? String, sourceBundleURL.path)
        XCTAssertEqual((provenanceJSON["output"] as? [String: Any])?["path"] as? String, outputURL.path)
        XCTAssertEqual((provenanceJSON["options"] as? [String: Any])?["node"] as? String, cladeID)
        XCTAssertNotNil((provenanceJSON["inputTreeFile"] as? [String: Any])?["sha256"])
        XCTAssertNotNil(provenanceJSON["wallTimeSeconds"])
    }

    func testRerootWritesNewBundleWithoutMutatingSourceBundle() throws {
        let sourceURL = try writeSource(
            name: "reroot-source.nwk",
            contents: "((A:0.1,B:0.2)Clade:0.3,C:0.4);"
        )
        let sourceBundleURL = workspaceURL.appendingPathComponent("RerootSource.lungfishtree", isDirectory: true)
        let sourceBundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: sourceBundleURL)
        let outputURL = workspaceURL.appendingPathComponent("Rerooted.lungfishtree", isDirectory: true)

        let rerooted = try sourceBundle.rerootedBundle(
            on: "C",
            to: outputURL,
            provenance: .init(
                toolName: "lungfish tree reroot",
                argv: ["lungfish", "tree", "reroot", "--bundle", sourceBundleURL.path, "--on", "C", "--output", outputURL.path],
                options: ["on": "C"]
            )
        )

        XCTAssertEqual(Set(rerooted.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)), ["A", "B", "C"])
        XCTAssertEqual(
            try String(contentsOf: sourceBundleURL.appendingPathComponent("tree/primary.nwk"), encoding: .utf8),
            "((A:0.1,B:0.2)Clade:0.3,C:0.4);\n"
        )
        XCTAssertTrue(try String(contentsOf: outputURL.appendingPathComponent("tree/primary.nwk"), encoding: .utf8).contains("C:0.0"))
        let provenanceJSON = try jsonObject(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(provenanceJSON["workflowName"] as? String, "phylogenetic-tree-reroot")
        XCTAssertEqual((provenanceJSON["input"] as? [String: Any])?["path"] as? String, sourceBundleURL.path)
        XCTAssertEqual((provenanceJSON["options"] as? [String: Any])?["on"] as? String, "C")
    }

    func testRelabelFromMetadataColumnWritesNewBundle() throws {
        let sourceURL = try writeSource(
            name: "relabel-source.nwk",
            contents: "(A:0.1,B:0.2,C:0.3);"
        )
        let sourceBundleURL = workspaceURL.appendingPathComponent("RelabelSource.lungfishtree", isDirectory: true)
        let sourceBundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: sourceBundleURL)
        try """
        id\tlineage\tcountry
        A\tBA.1\tUSA
        B\tBA.2\tCanada
        C\tBA.5\tMexico
        """.write(to: sourceBundleURL.appendingPathComponent("metadata.tsv"), atomically: true, encoding: .utf8)
        let outputURL = workspaceURL.appendingPathComponent("Relabeled.lungfishtree", isDirectory: true)

        let relabeled = try sourceBundle.relabeledBundle(
            column: "lineage",
            to: outputURL,
            provenance: .init(
                toolName: "lungfish tree relabel",
                argv: ["lungfish", "tree", "relabel", "--bundle", sourceBundleURL.path, "--column", "lineage", "--output", outputURL.path],
                options: ["column": "lineage"]
            )
        )

        XCTAssertEqual(Set(relabeled.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)), ["BA.1", "BA.2", "BA.5"])
        XCTAssertEqual(try String(contentsOf: outputURL.appendingPathComponent("metadata.tsv"), encoding: .utf8).split(separator: "\n").count, 4)
        let provenanceJSON = try jsonObject(at: outputURL.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertEqual(provenanceJSON["workflowName"] as? String, "phylogenetic-tree-relabel")
        XCTAssertEqual((provenanceJSON["options"] as? [String: Any])?["column"] as? String, "lineage")
        XCTAssertEqual((provenanceJSON["metadataFile"] as? [String: Any])?["path"] as? String, sourceBundleURL.appendingPathComponent("metadata.tsv").path)
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

    private func bundleContainsClade(_ bundle: PhylogeneticTreeBundle, labels: Set<String>) -> Bool {
        let nodesByID = Dictionary(uniqueKeysWithValues: bundle.normalizedTree.nodes.map { ($0.id, $0) })
        func descendantTips(for node: PhylogeneticTreeNormalizedNode) -> Set<String> {
            if node.isTip {
                return [node.displayLabel]
            }
            return node.childIDs.reduce(into: Set<String>()) { result, childID in
                guard let child = nodesByID[childID] else { return }
                result.formUnion(descendantTips(for: child))
            }
        }
        return bundle.normalizedTree.nodes.contains { descendantTips(for: $0) == labels }
    }
}
