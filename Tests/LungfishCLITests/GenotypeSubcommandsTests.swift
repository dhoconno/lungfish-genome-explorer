import XCTest
import LungfishCore
import LungfishIO
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
                "export-xlsx", "export-pivot-xlsx", "export-labkey"
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
}
