import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class HaplotypeDefinitionCommandServiceTests: XCTestCase {
    func testImportDefinitionWritesProjectDefinitionAndCLIProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let globalRoot = root.appendingPathComponent("global", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.lungfishhaplotypedef.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeDefinition(makeDefinition(id: "custom.mcm", displayName: "Custom MCM"), to: sourceURL)

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot, globalRoot: globalRoot)
        let result = try service.importDefinition(
            from: sourceURL,
            scope: .project,
            changeNote: "imported from notebook export",
            argv: ["lungfish", "haplotypes", "import", sourceURL.path, "--project", projectRoot.path]
        )

        XCTAssertEqual(result.definitionSet.id, "custom.mcm")
        XCTAssertEqual(result.scope, .project)
        XCTAssertFalse(result.definitionURL.lastPathComponent.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.definitionURL.path))

        let provenanceURL = result.definitionURL.appendingPathExtension("provenance.json")
        let provenance = try JSONDecoder().decode(
            HaplotypeDefinitionEditProvenance.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "Haplotype definition import")
        XCTAssertEqual(provenance.toolName, "lungfish-cli")
        XCTAssertEqual(provenance.argv.first, "lungfish")
        XCTAssertEqual(provenance.options.explicit["scope"], "project")
        XCTAssertEqual(provenance.inputs.first?.path, sourceURL.path)
        XCTAssertEqual(provenance.outputs.first?.path, result.definitionURL.path)
    }

    func testExportDefinitionWritesJSONAndProvenanceSidecar() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let globalRoot = root.appendingPathComponent("global", isDirectory: true)
        let exportURL = root.appendingPathComponent("exported.lungfishhaplotypedef.json")
        let definition = makeDefinition(id: "custom.export", displayName: "Export Me")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot, globalRoot: globalRoot)
        try service.exportDefinition(
            definitionID: definition.id,
            assayID: definition.assayID,
            scope: .project,
            to: exportURL,
            argv: ["lungfish", "haplotypes", "export", definition.id, "--output", exportURL.path]
        )

        let exported = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertEqual(exported.id, definition.id)

        let provenance = try JSONDecoder().decode(
            HaplotypeDefinitionEditProvenance.self,
            from: Data(contentsOf: exportURL.appendingPathExtension("provenance.json"))
        )
        XCTAssertEqual(provenance.workflowName, "Haplotype definition export")
        XCTAssertEqual(provenance.options.explicit["definitionID"], definition.id)
        XCTAssertEqual(provenance.inputs.first?.path, HaplotypeDefinitionStore(projectRoot: projectRoot).definitionURL(for: definition.id)?.path)
        XCTAssertEqual(provenance.outputs.first?.path, exportURL.path)
    }

    func testValidationRejectsEmptyDiagnosticHaplotypes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("invalid.lungfishhaplotypedef.json")
        let invalid = GenotypeHaplotypeDefinitionSet(
            id: "invalid",
            assayID: "MHC-exon2-miSeq",
            displayName: "Invalid",
            speciesName: "Mauritian cynomolgus macaques",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [GenotypeHaplotypeDefinition(name: "M2B", diagnosticAlleles: [])]
                )
            ]
        )
        try writeDefinition(invalid, to: sourceURL)

        let service = HaplotypeDefinitionCommandService(
            projectRoot: root.appendingPathComponent("project.lungfish", isDirectory: true),
            globalRoot: root.appendingPathComponent("global", isDirectory: true)
        )

        XCTAssertThrowsError(
            try service.importDefinition(from: sourceURL, scope: .project, argv: ["lungfish", "haplotypes", "import"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("diagnostic allele"))
        }
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionCommandService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
