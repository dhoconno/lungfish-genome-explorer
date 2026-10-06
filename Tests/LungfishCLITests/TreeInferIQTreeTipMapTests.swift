import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

/// Rulings C1, C3 and C4: safe tip IDs, the tip map, outgroup rooting and the effective seed.
final class TreeInferIQTreeTipMapTests: XCTestCase {
    // MARK: C3 safe tip IDs

    func testAwkwardHeadersAreStagedAsSafeIDsAndMappedBackToDisplayNames() async throws {
        let project = try IQTreeTestProject.make(fasta: awkwardHeaderFASTA)
        defer { project.remove() }
        let msa = try MultipleSequenceAlignmentBundle.load(from: project.msaBundleURL)
        let displayNames = msa.rows.sorted { $0.order < $1.order }.map(\.displayName)
        XCTAssertEqual(displayNames.count, 6)

        try await project.run(["--bootstrap", "1000"])

        let output = project.outputURL()
        let stagedInput = try String(contentsOf: output.appendingPathComponent("artifacts/iqtree/input.aligned.fasta"), encoding: .utf8)
        let stagedHeaders = stagedInput.split(separator: "\n").filter { $0.hasPrefix(">") }.map { String($0.dropFirst()) }
        XCTAssertEqual(stagedHeaders, ["t0001", "t0002", "t0003", "t0004", "t0005", "t0006"])

        let tipMap = try String(contentsOf: output.appendingPathComponent("artifacts/iqtree/tip-map.tsv"), encoding: .utf8)
        let lines = tipMap.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "tip_id\trow_id\tdisplay_name\theader")
        XCTAssertEqual(lines.count, 7)
        for (index, row) in msa.rows.sorted(by: { $0.order < $1.order }).enumerated() {
            let fields = lines[index + 1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields, [String(format: "t%04d", index + 1), row.id, row.displayName, row.sourceName])
        }

