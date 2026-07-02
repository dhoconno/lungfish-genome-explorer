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

    func testViewProjectionDecodesLegacyRowsWithoutLocus() throws {
        let legacyJSON = Data("""
        {
          "lens": "haplotype",
          "sampleColumns": ["S1"],
          "rows": [
            {
              "label": "01_M1A_A1_063",
              "cells": ["39"],
              "cellColorsHex": ["#FFF2CC"],
              "rowColorHex": null
            }
          ],
          "cellColorMode": "budde2010"
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(GenotypeViewProjection.self, from: legacyJSON)

        XCTAssertEqual(decoded.rows.first?.label, "01_M1A_A1_063")
        XCTAssertNil(decoded.rows.first?.locus)
        XCTAssertEqual(decoded.rows.first?.cells, ["39"])
    }

    // MARK: - Provenance

    func testGenotypeExportRecordsLungfishCliProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let out = root.appendingPathComponent("out.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
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
        let cmd = try GenotypeExportSubcommand.parse([
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

    func testAnnotationBearingProjectionExportEmbedsMatrixAnnotationsAndStableSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-matrix-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let sidecarURL = try seedMatrixAnnotations(in: fixture)

        let projection = GenotypeViewProjection(
            lens: "summary.matrix",
            sampleColumns: ["S1", "S2"],
            rows: [
                GenotypeViewProjectionRow(
                    label: "01_M1A_A1_063",
                    locus: "MHC-A",
                    cells: ["39", "20"]
                ),
                GenotypeViewProjectionRow(
                    label: "01_M1A_A1_063",
                    locus: "MHC-B",
                    cells: ["", "11"]
                )
            ],
            cellColorMode: "nativeAnnotations"
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)

        let out = root.appendingPathComponent("view.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--view-projection", projectionURL.path,
            "--sample", "S1",
            "--sample", "S2",
            "--force",
        ])
        _ = try await cmd.runReturningResolvedColumns()

        let workbookXML = try unzipEntry("xl/workbook.xml", from: out)
        XCTAssertTrue(workbookXML.contains("Matrix Annotations"))
        let contentTypesXML = try unzipEntry("[Content_Types].xml", from: out)
        XCTAssertTrue(contentTypesXML.contains("/xl/worksheets/sheet2.xml"))
        let workbookRelsXML = try unzipEntry("xl/_rels/workbook.xml.rels", from: out)
        XCTAssertTrue(workbookRelsXML.contains(#"Id="rId2""#))
        XCTAssertTrue(workbookRelsXML.contains(#"Target="worksheets/sheet2.xml""#))
        let viewSheetXML = try unzipEntry("xl/worksheets/sheet1.xml", from: out)
        XCTAssertTrue(viewSheetXML.contains("<t>Locus</t>"))
        XCTAssertTrue(viewSheetXML.contains("<t>Row</t>"))
        XCTAssertTrue(viewSheetXML.contains("<t>MHC-A</t>"))
        XCTAssertTrue(viewSheetXML.contains("<t>MHC-B</t>"))
        let annotationSheetXML = try unzipEntry("xl/worksheets/sheet2.xml", from: out)
        XCTAssertTrue(annotationSheetXML.contains("<t>Is Bold</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Bold Override</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Is Italic</t>"))
        XCTAssertTrue(annotationSheetXML.contains("<t>Italic Override</t>"))
        XCTAssertTrue(annotationSheetXML.contains("Visible cell comment."))
        XCTAssertTrue(annotationSheetXML.contains("Hidden annotation comment."))
        XCTAssertTrue(annotationSheetXML.contains("HiddenOnly"))
        XCTAssertTrue(annotationSheetXML.contains("#FFF2CC"))

        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: out.appendingPathExtension("lungfish-provenance.json")))
        let inputPaths = Set(env.steps.flatMap(\.inputs).map(\.path))
        XCTAssertTrue(
            inputPaths.contains(sidecarURL.path),
            "annotation-bearing exports must record the stable annotations.json sidecar as an input"
        )
    }

    func testFullMatrixExportEmbedsMatrixAnnotationsAndStableSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-full-matrix-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let sidecarURL = try seedMatrixAnnotations(in: fixture)
        let out = root.appendingPathComponent("matrix.xlsx")
        let cmd = try GenotypeExportSubcommand.parse([
            "--bundle", fixture.path,
            "--export-format", "xlsx",
            "--output", out.path,
            "--force",
        ])
        try await cmd.run()

        let workbookXML = try unzipEntry("xl/workbook.xml", from: out)
        XCTAssertTrue(workbookXML.contains("Matrix Annotations"))
        let contentTypesXML = try unzipEntry("[Content_Types].xml", from: out)
        XCTAssertTrue(contentTypesXML.contains("/xl/worksheets/sheet5.xml"))
        let workbookRelsXML = try unzipEntry("xl/_rels/workbook.xml.rels", from: out)
        XCTAssertTrue(workbookRelsXML.contains(#"Id="rId6""#))
        XCTAssertTrue(workbookRelsXML.contains(#"Target="worksheets/sheet5.xml""#))
        let annotationSheetXML = try unzipEntry("xl/worksheets/sheet5.xml", from: out)
        XCTAssertTrue(annotationSheetXML.contains("Visible cell comment."))
        XCTAssertTrue(annotationSheetXML.contains("Hidden annotation comment."))
        XCTAssertTrue(annotationSheetXML.contains("HiddenOnly"))
        XCTAssertTrue(annotationSheetXML.contains("#FFF2CC"))

        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: out.appendingPathExtension("lungfish-provenance.json")))
        let inputPaths = Set(env.steps.flatMap(\.inputs).map(\.path))
        XCTAssertTrue(
            inputPaths.contains(sidecarURL.path),
            "full matrix exports must record the stable annotations.json sidecar as an input"
        )
    }

    func testExportXlsxEmbedsMatrixAnnotationsAndStableSidecarProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genotype-export-xlsx-matrix-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fixture = try makeGenotypeBundleFixture(in: root)
        let sidecarURL = try seedMatrixAnnotations(in: fixture)
        let out = root.appendingPathComponent("legacy-matrix.xlsx")
        let cmd = try GenotypeExportXlsxSubcommand.parse([
            "--bundle", fixture.path,
            "--output", out.path,
        ])
        try await cmd.run()

        let workbookXML = try unzipEntry("xl/workbook.xml", from: out)
        XCTAssertTrue(workbookXML.contains("Matrix Annotations"))
        let contentTypesXML = try unzipEntry("[Content_Types].xml", from: out)
        XCTAssertTrue(contentTypesXML.contains("/xl/worksheets/sheet5.xml"))
        let workbookRelsXML = try unzipEntry("xl/_rels/workbook.xml.rels", from: out)
        XCTAssertTrue(workbookRelsXML.contains(#"Id="rId6""#))
        XCTAssertTrue(workbookRelsXML.contains(#"Target="worksheets/sheet5.xml""#))
        let annotationSheetXML = try unzipEntry("xl/worksheets/sheet5.xml", from: out)
        XCTAssertTrue(annotationSheetXML.contains("Visible cell comment."))
        XCTAssertTrue(annotationSheetXML.contains("Hidden annotation comment."))
        XCTAssertTrue(annotationSheetXML.contains("HiddenOnly"))
        XCTAssertTrue(annotationSheetXML.contains("#FFF2CC"))

        let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: out.appendingPathExtension("lungfish-provenance.json")))
        XCTAssertEqual(env.workflowName, "genotype.export.xlsx")
        let inputPaths = Set(env.steps.flatMap(\.inputs).map(\.path))
        XCTAssertTrue(
            inputPaths.contains(sidecarURL.path),
            "export-xlsx must record the stable annotations.json sidecar as an input"
        )
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

    private func unzipEntry(_ entry: String, from archiveURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let escapedEntry = entry
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        process.arguments = ["-p", archiveURL.path, escapedEntry]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @discardableResult
    private func seedMatrixAnnotations(in bundleURL: URL) throws -> URL {
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        var sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        sidecar.matrixStyles = [
            GenotypeAnnotationSidecar.MatrixStyleAnnotation(
                target: .cell(locus: "MHC-A", genotype: "01_M1A_A1_063", sample: "S1"),
                style: GenotypeAnnotationSidecar.MatrixStyle(
                    fillColor: "#FFF2CC",
                    textColor: "#C00000",
                    borderColor: "#00AAFF",
                    isBold: true,
                    isItalic: true
                ),
                author: "qa",
                timestamp: "2026-06-30T10:00:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixStyleAnnotation(
                target: .row(locus: "MHC-B", genotype: "HiddenOnly"),
                style: GenotypeAnnotationSidecar.MatrixStyle(fillColor: "#D9EAD3"),
                author: "qa",
                timestamp: "2026-06-30T10:01:00Z"
            ),
        ]
        sidecar.matrixComments = [
            GenotypeAnnotationSidecar.MatrixComment(
                target: .cell(locus: "MHC-A", genotype: "01_M1A_A1_063", sample: "S1"),
                body: "Visible cell comment.",
                author: "qa",
                timestamp: "2026-06-30T10:02:00Z"
            ),
            GenotypeAnnotationSidecar.MatrixComment(
                target: .row(locus: "MHC-B", genotype: "HiddenOnly"),
                body: "Hidden annotation comment.",
                author: "qa",
                timestamp: "2026-06-30T10:03:00Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        return sidecarURL
    }

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
