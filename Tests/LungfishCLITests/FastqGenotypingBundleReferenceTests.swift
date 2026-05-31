import Foundation
import XCTest
import LungfishIO
@testable import LungfishCLI

final class FastqGenotypingBundleReferenceTests: XCTestCase {
    func testReferenceHelpMentionsLungfishMHCRef() {
        XCTAssertTrue(FastqGenotypingSubcommand.referenceHelp.contains(".lungfishmhcref"))
    }

    func testExplicitHaplotypeDefinitionMustExistInBundle() throws {
        let bundleURL = try makeBundle(
            definitions: [Self.definition(id: "D1"), Self.definition(id: "D2")],
            defaultID: "D1"
        )

        XCTAssertThrowsError(
            try FastqGenotypingSubcommand.resolveBundleHaplotypeDefinition(
                referenceURL: bundleURL,
                explicitID: "D3"
            )
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("D3"), "Error should name the missing id: \(message)")
            XCTAssertTrue(message.contains("D1"), "Error should list available id D1: \(message)")
            XCTAssertTrue(message.contains("D2"), "Error should list available id D2: \(message)")
        }
    }

    func testExplicitHaplotypeDefinitionResolvesNonDefaultInBundle() throws {
        let bundleURL = try makeBundle(
            definitions: [Self.definition(id: "D1"), Self.definition(id: "D2")],
            defaultID: "D1"
        )

        let resolved = try FastqGenotypingSubcommand.resolveBundleHaplotypeDefinition(
            referenceURL: bundleURL,
            explicitID: "D2"
        )
        XCTAssertEqual(resolved?.id, "D2")
    }

    func testNilExplicitHaplotypeDefinitionResolvesBundleDefault() throws {
        let bundleURL = try makeBundle(
            definitions: [Self.definition(id: "D1"), Self.definition(id: "D2")],
            defaultID: "D1"
        )

        let resolved = try FastqGenotypingSubcommand.resolveBundleHaplotypeDefinition(
            referenceURL: bundleURL,
            explicitID: nil
        )
        XCTAssertEqual(resolved?.id, "D1")
    }

    func testNonBundleReferenceResolvesToNil() throws {
        let root = try temporaryDirectory()
        let fastaURL = root.appendingPathComponent("plain.fa")
        try ">M1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let resolved = try FastqGenotypingSubcommand.resolveBundleHaplotypeDefinition(
            referenceURL: fastaURL,
            explicitID: "D1"
        )
        XCTAssertNil(resolved)
    }

    private func makeBundle(
        definitions: [GenotypeHaplotypeDefinitionSet],
        defaultID: String?
    ) throws -> URL {
        let root = try temporaryDirectory()
        let bundleURL = root.appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let haplotypesDir = bundleURL.appendingPathComponent("haplotypes", isDirectory: true)
        try FileManager.default.createDirectory(at: haplotypesDir, withIntermediateDirectories: true)
        try ">M1\nACGT\n".write(to: bundleURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var relativePaths: [String] = []
        for definition in definitions {
            let relativePath = "haplotypes/\(definition.id).json"
            relativePaths.append(relativePath)
            try encoder.encode(definition).write(to: bundleURL.appendingPathComponent(relativePath))
        }
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "MCM MHC",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: relativePaths,
            defaultHaplotypeDefinitionID: defaultID,
            metrics: MHCAmpliconReferenceBundleMetrics(
                referenceCount: 1,
                haplotypeDefinitionCount: definitions.count
            ),
            createdAt: "2026-05-31T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)
        return bundleURL
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqGenotypingBundleReferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func definition(id: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "MHC-exon2-miSeq-\(id)",
            displayName: "Definition \(id)",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM-\(id)",
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
