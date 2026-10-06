import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

/// Fix lane F2 (review m2, m8, m9, m11, m13): the CLI applies the shared IQ-TREE option rules.
final class TreeInferIQTreeOptionRulesTests: XCTestCase {
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

    // MARK: m2 long aliases

    func testLongAliasesThatIQTreeAcceptsAreRejected() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let cases: [(String, String)] = [
            ("--msa other.fa", "input bundle"),
            ("--aln other.fa", "input bundle"),
            ("--model GTR", "--model"),
            ("--modelomatic", "--model"),
            ("--threads 4", "--threads"),
        ]
        for (text, curated) in cases {
            let message = await project.failure(["--extra-args", text])
            let flag = String(text.split(separator: " ")[0])
            XCTAssertTrue(message.contains("must not set \(flag)."), message)
            XCTAssertTrue(message.contains(curated), message)
        }
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    func testExtraArgsHelpListsTheLongAliases() {
        let help = TreeCommand.InferIQTreeSubcommand.helpMessage()
        for flag in ["--msa", "--aln", "--model", "--modelomatic", "--threads"] {
            XCTAssertTrue(help.contains(flag), flag)
        }
    }

    // MARK: m8 standard and local bootstrap

    func testStandardBootstrapRecordsNoSupportLabelsAndWarns() async throws {
        for extra in ["-b 100", "--boot 100", "--lbp 1000", "-lbp 1000"] {
            let project = try IQTreeTestProject.make(fasta: fiveRowFASTA)
            defer { project.remove() }
            try project.setFakeTree(supportTree)
            try await project.run(["--bootstrap", "1000", "--alrt", "1000", "--extra-args", extra])

            let tree = try PhylogeneticTreeBundle.load(from: project.outputURL())
            XCTAssertNil(tree.manifest.supportLabels, extra)
            let warnings = try XCTUnwrap(try project.provenance()["warnings"] as? [String], extra)
            XCTAssertEqual(warnings.filter { $0 == IQTreeOptionRules.unorderedSupportWarning }.count, 1, extra)
            let options = try XCTUnwrap(try project.provenance()["options"] as? [String: String], extra)
            XCTAssertNil(options["supportLabels"], extra)
        }
    }

    // MARK: m9 codon reading frame

    func testCodonColumnsMustKeepTheReadingFrame() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let shifted = await project.failure(["--sequence-type", "CODON", "--columns", "2-10"])
        XCTAssertTrue(shifted.contains(IQTreeOptionRules.codonFrameMessage(columnRanges: [2...10]) ?? "unset"), shifted)
        let split = await project.failure(["--sequence-type", "CODON", "--columns", "1-4,5-9"])
        XCTAssertTrue(split.contains("but 1-4 does not"), split)
        XCTAssertFalse(project.iqtreeWasInvoked)
        try await project.run(["--sequence-type", "CODON", "--columns", "4-9,1-3"])
    }

    func testCodonWholeAlignmentCountsAsOneRangeFromColumnOne() async throws {
        let elevenColumns = try IQTreeTestProject.make(fasta: ">A\nACGTACGTACG\n>B\nACGTACGTACA\n>C\nACGAACGTACG\n>D\nTCGTACGTACG\n")
        defer { elevenColumns.remove() }
        let message = await elevenColumns.failure(["--sequence-type", "CODON"])
        XCTAssertTrue(message.contains("but 1-11 does not"), message)

        let twelveColumns = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { twelveColumns.remove() }
        try await twelveColumns.run(["--sequence-type", "CODON"])
    }

    // MARK: m11 seed range

    func testSeedOutsideIQTreeRangeIsRejected() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        for arguments in [["--seed", "0"], ["--seed=-1"], ["--seed", "2147483648"]] {
            let message = await project.failure(arguments)
            XCTAssertTrue(message.contains("--seed must be 1 to 2147483647"), "\(arguments): \(message)")
        }
        XCTAssertFalse(project.iqtreeWasInvoked)
        try await project.run(["--seed", "2147483647"])
    }
}
