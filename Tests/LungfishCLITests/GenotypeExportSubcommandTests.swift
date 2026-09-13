import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class GenotypeExportSubcommandTests: XCTestCase {
    private static var managedPythonURL: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"]
            .map { root.appendingPathComponent("\($0)/conda/envs/openpyxl/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func testParsesReviewedXlsxScopeAndFilterOptions() throws {
        let command = try GenotypeExportSubcommand.parse([
            "--bundle", "/tmp/input.lungfishgenotype",
            "--output", "/tmp/report.xlsx",
            "--lens", "allele",
            "--min-reads", "7",
            "--min-percent", "4.5",
            "--percent-basis", "sample-retained",
            "--filter", "reviewed",
            "--sample", "S2",
            "--view-projection", "/tmp/view.json",
            "--annotations", "/tmp/annotations.json",
            "--force",
        ])
        XCTAssertEqual(command.format, .xlsx)
        XCTAssertEqual(command.minReads, 7)
        XCTAssertEqual(command.minPercent, 4.5)
        XCTAssertEqual(command.percentBasis, .sampleRetained)
        XCTAssertEqual(command.samples, ["S2"])
        XCTAssertTrue(command.force)
    }

    func testRejectsInvalidInputsAndFilters() {
        XCTAssertThrowsError(
            try GenotypeExportSubcommand.parse([
                "--bundle", "", "--output", "/tmp/report.xlsx",
            ]).validate()
        )
        for arguments in [
            ["--min-reads", "-1"],
            ["--min-percent", "-0.1"],
            ["--min-percent", "100.1"],
        ] {
            XCTAssertThrowsError(
                try GenotypeExportSubcommand.parse(
                    ["--bundle", "/tmp/in", "--output", "/tmp/out.xlsx"]
                        + arguments
                ).validate()
            )
        }
    }

    func testProjectionRoundTripKeepsScientificNestedFields() throws {
        let projection = GenotypeViewProjection(
            lens: "allele",
            sampleColumns: ["S1"],
            rows: [
                .init(
                    label: "short",
                    rawGenotype: "01_M1A_A1_063",
                    locus: "Mafa-A",
                    stableClusterID: "cluster-1",
                    cells: ["39"],
                    cellColorsHex: ["#123456"],
                    rowColorHex: "#ABCDEF",
                    rowStyle: .init(fillHex: "#ABCDEF", isBold: true),
                    cellStyles: [.init(textHex: "#FFFFFF", isItalic: true)]
                ),
            ],
            cellColorMode: "read-depth",
            genotypeLocusDisplayOrder: ["Mafa-A"],
            genotypeNumericPrefixOrder: true,
            diagnosticAllelesOnly: true,
            includeTotalReads: true,
            haplotypeCalls: [
                .init(
                    sample: "S1", locus: "MHC-A", haplotype1: "M1A",
                    haplotype2: "M3A", haplotype1Status: "called",
                    haplotype2Status: "called", haplotype1Source: "pipeline",
                    haplotype2Source: "pipeline", baselineHaplotype1: "M1A",
                    baselineHaplotype2: "M3A", comment: "captured"
                ),
            ],
            sourceRevision: .init(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: nil,
                definitionSetID: "mauritian-cynomolgus-macaques"
            ),
            filterContext: ["Search": "A1"],
            presentationColors: [
                .init(locus: "MHC-A", call: "M1A", fillHex: "#008000", fontHex: "#FFFFFF"),
            ]
        )

        let decoded = try JSONDecoder().decode(
            GenotypeViewProjection.self,
            from: JSONEncoder().encode(projection)
        )
        XCTAssertEqual(decoded.rows.first?.rawGenotype, "01_M1A_A1_063")
        XCTAssertEqual(decoded.rows.first?.stableClusterID, "cluster-1")
        XCTAssertEqual(decoded.rows.first?.cellStyles?.first??.textHex, "#FFFFFF")
        XCTAssertEqual(decoded.haplotypeCalls?.first?.baselineHaplotype2, "M3A")
        XCTAssertEqual(decoded.filterContext?["Search"], "A1")
        XCTAssertEqual(decoded.presentationColors?.first?.fillHex, "#008000")
    }

    func testCsvAndTsvExportsRemainOnTheNativeDelimitedPath() async throws {
        let root = try temporaryDirectory(prefix: "genotype-delimited")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)

        let csv = root.appendingPathComponent("matrix.csv")
        let csvColumns = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "csv",
            "--output", csv.path,
            "--sample", "S1",
        ]).runReturningResolvedColumns(managedPythonResolver: {
            XCTFail("CSV must not resolve the XLSX runtime")
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertEqual(csvColumns, ["S1"])
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(csvText.hasPrefix("Sample,MHC-A H1,MHC-A H2\n"))
        XCTAssertTrue(csvText.contains("S1,M1A,M3A"))

        let projectionURL = root.appendingPathComponent("view.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1", "S2"],
                rows: [
                    .init(label: "Visible allele", locus: "Mafa-A", cells: ["39", "20"]),
                ]
            )
        ).write(to: projectionURL)
        let tsv = root.appendingPathComponent("view.tsv")
        let tsvColumns = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "tsv",
            "--output", tsv.path,
            "--view-projection", projectionURL.path,
            "--sample", "S2",
        ]).runReturningResolvedColumns(managedPythonResolver: {
            XCTFail("TSV must not resolve the XLSX runtime")
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertEqual(tsvColumns, ["S2"])
        XCTAssertEqual(
            try String(contentsOf: tsv, encoding: .utf8),
            "Locus\tRow\tS2\nMafa-A\tVisible allele\t20\n"
        )
    }

    func testUnifiedXlsxUsesCapturedProjectionIdentityAnnotationsAndReceipt() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try temporaryDirectory(prefix: "genotype-unified-xlsx")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let loaded = try ONTGenotypeResultBundle.loadResult(from: bundle)
        let call = try XCTUnwrap(loaded.calls.first)
        let lowCall = try XCTUnwrap(
            loaded.calls.first { $0.genotype == "02_M3A_A2_010" }
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: call.locusGroup,
            genotype: call.genotype,
            sample: "S1"
        )
        sidecar.matrixReviews = [
            .init(
                target: target, disposition: .falsePositive,
                author: "Reviewer", timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: target, body: "captured note",
                author: "Reviewer", timestamp: "2026-09-12T00:00:00Z"
            ),
        ]
        try FileManager.default.removeItem(
            at: ONTGenotypeResultBundleData.annotationSidecarURL(
                forBundleAt: bundle
            )
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundle
        )
        let projectionURL = root.appendingPathComponent("projection.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1"],
                rows: [
                    .init(
                        label: "Concise A1",
                        rawGenotype: call.genotype,
                        locus: call.locusGroup,
                        cells: [String(call.passedUniqueReads)],
                        cellColorsHex: ["#123456"],
                        rowColorHex: "#ABCDEF"
                    ),
                    .init(
                        label: "Concise A2",
                        rawGenotype: lowCall.genotype,
                        locus: lowCall.locusGroup,
                        cells: [String(lowCall.passedUniqueReads)]
                    ),
                ],
                filterContext: ["Search": "A1"]
            )
        ).write(to: projectionURL)
        let output = root.appendingPathComponent("report.xlsx")

        let columns = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "xlsx",
            "--output", output.path,
            "--view-projection", projectionURL.path,
            "--min-reads", "31",
            "--sample", "S1",
        ]).runReturningResolvedColumns(managedPythonResolver: { python })

        XCTAssertEqual(columns, ["S1"])
        let receiptURL = output.appendingPathExtension("provenance.json")
        let receipt = try jsonObject(receiptURL)
        XCTAssertEqual(receipt["workflowName"] as? String, "lungfish genotype export")
        XCTAssertEqual((receipt["output"] as? [String: Any])?["path"] as? String, output.path)
        XCTAssertEqual(receipt["exitStatus"] as? Int, 0)
        let snapshotDescriptor = try XCTUnwrap(receipt["snapshot"] as? [String: Any])
        let snapshotURL = URL(fileURLWithPath: try XCTUnwrap(snapshotDescriptor["path"] as? String))
        let snapshot = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        let row = try XCTUnwrap(snapshot.filteredMatrix.rows.first)
        XCTAssertEqual(snapshot.filteredMatrix.rows.count, 1)
        XCTAssertEqual(row.displayName, "Concise A1")
        XCTAssertEqual(row.target.genotype, call.genotype)
        XCTAssertEqual(row.cells.first?.review, "false-positive")
        XCTAssertEqual(row.cells.first?.comment, "captured note")
        XCTAssertEqual(row.cells.first?.fillHex?.uppercased(), "#123456")
        XCTAssertEqual(snapshot.allMatrix.samples.map(\.id), ["S1", "S2"])
        XCTAssertTrue(
            (receipt["inputs"] as? [[String: Any]] ?? []).contains {
                $0["path"] as? String == projectionURL.path
                    && ($0["sha256"] as? String)?.isEmpty == false
            }
        )

        let inspection = try await inspect(output, python: python, root: root)
        XCTAssertEqual(
            inspection["sheets"] as? [String],
            [
                "Haplotype Calls", "Genotype Matrix - All",
                "Genotype Matrix - Filtered", "Export Metadata",
            ]
        )
        XCTAssertEqual(inspection["filteredSamples"] as? [String], ["S1"])
        XCTAssertEqual(inspection["filteredLabel"] as? String, "Concise A1")
        XCTAssertEqual(inspection["filteredValue"] as? Int, call.passedUniqueReads)
        XCTAssertTrue((inspection["filteredComment"] as? String ?? "").contains("captured note"))
    }

    func testMalformedProjectionIsRejectedBeforeExistingReportIsReplaced() async throws {
        let root = try temporaryDirectory(prefix: "genotype-malformed-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(in: root)
        let projection = root.appendingPathComponent("malformed.json")
        try JSONEncoder().encode(
            GenotypeViewProjection(
                lens: "allele",
                sampleColumns: ["S1"],
                rows: [.init(label: "bad", cells: [])]
            )
        ).write(to: projection)
        let output = root.appendingPathComponent("existing.xlsx")
        let prior = Data("existing owner".utf8)
        try prior.write(to: output)

        do {
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--output", output.path,
                "--view-projection", projection.path,
                "--force",
            ]).runReturningResolvedColumns(managedPythonResolver: {
                XCTFail("malformed projection must fail before runtime resolution")
                throw CocoaError(.fileNoSuchFile)
            })
            XCTFail("malformed projection was accepted")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("one value/style per sample")
            )
        }
        XCTAssertEqual(try Data(contentsOf: output), prior)
    }

    private func makeBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let workbook = bundle.appendingPathComponent("source.xlsx")
        let calls = bundle.appendingPathComponent("calls.csv")
        let samples = bundle.appendingPathComponent("samples.csv")
        let stats = bundle.appendingPathComponent("stats.json")
        let provenance = bundle.appendingPathComponent("provenance.json")
        let analysisURL = bundle.appendingPathComponent("haplotypes.json")
        try Data("not a workbook and never an XLSX input".utf8).write(to: workbook)
        try Data("{}".utf8).write(to: provenance)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        S1,01_M1A_A1_063,42,39,100,69,69.0,1000,89,8.9
        S1,02_M3A_A2_010,30,30,100,69,69.0,1000,89,8.9
        S2,01_M1A_A1_063,22,20,80,20,25.0,1000,89,8.9
        """.write(to: calls, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        S1,72,69,100,69.0,1000,8.9
        S2,22,20,80,25.0,1000,8.9
        """.write(to: samples, atomically: true, encoding: .utf8)
        try Data(#"{"totalInputReads":1000,"totalAlignments":94,"passedAlignments":94,"retainedUniqueReads":89,"retainedUniquePercentOfTotalReads":8.9,"assignedUniqueRetainedReads":89,"unassignedUniqueRetainedReads":0}"#.utf8).write(to: stats)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mauritian-cynomolgus-macaques",
            definitionSetName: "Fixture",
            speciesName: "Fixture",
            generatedAt: "2026-09-12T00:00:00Z",
            samples: [
                .init(sample: "S1", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "M1A", haplotype2: "M3A", status: .called,
                        matchedHaplotypes: [], observedGenotypeCount: 2,
                        observedGenotypes: ["01_M1A_A1_063", "02_M3A_A2_010"]
                    ),
                ]),
                .init(sample: "S2", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "M1A", haplotype2: "-", status: .called,
                        matchedHaplotypes: [], observedGenotypeCount: 1,
                        observedGenotypes: ["01_M1A_A1_063"]
                    ),
                ]),
            ]
        )
        try JSONEncoder().encode(analysis).write(to: analysisURL)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            primaryWorkbookPath: workbook.lastPathComponent,
            longSummaryCSVPath: calls.lastPathComponent,
            sampleSummaryCSVPath: samples.lastPathComponent,
            statsJSONPath: stats.lastPathComponent,
            provenancePath: provenance.lastPathComponent,
            haplotypeAnalysisPath: analysisURL.lastPathComponent,
            haplotypeDefinitionSetID: analysis.definitionSetID,
            createdAt: "2026-09-12T00:00:00Z"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            .empty(generatedAt: "2026-09-12T00:00:00Z"),
            forBundleAt: bundle
        )
        return bundle
    }

    private func inspect(
        _ workbook: URL,
        python: URL,
        root: URL
    ) async throws -> [String: Any] {
        let script = root.appendingPathComponent("inspect-\(UUID().uuidString).py")
        try Data(#"""
import json, sys
from openpyxl import load_workbook
w = load_workbook(sys.argv[1], data_only=False)
s = w['Genotype Matrix - Filtered']
header = next(r for r in range(1, s.max_row + 1) if s.cell(r, 3).value == 'Allele')
row = header + 1
print(json.dumps({
  'sheets': w.sheetnames,
  'filteredSamples': [s.cell(header, c).value for c in range(4, s.max_column + 1)],
  'filteredLabel': s.cell(row, 3).value,
  'filteredValue': s.cell(row, 4).value,
  'filteredComment': s.cell(row, 4).comment.text if s.cell(row, 4).comment else '',
}))
"""#.utf8).write(to: script)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, workbook.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let error = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: stdout.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
        )
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
    }
}
