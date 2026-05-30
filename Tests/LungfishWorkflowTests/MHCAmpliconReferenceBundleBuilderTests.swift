import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class MHCAmpliconReferenceBundleBuilderTests: XCTestCase {
    func testBuildsMHCReferenceBundleWithEmbeddedHaplotypeDefinitionAndProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleBuilderTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("MCM_MHC.fa")
        let definitionURL = root.appendingPathComponent("mcm-mhc.lungfishhaplotypedef.json")
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try ">M1\nACGT\n>M2\nTTTT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let definition = Self.definition(id: "mcm-mhc")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: definitionURL)

        let result = try await MHCAmpliconReferenceBundleBuilder().build(
            MHCAmpliconReferenceBundleBuildConfiguration(
                referenceFASTA: fastaURL,
                haplotypeDefinitionURLs: [definitionURL],
                outputURL: bundleURL,
                name: "MCM MHC",
                defaultHaplotypeDefinitionID: definition.id,
                forceOverwrite: true,
                argv: [
                    "lungfish-cli", "fastq", "mhc-reference-bundle",
                    "--reference-fasta", fastaURL.path,
                    "--haplotype-definition", definitionURL.path,
                    "--output", bundleURL.path,
                    "--default-haplotype-definition", definition.id,
                    "--force",
                ]
            )
        )

        XCTAssertEqual(result.bundleURL, bundleURL.standardizedFileURL)
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(manifest.name, "MCM MHC")
        XCTAssertEqual(manifest.metrics.referenceCount, 2)
        XCTAssertEqual(manifest.metrics.haplotypeDefinitionCount, 1)
        XCTAssertEqual(manifest.defaultHaplotypeDefinitionID, definition.id)
        XCTAssertEqual(try MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: bundleURL)?.id, definition.id)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish fastq mhc-reference-bundle")
        XCTAssertTrue(provenance.files.contains { $0.path == fastaURL.path })
        XCTAssertTrue(provenance.files.contains { $0.path == definitionURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == bundleURL.path })
        XCTAssertEqual(provenance.steps.count, 1)
        XCTAssertEqual(provenance.steps.first?.exitStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }

    private static func definition(id: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM MHC",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "MHC",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1", diagnosticAlleles: ["M1"])
                    ]
                )
            ]
        )
    }
}