        let tree = try PhylogeneticTreeBundle.load(from: output)
        let tipLabels = tree.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)
        XCTAssertEqual(Set(tipLabels), Set(displayNames))
        XCTAssertEqual(tipLabels.count, 6)

        // The raw IQ-TREE treefile keeps the safe IDs, so it stays readable through tip-map.tsv.
        let rawTreefile = try String(contentsOf: output.appendingPathComponent("artifacts/iqtree/run.treefile"), encoding: .utf8)
        XCTAssertTrue(rawTreefile.contains("t0001"))
        let manifest = try String(contentsOf: output.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("artifacts/iqtree/tip-map.tsv") || manifest.contains("artifacts\\/iqtree\\/tip-map.tsv"))
    }

    func testRowsMatchByRowIDFirstThenUniqueDisplayName() async throws {
        let project = try IQTreeTestProject.make(fasta: awkwardHeaderFASTA)
        defer { project.remove() }
        let rows = try MultipleSequenceAlignmentBundle.load(from: project.msaBundleURL).rows.sorted { $0.order < $1.order }
        try await project.run(["--rows", "\(rows[0].id),Xenopus (frog),\(rows[5].displayName)"])
        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertEqual(
            Set(tree.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)),
            [rows[0].displayName, "Xenopus (frog)", rows[5].displayName]
        )
    }

    func testDuplicateDisplayNamesInScopeAreAnErrorNamingThem() async throws {
        let project = try IQTreeTestProject.make(fasta: """
        >Same name
        ACGTACGTACGT
        >Same name
        ACGTACGTACGA
        >Other
        ACGAACGTACGT
        >Fourth
        TCGTACGTACGT

        """)
        defer { project.remove() }
        let rows = try MultipleSequenceAlignmentBundle.load(from: project.msaBundleURL).rows.sorted { $0.order < $1.order }

        let whole = await project.failure([])
        XCTAssertTrue(whole.contains("Same name"), whole)
        XCTAssertTrue(whole.contains(rows[0].id) && whole.contains(rows[1].id), whole)

        let ambiguous = await project.failure(["--rows", "Same name,Other,Fourth"])
        XCTAssertTrue(ambiguous.contains("ambiguous"), ambiguous)
        XCTAssertTrue(ambiguous.contains(rows[0].id) && ambiguous.contains(rows[1].id), ambiguous)
        XCTAssertFalse(project.iqtreeWasInvoked)

        // Picking one of the duplicates by row ID is fine.
        try await project.run(["--rows", "\(rows[0].id),Other,Fourth"])
    }

    func testUnknownRowIsAnError() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let message = await project.failure(["--rows", "A,B,Nope"])
        XCTAssertTrue(message.contains("Nope"), message)
    }

    // MARK: C4 outgroup

    func testMonophyleticOutgroupRootsTheSavedTree() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try project.setFakeTree("(t0001:0.1,t0002:0.2,(t0003:0.3,t0004:0.4)90:0.05);\n")

        try await project.run(["--outgroup", "C,D"])

        let arguments = try project.recordedIQTreeArguments()
        XCTAssertEqual(arguments.firstIndex(of: "-o").map { arguments[$0 + 1] }, "t0003,t0004")
        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertTrue(tree.manifest.isRooted)
        let root = try XCTUnwrap(tree.normalizedTree.nodes.first { $0.parentID == nil })
        XCTAssertEqual(root.childIDs.count, 2)
        let childTipSets = root.childIDs.map { tipLabels(under: $0, in: tree) }
        XCTAssertTrue(childTipSets.contains(["C", "D"]), "\(childTipSets)")
        XCTAssertTrue(childTipSets.contains(["A", "B"]), "\(childTipSets)")

        let provenance = try project.provenance()
        let argv = try XCTUnwrap(provenance["argv"] as? [String])
        XCTAssertEqual(argv.firstIndex(of: "--outgroup").map { argv[$0 + 1] }, "C,D")
        let options = try XCTUnwrap(provenance["options"] as? [String: String])
        XCTAssertEqual(options["outgroup"], "C,D")
        // Fix G (re-review minor 3): the display names sit beside the raw selectors.
        XCTAssertEqual(options["outgroupNames"], "C, D")
        XCTAssertEqual(options["rooting"], "outgroup")
        XCTAssertEqual((provenance["warnings"] as? [String]) ?? [], [])
    }

    /// Fix G (re-review minor 3): the dialog passes row IDs, and provenance still names the rows.
    func testRowIDOutgroupRecordsDisplayNamesInProvenance() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try project.setFakeTree("(t0001:0.1,t0002:0.2,(t0003:0.3,t0004:0.4)90:0.05);\n")
        let rows = try MultipleSequenceAlignmentBundle.load(from: project.msaBundleURL).rows
        let rowIDs = try ["C", "D"].map { name in try XCTUnwrap(rows.first { $0.displayName == name }?.id) }

        try await project.run(["--outgroup", rowIDs.joined(separator: ",")])

        let options = try XCTUnwrap(try project.provenance()["options"] as? [String: String])
        XCTAssertEqual(options["outgroup"], rowIDs.joined(separator: ","))
        XCTAssertEqual(options["outgroupNames"], "C, D")
        XCTAssertEqual(options["outgroupTipIDs"], "t0003,t0004")
    }

    func testSingleTipOutgroupRootsOnThatTip() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try project.setFakeTree("(t0001:0.1,t0002:0.2,(t0003:0.3,t0004:0.4)90:0.05);\n")
        try await project.run(["--outgroup", "A"])
        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertTrue(tree.manifest.isRooted)
        let root = try XCTUnwrap(tree.normalizedTree.nodes.first { $0.parentID == nil })
        XCTAssertTrue(root.childIDs.map { tipLabels(under: $0, in: tree) }.contains(["A"]))
    }

    func testOutgroupWhoseComplementIsTheDrawnCladeStillRoots() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        // A,B is a clade of the unrooted tree even though the drawn root sits inside it.
        try project.setFakeTree("(t0001:0.1,t0002:0.2,(t0003:0.3,t0004:0.4)90:0.05);\n")
        try await project.run(["--outgroup", "A,B"])
        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertTrue(tree.manifest.isRooted)
        let root = try XCTUnwrap(tree.normalizedTree.nodes.first { $0.parentID == nil })
        XCTAssertEqual(Set(root.childIDs.map { tipLabels(under: $0, in: tree) }), [["A", "B"], ["C", "D"]])
    }

    func testNonMonophyleticOutgroupKeepsTheTreeUnrootedWithAWarning() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try project.setFakeTree("(t0001:0.1,t0002:0.2,(t0003:0.3,t0004:0.4)90:0.05);\n")
        try project.setFakeLog("Seed:    11 (Using SPRNG)\nWARNING: Branch separating outgroup is not found\n")

        let lines = try await project.run(["--outgroup", "A,C"])

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertFalse(tree.manifest.isRooted)
        let warnings = try XCTUnwrap(try project.provenance()["warnings"] as? [String])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("not monophyletic"), warnings[0])
        XCTAssertTrue(lines.contains { $0.contains(#""event":"log""#) && $0.contains("not monophyletic") }, lines.joined(separator: "\n"))
        let manifest = try String(contentsOf: project.outputURL().appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("not monophyletic"), manifest)
    }

    func testOutgroupOutsideScopeIsAnError() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let message = await project.failure(["--rows", "A,B,C", "--outgroup", "D"])
        XCTAssertTrue(message.contains("D"), message)
        XCTAssertTrue(message.contains("--outgroup"), message)
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    // MARK: C1 seed

    func testOmittedSeedRecordsEffectiveSeedFromRunLog() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run([])
        let provenance = try project.provenance()
        let options = try XCTUnwrap(provenance["options"] as? [String: String])
        XCTAssertNil(options["seed"])
        XCTAssertEqual(options["effectiveSeed"], "937314")
        let argv = try XCTUnwrap(provenance["argv"] as? [String])
        XCTAssertFalse(argv.contains("--seed"))
    }

    func testGivenSeedIsTheEffectiveSeed() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try project.setFakeLog("Seed:    42 (Using SPRNG)\n")
        try await project.run(["--seed", "42"])
        let options = try XCTUnwrap(try project.provenance()["options"] as? [String: String])
        XCTAssertEqual(options["seed"], "42")
        XCTAssertEqual(options["effectiveSeed"], "42")
    }

    func testCanonicalArgvRecordsEveryOptionInStableOrder() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run([
            "--outgroup", "D", "--seed", "3", "--threads", "1", "--bootstrap", "1000", "--alrt", "1000",
            "--model", "JC", "--sequence-type", "DNA", "--safe", "--keep-identical", "--name", "T",
            "--extra-args", "-bnni",
        ])
        let argv = try XCTUnwrap(try project.provenance()["argv"] as? [String])
        let flags = argv.filter { $0.hasPrefix("--") }
        XCTAssertEqual(flags, [
            "--project", "--output", "--model", "--sequence-type", "--threads", "--name",
            "--bootstrap", "--alrt", "--seed", "--outgroup", "--safe", "--keep-identical",
            "--extra-args", "--iqtree-path", "--format",
        ])
    }

    // MARK: Real IQ-TREE

    func testRealIQTreeSameSeedAndThreadsGiveByteIdenticalTrees() async throws {
        let iqtree = try installedIQTree()
        let fasta = try String(contentsOf: knownSarcopterygianAlignment(), encoding: .utf8)
        let project = try IQTreeTestProject.make(fasta: fasta)
        defer { project.remove() }
        let options = ["--seed", "12345", "--threads", "1", "--bootstrap", "1000", "--alrt", "1000", "--model", "JC"]
        try await project.run(options, output: project.outputURL("First"), iqtreePath: iqtree.path)
        try await project.run(options, output: project.outputURL("Second"), iqtreePath: iqtree.path)
        let first = try Data(contentsOf: project.outputURL("First").appendingPathComponent("tree/primary.nwk"))
        let second = try Data(contentsOf: project.outputURL("Second").appendingPathComponent("tree/primary.nwk"))
        XCTAssertEqual(first, second)
        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL("First"))
        XCTAssertEqual(
            Set(tree.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)),
            ["Zebrafish_outgroup", "Coelacanth", "Australian_lungfish", "African_lungfish", "Human", "Frog"]
        )
    }

    func testRealIQTreeOutgroupRootsWithoutChangingSplits() async throws {
        let iqtree = try installedIQTree()
        let fasta = try String(contentsOf: knownSarcopterygianAlignment(), encoding: .utf8)
        let project = try IQTreeTestProject.make(fasta: fasta)
        defer { project.remove() }
        let options = ["--seed", "12345", "--threads", "1", "--model", "JC"]
        try await project.run(options, output: project.outputURL("Unrooted"), iqtreePath: iqtree.path)
        try await project.run(options + ["--outgroup", "Zebrafish_outgroup"], output: project.outputURL("Rooted"), iqtreePath: iqtree.path)
        let unrooted = try PhylogeneticTreeBundle.load(from: project.outputURL("Unrooted"))
        let rooted = try PhylogeneticTreeBundle.load(from: project.outputURL("Rooted"))
        XCTAssertFalse(unrooted.manifest.isRooted)
        XCTAssertTrue(rooted.manifest.isRooted)
        XCTAssertEqual(splits(of: unrooted), splits(of: rooted))
        let root = try XCTUnwrap(rooted.normalizedTree.nodes.first { $0.parentID == nil })
        XCTAssertTrue(root.childIDs.map { tipLabels(under: $0, in: rooted) }.contains(["Zebrafish_outgroup"]))

        try await project.run(options + ["--outgroup", "Human,Zebrafish_outgroup"], output: project.outputURL("Split"), iqtreePath: iqtree.path)
        let split = try PhylogeneticTreeBundle.load(from: project.outputURL("Split"))
        XCTAssertFalse(split.manifest.isRooted)
        XCTAssertEqual((try project.provenance(project.outputURL("Split"))["warnings"] as? [String])?.count, 1)
    }

    // MARK: Helpers

    private func installedIQTree() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/conda/envs/iqtree/bin/iqtree3")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("iqtree3 is not installed at \(url.path)")
        }
        return url
    }

    private func knownSarcopterygianAlignment() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phylogenetics/known-sarcopterygian/alignment.fasta")
    }

    private func tipLabels(under nodeID: String, in tree: PhylogeneticTreeBundle) -> Set<String> {
        let nodes = Dictionary(uniqueKeysWithValues: tree.normalizedTree.nodes.map { ($0.id, $0) })
        var result: Set<String> = []
        var stack = [nodeID]
        while let id = stack.popLast(), let node = nodes[id] {
            if node.isTip {
                result.insert(node.displayLabel)
            }
            stack += node.childIDs
        }
        return result
    }

    /// Every bipartition of the tree, each written as the side that does not hold the first tip.
    private func splits(of tree: PhylogeneticTreeBundle) -> Set<Set<String>> {
        let all = Set(tree.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel))
        guard let anchor = all.sorted().first else { return [] }
        var result: Set<Set<String>> = []
        for node in tree.normalizedTree.nodes where node.parentID != nil {
            let below = tipLabels(under: node.id, in: tree)
            let side = below.contains(anchor) ? all.subtracting(below) : below
            if side.count > 1, side.count < all.count - 1 {
                result.insert(side)
            }
        }
        return result
    }
}
