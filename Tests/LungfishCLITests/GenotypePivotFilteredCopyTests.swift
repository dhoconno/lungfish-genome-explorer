import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishCLI

/// Covers the Filtered Pivot export as a copy of the result workbook.
///
/// Context (2026-09-03): the analyst wants the export to be the canonical
/// workbook, every sheet and all its formatting, with only the pivot sheet
/// filtered. The pivot-only workbook the subcommand used to write dropped
/// the Long Summary, Sample Summary and Run Stats sheets. The copy is
/// rewritten through the managed openpyxl runtime, so these tests skip when
/// that runtime is not installed.
final class GenotypePivotFilteredCopyTests: XCTestCase {
    private typealias Command = GenotypeExportPivotXlsxSubcommand
    private typealias Thresholds = Command.PivotWorkbookBuilder.Thresholds

    private static let currentRawFirst = "SYNTH_REF_0001|source_loci=MHC-DQB1|alleles=Mafa-DQB1_01:01:01:01,Mafa-DQB1_01:01:02:01"
    private static let currentRawSecond = "SYNTH_REF_0002|source_loci=MHC-DQB1|alleles=Mafa-DQB1_02:01:01:01"
    private static let currentDisplayFirst = "Mafa-DQB1*01:01:01:01/Mafa-DQB1*01:01:02:01"
    private static let currentDisplaySecond = "Mafa-DQB1*02:01:01:01"

