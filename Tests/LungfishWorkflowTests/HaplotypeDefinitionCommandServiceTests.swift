import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class HaplotypeDefinitionCommandServiceTests: XCTestCase {
    func testImportDefinitionWritesProjectDefinitionAndCLIProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.lungfishhaplotypedef.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeDefinition(makeDefinition(id: "custom.mcm", displayName: "Custom MCM"), to: sourceURL)

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot)
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
        let exportURL = root.appendingPathComponent("exported.lungfishhaplotypedef.json")
        let definition = makeDefinition(id: "custom.export", displayName: "Export Me")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot)
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
            projectRoot: root.appendingPathComponent("project.lungfish", isDirectory: true)
        )

        XCTAssertThrowsError(
            try service.importDefinition(from: sourceURL, scope: .project, argv: ["lungfish", "haplotypes", "import"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("diagnostic allele"))
        }
    }

    func testSaveDefinitionInMHCReferenceBundleUpdatesEmbeddedDefinitionAndCanonicalProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let bundleURL = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let original = makeDefinition(id: "custom.bundle", displayName: "Original Bundle Definition")
        try writeMHCReferenceBundle(
            bundleURL: bundleURL,
            referenceContents: ">M1\nACGT\n",
            definition: original
        )
        let edited = GenotypeHaplotypeDefinitionSet(
            id: original.id,
            assayID: original.assayID,
            displayName: "Edited Bundle Definition",
            speciesName: original.speciesName,
            speciesCode: original.speciesCode,
            prefix: original.prefix,
            locusDefinitions: original.locusDefinitions
        )

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot)
        let result = try service.saveDefinition(
            edited,
            inMHCReferenceBundle: bundleURL,
            changeNote: "Edited in Haplotype Definition Manager",
            argv: ["lungfish-gui", "haplotypes", "bundle-save", bundleURL.path, original.id]
        )

        XCTAssertEqual(result.definitionSet.id, original.id)
        XCTAssertEqual(result.definitionURL.lastPathComponent, "custom.bundle.lungfishhaplotypedef.json")
        let stored = try XCTUnwrap(
            MHCAmpliconReferenceBundle.haplotypeDefinition(id: original.id, in: bundleURL)
        )
        XCTAssertEqual(stored.displayName, "Edited Bundle Definition")
        XCTAssertEqual(stored.schemaVersion, 1)
        XCTAssertEqual(stored.changeNote, "Edited in Haplotype Definition Manager")

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(provenance.workflowName, "Haplotype definition edit in MHC reference bundle")
        XCTAssertTrue(provenance.files.contains { $0.path == bundleURL.appendingPathComponent("reference.fa").path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == result.definitionURL.path })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                .path
        ))
    }

    func testReplaceReferenceFASTAInMHCReferenceBundleUpdatesManifestMetricsAndProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let bundleURL = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let definition = makeDefinition(id: "custom.bundle", displayName: "Bundle Definition")
        try writeMHCReferenceBundle(
            bundleURL: bundleURL,
            referenceContents: ">M1\nACGT\n",
            definition: definition
        )
        let replacementURL = root.appendingPathComponent("replacement.fa")
        try ">M1\nACGT\n>M2\nTTTT\n".write(to: replacementURL, atomically: true, encoding: .utf8)

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot)
        let storedReferenceURL = try service.replaceReferenceFASTA(
            inMHCReferenceBundle: bundleURL,
            with: replacementURL,
            argv: ["lungfish-gui", "haplotypes", "bundle-replace-reference", bundleURL.path, replacementURL.path]
        )

        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: bundleURL)
        XCTAssertEqual(manifest.metrics.referenceCount, 2)
        XCTAssertEqual(manifest.metrics.haplotypeDefinitionCount, 1)
        XCTAssertEqual(storedReferenceURL.lastPathComponent, "reference.fa")
        XCTAssertEqual(
            try String(contentsOf: storedReferenceURL, encoding: .utf8),
            ">M1\nACGT\n>M2\nTTTT\n"
        )

        let provenanceURL = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(provenance.workflowName, "MHC reference bundle FASTA replacement")
        XCTAssertTrue(provenance.files.contains { $0.path == replacementURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == storedReferenceURL.path })
    }

    func testCreateMHCReferenceBundleFromProjectDefinitionEmbedsReferenceDefinitionAndProvenance() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let referenceURL = root.appendingPathComponent("reference.fa")
        try ">Mafa-B*001\nACGT\n>Mafa-B*002\nTTTT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        let outputURL = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("MCM-MHC.lungfishmhcref", isDirectory: true)
        let definitionID = "custom.mcm-bundle"
        let definition = makeDefinition(id: definitionID, displayName: "Project MCM")
        let bundleSourceURL = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("MCM-source.lungfishmhcref", isDirectory: true)
        try writeMHCReferenceBundle(
            bundleURL: bundleSourceURL,
            referenceContents: ">Mafa-B*001\nACGT\n",
            definition: definition
        )

        let service = HaplotypeDefinitionCommandService(projectRoot: projectRoot)
        let result = try await service.createMHCReferenceBundle(
            definitionIDs: [definitionID],
            assayID: "MHC-exon2-miSeq",
            speciesCode: "MCM",
            scope: .project,
            referenceFASTA: referenceURL,
            outputURL: outputURL,
            name: "MCM Explicit MHC",
            defaultDefinitionID: definitionID,
            forceOverwrite: false,
            argv: [
                "lungfish-cli", "haplotypes", "bundle-create",
                "--definition", definitionID,
                "--scope", "project",
                "--reference-fasta", referenceURL.path,
                "--output", outputURL.path,
            ]
        )

        XCTAssertEqual(result.bundleURL, outputURL.standardizedFileURL)
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: outputURL)
        XCTAssertEqual(manifest.name, "MCM Explicit MHC")
        XCTAssertEqual(manifest.defaultHaplotypeDefinitionID, definitionID)
        XCTAssertEqual(manifest.metrics.referenceCount, 2)
        XCTAssertEqual(manifest.metrics.haplotypeDefinitionCount, 1)
        XCTAssertEqual(try MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: outputURL)?.id, definitionID)
        XCTAssertEqual(MHCAmpliconReferenceBundle.referenceFASTAURL(in: outputURL)?.lastPathComponent, "reference.fa")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(provenance.workflowName, "lungfish haplotypes bundle-create")
        XCTAssertTrue(provenance.files.contains { $0.path == referenceURL.path })
        XCTAssertTrue(provenance.outputs.contains { $0.path == outputURL.path })
        let definitionSources = try XCTUnwrap(provenance.options.explicit["haplotypeDefinitionSources"]?.arrayValue)
        XCTAssertTrue(definitionSources.contains { value in
            guard let fields = value.dictionaryValue else { return false }
            return fields["definitionID"] == .string(definitionID)
                && fields["scope"] == .string(HaplotypeDefinitionScope.project.rawValue)
        })
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
                provenancePath: ProvenanceWriter.provenanceFilename,
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: bundleURL
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaplotypeDefinitionCommandService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
