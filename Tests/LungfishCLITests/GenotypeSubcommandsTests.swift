import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypeSubcommandsTests: XCTestCase {
    func testCLIRegistersGenotypeCommandGroup() {
        let names = LungfishCLI.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("genotype"))
    }

    func testGenotypeGroupRegistersAllSubcommands() {
        let names = GenotypeCommandGroup.configuration.subcommands.map {
            $0.configuration.commandName
        }
        XCTAssertEqual(
            Set(names),
            [
                "list-samples", "list-cohorts", "apply-annotations",
                "export", "export-xlsx", "export-pivot-xlsx", "export-labkey"
            ]
        )
    }

    func testListSamplesParsesBundleOption() throws {
        let command = try GenotypeListSamplesSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
    }

    func testListSamplesRejectsEmptyBundle() {
        XCTAssertThrowsError(
            try GenotypeListSamplesSubcommand.parse(["--bundle", "   "]).validate()
        )
    }

    func testListCohortsParsesBundleOption() throws {
        let command = try GenotypeListCohortsSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
    }

    func testApplyAnnotationsParsesBundleAndPatch() throws {
        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--patch", "/tmp/patch.json",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.patch, "/tmp/patch.json")
    }

    func testApplyAnnotationsRejectsEmptyPatch() {
        XCTAssertThrowsError(
            try GenotypeApplyAnnotationsSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype",
                "--patch", "",
            ]).validate()
        )
    }

    func testApplyAnnotationsWritesAnnotationSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeApplyAnnotationsProvenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
            .encoded()
            .write(to: annotationURL)
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        patch.sampleNotes = [
            GenotypeAnnotationSidecar.SampleNote(
                sample: "DW472",
                body: "manual review",
                author: "analyst",
                timestamp: "2026-05-23T00:01:00Z"
            )
        ]
        let patchURL = root.appendingPathComponent("patch.json")
        try patch.encoded().write(to: patchURL)

        let command = try GenotypeApplyAnnotationsSubcommand.parse([
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])
        try await command.run()

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "lungfish genotype apply-annotations")
        XCTAssertEqual(envelope.argv, [
            "lungfish",
            "genotype",
            "apply-annotations",
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ])
        XCTAssertTrue(envelope.files.contains { file in
            file.path == patchURL.path && file.role == .input && file.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.files.contains { file in
            file.path == annotationURL.path && file.role == .output && file.checksumSHA256 != nil
        })
        XCTAssertEqual(envelope.options.explicit["appendedSampleNotes"], .integer(1))
    }

    func testMergeAppendsNewEntriesAndSkipsDuplicates() throws {
        let now = "2026-05-22T10:00:00Z"
        let later = "2026-05-22T11:00:00Z"

        let existingOverride = GenotypeAnnotationSidecar.CallOverride(
            sample: "H1", locus: "MHC-A", slot: .h1,
            originalCall: "Mafa-A1*063:02_M1A", overrideCall: "Mafa-A1*063:03_M1A",
            reasonTag: .misCall, rationale: "Manual review",
            author: "alice", timestamp: now
        )

        let duplicateOverride = existingOverride
        let newOverride = GenotypeAnnotationSidecar.CallOverride(
            sample: "H2", locus: "MHC-A", slot: .h1,
            originalCall: "Mafa-A1*063:02_M1A", overrideCall: "Mafa-A1*063:03_M1A",
            reasonTag: .misCall, rationale: "Manual review",
            author: "alice", timestamp: later
        )

        let existing = GenotypeAnnotationSidecar(
            schemaVersion: GenotypeAnnotationSidecar.currentSchemaVersion,
            generatedAt: now,
            lastEditedAt: nil, lastEditor: nil,
            callOverrides: [existingOverride], cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [], manualHaplotypeAssignments: [],
            settings: .default, auditLog: []
        )

        let patch = GenotypeAnnotationSidecar(
            schemaVersion: GenotypeAnnotationSidecar.currentSchemaVersion,
            generatedAt: now,
            lastEditedAt: nil, lastEditor: nil,
            callOverrides: [duplicateOverride, newOverride],
            cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [], manualHaplotypeAssignments: [],
            settings: .default, auditLog: []
        )

        let result = GenotypeApplyAnnotationsSubcommand.merge(existing: existing, patch: patch)
        XCTAssertEqual(result.sidecar.callOverrides.count, 2)
        XCTAssertEqual(result.appendedCounts.callOverrides, 1)
        XCTAssertEqual(result.skippedDuplicateCounts.callOverrides, 1)
    }

    // MARK: - export-pivot-xlsx

    func testExportPivotXlsxParsesBundleAndOutput() throws {
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/example.pivot.xlsx",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.output, "/tmp/example.pivot.xlsx")
    }

    func testExportPivotXlsxRejectsEmptyBundleOrOutput() {
        XCTAssertThrowsError(
            try GenotypeExportPivotXlsxSubcommand.parse([
                "--bundle", "", "--output", "/tmp/out.xlsx",
            ]).validate()
        )
        XCTAssertThrowsError(
            try GenotypeExportPivotXlsxSubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype", "--output", "  ",
            ]).validate()
        )
    }

    func testPivotWorkbookBuilderLaysOutSamplesHaplotypesAndAlleleGroups() {
        // Build a small bundle data model directly so the test is hermetic.
        let bundleURL = URL(fileURLWithPath: "/tmp/dummy.lungfishgenotype", isDirectory: true)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "test", analysisName: "TestRun",
            primaryWorkbookPath: "test.xlsx",
            longSummaryCSVPath: "g.csv", sampleSummaryCSVPath: "s.csv",
            statsJSONPath: "stats.json", provenancePath: "prov.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("test.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("g.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("s.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("prov.json")
        )
        let stats = ONTGenotypeRunStats()
        let calls: [ONTGenotypeCall] = [
            ONTGenotypeCall(
                sample: "Animal1", genotype: "01_M1_F_01_w_06",
                passedAlignments: 100, passedUniqueReads: 80,
                sampleTotalReads: 200, sampleUniqueRetainedReads: 150,
                sampleUniqueRetainedPercent: 75.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "Animal1", genotype: "02_M1_G_02_07_2mis_156bp",
                passedAlignments: 50, passedUniqueReads: 40,
                sampleTotalReads: 200, sampleUniqueRetainedReads: 150,
                sampleUniqueRetainedPercent: 75.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "Animal2", genotype: "01_M1_F_01_w_06",
                passedAlignments: 25, passedUniqueReads: 20,
                sampleTotalReads: 100, sampleUniqueRetainedReads: 60,
                sampleUniqueRetainedPercent: 60.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        let samples: [ONTGenotypeSampleResult] = [
            ONTGenotypeSampleResult(
                sample: "Animal1", passedAlignments: 150, passedUniqueReads: 120,
                sampleTotalReads: 200, sampleUniqueRetainedPercent: 75.0,
                calls: calls.filter { $0.sample == "Animal1" }
            ),
            ONTGenotypeSampleResult(
                sample: "Animal2", passedAlignments: 25, passedUniqueReads: 20,
                sampleTotalReads: 100, sampleUniqueRetainedPercent: 60.0,
                calls: calls.filter { $0.sample == "Animal2" }
            ),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "ont-macaque", definitionSetID: "mafa-mhc",
            definitionSetName: "Mafa MHC", speciesName: "Macaca fascicularis",
            samples: [
                GenotypeHaplotypeSampleAnalysis(sample: "Animal1", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "M1A", haplotype2: "M2A",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2, observedGenotypes: []
                    ),
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-B", sourceLocus: "Mafa-B",
                        haplotype1: "ERR: NO HAP", haplotype2: "ERR: NO HAP",
                        status: .noHaplotype, matchedHaplotypes: [],
                        observedGenotypeCount: 0, observedGenotypes: []
                    ),
                ]),
                GenotypeHaplotypeSampleAnalysis(sample: "Animal2", calls: []),
            ]
        )
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL, manifest: manifest, artifacts: artifacts,
            stats: stats, calls: calls, samples: samples,
            haplotypeAnalysis: analysis
        )

        let workbook = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.build(from: result)

        XCTAssertEqual(workbook.samples, ["Animal1", "Animal2"])
        XCTAssertEqual(workbook.sheetName, "TestRun")
        XCTAssertEqual(workbook.mappedReadCounts, [150, 25])
        XCTAssertEqual(workbook.totalReadCounts, [200, 100])
        XCTAssertEqual(workbook.percentReadsUnmapped, [25.0, 40.0])

        // 14 haplotype rows in canonical locus order.
        XCTAssertEqual(workbook.haplotypeRows.count, 14)
        XCTAssertEqual(workbook.haplotypeRows[0].label, "MHC-A Haplotype 1")
        XCTAssertEqual(workbook.haplotypeRows[0].values, ["M1A", nil])
        XCTAssertEqual(workbook.haplotypeRows[1].label, "MHC-A Haplotype 2")
        XCTAssertEqual(workbook.haplotypeRows[1].values, ["M2A", nil])
        XCTAssertEqual(workbook.haplotypeRows[2].label, "MHC-B Haplotype 1")
        XCTAssertEqual(workbook.haplotypeRows[2].values, ["ERR: NO HAP", nil])

        // Comments row reports the non-called locus for Animal1.
        XCTAssertEqual(workbook.commentsRow[0], "MHC-B: ERR: NO HAP")
        XCTAssertNil(workbook.commentsRow[1])

        // Two allele groups (Mafa-F + Mafa-G) seen in calls.
        XCTAssertEqual(workbook.groups.map(\.label), ["Mafa-F alleles", "Mafa-G alleles"])
        XCTAssertEqual(workbook.groups[0].alleles.map(\.name), ["01_M1_F_01_w_06"])
        XCTAssertEqual(workbook.groups[0].alleles[0].counts, [80, 20])
        XCTAssertEqual(workbook.groups[1].alleles[0].counts, [40, nil])
    }

    func testPivotWorkbookUsesSidecarActiveCustomHaplotypeDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-active-definition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definition = customDefinition(id: "custom.pivot.definition", haplotypeName: "NewB")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = definition.id
        let result = activeDefinitionResult(bundleURL: bundleURL)

        let workbook = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.build(from: result, sidecar: sidecar)

        XCTAssertEqual(workbook.haplotypeRows[2].label, "MHC-B Haplotype 1")
        XCTAssertEqual(workbook.haplotypeRows[2].values, ["NewB"])
    }

    func testPlainXlsxMatrixUsesSidecarActiveCustomHaplotypeDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xlsx-active-definition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definition = customDefinition(id: "custom.xlsx.definition", haplotypeName: "NewB")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = definition.id
        let result = activeDefinitionResult(bundleURL: bundleURL)

        let matrix = GenotypeXlsxWorkbookWriter.MatrixBuilder.build(from: result, sidecar: sidecar)

        XCTAssertEqual(matrix.loci, ["MHC-B"])
        XCTAssertEqual(matrix.rows.first?.cells.first?.label, "NewB")
    }

    func testPivotWorkbookSheetNameSanitization() {
        let sanitized = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.sanitizedSheetName(
            "Long/Name:With*Illegal[Chars]/AndMoreCharactersThan31"
        )
        XCTAssertLessThanOrEqual(sanitized.count, 31)
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.contains("*"))
        XCTAssertFalse(sanitized.contains("["))
        XCTAssertFalse(sanitized.contains("]"))
        XCTAssertEqual(
            GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder.sanitizedSheetName("   "),
            "Genotype"
        )
    }

    private func activeDefinitionResult(bundleURL: URL) -> ONTGenotypeResultBundleData {
        let calls = [makeCall(sample: "AnimalA", genotype: "12_M9_B_001_01", reads: 150)]
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "test",
                analysisName: "TestRun",
                primaryWorkbookPath: "test.xlsx",
                longSummaryCSVPath: "test.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "test.retained-demux-samples.csv",
                statsJSONPath: "test.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("test.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("test.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("test.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("test.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 150),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "custom-assay",
                definitionSetID: "old.definition",
                definitionSetName: "Old Definition",
                speciesName: "Test macaque",
                samples: [
                    GenotypeHaplotypeSampleAnalysis(
                        sample: "AnimalA",
                        calls: [
                            GenotypeHaplotypeLocusCall(
                                locus: "MHC-B",
                                sourceLocus: "Mafa-B",
                                haplotype1: "OldB",
                                haplotype2: "-",
                                status: .called,
                                matchedHaplotypes: [],
                                observedGenotypeCount: 1,
                                observedGenotypes: ["12_OLD_B_001_01"]
                            )
                        ]
                    )
                ]
            )
        )
    }

    private func customDefinition(id: String, haplotypeName: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "custom-assay",
            displayName: "Custom Export Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: haplotypeName, diagnosticAlleles: ["12_M9_B_001_01"])
                    ]
                )
            ]
        )
    }

    private func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}
