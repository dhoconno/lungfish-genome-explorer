import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class GenotypeExportSubcommandTests: XCTestCase {
    // MARK: - Argument parsing

    func testParsesFilterLensAndProjectionFlags() throws {
        // NOTE: the container format flag is `--export-format` (not
        // `--format`). `GlobalOptions`, included via `@OptionGroup` per the
        // binding rule, already owns `--format` (text/json/tsv), so the
        // export format gets a distinct long name to avoid a duplicate.
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--export-format", "csv",
            "--output", "/tmp/out.csv",
            "--lens", "haplotype",
            "--min-reads", "25",
            "--filter", "errors",
            "--sample", "S1",
            "--sample", "S2",
            "--active-haplotype-definition", "custom.def",
            "--view-projection", "/tmp/projection.json",
            "--force",
        ])
        XCTAssertEqual(command.bundle, "/tmp/example.lungfishgenotype")
        XCTAssertEqual(command.format, .csv)
        XCTAssertEqual(command.output, "/tmp/out.csv")
        XCTAssertEqual(command.lens, "haplotype")
        XCTAssertEqual(command.minReads, 25)
        XCTAssertEqual(command.filter, "errors")
        XCTAssertEqual(command.samples, ["S1", "S2"])
        XCTAssertEqual(command.activeHaplotypeDefinition, "custom.def")
        XCTAssertEqual(command.viewProjection, "/tmp/projection.json")
        XCTAssertTrue(command.force)
    }

    func testRejectsEmptyBundle() {
        XCTAssertThrowsError(
            try GenotypeExportSubcommand.parse([
                "--bundle", "   ",
                "--export-format", "xlsx",
                "--output", "/tmp/out.xlsx",
            ]).validate()
        )
    }

    // MARK: - Projection round-trip

    func testViewProjectionRoundTripsThroughCodable() throws {
        let projection = GenotypeViewProjection(
            lens: "haplotype",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "MHC-A H1",
                    cells: ["M1A", "M2A"],
                    rowColorHex: "#D47B3A"
                )
            ],
            cellColorMode: "budde2010"
        )
        let data = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(GenotypeViewProjection.self, from: data)
        XCTAssertEqual(decoded, projection)
    }

    // MARK: - Provenance

    func testGenotypeExportRecordsLungfishCliProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let out = root.appendingPathComponent("out.xlsx")
        var cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--force",
        ])
        try await cmd.run()

        let prov = out.appendingPathExtension("lungfish-provenance.json")
        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: prov))
        XCTAssertEqual(env.toolName, "lungfish-cli")
        XCTAssertEqual(env.workflowName, "lungfish genotype export")
        XCTAssertEqual(env.exitStatus, 0)
        XCTAssertFalse(env.argv.isEmpty)
        XCTAssertTrue(env.argv.contains("export"))
    }

    // MARK: - Projection filters visible samples

    func testGenotypeExportProjectionFiltersToVisibleSamples() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)

        // The fixture has three samples (S1, S2, S3). The GUI projection
        // shows only S1 and S2 with the analyst-visible cells/colors. The
        // produced workbook's sample columns must reproduce that view.
        let projection = GenotypeViewProjection(
            lens: "haplotype",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "MHC-A H1",
                    cells: ["M1A", "M2A"],
                    rowColorHex: nil
                ),
                GenotypeViewProjectionRow(
                    label: "MHC-A H2",
                    cells: ["M3A", "-"],
                    rowColorHex: nil
                ),
            ],
            cellColorMode: "budde2010"
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)

        let out = root.appendingPathComponent("view.xlsx")
        var cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--view-projection", projectionURL.path,
            "--sample", "S1",
            "--sample", "S2",
            "--force",
        ])
        let resolved = try await cmd.runReturningResolvedColumns()
        XCTAssertEqual(resolved, ["S1", "S2"], "expected only the projection's visible sample columns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: - Writer-level projection rendering

    func testWorkbookWriterRendersProjectionSampleColumns() throws {
        let projection = GenotypeViewProjection(
            lens: "haplotype",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "MHC-A H1",
                    cells: ["M1A", "M2A"],
                    rowColorHex: nil
                )
            ],
            cellColorMode: "budde2010"
        )
        let columns = GenotypeXlsxWorkbookWriter.resolvedSampleColumns(for: projection)
        XCTAssertEqual(columns, ["S1", "S2"])
    }

    // MARK: - Fixture

    /// Builds a minimal `.lungfishgenotype` bundle with three samples
    /// (S1, S2, S3) so projection-driven filtering has something to drop.
    private func makeGenotypeBundleFixture(in root: URL) throws -> URL {
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
        S1,01_M1A_A1_063,42,39,100,46,46.0,1000,60,6.0
        S1,02_M3A_A2_010,30,30,100,46,46.0,1000,60,6.0
        S2,01_M1A_A1_063,22,20,80,30,37.5,1000,60,6.0
        S3,13_Mafa_DRB1_06,12,12,90,4,4.4,1000,60,6.0
        """.write(to: longCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,72,69,100,46.0,1000,6.0
        S2,22,20,80,37.5,1000,6.0
        S3,12,12,90,4.4,1000,6.0
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

        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus",
            speciesName: "Macaca fascicularis",
            generatedAt: "2026-05-22T10:00:00Z",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S1",
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
                    sample: "S2",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1A_A1_063"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S3",
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
                ),
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

        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        return bundleURL
    }
}
