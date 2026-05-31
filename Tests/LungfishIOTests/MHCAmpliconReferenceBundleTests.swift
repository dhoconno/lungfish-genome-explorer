import Foundation
import XCTest
@testable import LungfishIO

final class MHCAmpliconReferenceBundleTests: XCTestCase {
    func testWritesManifestAndResolvesReferenceAndHaplotypeDefinitions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let haplotypeURL = bundleURL.appendingPathComponent("haplotypes/mcm.json")
        try FileManager.default.createDirectory(at: haplotypeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">M1\nACGT\n".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let definition = Self.definition(id: "mcm-mhc")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: haplotypeURL)
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: ["haplotypes/mcm.json"],
            defaultHaplotypeDefinitionID: definition.id,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )

        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.kind, "mhc-reference")
        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(bundleURL))
        XCTAssertTrue(MHCAmpliconReferenceBundle.hasBundleExtension(bundleURL))
        XCTAssertNoThrow(try MHCAmpliconReferenceBundle.validate(at: bundleURL))
        XCTAssertEqual(MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL)?.lastPathComponent, "reference.fa")
        XCTAssertEqual(try MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: bundleURL)?.id, definition.id)
        XCTAssertEqual(
            try MHCAmpliconReferenceBundle.haplotypeDefinition(
                id: definition.id,
                assayID: definition.assayID,
                speciesCode: definition.speciesCode,
                in: bundleURL
            )?.displayName,
            definition.displayName
        )
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
