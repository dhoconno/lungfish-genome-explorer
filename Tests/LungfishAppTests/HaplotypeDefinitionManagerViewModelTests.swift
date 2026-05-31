import LungfishIO
@testable import LungfishApp
import XCTest

@MainActor
final class HaplotypeDefinitionManagerViewModelTests: XCTestCase {
    func testImportBundleInstallsBundleIntoProjectAndSelectsIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let sourceBundleURL = root
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent("Example.lungfishmhcref", isDirectory: true)
        try writeMHCReferenceBundle(
            bundleURL: sourceBundleURL,
            referenceContents: ">M1\nACGT\n",
            definition: makeDefinition(id: "custom.install", displayName: "Installed Definition")
        )

        let viewModel = HaplotypeDefinitionManagerViewModel(projectURL: projectRoot)
        XCTAssertTrue(viewModel.records.isEmpty)

        viewModel.importBundle(at: sourceBundleURL)

        XCTAssertNil(viewModel.errorMessage)
        let installedParent = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .standardizedFileURL
        let installedRecord = try XCTUnwrap(
            viewModel.records.first { $0.definitionSet.id == "custom.install" }
        )
        let bundleURL = try XCTUnwrap(installedRecord.referenceBundleURL)
        XCTAssertEqual(bundleURL.deletingLastPathComponent().standardizedFileURL, installedParent)
        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(bundleURL))
        XCTAssertEqual(viewModel.selectedRecordID, installedRecord.id)
    }

    func testImportBundleRejectsNonBundleWithError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let jsonURL = root.appendingPathComponent("plain.json")
        try writeDefinition(makeDefinition(id: "custom.json", displayName: "Plain JSON"), to: jsonURL)

        let viewModel = HaplotypeDefinitionManagerViewModel(projectURL: projectRoot)
        viewModel.importBundle(at: jsonURL)

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.records.isEmpty)
    }

    private func makeDefinition(id: String, displayName: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "MHC-exon2-miSeq",
            displayName: displayName,
            speciesName: "Mauritian cynomolgus macaques",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: "M2B",
                            diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"]
                        )
                    ]
                )
            ]
        )
    }

    private func writeDefinition(_ definition: GenotypeHaplotypeDefinitionSet, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: url, options: .atomic)
    }

    private func writeMHCReferenceBundle(
        bundleURL: URL,
        referenceContents: String,
        definition: GenotypeHaplotypeDefinitionSet
    ) throws {
        let referenceURL = bundleURL.appendingPathComponent("reference.fa")
        let definitionURL = bundleURL
            .appendingPathComponent("haplotypes", isDirectory: true)
            .appendingPathComponent("\(definition.id).lungfishhaplotypedef.json")
        try FileManager.default.createDirectory(at: definitionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try referenceContents.write(to: referenceURL, atomically: true, encoding: .utf8)
        try writeDefinition(definition, to: definitionURL)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: "MCM MHC",
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: ["haplotypes/\(definition.id).lungfishhaplotypedef.json"],
                defaultHaplotypeDefinitionID: definition.id,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
                provenancePath: ".lungfish-provenance.json",
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: bundleURL
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionManagerViewModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
