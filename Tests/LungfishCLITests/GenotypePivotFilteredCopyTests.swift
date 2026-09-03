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
ws.append(["01_Strong", 560, 2, 500, 60])
ws.append(["01_Middle", 48, 2, 40, 8])
ws.append(["01_Background", 5, 1, 5, None])
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

    private static let dumpWorkbookScript = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1])
out = {"sheets": wb.sheetnames, "freeze": wb.worksheets[0].freeze_panes,
       "widthA": wb.worksheets[0].column_dimensions["A"].width,
       "boldA1": wb.worksheets[0]["A1"].font.bold,
       "fillA1": wb.worksheets[0]["A1"].fill.fgColor.rgb,
       "rows": [[c for c in row] for row in wb.worksheets[0].iter_rows(values_only=True)],
       "long": [[c for c in row] for row in wb["Thresholds Long Summ"].iter_rows(values_only=True)]}
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
}
