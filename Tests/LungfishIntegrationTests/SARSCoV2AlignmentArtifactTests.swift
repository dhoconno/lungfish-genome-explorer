import LungfishIO
import XCTest

final class SARSCoV2AlignmentArtifactTests: XCTestCase {
    func testSARSCoV2AlignmentArtifactContainsUnalignedInputAndNativeMAFFTBundle() throws {
        let projectURL = TestFixtures.sarscov2Alignment.project
        let inputURL = TestFixtures.sarscov2Alignment.unalignedGenomes
        let metadataURL = TestFixtures.sarscov2Alignment.sourceMetadata
        let mafftBundleURL = TestFixtures.sarscov2Alignment.mafftBundle

        let inputText = try String(contentsOf: inputURL, encoding: .utf8)
        let recordCount = inputText.components(separatedBy: .newlines)
            .filter { $0.hasPrefix(">") }
            .count
        XCTAssertEqual(recordCount, 5)
        XCTAssertTrue(inputText.contains(">sarscov2_fixture_A_source"))
        XCTAssertTrue(inputText.contains(">sarscov2_fixture_E_mixed_variation"))

        let metadataText = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertTrue(metadataText.contains("sample_id\tsource_accession"))
        XCTAssertTrue(metadataText.contains("deterministic synthetic derivative"))

        let fixtureProvenanceURL = projectURL.appendingPathComponent(".lungfish-provenance.json")
        let fixtureProvenance = try String(contentsOf: fixtureProvenanceURL, encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(fixtureProvenance.contains(#""workflowName": "sars-cov-2-alignment-fixture-generation""#))
        XCTAssertTrue(fixtureProvenance.contains(#""toolName": "create_sarscov2_alignment_fixture.py""#))
        XCTAssertTrue(fixtureProvenance.contains("Inputs/sars-cov-2-genomes.fasta"))
        XCTAssertFalse(fixtureProvenance.contains(#""/tmp/"#))
        XCTAssertFalse(fixtureProvenance.contains("/private/tmp/"))
        XCTAssertFalse(fixtureProvenance.contains("/var/folders/"))

        let bundle = try MultipleSequenceAlignmentBundle.load(from: mafftBundleURL)
        XCTAssertEqual(bundle.manifest.bundleKind, "multiple-sequence-alignment")
        XCTAssertEqual(bundle.manifest.name, "sars-cov-2-genomes-mafft")
        XCTAssertEqual(bundle.manifest.rowCount, 5)
        XCTAssertEqual(bundle.rows.count, 5)
        XCTAssertGreaterThanOrEqual(bundle.manifest.alignedLength, 29_829)
        XCTAssertGreaterThan(bundle.manifest.variableSiteCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: mafftBundleURL.appendingPathComponent("alignment/primary.aligned.fasta").path
            )
        )

        let provenanceURL = mafftBundleURL.appendingPathComponent(".lungfish-provenance.json")
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(provenance.contains(#""workflowName" : "multiple-sequence-alignment-mafft""#))
        XCTAssertTrue(provenance.contains(#""toolName" : "lungfish align mafft""#))
        XCTAssertTrue(provenance.contains(#""name" : "mafft""#))
        XCTAssertTrue(provenance.contains("Inputs/sars-cov-2-genomes.fasta"))
        XCTAssertTrue(provenance.contains("alignment/input.unaligned.fasta"))
        XCTAssertTrue(provenance.contains("alignment/primary.aligned.fasta"))
        XCTAssertTrue(provenance.contains("Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa"))
        XCTAssertFalse(provenance.contains(#""/tmp/"#))
        XCTAssertFalse(provenance.contains("/.tmp/"))
        XCTAssertFalse(provenance.contains("/private/tmp/"))
        XCTAssertFalse(provenance.contains("/var/folders/"))
    }
}
