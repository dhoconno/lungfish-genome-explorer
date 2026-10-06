import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

/// Rulings C3, C6 and C8 at import: support labels, branch length unit, the inference summary,
/// the importer's tip map, the alias spellings of curated flags and the normalized sequence type.
final class TreeInferIQTreeImportTests: XCTestCase {
    private let fiveRowFASTA = """
    >A
    ACGTACGTACGT
    >B
    ACGTACGTACGA
    >C
    ACGAACGTACGT
    >D
    TCGTACGTACGT
    >E
    TCGTACGTACCT

    """

    private let supportTree = "(t0001:0.1,t0002:0.2,(t0003:0.3,(t0004:0.4,t0005:0.5)70/88:0.1)85.5/97:0.05);\n"

    // MARK: C8 support labels and branch length unit

    func testSupportLabelsFollowTheRequestedTestsInIQTreeOrder() async throws {
        let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
        defer { project.remove() }
        try project.setFakeTree(supportTree)

        try await project.run(["--bootstrap", "1500", "--alrt", "1000"])

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertEqual(tree.manifest.supportLabels, ["SH-aLRT", "UFBoot"])
        XCTAssertEqual(tree.manifest.inference?.ufBootReplicates, 1500)
        XCTAssertEqual(tree.manifest.inference?.shALRTReplicates, 1000)
        XCTAssertEqual(tree.manifest.branchLengthUnit, "substitutions per site")
        let clade = try XCTUnwrap(node(over: ["D", "E"], in: tree))
        XCTAssertEqual(clade.supportValues.map(\.label), ["SH-aLRT", "UFBoot"])
        XCTAssertEqual(clade.supportValues.map(\.value), [70, 88])
    }

    func testABayesInExtraArgsSitsBetweenSHALRTAndUFBoot() async throws {
        let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
        defer { project.remove() }
        try project.setFakeTree("(t0001:0.1,t0002:0.2,(t0003:0.3,(t0004:0.4,t0005:0.5)70/0.9/88:0.1)85.5/1/97:0.05);\n")

        try await project.run(["--bootstrap", "1000", "--alrt", "1000", "--extra-args", "--abayes"])

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertEqual(tree.manifest.supportLabels, ["SH-aLRT", "aBayes", "UFBoot"])
    }

    func testNoSupportRequestedRecordsNoSupportLabels() async throws {
        let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
        defer { project.remove() }

        try await project.run([])

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertNil(tree.manifest.supportLabels)
        XCTAssertNil(tree.manifest.inference?.ufBootReplicates)
        XCTAssertNil(tree.manifest.inference?.shALRTReplicates)
        XCTAssertEqual(tree.manifest.branchLengthUnit, "substitutions per site")
    }

