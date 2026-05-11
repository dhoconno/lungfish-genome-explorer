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
        let fixtureProvenanceData = try Data(contentsOf: fixtureProvenanceURL)
        let fixtureProvenance = String(data: fixtureProvenanceData, encoding: .utf8)?
            .replacingOccurrences(of: "\\/", with: "/")
        let fixtureProvenanceJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureProvenanceData) as? [String: Any]
        )
        XCTAssertEqual(fixtureProvenanceJSON["workflowName"] as? String, "sars-cov-2-alignment-e2e-fixture-generation")
        let fixtureToolName = try XCTUnwrap(fixtureProvenanceJSON["toolName"] as? String)
        XCTAssertTrue(fixtureToolName.contains("create_sarscov2_alignment_fixture.py"))
        XCTAssertTrue(fixtureToolName.contains("lungfish align mafft"))
        let fixtureCommand = try XCTUnwrap(fixtureProvenanceJSON["reproducibleCommand"] as? String)
        XCTAssertTrue(fixtureCommand.contains("create_sarscov2_alignment_fixture.py"))
        XCTAssertTrue(fixtureCommand.contains("lungfish align mafft"))
        let workflowSteps = try XCTUnwrap(fixtureProvenanceJSON["workflowSteps"] as? [[String: Any]])
        let workflowStepTools = workflowSteps.compactMap { $0["toolName"] as? String }
        XCTAssertTrue(workflowStepTools.contains("create_sarscov2_alignment_fixture.py"))
        XCTAssertTrue(workflowStepTools.contains("lungfish align mafft"))
        XCTAssertTrue(try XCTUnwrap(fixtureProvenance).contains("Inputs/sars-cov-2-genomes.fasta"))
        XCTAssertFalse(try XCTUnwrap(fixtureProvenance).contains(#""/tmp/"#))
        XCTAssertFalse(try XCTUnwrap(fixtureProvenance).contains("/private/tmp/"))
        XCTAssertFalse(try XCTUnwrap(fixtureProvenance).contains("/var/folders/"))

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
        let provenanceData = try Data(contentsOf: provenanceURL)
        let provenance = String(data: provenanceData, encoding: .utf8)?
            .replacingOccurrences(of: "\\/", with: "/")
        let provenanceJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: provenanceData) as? [String: Any]
        )
        XCTAssertEqual(provenanceJSON["workflowName"] as? String, "multiple-sequence-alignment-mafft")
        XCTAssertEqual(provenanceJSON["toolName"] as? String, "lungfish align mafft")
        let externalInvocations = try XCTUnwrap(provenanceJSON["externalToolInvocations"] as? [[String: Any]])
        XCTAssertEqual(externalInvocations.first?["name"] as? String, "mafft")
        XCTAssertTrue(try XCTUnwrap(provenance).contains("Inputs/sars-cov-2-genomes.fasta"))
        XCTAssertTrue(try XCTUnwrap(provenance).contains("alignment/input.unaligned.fasta"))
        XCTAssertTrue(try XCTUnwrap(provenance).contains("alignment/primary.aligned.fasta"))
        XCTAssertTrue(try XCTUnwrap(provenance).contains("Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa"))
        XCTAssertFalse(try XCTUnwrap(provenance).contains(#""/tmp/"#))
        XCTAssertFalse(try XCTUnwrap(provenance).contains("/.tmp/"))
        XCTAssertFalse(try XCTUnwrap(provenance).contains("/private/tmp/"))
        XCTAssertFalse(try XCTUnwrap(provenance).contains("/var/folders/"))
    }
}
