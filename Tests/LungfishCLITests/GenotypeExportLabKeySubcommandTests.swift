import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishCLI

final class GenotypeExportLabKeySubcommandTests: XCTestCase {
    // MARK: - Argument parsing

    func testParsesBundleAndOutputDir() throws {
        let command = try GenotypeExportLabKeySubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output-dir", "/tmp/labkey-out"
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.outputDir, "/tmp/labkey-out")
    }

    func testRejectsEmptyBundle() {
        XCTAssertThrowsError(
            try GenotypeExportLabKeySubcommand.parse([
                "--bundle", "   ",
                "--output-dir", "/tmp/labkey-out"
            ]).validate()
        )
    }

    func testRejectsEmptyOutputDir() {
        XCTAssertThrowsError(
            try GenotypeExportLabKeySubcommand.parse([
                "--bundle", "/tmp/example.lungfishgenotype",
                "--output-dir", "  "
            ]).validate()
        )
    }

    // MARK: - CSV escaping

    func testCSVFieldEscapesEmbeddedCommasAndQuotes() {
        XCTAssertEqual(LabKeyExporter.csvField("plain"), "plain")
        XCTAssertEqual(LabKeyExporter.csvField(""), "")
        XCTAssertEqual(LabKeyExporter.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(LabKeyExporter.csvField("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(LabKeyExporter.csvField("line1\nline2"), "\"line1\nline2\"")
    }

    // MARK: - End-to-end export

    func testExportWritesAllFiveFilesWithExpectedHeaders() throws {
        let root = try TestTempDirectory.make(prefix: "labkey-export")
        defer { TestTempDirectory.cleanup(root) }

        let bundleURL = try makeFixtureBundle(in: root)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)

        let sidecar = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        let exporter = LabKeyExporter(
            outputDir: outputDir,
            bundleURL: bundleURL,
            result: result,
            sidecar: sidecar
        )
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let written = try exporter.writeAll()

        // 1) All five expected files present, in order.
        let labels = written.map(\.label)
        XCTAssertEqual(labels, [
            "haplotype_calls",
            "allele_read_counts",
            "overrides",
            "audit_log",
            "smart_cohorts"
        ])
        for file in written {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.url.path),
                "missing output file: \(file.filename)"
            )
        }

        // 2) Header rows match the LabKey ingestion contract exactly.
        let headersByLabel = try Dictionary(uniqueKeysWithValues: written.map { file -> (String, String) in
            let content = try String(contentsOf: file.url, encoding: .utf8)
            return (file.label, content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
        })
        XCTAssertEqual(
            headersByLabel["haplotype_calls"],
            "animal_id,gs_id,locus,slot,called_haplotype,status,reads_supporting,is_override,notes"
        )
        XCTAssertEqual(
            headersByLabel["allele_read_counts"],
            "animal_id,gs_id,allele,locus_group,unique_reads,passed_unique_reads,passed_alignments"
        )
        XCTAssertEqual(
            headersByLabel["overrides"],
            "animal_id,locus,slot,original_call,override_call,reason_tag,rationale,author,timestamp"
        )
        XCTAssertEqual(
            headersByLabel["audit_log"],
            "action,animal_id,locus,slot,before,after,color,reason,rationale,author,timestamp"
        )
        XCTAssertEqual(
            headersByLabel["smart_cohorts"],
            "cohort_id,cohort_name,predicate_json,created_at,sample_count"
        )

        // 3) Haplotype rows reflect the analyst override: AnimalA's MHC-A
        //    haplotype1 was overridden from "M1A" -> "M2A". The pipeline's
        //    raw call set never emitted M2A but the LabKey export must show
        //    the analyst-final haplotype.
        let haplotypeContent = try String(
            contentsOf: outputDir.appendingPathComponent("haplotype_calls.csv"),
            encoding: .utf8
        )
        let haplotypeLines = haplotypeContent.split(separator: "\n").map(String.init)
        let aH1Row = try XCTUnwrap(haplotypeLines.first { $0.hasPrefix("AnimalA,AnimalA,MHC-A,h1,") })
        XCTAssertTrue(aH1Row.contains(",M2A,"), "expected override M2A in row: \(aH1Row)")
        XCTAssertTrue(aH1Row.hasSuffix(",true,"), "expected is_override=true in row: \(aH1Row)")

        // The H2 slot was not overridden; it should remain "M3A" with
        // is_override=false.
        let aH2Row = try XCTUnwrap(haplotypeLines.first { $0.hasPrefix("AnimalA,AnimalA,MHC-A,h2,") })
        XCTAssertTrue(aH2Row.contains(",M3A,"))
        XCTAssertTrue(aH2Row.contains(",false,"))

        // 4) Override + audit rows round-trip the sidecar exactly once each.
        let overridesContent = try String(
            contentsOf: outputDir.appendingPathComponent("overrides.csv"),
            encoding: .utf8
        )
        let overrideLines = overridesContent.split(separator: "\n").map(String.init)
        XCTAssertEqual(overrideLines.count, 2, "1 header + 1 override row expected")
        XCTAssertTrue(overrideLines[1].hasPrefix("AnimalA,MHC-A,h1,M1A,M2A,mis-call,"))

        let auditContent = try String(
            contentsOf: outputDir.appendingPathComponent("audit_log.csv"),
            encoding: .utf8
        )
        XCTAssertEqual(
            auditContent.split(separator: "\n").count,
            2,
            "1 header + 1 audit row expected"
        )

        // 5) Smart cohort row encodes the predicate JSON and the matching
        //    sample count derived from the bundle subjects.
        let cohortContent = try String(
            contentsOf: outputDir.appendingPathComponent("smart_cohorts.csv"),
            encoding: .utf8
        )
        let cohortLines = cohortContent.split(separator: "\n").map(String.init)
        XCTAssertEqual(cohortLines.count, 2)
        XCTAssertTrue(cohortLines[1].contains("Errors at MHC-A"))
        // predicate_json column is field 3 (after cohort_id, cohort_name).
        // The CSV row uses quote-escaped JSON; just check the value type.
        XCTAssertTrue(cohortLines[1].contains("hasErrorAt"))

        // 6) Allele rows include one entry per (sample, call). AnimalA has
        //    two calls in the fixture; AnimalB has one.
        let alleleContent = try String(
            contentsOf: outputDir.appendingPathComponent("allele_read_counts.csv"),
            encoding: .utf8
        )
        let alleleLines = alleleContent.split(separator: "\n").map(String.init)
        XCTAssertEqual(alleleLines.count, 4, "header + 3 call rows")
    }

    func testLabKeyExportUsesSidecarActiveCustomHaplotypeDefinition() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "labkey-active-definition")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definition = customDefinition(id: "custom.labkey.definition", haplotypeName: "NewB")
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = definition.id
        let result = inMemoryResult(
            bundleURL: bundleURL,
            calls: [GenotypeTestFixtures.makeCall(sample: "AnimalA", genotype: "12_M9_B_001_01", reads: 150)],
            haplotypeAnalysis: persistedAnalysis(haplotypeName: "OldB")
        )
        let outputDir = projectRoot.appendingPathComponent("labkey", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let exporter = LabKeyExporter(
            outputDir: outputDir,
            bundleURL: bundleURL,
            result: result,
            sidecar: sidecar
        )

        _ = try exporter.writeAll()

        let content = try String(
            contentsOf: outputDir.appendingPathComponent("haplotype_calls.csv"),
            encoding: .utf8
        )
        XCTAssertTrue(content.contains("AnimalA,AnimalA,MHC-B,h1,NewB,called"))
        XCTAssertFalse(content.contains("OldB"))
    }

    func testExportCommandWritesProvenanceForLabKeyOutputs() async throws {
        let root = try TestTempDirectory.make(prefix: "labkey-export-provenance")
        defer { TestTempDirectory.cleanup(root) }

        let bundleURL = try makeFixtureBundle(in: root)
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)
        let command = try GenotypeExportLabKeySubcommand.parse([
            "--bundle", bundleURL.path,
            "--output-dir", outputDir.path,
        ])

        try await command.run()

        let rootProvenanceURL = outputDir.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootProvenanceURL.path))
        let haplotypeSidecar = ProvenanceRecorder.fileSidecarURL(
            for: outputDir.appendingPathComponent("haplotype_calls.csv")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: haplotypeSidecar.path))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: rootProvenanceURL))
        XCTAssertEqual(envelope.workflowName, "genotype.export.labkey")
        XCTAssertTrue(envelope.argv.contains("export-labkey"))
        XCTAssertEqual(Set(envelope.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }), [
            "haplotype_calls.csv",
            "allele_read_counts.csv",
            "overrides.csv",
            "audit_log.csv",
            "smart_cohorts.csv",
        ])
    }

    // MARK: - Fixture

    /// Build a minimal but realistic `.lungfishgenotype` bundle with a
    /// haplotype analysis, two samples, an override (M1A -> M2A on
    /// AnimalA's MHC-A H1), an audit entry, and one smart cohort.
    private func makeFixtureBundle(in root: URL) throws -> URL {
        let bundleURL = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let workbookURL = bundleURL.appendingPathComponent("fixture.xlsx")
        let longCSV = bundleURL.appendingPathComponent("fixture.retained-demux-genotypes.csv")
        let sampleCSV = bundleURL.appendingPathComponent("fixture.retained-demux-samples.csv")
        let statsJSON = bundleURL.appendingPathComponent("fixture.retained-demux-stats.json")
        let provenanceJSON = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let haplotypeJSON = bundleURL.appendingPathComponent("haplotype-analysis.json")

        try Data("workbook".utf8).write(to: workbookURL)
        try Data("{}".utf8).write(to: provenanceJSON)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        AnimalA,01_M1A_A1_063,42,39,100,46,46.0,1000,60,6.0
        AnimalA,02_M3A_A2_010,30,30,100,46,46.0,1000,60,6.0
        AnimalB,13_Mafa_DRB1_06,12,12,90,4,4.4,1000,60,6.0
        """.write(to: longCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        AnimalA,72,69,100,46.0,1000,6.0
        AnimalB,12,12,90,4.4,1000,6.0
        """.write(to: sampleCSV, atomically: true, encoding: .utf8)
        try """
        {
          "totalInputReads": 1000,
          "totalAlignments": 120,
          "passedAlignments": 84,
          "retainedUniqueReads": 60,
          "retainedUniquePercentOfTotalReads": 6.0,
          "assignedUniqueRetainedReads": 53,
          "unassignedUniqueRetainedReads": 7
        }
        """.write(to: statsJSON, atomically: true, encoding: .utf8)

        // Haplotype analysis: AnimalA has a successful MHC-A call M1A/M3A,
        // AnimalB has a no-haplotype error at MHC-DRB. AnimalB drives the
        // "Errors at MHC-A" smart cohort below to a count of zero (only
        // AnimalA had a successful call at MHC-A).
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus",
            speciesName: "Macaca fascicularis",
            generatedAt: "2026-05-22T10:00:00Z",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalA",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["01_M1A_A1_063", "02_M3A_A2_010"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalB",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: NO HAP",
                            haplotype2: "ERR: NO HAP",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["13_Mafa_DRB1_06"]
                        )
                    ]
                )
            ]
        )
        let analysisEncoder = JSONEncoder()
        analysisEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try analysisEncoder.encode(analysis).write(to: haplotypeJSON)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: longCSV.lastPathComponent,
            sampleSummaryCSVPath: sampleCSV.lastPathComponent,
            statsJSONPath: statsJSON.lastPathComponent,
            provenancePath: provenanceJSON.lastPathComponent,
            haplotypeAnalysisPath: haplotypeJSON.lastPathComponent,
            haplotypeDefinitionSetID: "mauritian-cynomolgus-macaques",
            createdAt: "2026-05-22T10:00:00Z"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        // Annotation sidecar with one override + one audit + one cohort.
        let sidecar = GenotypeAnnotationSidecar(
            schemaVersion: GenotypeAnnotationSidecar.currentSchemaVersion,
            generatedAt: "2026-05-22T10:00:00Z",
            lastEditedAt: "2026-05-22T11:00:00Z",
            lastEditor: "alice",
            callOverrides: [
                GenotypeAnnotationSidecar.CallOverride(
                    sample: "AnimalA",
                    locus: "MHC-A",
                    slot: .h1,
                    originalCall: "M1A",
                    overrideCall: "M2A",
                    reasonTag: .misCall,
                    rationale: "Reviewed read pileup; M2A diagnostic clearer.",
                    author: "alice",
                    timestamp: "2026-05-22T11:00:00Z"
                )
            ],
            cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [
                GenotypeCohortSmartFilter(
                    name: "Errors at MHC-A",
                    description: "Samples that fail to call any haplotype at MHC-A.",
                    scope: "bundle",
                    isStarred: true,
                    predicate: .hasErrorAt(locus: "MHC-A")
                )
            ],
            manualHaplotypeAssignments: [],
            settings: .default,
            auditLog: [
                GenotypeAnnotationSidecar.AuditEntry(
                    action: "override",
                    sample: "AnimalA",
                    locus: "MHC-A",
                    slot: .h1,
                    before: "M1A",
                    after: "M2A",
                    color: nil,
                    reason: "mis-call",
                    rationale: "Reviewed read pileup; M2A diagnostic clearer.",
                    author: "alice",
                    timestamp: "2026-05-22T11:00:00Z"
                )
            ]
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        return bundleURL
    }

    private func inMemoryResult(
        bundleURL: URL,
        calls: [ONTGenotypeCall],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "test",
                analysisName: "Test",
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
            haplotypeAnalysis: haplotypeAnalysis
        )
    }

    private func customDefinition(id: String, haplotypeName: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "custom-assay",
            displayName: "Custom LabKey Definition",
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

    private func persistedAnalysis(haplotypeName: String) -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
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
                            haplotype1: haplotypeName,
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
    }

}
