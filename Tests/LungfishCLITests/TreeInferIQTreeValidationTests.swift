import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

/// Rulings C2, C5, C6 and C7: options are checked before anything is staged, and the
/// IQ-TREE argv uses the documented 3.x flags.
final class TreeInferIQTreeValidationTests: XCTestCase {
    // MARK: C5 validation before staging

    func testBootstrapBelowOneThousandFailsBeforeStaging() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let message = await project.failure(["--bootstrap", "999"])
        XCTAssertTrue(message.contains("--bootstrap must be 1000 or more"), message)
        XCTAssertFalse(project.iqtreeWasInvoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.projectURL.appendingPathComponent(".tmp").path))
    }

    func testALRTBelowOneFails() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let message = await project.failure(["--alrt", "0"])
        XCTAssertTrue(message.contains("--alrt must be 1 or more"), message)
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    func testFewerThanThreeRowsFails() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let message = await project.failure(["--rows", "A,B"])
        XCTAssertTrue(message.contains("at least 3 sequences"), message)
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    func testThreeRowsWithBranchSupportFails() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let bootstrap = await project.failure(["--rows", "A,B,C", "--bootstrap", "1000"])
        XCTAssertTrue(bootstrap.contains("at least 4 sequences"), bootstrap)
        let alrt = await project.failure(["--rows", "A,B,C", "--alrt", "1000"])
        XCTAssertTrue(alrt.contains("at least 4 sequences"), alrt)
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    func testThreeRowsWithoutSupportRuns() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run(["--rows", "A,B,C"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.outputURL().path))
    }

    func testModelsWithoutTreeSearchAreRejected() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        for model in ["MF", "mf", "TESTONLY", "MFONLY", "TESTNEWONLY", "testmergeonly"] {
            let message = await project.failure(["--model", model])
            XCTAssertTrue(
                message.contains("MF/TESTONLY select a model without a tree search, use MFP or TEST"),
                "\(model): \(message)"
            )
        }
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    func testModelsWithPlusTermsAreAccepted() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run(["--model", "GTR+F"])
        let arguments = try project.recordedIQTreeArguments()
        XCTAssertEqual(arguments.firstIndex(of: "-m").map { arguments[$0 + 1] }, "GTR+F")
    }

    // MARK: C2 and C6 flags

    func testIQTreeArgvUsesDocumentedFlags() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run([
            "--sequence-type", "DNA",
            "--threads", "2",
            "--safe",
            "--keep-identical",
            "--seed", "7",
        ])
        let arguments = try project.recordedIQTreeArguments()
        XCTAssertEqual(value(after: "-T", in: arguments), "2")
        XCTAssertEqual(value(after: "--seqtype", in: arguments), "DNA")
        XCTAssertTrue(arguments.contains("--safe"))
        XCTAssertTrue(arguments.contains("--keep-ident"))
        for legacy in ["-nt", "-st", "-safe", "-keep-ident"] {
            XCTAssertFalse(arguments.contains(legacy), "legacy alias \(legacy) must not be emitted")
        }
    }

    func testOmittedThreadsSendsAutoAndRecordsIt() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run([])
        let arguments = try project.recordedIQTreeArguments()
        XCTAssertEqual(value(after: "-T", in: arguments), "AUTO")
        let options = try XCTUnwrap(try project.provenance()["options"] as? [String: String])
        XCTAssertEqual(options["threads"], "AUTO")
    }

    func testThreadsHelpSaysAutoIsNotReproducible() {
        let help = TreeCommand.InferIQTreeSubcommand.helpMessage()
        XCTAssertTrue(help.contains("AUTO"), help)
        XCTAssertTrue(help.contains("not reproducible"), help)
    }

    func testExtraIQTreeOptionsFoldsIntoExtraArgsAndIsHidden() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run(["--extra-iqtree-options", "-bnni", "--extra-args", "--pathogen"])
        let provenance = try project.provenance()
        let argv = try XCTUnwrap(provenance["argv"] as? [String])
        XCTAssertFalse(argv.contains("--extra-iqtree-options"))
        XCTAssertEqual(value(after: "--extra-args", in: argv), "-bnni --pathogen")
        let arguments = try project.recordedIQTreeArguments()
        XCTAssertTrue(arguments.contains("-bnni"))
        XCTAssertTrue(arguments.contains("--pathogen"))
        XCTAssertFalse(TreeCommand.InferIQTreeSubcommand.helpMessage().contains("--extra-iqtree-options"))
    }

    func testReservedFlagsInExtraArgsAreRejectedNamingTheCuratedOption() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let cases: [(String, String)] = [
            ("-T 8", "--threads"),
            ("-nt 8", "--threads"),
            ("--seed 1", "--seed"),
            ("-m GTR", "--model"),
            ("-s other.fa", "input bundle"),
            ("--prefix x", "--output"),
            ("-B 1000", "--bootstrap"),
            ("--alrt 1000", "--alrt"),
            ("-alrt 1000", "--alrt"),
            ("-o A", "--outgroup"),
            ("-st DNA", "--sequence-type"),
            ("--seqtype DNA", "--sequence-type"),
        ]
        for (extra, curated) in cases {
            let message = await project.failure(["--extra-args", extra])
            XCTAssertTrue(message.contains(curated), "\(extra): \(message)")
            XCTAssertTrue(message.contains(extra.split(separator: " ")[0]), "\(extra): \(message)")
        }
        let alias = await project.failure(["--extra-iqtree-options", "-T 8"])
        XCTAssertTrue(alias.contains("--threads"), alias)
        XCTAssertFalse(project.iqtreeWasInvoked)
    }

    // MARK: C7 sequence types

    func testCodonGeneticCodesFollowIQTree() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        try await project.run(["--sequence-type", "codon2"])
        XCTAssertEqual(value(after: "--seqtype", in: try project.recordedIQTreeArguments()), "CODON2")
        for invalid in ["CODON7", "CODON8", "CODON17", "CODON20", "CODON26", "CODON0"] {
            let message = await project.failure(["--sequence-type", invalid, "--force"])
            XCTAssertTrue(message.contains("Unsupported IQ-TREE sequence type"), "\(invalid): \(message)")
        }
        for valid in ["CODON", "CODON1", "CODON25", "BIN", "MORPH", "NT2AA", "AA"] {
            XCTAssertNoThrow(try TreeCommand.InferIQTreeSubcommand.normalizedSequenceType(valid), valid)
        }
    }

    func testCodonTypeRequiresColumnsInWholeCodons() async throws {
        let project = try IQTreeTestProject.make(fasta: fourRowFASTA)
        defer { project.remove() }
        let message = await project.failure(["--sequence-type", "CODON", "--columns", "1-11"])
        XCTAssertTrue(message.contains("multiple of 3"), message)
        XCTAssertFalse(project.iqtreeWasInvoked)
        try await project.run(["--sequence-type", "CODON", "--columns", "1-9"])
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
