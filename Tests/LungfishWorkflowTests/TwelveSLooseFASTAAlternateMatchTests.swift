import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

/// Alternate species from the `also_matches=` header field of a loose 12S
/// reference FASTA, without a `.lungfish12sref` metadata table.
final class TwelveSLooseFASTAAlternateMatchTests: XCTestCase {
    func testReferenceIndexParsesAlsoMatchesIntoAlternateMatches() throws {
        let index = try TwelveSReferenceIndex.parse("""
        >rhesus macaque (Macaca mulatta)|locus=12S|len=8|n_refs=2|n_species=2|also_matches=Japanese macaque (Macaca fuscata), Macaca cyclopis|primer_pairs=12S_vert
        ACGTACGT
        >dog (Canis lupus familiaris)|locus=12S|len=8|also_matches=
        GGGGCCCC
        """)
        let macaque = try XCTUnwrap(index.records.first)
        XCTAssertEqual(macaque.alternateMatches.map(\.displayName), ["Japanese macaque (Macaca fuscata)", "Macaca cyclopis"])
        XCTAssertEqual(macaque.alternateMatches.map(\.scientificName), ["Macaca fuscata", nil])
        XCTAssertEqual(macaque.alternateMatches.map(\.commonName), ["Japanese macaque", "Macaca cyclopis"])
        XCTAssertEqual(macaque.alternateMatches.map(\.reason), ["shared_exact_amplicon", "shared_exact_amplicon"])
        XCTAssertEqual(macaque.target.alternateMatches.count, 2)
        XCTAssertEqual(index.records[1].alternateMatches, [])
    }

    /// `target-alternate-matches.tsv` used to be header-only for a loose FASTA
    /// reference because only the metadata table filled `alternateMatches`.
    func testWorkflowWritesAlternateMatchesTableForLooseFASTAReference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSLooseFASTAAlternateMatchTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        let fastqURL = root.appendingPathComponent("sampleA.fastq")
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)

        try """
        >rhesus macaque (Macaca mulatta)|locus=12S|len=8|n_refs=2|n_species=2|also_matches=Japanese macaque (Macaca fuscata)|n_primer_pairs=1|primer_pairs=12S_vert
        ACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII
        """.write(to: fastqURL, atomically: true, encoding: .utf8)

        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: "sampleA-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                runChimeraReview: false
            )
        )

        let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
        let target = try XCTUnwrap(loaded.targets.first)
        XCTAssertEqual(target.alternateMatches.map(\.displayName), ["Japanese macaque (Macaca fuscata)"])
        XCTAssertEqual(target.alternateMatches.first?.scientificName, "Macaca fuscata")
        XCTAssertEqual(target.alternateMatches.first?.reason, "shared_exact_amplicon")

        let tableURL = try XCTUnwrap(loaded.artifacts.alternateMatchesTableURL)
        let lines = try String(contentsOf: tableURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "header plus one alternate row: \(lines)")
        let fields = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields[0], target.targetID)
        XCTAssertEqual(fields[1], "Japanese macaque (Macaca fuscata)")
        XCTAssertEqual(fields[2], "Macaca fuscata")
        XCTAssertEqual(fields[3], "Japanese macaque")
        XCTAssertEqual(fields.last, "shared_exact_amplicon")
        XCTAssertEqual(loaded.scientificNameRows.first?.potentialMatches, ["Japanese macaque (Macaca fuscata)"])
    }
}