    private static var managedPythonURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"]
            .map { home.appendingPathComponent("\($0)/conda/envs/openpyxl/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A workbook shaped like the pipeline's: the pivot sheet with its header,
    /// read-count, haplotype and comment rows, a Genotype header row, allele
    /// rows carrying Total and # Obs., plus a second sheet and a frozen pane
    /// the export must carry through untouched.
    private static let makeSourceWorkbookScript = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill

wb = Workbook()
ws = wb.active
ws.title = "Thresholds"
samples = ["Animal1", "Animal2"]
ws.append(["Animal ID", None, None] + samples)
for cell in ws[1]:
    cell.font = Font(bold=True)
    cell.fill = PatternFill("solid", fgColor="4472C4")
ws.append(["GS ID", "Total", "Average"] + samples)
ws.append(["Filtered exact-match read count", 1100, 550.0, 1000, 100])
ws.append([None] * 5)
ws.append([None] * 5)
for locus in ["MHC-A", "MHC-B"]:
    for slot in (1, 2):
        ws.append([f"{locus} Haplotype {slot}", None, None, "H1" if slot == 1 else "H2", None])
ws.append(["Comments", "Subtotal", "# Obs.", None, None])
ws.append(["Genotype", "Total", "# Obs."] + samples)
ws.append(["MHC-A alleles", None, None, None, None])
ws.append(["01_Strong", 560, 2, 500, 60])
ws.append(["01_Middle", 48, 2, 40, 8])
ws.append(["01_Background", 5, 1, 5, None])
ws.append(["01_Candidate", 5, 2, 3, 2])
ws.freeze_panes = "A2"
ws.column_dimensions["A"].width = 40
long = wb.create_sheet("Thresholds Long Summ")
long.append(["sample", "genotype", "passed_unique_reads"])
long.append(["Animal1", "01_Strong", 500])
stats = wb.create_sheet("Run Stats")
stats.append(["metric", "value"])
stats.append(["assignmentMode", "query-prefix"])
wb.save(sys.argv[1])
"""#

    /// Mirrors the published current-workbook shape without carrying customer
    /// data: the interpretation guide is first, while the projectable matrix
    /// uses compact analyst-facing allele labels on Full Sequencing Results 1.
    private static let makeCurrentWorkbookScript = #"""
import sys
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.styles import Font, PatternFill

raw_first, raw_second, display_first, display_second = sys.argv[2:6]
wb = Workbook()
guide = wb.active
guide.title = "Interpretation Guide"
guide.append(["Field", "Interpretation"])
guide.append(["Client ID", "Synthetic client identifier"])
guide.append(["GS ID", "Synthetic genotyping sample identifier"])
guide["B3"].comment = Comment("Guide comment must survive", "Curator")

pivot = wb.create_sheet("Full Sequencing Results 1")
pivot.append(["Client ID", None, None, "SyntheticSubjectA", "SyntheticSubjectB"])
pivot.append(["GS ID", None, None, "SyntheticSubjectA", "SyntheticSubjectB"])
pivot.append(["Mapped Read Count", None, None, 100, 200])
pivot.append(["total_read_count", None, None, 125, 250])
pivot.append(["percent_reads_unmapped", None, None, 20.0, 20.0])
for locus in ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]:
    for slot in (1, 2):
        pivot.append([f"{locus} Haplotype {slot}", None, None, "M1", "M2"])
pivot.append(["Comments", "Subtotal", "# Obs.", "Manual call A", "Manual call B"])
pivot.append(["Mafa-DQB alleles", None, None, None, None])
pivot.append([display_first, 17, 2, 11, 6])
pivot.append([display_second, 9, 1, None, 9])
pivot["D2"].comment = Comment("Native sample A note", "Curator")
pivot["E2"].comment = Comment("Native sample B note", "Curator")
pivot["D12"] = "STALE-A-H1"
pivot["E12"] = "STALE-B-H1"
pivot["D13"] = "STALE-A-H2"
pivot["E13"] = "STALE-B-H2"
pivot["D14"] = "STALE-A-H1"
pivot["E14"] = "STALE-B-H1"
pivot["D15"] = "STALE-A-H2"
pivot["E15"] = "STALE-B-H2"
pivot["D12"].font = Font(bold=True, color="FFFF0000")
pivot["D12"].fill = PatternFill("solid", fgColor="FFFFFF00")
pivot["E12"].font = Font(bold=True, color="FF00B050")
pivot["D12"].comment = Comment("Native haplotype note", "Curator")
pivot["A22"].comment = Comment("Native first allele note", "Curator")
pivot["E23"].comment = Comment("Native second allele cell note", "Curator")
pivot.freeze_panes = "D3"
for cell in pivot[1]:
    cell.font = Font(bold=True)
    cell.fill = PatternFill("solid", fgColor="D9EAF7")

overrides = wb.create_sheet("Overrides")
overrides.append(["Sample", "Locus", "Slot", "Override Call"])
overrides.append(["SyntheticSubjectA", "MHC-DQ", "h1", "M2DQ"])
audit = wb.create_sheet("Audit Log")
audit.append(["Action", "Sample", "Reason"])
audit.append(["override", "SyntheticSubjectA", "synthetic-review"])
wb.save(sys.argv[1])
"""#

    private static let dumpWorkbookScript = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1])
out = {"sheets": wb.sheetnames, "freeze": wb.worksheets[0].freeze_panes,
       "widthA": wb.worksheets[0].column_dimensions["A"].width,
       "boldA1": wb.worksheets[0]["A1"].font.bold,
       "fillA1": wb.worksheets[0]["A1"].fill.fgColor.rgb,
       "maxColumn": wb.worksheets[0].max_column,
       "rows": [[c for c in row] for row in wb.worksheets[0].iter_rows(values_only=True)]}
if "Thresholds Long Summ" in wb.sheetnames:
    out["long"] = [[c for c in row] for row in wb["Thresholds Long Summ"].iter_rows(values_only=True)]
if "Haplotype Calls" in wb.sheetnames:
    calls = wb["Haplotype Calls"]
    out["exactCall"] = [calls.cell(2, column).value for column in range(1, 7)]
    out["exactComment"] = calls.cell(2, 11).value
    out["exactCommentType"] = calls.cell(2, 11).data_type
for row in wb.worksheets[0].iter_rows():
    for cell in row:
        if cell.value in ("[8]", "FN"):
            out[cell.value] = {
                "coordinate": cell.coordinate,
                "italic": bool(cell.font.italic),
                "fontColor": cell.font.color.rgb if cell.font.color and cell.font.color.type == "rgb" else None,
                "fillColor": cell.fill.fgColor.rgb,
                "border": cell.border.left.style,
                "comment": "" if cell.comment is None else cell.comment.text,
            }
        if cell.value in ("Animal2", "01_Background") and cell.comment is not None:
            out[cell.value + "Comment"] = cell.comment.text
print(json.dumps(out))
"""#

    private static let dumpCurrentWorkbookScript = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1])
