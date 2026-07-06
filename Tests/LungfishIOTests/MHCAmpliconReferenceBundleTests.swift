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

    func testReferenceFASTAURLRejectsTraversalPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">outside\nACGT\n".write(to: root.appendingPathComponent("outside.fa"), atomically: true, encoding: .utf8)

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "../outside.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertNil(MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL))
        XCTAssertThrowsError(try MHCAmpliconReferenceBundle.validate(at: bundleURL))
    }

    func testValidateRejectsUnsupportedSchemaVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">M1\nACGT\n".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)

        let manifest = MHCAmpliconReferenceBundleManifest(
            schemaVersion: 2,
            name: "MCM MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertThrowsError(try MHCAmpliconReferenceBundle.validate(at: bundleURL)) { error in
            XCTAssertEqual(
                (error as? ReferenceBundleValidationError)?.kind,
                .schemaMismatch(expected: 1, found: 2)
            )
        }
    }

    func testHaplotypeDefinitionURLsRejectTraversalPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCAmpliconReferenceBundleTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">M1\nACGT\n".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let outsideDefinition = Self.definition(id: "outside")
        let encoder = JSONEncoder()
        try encoder.encode(outsideDefinition).write(to: root.appendingPathComponent("outside.json"))

        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: ["../outside.json"],
            defaultHaplotypeDefinitionID: outsideDefinition.id,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
            provenancePath: ".lungfish-provenance.json",
            createdAt: "2026-05-30T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertTrue(MHCAmpliconReferenceBundle.haplotypeDefinitionURLs(in: bundleURL).isEmpty)
        XCTAssertThrowsError(try MHCAmpliconReferenceBundle.haplotypeDefinitions(in: bundleURL))
        XCTAssertThrowsError(try MHCAmpliconReferenceBundle.validate(at: bundleURL))
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