    func testOutgroupRerootKeepsSupportValuesWithTheirLabels() async throws {
        let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
        defer { project.remove() }
        try project.setFakeTree(supportTree)

        try await project.run(["--bootstrap", "1000", "--alrt", "1000", "--outgroup", "A"])

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertTrue(tree.manifest.isRooted)
        XCTAssertEqual(tree.manifest.supportLabels, ["SH-aLRT", "UFBoot"])
        let root = try XCTUnwrap(tree.normalizedTree.nodes.first { $0.parentID == nil })
        XCTAssertTrue(root.childIDs.map { tipLabels(under: $0, in: tree) }.contains(["A"]))
        let inner = try XCTUnwrap(node(over: ["D", "E"], in: tree))
        XCTAssertEqual(inner.supportValues.map(\.label), ["SH-aLRT", "UFBoot"])
        XCTAssertEqual(inner.supportValues.map(\.value), [70, 88])
        let outer = try XCTUnwrap(node(over: ["C", "D", "E"], in: tree))
        XCTAssertEqual(outer.supportValues.map(\.value), [85.5, 97])
        XCTAssertEqual(Set(tree.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)), ["A", "B", "C", "D", "E"])
    }

    // MARK: C8 inference summary

    func testInferenceSummaryRecordsModelSelectionRunOptionsAndScope() async throws {
        let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
        defer { project.remove() }
        try project.setFakeReport(try String(contentsOf: sarcopterygianReport(), encoding: .utf8))
        try project.setFakeLog("Seed:    42 (Using SPRNG)\n")

        try await project.run([
            "--rows", "A,B,C,D", "--columns", "1-9", "--sequence-type", "dna", "--threads", "2",
            "--seed", "42", "--outgroup", "D",
        ])

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        let inference = try XCTUnwrap(tree.manifest.inference)
        XCTAssertEqual(inference.program, "IQ-TREE")
        XCTAssertEqual(inference.programVersion, "3.1.3")
        XCTAssertEqual(inference.requestedModel, "MFP")
        XCTAssertEqual(inference.bestFitModel, "TIM2+ASC")
        XCTAssertEqual(inference.modelSelectionCriterion, "BIC")
        XCTAssertEqual(inference.substitutionModel, "TIM2+F+ASC")
        XCTAssertEqual(inference.logLikelihood, -173.4941)
        XCTAssertEqual(inference.logLikelihoodStandardError, 7.9018)
        XCTAssertEqual(inference.freeParameters, 15)
        XCTAssertEqual(inference.sequenceType, "DNA")
        XCTAssertEqual(inference.seed, 42)
        XCTAssertEqual(inference.threads, 2)
        XCTAssertEqual(inference.outgroup, ["D"])
        XCTAssertNil(inference.outgroupWarning)
        XCTAssertEqual(inference.sourceAlignmentName, "Input")
        XCTAssertEqual(inference.sourceAlignmentPath, project.msaBundleURL.standardizedFileURL.path)
        XCTAssertEqual(inference.selectedRowCount, 4)
        XCTAssertEqual(inference.totalRowCount, 5)
        XCTAssertEqual(inference.selectedColumns, "1-9")
        XCTAssertEqual(inference.alignedLength, 9)
    }

    func testFixedModelSummaryUsesFixedCriterionAutoThreadsAndTheDrawnSeed() async throws {
        let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
        defer { project.remove() }
        try project.setFakeTree(supportTree)
        try project.setFakeLog("Seed:    11 (Using SPRNG)\nWARNING: Branch separating outgroup is not found\n")

        try await project.run(["--model", "JC", "--outgroup", "A,C"])

        let inference = try XCTUnwrap(try PhylogeneticTreeBundle.load(from: project.outputURL()).manifest.inference)
        XCTAssertEqual(inference.requestedModel, "JC")
        XCTAssertNil(inference.bestFitModel)
        XCTAssertEqual(inference.modelSelectionCriterion, "fixed")
        XCTAssertEqual(inference.sequenceType, "auto")
        XCTAssertEqual(inference.seed, 11)
        XCTAssertNil(inference.threads)
        XCTAssertEqual(inference.outgroup, ["A", "C"])
        XCTAssertTrue(inference.outgroupWarning?.contains("not monophyletic") == true, "\(String(describing: inference.outgroupWarning))")
        XCTAssertNil(inference.selectedColumns)
        XCTAssertEqual(inference.alignedLength, 12)
    }

    // MARK: C6 alias spellings

    func testAliasSpellingsOfCuratedFlagsAreRejected() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let cases: [(String, String)] = [
            ("-bb 1000", "--bootstrap"),
            ("--ufboot 1000", "--bootstrap"),
            ("-pre other", "--output"),
            ("-seed 7", "--seed"),
        ]
        for (text, curated) in cases {
            let message = await project.failure(["--extra-args", text])
            let flag = String(text.split(separator: " ")[0])
            XCTAssertTrue(message.contains("must not set \(flag)."), message)
            XCTAssertTrue(message.contains(curated), message)
        }
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    func testStandardBootstrapAndThreadsMaxStayAllowed() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run(["--extra-args", "-b 100 --threads-max 4"])
        let arguments = try project.recordedIQTreeArguments()
        XCTAssertEqual(Array(arguments.suffix(4)), ["-b", "100", "--threads-max", "4"])
    }

    // MARK: Canonical --sequence-type

    func testCanonicalArgvRecordsTheNormalizedSequenceType() async throws {
        for (typed, expected) in [("codon2", "CODON2"), ("dna", "DNA"), ("aa", "AA")] {
            let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
            defer { project.remove() }
            try await project.run(["--sequence-type", typed])
            let argv = try XCTUnwrap(try project.provenance()["argv"] as? [String])
            XCTAssertEqual(argv.firstIndex(of: "--sequence-type").map { argv[$0 + 1] }, expected)
            let arguments = try project.recordedIQTreeArguments()
            XCTAssertEqual(arguments.firstIndex(of: "--seqtype").map { arguments[$0 + 1] }, expected)
            let options = try XCTUnwrap(try project.provenance()["options"] as? [String: String])
            XCTAssertEqual(options["sequenceType"], expected)
        }
    }

    func testAutoSequenceTypeIsLeftOutOfTheCanonicalArgv() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run(["--sequence-type", "AUTO"])
        let argv = try XCTUnwrap(try project.provenance()["argv"] as? [String])
        XCTAssertFalse(argv.contains("--sequence-type"))
    }

    // MARK: Real IQ-TREE

    func testRealIQTreeRecordsSupportLabelsModelSelectionAndDisplayNamesWithSpaces() async throws {
        let iqtree = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/conda/envs/iqtree/bin/iqtree3")
        guard FileManager.default.isExecutableFile(atPath: iqtree.path) else {
            throw XCTSkip("iqtree3 is not installed at \(iqtree.path)")
        }
        // Spaces in the headers prove the tip map, since IQ-TREE would rewrite them.
        let fasta = try String(contentsOf: sarcopterygianAlignment(), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(">") ? $0.replacingOccurrences(of: "_", with: " ") : String($0) }
            .joined(separator: "\n")
        let project = try IQTreeTestProject.make(fasta: fasta)
        defer { project.remove() }

        try await project.run(
            ["--seed", "12345", "--threads", "1", "--bootstrap", "1000", "--alrt", "1000"],
            iqtreePath: iqtree.path
        )

        let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
        XCTAssertEqual(tree.manifest.supportLabels, ["SH-aLRT", "UFBoot"])
        XCTAssertEqual(tree.manifest.branchLengthUnit, "substitutions per site")
        let inference = try XCTUnwrap(tree.manifest.inference)
        XCTAssertNotNil(inference.bestFitModel)
        XCTAssertEqual(inference.modelSelectionCriterion, "BIC")
        XCTAssertEqual(inference.seed, 12345)
        XCTAssertEqual(inference.threads, 1)
        let msa = try MultipleSequenceAlignmentBundle.load(from: project.msaBundleURL)
        let displayNames = Set(msa.rows.map(\.displayName))
        XCTAssertTrue(displayNames.contains("Zebrafish outgroup"), "\(displayNames)")
        XCTAssertEqual(Set(tree.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel)), displayNames)
        let supported = tree.normalizedTree.nodes.filter { $0.supportValues.isEmpty == false }
        XCTAssertFalse(supported.isEmpty)
        XCTAssertTrue(supported.allSatisfy { $0.supportValues.map(\.label) == ["SH-aLRT", "UFBoot"] })
    }

    // MARK: Helpers

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phylogenetics/known-sarcopterygian/\(name)")
    }

    private func sarcopterygianAlignment() -> URL { fixture("alignment.fasta") }

    private func sarcopterygianReport() -> URL { fixture("run.iqtree") }

    private func node(over tips: Set<String>, in tree: PhylogeneticTreeBundle) -> PhylogeneticTreeNormalizedNode? {
        tree.normalizedTree.nodes.first { $0.isTip == false && tipLabels(under: $0.id, in: tree) == tips }
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
}