ws = wb["Full Sequencing Results 1"]
out = {
    "sheets": wb.sheetnames,
    "headers": [ws.cell(2, column).value for column in range(4, ws.max_column + 1)],
    "labels": [ws.cell(row, 1).value for row in range(21, ws.max_row + 1)],
    "rows": [[ws.cell(row, column).value for column in range(1, ws.max_column + 1)]
             for row in range(21, ws.max_row + 1)],
    "sampleAComment": ws["E2"].comment.text if ws["E2"].comment else None,
    "sampleBComment": ws["D2"].comment.text if ws["D2"].comment else None,
    "haplotypeHeaders": [
        [ws["D12"].value, ws["E12"].value],
        [ws["D13"].value, ws["E13"].value],
        [ws["D14"].value, ws["E14"].value],
        [ws["D15"].value, ws["E15"].value],
    ],
    "haplotypeComment": ws["E12"].comment.text if ws["E12"].comment else None,
    "haplotypeColors": [
        ws["D12"].font.color.rgb if ws["D12"].font.color and ws["D12"].font.color.type == "rgb" else None,
        ws["E12"].font.color.rgb if ws["E12"].font.color and ws["E12"].font.color.type == "rgb" else None,
    ],
    "haplotypeFillTypes": [ws["D12"].fill.fill_type, ws["E12"].fill.fill_type],
    "manualCommentsRow": [ws["D20"].value, ws["E20"].value],
    "firstAlleleComment": ws["A23"].comment.text if ws["A23"].comment else None,
    "falsePositive": {
        "value": ws["D22"].value,
        "italic": bool(ws["D22"].font.italic),
        "comment": ws["D22"].comment.text if ws["D22"].comment else None,
    },
    "falseNegative": {
        "value": ws["E23"].value,
        "border": ws["E23"].border.left.style,
        "comment": ws["E23"].comment.text if ws["E23"].comment else None,
    },
    "guideComment": wb["Interpretation Guide"]["B3"].comment.text,
    "override": wb["Overrides"]["D2"].value,
    "audit": wb["Audit Log"]["C2"].value,
}
print(json.dumps(out))
"""#

    private func makeResult(bundleURL: URL) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "thresholds", analysisName: "Thresholds",
            primaryWorkbookPath: "t.xlsx",
            longSummaryCSVPath: "g.csv", sampleSummaryCSVPath: "s.csv",
            statsJSONPath: "stats.json", provenancePath: "prov.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("t.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("g.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("s.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("prov.json")
        )
        func call(_ sample: String, _ genotype: String, unique: Int, retained: Int) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: sample, genotype: genotype,
                passedAlignments: unique * 2, passedUniqueReads: unique,
                sampleTotalReads: retained * 2, sampleUniqueRetainedReads: retained,
                sampleUniqueRetainedPercent: 50.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        let calls = [
            call("Animal1", "01_Strong", unique: 500, retained: 1_000),
            call("Animal1", "01_Middle", unique: 40, retained: 1_000),
            call("Animal1", "01_Background", unique: 5, retained: 1_000),
            call("Animal2", "01_Strong", unique: 60, retained: 100),
            call("Animal2", "01_Middle", unique: 8, retained: 100),
        ]
        let samples = [
            ONTGenotypeSampleResult(
                sample: "Animal1", passedAlignments: 1_090, passedUniqueReads: 1_000,
                sampleTotalReads: 2_000, sampleUniqueRetainedPercent: 50.0,
                calls: calls.filter { $0.sample == "Animal1" }
            ),
            ONTGenotypeSampleResult(
                sample: "Animal2", passedAlignments: 136, passedUniqueReads: 100,
                sampleTotalReads: 200, sampleUniqueRetainedPercent: 50.0,
                calls: calls.filter { $0.sample == "Animal2" }
            ),
        ]
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL, manifest: manifest, artifacts: artifacts,
            stats: ONTGenotypeRunStats(), calls: calls, samples: samples,
            haplotypeAnalysis: nil
        )
    }

    private func makeCurrentWorkbookResult(bundleURL: URL) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "synthetic-current", analysisName: "Synthetic Current Analysis",
            primaryWorkbookPath: "report.xlsx",
            longSummaryCSVPath: "calls.csv", sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json", provenancePath: "provenance.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("report.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("calls.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("samples.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("provenance.json")
        )
        func call(_ sample: String, _ genotype: String, unique: Int, retained: Int) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: sample, genotype: genotype,
                passedAlignments: unique, passedUniqueReads: unique,
                sampleTotalReads: retained, sampleUniqueRetainedReads: retained,
                sampleUniqueRetainedPercent: 100,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        let calls = [
            call("SyntheticSubjectA", Self.currentRawFirst, unique: 11, retained: 100),
            call("SyntheticSubjectA", Self.currentRawSecond, unique: 0, retained: 100),
            call("SyntheticSubjectB", Self.currentRawFirst, unique: 6, retained: 200),
            call("SyntheticSubjectB", Self.currentRawSecond, unique: 9, retained: 200),
        ]
        let samples = [
            ONTGenotypeSampleResult(
                sample: "SyntheticSubjectA", passedAlignments: 11, passedUniqueReads: 100,
                sampleTotalReads: 100, sampleUniqueRetainedPercent: 100,
                calls: calls.filter { $0.sample == "SyntheticSubjectA" }
            ),
            ONTGenotypeSampleResult(
                sample: "SyntheticSubjectB", passedAlignments: 15, passedUniqueReads: 200,
                sampleTotalReads: 200, sampleUniqueRetainedPercent: 100,
                calls: calls.filter { $0.sample == "SyntheticSubjectB" }
            ),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "synthetic-assay", definitionSetID: "synthetic-definition",
            definitionSetName: "Synthetic definition", speciesName: "Synthetic species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(sample: "SyntheticSubjectA", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DQ", sourceLocus: "MHC-DQ",
                        haplotype1: "M1DQ", haplotype2: "M2DQ",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2, observedGenotypes: []
                    ),
                ]),
                GenotypeHaplotypeSampleAnalysis(sample: "SyntheticSubjectB", calls: [
                    GenotypeHaplotypeLocusCall(
                        locus: "MHC-DQ", sourceLocus: "MHC-DQ",
                        haplotype1: "M3DQ", haplotype2: "M4DQ",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2, observedGenotypes: []
                    ),
                ]),
            ]
        )
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL, manifest: manifest, artifacts: artifacts,
            stats: ONTGenotypeRunStats(), calls: calls, samples: samples,
            haplotypeAnalysis: analysis
        )
    }

    private func runPython(_ python: URL, script: String, arguments: [String], in dir: URL) async throws -> String {
        let scriptURL = dir.appendingPathComponent("script-\(UUID().uuidString).py")
        try Data(script.utf8).write(to: scriptURL)
        let run = try await Command.runProcess(executableURL: python, arguments: [scriptURL.path] + arguments)
        XCTAssertEqual(run.status, 0, run.stderr)
        return run.stdout
    }

    func testFilteredCopyKeepsEverySheetAndFormattingAndFiltersOnlyThePivot() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL, "managed openpyxl runtime not installed")
        let root = try TestTempDirectory.make(prefix: "PivotFilteredCopy")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("thresholds.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sourceURL = bundleURL.appendingPathComponent("t.xlsx")
        _ = try await runPython(python, script: Self.makeSourceWorkbookScript, arguments: [sourceURL.path], in: root)
        let bundleFilesBefore = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path).sorted()

        let outputURL = root.appendingPathComponent("exports/thresholds-filtered-pivot.xlsx")
        let command = try Command.parse([
            "--bundle", bundleURL.path, "--output", outputURL.path, "--min-reads", "10",
        ])
        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try await command.exportFilteredCopy(
            of: sourceURL,
            result: makeResult(bundleURL: bundleURL),
            sidecar: nil,
            thresholds: Thresholds(minimumReads: 10),
            bundleURL: bundleURL,
            outputURL: outputURL,
            buildDir: buildDir,
            managedPythonResolver: { python },
            startedAt: Date()
        )

        let dump = try await runPython(python, script: Self.dumpWorkbookScript, arguments: [outputURL.path], in: root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any])
        XCTAssertEqual(object["sheets"] as? [String], ["Thresholds", "Thresholds Long Summ", "Run Stats"],
                       "every sheet survives; only the pivot is filtered")
        XCTAssertEqual(object["freeze"] as? String, "A2")
        XCTAssertEqual(object["widthA"] as? Double, 40)
        XCTAssertEqual(object["boldA1"] as? Bool, true)
        XCTAssertEqual((object["fillA1"] as? String)?.hasSuffix("4472C4"), true)
        let rows = try XCTUnwrap(object["rows"] as? [[Any]])
        let labels = rows.map { $0.first as? String }
        XCTAssertEqual(labels[0], "Animal ID")
        XCTAssertEqual(labels[2], "Filtered exact-match read count")
        XCTAssertTrue(labels.contains("MHC-B Haplotype 2"))
        XCTAssertTrue(labels.contains("01_Strong"))
        XCTAssertTrue(labels.contains("01_Middle"))
        XCTAssertFalse(labels.contains("01_Background"), "a row with nothing above the threshold is removed")
        let middle = try XCTUnwrap(rows.first { ($0.first as? String) == "01_Middle" })
        XCTAssertEqual(middle[3] as? Int, 40)
        XCTAssertTrue(middle[4] is NSNull, "Animal2's 8 reads fall below 10 and are blanked")
        XCTAssertEqual(middle[1] as? Int, 40, "Total is recomputed from what remains")
        XCTAssertEqual(middle[2] as? Int, 1, "# Obs. is recomputed from what remains")
        let strong = try XCTUnwrap(rows.first { ($0.first as? String) == "01_Strong" })
        XCTAssertEqual(strong[1] as? Int, 560)
        XCTAssertEqual((object["long"] as? [[Any]])?.count ?? 0, 2, "the Long Summary sheet is untouched")

        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: outputURL).path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: bundleURL.path).sorted(),
            bundleFilesBefore,
            "the export is one-way: nothing is written into the bundle"
        )
    }

    func testFilteredCopyReportsAMissingSourceWorkbook() async throws {
        let root = try TestTempDirectory.make(prefix: "PivotFilteredCopyMissing")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("t.lungfishgenotype", isDirectory: true)
        let command = try Command.parse(["--bundle", bundleURL.path, "--output", root.appendingPathComponent("o.xlsx").path])
        do {
            try await command.exportFilteredCopy(
                of: bundleURL.appendingPathComponent("missing.xlsx"),
                result: makeResult(bundleURL: bundleURL),
                sidecar: nil,
                thresholds: .none,
                bundleURL: bundleURL,
                outputURL: root.appendingPathComponent("o.xlsx"),
                buildDir: root,
                managedPythonResolver: { XCTFail("python must not be resolved for a missing workbook"); return root },
                startedAt: Date()
            )
            XCTFail("expected a missing-workbook error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing.xlsx"))
        }
    }

    func testViewportProjectionControlsVisibleRowsColumnsValuesAndAnnotations() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL, "managed openpyxl runtime not installed")
        let root = try TestTempDirectory.make(prefix: "PivotViewportProjection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("thresholds.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sourceURL = bundleURL.appendingPathComponent("t.xlsx")
        _ = try await runPython(python, script: Self.makeSourceWorkbookScript, arguments: [sourceURL.path], in: root)

        let projection = GenotypeViewProjection(
            lens: "comparison",
            sampleColumns: ["Animal2", "Animal1"],
            rows: [
                .init(label: "01_Background", rawGenotype: "01_Background", locus: "MHC-A", cells: ["", "5"]),
                .init(label: "01_Candidate", rawGenotype: "01_Candidate", locus: "MHC-A", stableClusterID: "candidate-1", cells: ["10", ""]),
                .init(label: "01_Middle", rawGenotype: "01_Middle", locus: "MHC-A", cells: ["8", "40"]),
            ],
            haplotypeCalls: [
                .init(
                    sample: "Animal2", locus: "MHC-DRB",
                    haplotype1: "M4DR", haplotype2: "M4DR",
                    haplotype1Status: "called", haplotype2Status: "called",
                    haplotype1Source: "pipeline", haplotype2Source: "pipeline",
                    baselineHaplotype1: "M4DR", baselineHaplotype2: "-",
                    comment: "=not-a-formula"
                ),
            ],
            sourceRevision: .init(
                assayID: "assay", analysisRevisionID: "revision-7",
                definitionSetID: "definitions"
            ),
            filterContext: ["matrixMinimumReads": "5"]
        )
        let projectionURL = root.appendingPathComponent("viewport.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-10T00:00:00Z")
        sidecar.matrixReviews = [
            .init(target: .cell(locus: "MHC-A", genotype: "01_Middle", sample: "Animal2"), disposition: .falsePositive, author: "analyst", timestamp: "2026-09-10T00:00:01Z"),
            .init(target: .cell(locus: "MHC-A", genotype: "01_Background", sample: "Animal2"), disposition: .falseNegative, author: "analyst", timestamp: "2026-09-10T00:00:02Z"),
        ]
        sidecar.matrixComments = [
            .init(target: .column(sample: "Animal2"), body: "Visible sample note", author: "analyst", timestamp: "2026-09-10T00:00:03Z"),
            .init(target: .row(locus: "MHC-A", genotype: "01_Background"), body: "Visible allele note", author: "analyst", timestamp: "2026-09-10T00:00:04Z"),
            .init(target: .cell(locus: "MHC-A", genotype: "01_Middle", sample: "Animal2"), body: "Visible cell note", author: "analyst", timestamp: "2026-09-10T00:00:05Z"),
            .init(target: .cell(locus: "MHC-A", genotype: "01_Strong", sample: "Animal1"), body: "Hidden note", author: "analyst", timestamp: "2026-09-10T00:00:06Z"),
        ]
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try sidecar.encoded().write(to: annotationURL)
        let outputURL = root.appendingPathComponent("exports/viewport.xlsx")
        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let command = try Command.parse([
            "--bundle", bundleURL.path, "--output", outputURL.path,
            "--view-projection", projectionURL.path, "--annotations", annotationURL.path,
        ])

        try await command.exportFilteredCopy(
            of: sourceURL,
            result: makeResult(bundleURL: bundleURL),
            sidecar: sidecar,
            thresholds: .none,
            projection: projection,
            projectionURL: projectionURL,
            annotationURL: annotationURL,
            capturedInputRecords: [
                ProvenanceRecorder.fileRecord(url: projectionURL, role: .input),
                ProvenanceRecorder.fileRecord(url: annotationURL, role: .input),
            ],
            bundleURL: bundleURL,
            outputURL: outputURL,
            buildDir: buildDir,
            managedPythonResolver: { python },
            startedAt: Date()
        )

        let dump = try await runPython(python, script: Self.dumpWorkbookScript, arguments: [outputURL.path], in: root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any])
        XCTAssertEqual(object["sheets"] as? [String], ["Genotype Matrix", "Haplotype Calls", "Export Metadata"])
        XCTAssertEqual(object["exactCall"] as? [String], ["Animal2", "MHC-DRB", "M4DR", "M4DR", "called", "called"])
        XCTAssertEqual(object["exactComment"] as? String, "=not-a-formula")
        XCTAssertEqual(object["exactCommentType"] as? String, "s")
        XCTAssertEqual(object["maxColumn"] as? Int, 5)
        let rows = try XCTUnwrap(object["rows"] as? [[Any]])
        XCTAssertEqual(Array(rows[0].dropFirst(3)).compactMap { $0 as? String }, ["Animal2", "Animal1"])
        let labels = rows.compactMap { $0.first as? String }
        XCTAssertFalse(labels.contains("01_Strong"))
        XCTAssertTrue(labels.contains("01_Middle"))
        XCTAssertTrue(labels.contains("01_Background"))
        XCTAssertTrue(labels.contains("01_Candidate"), "candidate-only viewport rows survive even without a result call")
        let boundaryRow = try XCTUnwrap(rows.first { $0.first as? String == "01_Candidate" })
        XCTAssertEqual(boundaryRow[3] as? Int, 10)
        XCTAssertTrue(boundaryRow[4] is NSNull, "the projection's filtered one-read cell stays blank")
        XCTAssertFalse(labels.contains("MHC-A alleles"), "typed snapshots do not retain template group/header data")
        XCTAssertLessThan(
            try XCTUnwrap(labels.firstIndex(of: "01_Background")),
            try XCTUnwrap(labels.firstIndex(of: "01_Middle"))
        )
        let falsePositive = try XCTUnwrap(object["[8]"] as? [String: Any])
        XCTAssertEqual(falsePositive["italic"] as? Bool, true)
        XCTAssertTrue((falsePositive["fontColor"] as? String)?.hasSuffix("767676") == true)
        XCTAssertTrue((falsePositive["comment"] as? String)?.contains("Visible cell note") == true)
        let falseNegative = try XCTUnwrap(object["FN"] as? [String: Any])
        XCTAssertEqual(falseNegative["border"] as? String, "mediumDashed")
        XCTAssertTrue((object["Animal2Comment"] as? String)?.contains("Visible sample note") == true)
        XCTAssertTrue((object["01_BackgroundComment"] as? String)?.contains("Visible allele note") == true)
        XCTAssertFalse(dump.contains("Hidden note"))

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
        let inputs = provenance.files + provenance.steps.flatMap(\.inputs)
        XCTAssertTrue(inputs.contains { $0.path == projectionURL.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(inputs.contains { $0.path == annotationURL.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(provenance.argv.contains(projectionURL.path))
        XCTAssertTrue(provenance.argv.contains(annotationURL.path))
        XCTAssertFalse(provenance.argv.contains("--source-workbook"), "auto-resolved inputs belong in resolved options, not exact argv")
        XCTAssertEqual(provenance.options.defaults["viewProjection"], .null)
        XCTAssertEqual(provenance.options.defaults["annotations"], .null)
        XCTAssertEqual(provenance.options.resolvedDefaults["viewProjection"], .file(projectionURL))
        XCTAssertEqual(provenance.options.resolvedDefaults["annotations"], .file(annotationURL))
        XCTAssertEqual(provenance.options.resolvedDefaults["minReads"], .integer(0))
        XCTAssertEqual(provenance.options.resolvedDefaults["percentBasis"], .string("sample-retained"))
        XCTAssertNotNil(provenance.options.resolvedDefaults["transformRuntime"])
        XCTAssertNotNil(provenance.options.resolvedDefaults["transformCommand"])
        let transformStep = try XCTUnwrap(
            provenance.steps.first { $0.toolName == "python/openpyxl pivot transform" }
        )
        XCTAssertEqual(transformStep.exitStatus, 0)
        XCTAssertNotNil(transformStep.wallTimeSeconds)
        XCTAssertEqual(transformStep.runtimeIdentity?.condaEnvironment, "openpyxl")
        XCTAssertEqual(transformStep.inputs.count, 3)
        XCTAssertTrue(transformStep.inputs.allSatisfy { $0.checksumSHA256?.isEmpty == false })
    }

    func testViewportProjectionFindsPublishedCurrentWorkbookMatrixAndMatchesDisplayAliases() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL, "managed openpyxl runtime not installed")
        let root = try TestTempDirectory.make(prefix: "PivotPublishedCurrentWorkbook")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("synthetic-current.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sourceURL = bundleURL.appendingPathComponent("current.xlsx")
        _ = try await runPython(
            python,
            script: Self.makeCurrentWorkbookScript,
            arguments: [
                sourceURL.path,
                Self.currentRawFirst,
                Self.currentRawSecond,
                Self.currentDisplayFirst,
                Self.currentDisplaySecond,
            ],
            in: root
        )

        let projection = GenotypeViewProjection(
            lens: "comparison",
            sampleColumns: ["SyntheticSubjectB", "SyntheticSubjectA"],
            rows: [
                .init(
                    label: "Mafa-DQB1_02:01:01:01",
                    rawGenotype: Self.currentRawSecond,
                    locus: "MHC-DQB1",
                    stableClusterID: "synthetic-stable-second",
                    cells: ["9", ""]
                ),
                .init(
                    label: "Mafa-DQB1_01:01:01:01 / Mafa-DQB1_01:01:02:01",
                    rawGenotype: Self.currentRawFirst,
                    locus: "MHC-DQB1",
                    stableClusterID: "synthetic-stable-first",
                    cells: ["6", "11"]
                ),
            ]
        )
        let projectionURL = root.appendingPathComponent("viewport.json")
        try JSONEncoder().encode(projection).write(to: projectionURL)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-11T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-DQB1",
                    genotype: Self.currentRawSecond,
                    sample: "SyntheticSubjectB",
                    stableClusterID: "synthetic-stable-second"
                ),
                disposition: .falsePositive,
                author: "analyst",
                timestamp: "2026-09-11T00:00:01Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-DQB1",
                    genotype: Self.currentRawFirst,
                    sample: "SyntheticSubjectA",
                    stableClusterID: "synthetic-stable-first"
                ),
                disposition: .falseNegative,
                author: "analyst",
                timestamp: "2026-09-11T00:00:02Z"
            ),
        ]
        sidecar.callOverrides = [
            .init(
                sample: "SyntheticSubjectA", locus: "MHC-DQ", slot: .h1,
                originalCall: "M1DQ", overrideCall: "M6DQ",
                reasonTag: .misCall, rationale: "Synthetic manual review",
                author: "analyst", timestamp: "2026-09-11T00:00:02Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .column(sample: "SyntheticSubjectB"),
                body: "Projected sample note",
                author: "analyst",
                timestamp: "2026-09-11T00:00:03Z"
            ),
            .init(
                target: .row(
                    locus: "MHC-DQB1",
                    genotype: Self.currentRawFirst,
                    stableClusterID: "synthetic-stable-first"
                ),
                body: "Projected first allele note",
                author: "analyst",
                timestamp: "2026-09-11T00:00:04Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-DQB1",
                    genotype: Self.currentRawSecond,
                    sample: "SyntheticSubjectB",
                    stableClusterID: "synthetic-stable-second"
                ),
                body: "Projected second allele cell note",
                author: "analyst",
                timestamp: "2026-09-11T00:00:05Z"
            ),
        ]
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try sidecar.encoded().write(to: annotationURL)
        let outputURL = root.appendingPathComponent("exports/current-viewport.xlsx")
        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let command = try Command.parse([
            "--bundle", bundleURL.path, "--output", outputURL.path,
            "--view-projection", projectionURL.path, "--annotations", annotationURL.path,
        ])

        try await command.exportFilteredCopy(
            of: sourceURL,
            result: makeCurrentWorkbookResult(bundleURL: bundleURL),
            sidecar: sidecar,
            thresholds: .none,
            projection: projection,
            projectionURL: projectionURL,
            annotationURL: annotationURL,
            capturedInputRecords: [
                ProvenanceRecorder.fileRecord(url: projectionURL, role: .input),
                ProvenanceRecorder.fileRecord(url: annotationURL, role: .input),
            ],
            bundleURL: bundleURL,
            outputURL: outputURL,
            buildDir: buildDir,
            managedPythonResolver: { python },
            startedAt: Date()
        )

        let dump = try await runPython(
            python,
            script: Self.dumpCurrentWorkbookScript,
            arguments: [outputURL.path],
            in: root
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any])
        XCTAssertEqual(
            object["sheets"] as? [String],
            ["Interpretation Guide", "Full Sequencing Results 1", "Overrides", "Audit Log"]
        )
        XCTAssertEqual(object["headers"] as? [String], ["SyntheticSubjectB", "SyntheticSubjectA"])
        XCTAssertEqual(
            object["labels"] as? [String],
            ["Mafa-DQB alleles", Self.currentDisplaySecond, Self.currentDisplayFirst],
            "projected rows keep viewport order even though the current workbook stores display aliases"
        )
        let rows = try XCTUnwrap(object["rows"] as? [[Any]])
        XCTAssertEqual(rows[1][1] as? Int, 9)
        XCTAssertEqual(rows[1][2] as? Int, 1)
        XCTAssertEqual(rows[2][1] as? Int, 17)
        XCTAssertEqual(rows[2][2] as? Int, 2)
        XCTAssertEqual(
            object["haplotypeHeaders"] as? [[String]],
            [
                ["M3DQ", "M6DQ"], ["M4DQ", "M2DQ"],
                ["M3DQ", "M6DQ"], ["M4DQ", "M2DQ"],
            ],
            "grouped active DQ calls refresh both recognized split workbook headers"
        )
        XCTAssertEqual(object["haplotypeComment"] as? String, "Native haplotype note")
        let haplotypeColors = try XCTUnwrap(object["haplotypeColors"] as? [String])
        XCTAssertTrue(haplotypeColors[0].hasSuffix("0432FF"), "M3 uses the canonical blue swatch")
        XCTAssertTrue(haplotypeColors[1].hasSuffix("595959"), "the M6 override uses the canonical gray swatch")
        let haplotypeFillTypes = try XCTUnwrap(object["haplotypeFillTypes"] as? [Any])
        XCTAssertTrue(
            haplotypeFillTypes.allSatisfy { $0 is NSNull },
            "refreshed calls clear stale source fills"
        )
        XCTAssertEqual(object["manualCommentsRow"] as? [String], ["Manual call B", "Manual call A"])
        let falsePositive = try XCTUnwrap(object["falsePositive"] as? [String: Any])
        XCTAssertEqual(falsePositive["value"] as? String, "[9]")
        XCTAssertEqual(falsePositive["italic"] as? Bool, true)
        XCTAssertTrue((falsePositive["comment"] as? String)?.contains("Native second allele cell note") == true)
        XCTAssertTrue((falsePositive["comment"] as? String)?.contains("Projected second allele cell note") == true)
        let falseNegative = try XCTUnwrap(object["falseNegative"] as? [String: Any])
        XCTAssertEqual(falseNegative["value"] as? String, "FN")
        XCTAssertEqual(falseNegative["border"] as? String, "mediumDashed")
        XCTAssertFalse(
            (falseNegative["comment"] as? String ?? "").contains("Native first allele note")
        )
        XCTAssertTrue((object["sampleAComment"] as? String)?.contains("Native sample A note") == true)
        XCTAssertTrue((object["sampleBComment"] as? String)?.contains("Native sample B note") == true)
        XCTAssertTrue((object["sampleBComment"] as? String)?.contains("Projected sample note") == true)
        XCTAssertTrue((object["firstAlleleComment"] as? String)?.contains("Native first allele note") == true)
        XCTAssertTrue((object["firstAlleleComment"] as? String)?.contains("Projected first allele note") == true)
        XCTAssertEqual(object["guideComment"] as? String, "Guide comment must survive")
        XCTAssertEqual(object["override"] as? String, "M2DQ")
        XCTAssertEqual(object["audit"] as? String, "synthetic-review")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: outputURL).path))
    }

    func testViewportAnnotationsRequireExactStableClusterIdentity() throws {
        let root = try TestTempDirectory.make(prefix: "PivotStableIdentity")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("thresholds.lungfishgenotype", isDirectory: true)
        let projection = GenotypeViewProjection(
            lens: "comparison",
            sampleColumns: ["Animal1"],
            rows: [
                .init(
                    label: "01_Middle",
                    rawGenotype: "01_Middle",
                    locus: "MHC-A",
                    stableClusterID: "cluster-current",
                    cells: ["40"]
                ),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-10T00:00:00Z")
        sidecar.matrixReviews = [
            .init(
                target: .cell(locus: "MHC-A", genotype: "01_Middle", sample: "Animal1"),
                disposition: .falsePositive,
                author: "legacy",
                timestamp: "2026-09-10T00:00:01Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A", genotype: "01_Middle"),
                body: "Annotation for an obsolete row identity",
                author: "legacy",
                timestamp: "2026-09-10T00:00:02Z"
            ),
        ]

        let plan = Command.FilterPlan.make(
            from: makeResult(bundleURL: bundleURL),
            sidecar: sidecar,
            thresholds: .none,
            projection: projection
        )

        let row = try XCTUnwrap(plan.projectedRows?.first)
        XCTAssertNil(row.comment)
        XCTAssertNil(row.cells.first?.review)
    }
}
