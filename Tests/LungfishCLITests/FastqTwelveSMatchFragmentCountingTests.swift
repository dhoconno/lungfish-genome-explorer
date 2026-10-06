import Foundation
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow
import XCTest

/// `lungfish-cli fastq 12s-match` counts fragments the way the app's run
/// does, through the one workflow (Phase 2.1 lane L4, CLI parity).
final class FastqTwelveSMatchFragmentCountingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqTwelveSMatchFragmentCountingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func record(_ name: String, _ sequence: String) -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    /// The fixture of the workflow tests: four merged reads (two human, one
    /// dog, one unmatched) and four pairs (one human on both mates, one human
    /// beside dog, one human beside nothing, one unmatched on both mates).
    private func writeMergeDerivative() throws -> URL {
        let bundle = root.appendingPathComponent("SampleA.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try (Self.record("m1", "TTACCTTGACGG") + Self.record("m2", "TTACCTTGACGG")
            + Self.record("m3", "TTGGGACCCTGG") + Self.record("m4", "TTAAAAAAAAGG"))
            .write(to: bundle.appendingPathComponent("merged.fastq"), atomically: true, encoding: .utf8)
        try (Self.record("p1", "CCACCTTGACAA") + Self.record("p2", "CCACCTTGACAA")
            + Self.record("p3", "CCACCTTGACAA") + Self.record("p4", "CCAAAAAAAACC"))
            .write(to: bundle.appendingPathComponent("unmerged_R1.fastq"), atomically: true, encoding: .utf8)
        try (Self.record("p1", "AAGTCAAGGTCC") + Self.record("p2", "AAAGGGTCCCCC")
            + Self.record("p3", "CCTTTTTTTTAA") + Self.record("p4", "GGTTTTTTTTGG"))
            .write(to: bundle.appendingPathComponent("unmerged_R2.fastq"), atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 4),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 4),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 4),
        ])
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "SampleA",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "reads.fastq",
                payload: .fullMixed(classification),
                lineage: [FASTQDerivativeOperation(kind: .pairedEndMerge)],
                operation: FASTQDerivativeOperation(kind: .pairedEndMerge),
                cachedStatistics: .placeholder(readCount: 12, baseCount: 144),
                pairingMode: .pairedEnd,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    func testCommandCountsEachFragmentOnceAndRecordsItsOwnArgv() async throws {
        let bundle = try writeMergeDerivative()
        let reference = root.appendingPathComponent("reference.fa")
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACCTTGAC
        >dog (Canis lupus familiaris)|locus=12S|len=8
        GGGACCCT

        """.write(to: reference, atomically: true, encoding: .utf8)
        let outputDirectory = root.appendingPathComponent("results", isDirectory: true)
        let arguments = [
            bundle.path,
            "--reference", reference.path,
            "--output-dir", outputDirectory.path,
            "--output-name", "cli-12s",
            "--min-soft-clip", "2",
            "--max-indels", "2",
            "--matching-mode", "illumina-exact",
            "--threads", "1",
            "--no-chimera-review",
        ]

        let command = try FastqTwelveSMatchSubcommand.parse(arguments)
        try await command.run()

        let bundleURL = outputDirectory.appendingPathComponent("cli-12s.lungfish12s", isDirectory: true)
        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL)
        let sample = try XCTUnwrap(loaded.samples.first { $0.sampleID == "SampleA" })
        XCTAssertEqual(sample.inputReads, 8)
        XCTAssertEqual(sample.exactMatchReads, 4)
        XCTAssertEqual(sample.unresolvedReads, 2)
        XCTAssertEqual(sample.discordantPairs, 2)
        XCTAssertEqual(loaded.scientificNameRows.first { $0.scientificName == "Homo sapiens" }?.count(forSample: "SampleA"), 3)
        XCTAssertEqual(loaded.scientificNameRows.first { $0.scientificName == "Canis lupus familiaris" }?.count(forSample: "SampleA"), 1)
        XCTAssertEqual(loaded.readFate.discordantPairs, 2)
        XCTAssertEqual(loaded.readFate.discordantPairsByReason, ["different_targets": 1, "one_mate_unresolved": 1])

        let samplesTable = try String(contentsOf: loaded.artifacts.sampleTableURL, encoding: .utf8)
        XCTAssertTrue(samplesTable.hasPrefix("sample\tsample_name\tsample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent\treassigned_reads\tdiscordant_pairs\n"))
        XCTAssertTrue(samplesTable.hasSuffix("\t0\t2\n"), samplesTable)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(provenance.argv, ["lungfish-cli", "fastq", "12s-match"] + arguments)
        XCTAssertEqual(provenance.options.explicit["ambiguityResolution"], .string("strict"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path), ["cli-12s.lungfish12s"])
    }
}
