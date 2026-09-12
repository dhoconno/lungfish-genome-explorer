import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishCLI

/// Covers the filtered Excel export as a three-sheet snapshot of the settled
/// LGE projection. Legacy source workbooks remain fixtures only: their extra
/// worksheets and presentation geometry do not flow into the export.
final class GenotypePivotFilteredCopyTests: XCTestCase {
    func testSparseSampleRosterDoesNotAttestMissingFilteredCellSupport() throws {
        let base = makeResult(bundleURL: URL(fileURLWithPath: "/tmp/synthetic-sparse-pairs.lungfishgenotype"))
        let calls = [("S1", "G", 5), ("S2", "Z", 0)].map { sample, genotype, reads in
            ONTGenotypeCall(sample: sample, genotype: genotype, passedAlignments: reads, passedUniqueReads: reads, sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil, overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil)
        }
        let result = ONTGenotypeResultBundleData(bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts, stats: base.stats, calls: calls, samples: [], haplotypeAnalysis: nil)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        sidecar.matrixReviews = ["G", "Z"].map {
                .init(target: .cell(locus: "MHC-\($0)", genotype: $0, sample: "S2"), disposition: .falseNegative, author: "A", timestamp: "now")
        }
        let original = try sidecar.encoded()
        let projection = GenotypeViewProjection(lens: "allele", sampleColumns: ["S1", "S2"], rows: [
            .init(label: "G", rawGenotype: "G", locus: "MHC-G", cells: ["5", ""]),
            .init(label: "Z", rawGenotype: "Z", locus: "MHC-Z", cells: ["", "0"])
        ])
        let payload = try Command().filteredPresentation(result: result, sidecar: sidecar, thresholds: .init(), projection: projection)
        let missing = try XCTUnwrap(payload.rows.first { $0.target.genotype == "G" }?.cells.first { $0.sampleID == "S2" })
        XCTAssertNil(missing.rawSupport)
        XCTAssertNil(missing.displayValue)
        XCTAssertNil(missing.review)
        XCTAssertFalse(missing.reviewEligible)
        let zero = try XCTUnwrap(payload.rows.first { $0.target.genotype == "Z" }?.cells.first { $0.sampleID == "S2" })
        XCTAssertEqual(zero.rawSupport, 0)
        XCTAssertTrue(zero.reviewEligible)
        XCTAssertEqual(zero.review, "false-negative")
        XCTAssertEqual(try sidecar.encoded(), original)
    }

    func testThreeSheetFilteredUsesObservedRawSupportWithoutCatalogAndNeverCapturedMaskOrOtherStableIdentity() throws {
        let base = makeResult(bundleURL: URL(fileURLWithPath: "/tmp/synthetic-observed-review.lungfishgenotype"))
        let zero = ONTGenotypeCall(sample: "Animal1", genotype: "01_Mafa_A1_Zero", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil, overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil)
        let positive = ONTGenotypeCall(sample: "Animal1", genotype: "01_Mafa_A1_Strong", passedAlignments: 500, passedUniqueReads: 500, sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil, overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil)
        let result = ONTGenotypeResultBundleData(bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts, stats: base.stats, calls: [positive, zero], samples: base.samples, haplotypeAnalysis: nil)
        let targets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .cell(locus: "MHC-A", genotype: "01_Mafa_A1_Strong", sample: "Animal1"),
            .cell(locus: "MHC-A", genotype: "01_Mafa_A1_Zero", sample: "Animal1"),
            .cell(locus: "MHC-A", genotype: "01_Unknown", sample: "Animal1"),
            .cell(locus: "MHC-A", genotype: "01_Mafa_A1_Strong", sample: "Animal1", stableClusterID: "other-cluster")
        ]
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        sidecar.matrixReviews = zip(targets, [GenotypeAnnotationSidecar.MatrixReviewDisposition.falsePositive, .falseNegative, .falseNegative, .falsePositive]).map {
            .init(target: $0, disposition: $1, author: "A", timestamp: "now")
        }
        let projection = GenotypeViewProjection(lens: "allele", sampleColumns: ["Animal1"], rows: [
            .init(label: "Masked positive", rawGenotype: "01_Mafa_A1_Strong", locus: "MHC-A", cells: [""]),
            .init(label: "Masked zero", rawGenotype: "01_Mafa_A1_Zero", locus: "MHC-A", cells: [""]),
            .init(label: "Unknown", rawGenotype: "01_Unknown", locus: "MHC-A", cells: [""]),
            .init(label: "Other stable identity", rawGenotype: "01_Mafa_A1_Strong", locus: "MHC-A", stableClusterID: "other-cluster", cells: [""])
        ])
        let payload = try Command().filteredPresentation(result: result, sidecar: sidecar, thresholds: .init(minimumReads: 1000), projection: projection)
        let cells = payload.rows.flatMap(\.cells)
        XCTAssertEqual(cells.map(\.rawSupport), [500, 0, nil, nil])
        XCTAssertEqual(cells.map(\.review), ["false-positive", "false-negative", nil, nil])
        XCTAssertTrue(cells.allSatisfy { $0.displayValue == nil })
        XCTAssertEqual(sidecar.matrixReviews.count, 4)
    }

    func testThreeSheetFilteredWithholdsConflictingAndUnsupportedReviewsDespiteCapturedMask() throws {
        let base = makeResult(bundleURL: URL(fileURLWithPath: "/tmp/synthetic-review.lungfishgenotype"))
        let support = ["fp": 5, "fn": 0, "fn-positive": 5, "fp-zero": 0, "duplicate": 5, "conflict": 5]
        let catalog = GenotypeReviewableRowCatalog(samples: support.keys.sorted(), rows: [.init(kind: .reference, callID: "raw", displayName: "Display", locus: "MHC-A", stableID: nil, section: "reference", sortKey: "raw", supportBySample: support)])
        let result = ONTGenotypeResultBundleData(bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts, stats: base.stats, calls: base.calls, samples: base.samples, haplotypeAnalysis: nil, mhcCandidates: nil, mhcUnnameableClusters: nil, mhcCandidateSequencesByStableClusterID: [:], mhcCandidateGenBankArtifactURLs: .empty, mhcAlignmentArtifactURLs: .empty, mhcReferenceVisualizations: nil, integrityWarnings: [], referenceMetadata: nil, provisionalExon2SequencesByGenotype: [:], provisionalExon2ArtifactURLs: .empty, reviewableRowCatalog: catalog)
        let samples = support.keys.sorted() + ["unknown-fp", "unknown-fn"]
        let projection = GenotypeViewProjection(lens: "allele", sampleColumns: samples, rows: [.init(label: "Display", rawGenotype: "raw", locus: "MHC-A", cells: Array(repeating: "", count: samples.count))])
        for reverse in [false, true] {
            var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
            let cases: [(String, GenotypeAnnotationSidecar.MatrixReviewDisposition)] = [("fp", .falsePositive), ("fn", .falseNegative), ("fn-positive", .falseNegative), ("fp-zero", .falsePositive), ("unknown-fp", .falsePositive), ("unknown-fn", .falseNegative), ("duplicate", .falsePositive), ("duplicate", .falsePositive), ("conflict", .falseNegative), ("conflict", .falsePositive)]
            sidecar.matrixReviews = cases.enumerated().map { index, value in
                .init(target: .cell(locus: "MHC-A", genotype: "raw", sample: value.0), disposition: value.1, author: "tester", timestamp: "2026-09-12T00:00:\(String(format: "%02d", index))Z")
            }
            if reverse { sidecar.matrixReviews.reverse() }
            let payload = try Command().filteredPresentation(result: result, sidecar: sidecar, thresholds: .init(minimumReads: 5), projection: projection)
            let cells = try XCTUnwrap(payload.rows.first).cells
            XCTAssertTrue(cells.allSatisfy { $0.displayValue == nil })
            XCTAssertEqual(cells.first { $0.sampleID == "fp" }?.review, "false-positive")
            XCTAssertEqual(cells.first { $0.sampleID == "fn" }?.review, "false-negative")
            for cell in cells where !["fp", "fn"].contains(cell.sampleID) { XCTAssertNil(cell.review, cell.sampleID) }
            XCTAssertEqual(sidecar.matrixReviews.count, 10)
        }
    }

    func testThreeSheetHeadlessResolvesCustomActiveDefinitionPalette() throws {
        let root = try TestTempDirectory.make(prefix: "HeadlessPalette")
        defer { TestTempDirectory.cleanup(root) }
        let definition = GenotypeHaplotypeDefinitionSet(id: "synthetic-definition", assayID: "synthetic-assay", displayName: "Synthetic", speciesName: "Synthetic", speciesCode: "Syn", prefix: "S", locusDefinitions: [
            .init(locus: "MHC-DQ", sourceLocus: "MHC-DQ", haplotypes: [.init(name: "M1DQ", diagnosticAlleles: [], colorOverride: .init(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))])
        ])
        let inputs = root.appendingPathComponent(".ont-barcode-genotyping/inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try JSONEncoder().encode(definition).write(to: inputs.appendingPathComponent("haplotype-definition.json"))
        let payload = try Command().filteredPresentation(result: makeCurrentWorkbookResult(bundleURL: root), sidecar: nil, thresholds: .init(minimumReads: 5), projection: nil)
        let color = try XCTUnwrap(payload.colors.first { $0.locus == "MHC-DQ" && $0.call == "M1DQ" })
        XCTAssertEqual(color.fillHex.uppercased(), "#336699")
        XCTAssertEqual(color.fontHex, "#FFFFFF")
    }

    func testThreeSheetHeadlessManualCallsPreserveUnavailableBaselineAndSlotSources() throws {
        let root = try TestTempDirectory.make(prefix: "ManualDefinitionAuthority")
        defer { TestTempDirectory.cleanup(root) }
        let result = makeResult(bundleURL: root, kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue)
        let definition = GenotypeHaplotypeDefinitionSet(id: "manual-test", assayID: "manual-assay", displayName: "Manual test", speciesName: "Synthetic", speciesCode: "Syn", prefix: "S", locusDefinitions: [.init(locus: "MHC-A", sourceLocus: "MHC-A", haplotypes: [.init(name: "Not the manual label", diagnosticAlleles: ["01_Strong"])])])
        let inputs = root.appendingPathComponent(".ont-barcode-genotyping/inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try JSONEncoder().encode(definition).write(to: inputs.appendingPathComponent("haplotype-definition.json"))
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        sidecar.manualHaplotypeAssignments = [.init(sample: "Animal1", locus: "MHC-A", slot: .h1, label: "Exact manual", colorTokenIndex: 0, diagnosticAlleles: [], notes: "Analyst note")]
        XCTAssertNotNil(GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: result, sidecar: sidecar), "The fixture must trigger the competing resolvable-analysis branch")
        let payload = try Command().filteredPresentation(result: result, sidecar: sidecar, thresholds: .init(minimumReads: 5), projection: nil)
        let call = try XCTUnwrap(payload.calls.first { $0.sampleID == "Animal1" && $0.locus == "MHC-A" })
        XCTAssertEqual(call.h1.effective, "Exact manual")
        XCTAssertEqual(call.h1.source, "manualAssignment")
        XCTAssertEqual(call.h2.source, "unassigned")
        XCTAssertNil(call.h1.pipeline)
        XCTAssertNil(call.h2.pipeline)
        XCTAssertFalse(call.h1.baselineAvailable)
        XCTAssertFalse(call.h2.baselineAvailable)
        XCTAssertEqual(call.comment, "Analyst note")
    }

    func testThreeSheetFilteredPreservesCapturedMaskAndHeadlessThresholdBoundary() async throws {
        let python = try XCTUnwrap(Self.managedPythonURL)
        let root = try TestTempDirectory.make(prefix: "ThreeSheetFiltered")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("test.lungfishgenotype")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let source = bundle.appendingPathComponent("source.xlsx")
        _ = try await runPython(python, script: Self.makeSourceWorkbookScript, arguments: [source.path], in: root)
        let rawCSV = bundle.appendingPathComponent("g.csv")
        try "sample,genotype,passed_alignments,passed_unique_reads\nAnimal1,01_Strong,1000,500\nAnimal1,01_Middle,80,40\nAnimal1,01_Background,10,5\nAnimal2,01_Strong,120,60\nAnimal2,01_Middle,16,8\n".write(to: rawCSV, atomically: true, encoding: .utf8)
        for captured in [true, false] {
            let build = root.appendingPathComponent("build-\(captured)")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            let output = root.appendingPathComponent("export-\(captured).xlsx")
            let command = try Command.parse(["--bundle", bundle.path, "--output", output.path, "--min-reads", "5"])
            let projection: GenotypeViewProjection? = captured ? .init(lens: "allele", sampleColumns: ["Animal1", "Animal2"], rows: [
                .init(label: "Captured", rawGenotype: "01_Strong", locus: "MHC-A", cells: ["1", ""]),
                .init(label: "Settled min5", rawGenotype: "01_Middle", locus: "MHC-A", cells: ["", "5"]),
            ], haplotypeCalls: [.init(sample: "Animal1", locus: "MHC-A", haplotype1: "Exact1", haplotype2: "Exact2", haplotype1Status: "called", haplotype2Status: "called", haplotype1Source: "pipeline", haplotype2Source: "pipeline", baselineHaplotype1: "Exact1", baselineHaplotype2: "Exact2")]) : nil
            try await command.exportFilteredCopy(of: captured ? source : nil, result: makeResult(bundleURL: bundle), sidecar: nil, thresholds: .init(minimumReads: 5), projection: projection, bundleURL: bundle, outputURL: output, buildDir: build, managedPythonResolver: { python }, startedAt: Date())
            try FileManager.default.removeItem(at: build)
            let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: output)))
            let rawInput = try XCTUnwrap(envelope.files.first { $0.path.hasSuffix("/g.csv") && $0.role == .input })
            XCTAssertEqual(rawInput.checksumSHA256, try ProvenanceFileHasher.sha256(of: rawCSV))
            XCTAssertEqual(rawInput.fileSize, try ProvenanceFileHasher.fileSize(of: rawCSV))
            let retainedInputs = envelope.steps.flatMap(\.inputs).filter { $0.path.hasSuffix(".py") || $0.path.hasSuffix("presentation-payload.json") }
            XCTAssertFalse(retainedInputs.isEmpty)
            XCTAssertTrue(retainedInputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Renderer and payload must survive build-directory cleanup")
            _ = try await runPython(python, script: #"""
import sys
from openpyxl import load_workbook
w=load_workbook(sys.argv[1]); c=load_workbook(sys.argv[1],data_only=True)
assert w.sheetnames==['Genotype Matrix','Haplotype Calls','Export Metadata'],w.sheetnames
m=w['Genotype Matrix']
if sys.argv[2]=='true':
    row=next(r for r in m if r[2].value=='Captured')
    assert row[3].value==1 and row[4].value is None
    settled=next(r for r in m if r[2].value=='Settled min5')
    assert settled[3].value is None and settled[4].value==5
    formulas=[x for r in m for x in r if x.data_type=='f']
    assert [c[m.title][x.coordinate].value for x in formulas]==['Exact1','Exact2']
else:
    row=next(r for r in m if r[2].value=='01_Background')
    assert row[3].value==5 and row[4].value is None
print('three-sheet filtered contract')
"""#, arguments: [output.path, String(captured)], in: root)
        }
    }

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
pivot["A23"].fill = PatternFill("solid", fgColor="FF2468AC")
pivot["D23"].fill = PatternFill("solid", fgColor="FF13579B")
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
matrix = wb["Genotype Matrix"]
out = {"sheets": wb.sheetnames, "freeze": matrix.freeze_panes,
       "maxColumn": matrix.max_column,
       "rows": [[c for c in row] for row in matrix.iter_rows(values_only=True)]}
calls = wb["Haplotype Calls"]
exact = next((row for row in range(2, calls.max_row + 1)
              if calls.cell(row, 2).value == "Animal2" and calls.cell(row, 3).value == "MHC-DRB"), None)
if exact:
    out["exactCall"] = [calls.cell(exact, column).value for column in (2, 3, 4, 9, 6, 11)]
    out["exactComment"] = calls.cell(exact, 14).value
    out["exactCommentType"] = calls.cell(exact, 14).data_type
for row in range(2, matrix.max_row + 1):
    if matrix.cell(row, 3).value in ("01_Candidate", "Compact candidate"):
        out["candidateRowFill"] = matrix.cell(row, 3).fill.fgColor.rgb
        out["candidateCellFill"] = matrix.cell(row, 4).fill.fgColor.rgb
        out["candidateBlankFillType"] = matrix.cell(row, 5).fill.fill_type
for row in range(2, matrix.max_row + 1):
    label = matrix.cell(row, 3).value
    if label == "01_Middle":
        cell = matrix.cell(row, 4)
        out["falsePositive"] = {"value": cell.value, "comment": "" if cell.comment is None else cell.comment.text}
    if label == "01_Background":
        cell = matrix.cell(row, 4)
        out["falseNegative"] = {"value": cell.value, "comment": "" if cell.comment is None else cell.comment.text}
        out["01_BackgroundComment"] = "" if matrix.cell(row, 3).comment is None else matrix.cell(row, 3).comment.text
out["Animal2Comment"] = "" if matrix["D1"].comment is None else matrix["D1"].comment.text
print(json.dumps(out))
"""#

    private static let dumpCurrentWorkbookScript = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1])
ws = wb["Genotype Matrix"]
calls = wb["Haplotype Calls"]
call_rows = {
    (calls.cell(row, 2).value, calls.cell(row, 3).value): [
        calls.cell(row, 4).value, calls.cell(row, 9).value
    ]
    for row in range(2, calls.max_row + 1)
}
evidence_header = next(row for row in range(2, ws.max_row + 1) if ws.cell(row, 3).value == "Allele")
evidence_rows = list(range(evidence_header + 1, ws.max_row + 1))
sample_columns = {ws.cell(1, column).value: column for column in range(4, ws.max_column + 1)}
def note(cell): return cell.comment.text if cell.comment else None
out = {
    "sheets": wb.sheetnames,
    "headers": [ws.cell(1, column).value for column in range(4, ws.max_column + 1)],
    "labels": [ws.cell(row, 3).value for row in evidence_rows],
    "rows": [[ws.cell(row, column).value for column in range(1, ws.max_column + 1)] for row in evidence_rows],
    "sampleAComment": note(ws.cell(1, sample_columns["SyntheticSubjectA"])),
    "sampleBComment": note(ws.cell(1, sample_columns["SyntheticSubjectB"])),
    "calls": {sample: values for (sample, locus), values in call_rows.items() if locus == "MHC-DQ"},
}
for row in evidence_rows:
    label = ws.cell(row, 3).value
    if label == "Mafa-DQB1_02:01:01:01":
        out["falsePositive"] = {"value": ws.cell(row, sample_columns["SyntheticSubjectB"]).value,
                                "comment": note(ws.cell(row, sample_columns["SyntheticSubjectB"]))}
    if label == "Mafa-DQB1_01:01:01:01 / Mafa-DQB1_01:01:02:01":
        out["falseNegative"] = {"value": ws.cell(row, sample_columns["SyntheticSubjectA"]).value,
                                "comment": note(ws.cell(row, sample_columns["SyntheticSubjectA"]))}
        out["firstAlleleComment"] = note(ws.cell(row, 3))
print(json.dumps(out))
"""#

    private func makeResult(bundleURL: URL, kind: String = "ont-barcode-genotype") -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            kind: kind, outputName: "thresholds", analysisName: "Thresholds",
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

    func testFilteredCopyWritesThreeSheetSnapshotAndFiltersOnlyTheEvidenceMatrix() async throws {
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
        XCTAssertEqual(object["sheets"] as? [String], ["Genotype Matrix", "Haplotype Calls", "Export Metadata"])
        let rows = try XCTUnwrap(object["rows"] as? [[Any]])
        let labels = rows.compactMap { $0.count > 2 ? $0[2] as? String : nil }
        XCTAssertEqual(Array(rows[0].dropFirst(3)).compactMap { $0 as? String }, ["Animal1", "Animal2"])
        XCTAssertTrue(labels.contains("01_Strong"))
        XCTAssertTrue(labels.contains("01_Middle"))
        XCTAssertFalse(labels.contains("01_Background"), "a row with nothing above the threshold is removed")
        let middle = try XCTUnwrap(rows.first { $0.count > 2 && ($0[2] as? String) == "01_Middle" })
        XCTAssertEqual(middle[3] as? Int, 40)
        XCTAssertTrue(middle[4] is NSNull, "Animal2's 8 reads fall below 10 and are blanked")
        let strong = try XCTUnwrap(rows.first { $0.count > 2 && ($0[2] as? String) == "01_Strong" })
        XCTAssertEqual(strong[3] as? Int, 500)
        XCTAssertEqual(strong[4] as? Int, 60)

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
        _ = try await runPython(python, script: #"""
import sys
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import Font, Border, Side
w=load_workbook(sys.argv[1]); s=w.active
for cell in ('A16','D2','D16','E16'):
    s[cell].comment=Comment('[LGE Matrix Comments]\nBody: cleared managed note', 'Lungfish')
s['D16'].font=Font(italic=True,color='FF767676')
s['E16'].font=Font(bold=True,color='FF7F6000')
edge=Side(style='mediumDashed',color='FFC65911')
s['E16'].border=Border(left=edge,right=edge,top=edge,bottom=edge)
w.save(sys.argv[1])
"""#, arguments: [sourceURL.path], in: root)

        let projection = GenotypeViewProjection(
            lens: "comparison",
            sampleColumns: ["Animal2", "Animal1"],
            rows: [
                .init(
                    label: "01_Background", rawGenotype: "01_Background", locus: "MHC-A",
                    cells: ["", "5"], cellColorsHex: ["#111111", nil]
                ),
                .init(
                    label: "Compact candidate", rawGenotype: "01_Candidate",
                    locus: "MHC-A", stableClusterID: "candidate-1",
                    cells: ["10", ""],
                    cellColorsHex: ["#123456", nil],
                    rowColorHex: "#ABCDEF"
                ),
                .init(
                    label: "01_Middle", rawGenotype: "01_Middle", locus: "MHC-A",
                    cells: ["8", "40"], cellColorsHex: ["#654321", nil]
                ),
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
        let labels = rows.compactMap { $0.count > 2 ? $0[2] as? String : nil }
        XCTAssertFalse(labels.contains("01_Strong"))
        XCTAssertTrue(labels.contains("01_Middle"))
        XCTAssertTrue(labels.contains("01_Background"))
        XCTAssertTrue(labels.contains("Compact candidate"), "captured display labels remain distinct from raw identity")
        let boundaryRow = try XCTUnwrap(rows.first { $0.count > 2 && $0[2] as? String == "Compact candidate" })
        XCTAssertEqual(boundaryRow[3] as? Int, 10)
        XCTAssertTrue(boundaryRow[4] is NSNull, "the projection's filtered one-read cell stays blank")
        XCTAssertTrue((object["candidateCellFill"] as? String)?.hasSuffix("123456") == true)
        XCTAssertTrue((object["candidateRowFill"] as? String)?.hasSuffix("ABCDEF") == true)
        XCTAssertTrue(object["candidateBlankFillType"] is NSNull)
        XCTAssertFalse(labels.contains("MHC-A alleles"), "typed snapshots do not retain template group/header data")
        XCTAssertLessThan(
            try XCTUnwrap(labels.firstIndex(of: "01_Background")),
            try XCTUnwrap(labels.firstIndex(of: "01_Middle"))
        )
        let falsePositive = try XCTUnwrap(object["falsePositive"] as? [String: Any])
        XCTAssertEqual(falsePositive["value"] as? Int, 8)
        XCTAssertFalse((falsePositive["comment"] as? String ?? "").contains("Current review:"), "without attested raw support the captured display value cannot authorize a review")
        XCTAssertTrue((falsePositive["comment"] as? String)?.contains("Visible cell note") == true)
        let falseNegative = try XCTUnwrap(object["falseNegative"] as? [String: Any])
        XCTAssertTrue(falseNegative["value"] is NSNull)
        XCTAssertFalse((falseNegative["comment"] as? String ?? "").contains("Current review:"), "an absent display value is not attested zero support")
        XCTAssertTrue((object["Animal2Comment"] as? String)?.contains("Visible sample note") == true)
        XCTAssertTrue((object["01_BackgroundComment"] as? String)?.contains("Visible allele note") == true)
        XCTAssertFalse(dump.contains("Hidden note"))
        _ = try await runPython(python, script: #"""
import sys
from openpyxl import load_workbook
w=load_workbook(sys.argv[1]); s=w['Genotype Matrix']
r=next(row for row in s if row[2].value=='Compact candidate')
assert r[2].comment is None
assert all(c.comment is not None and c.comment.text.startswith('Evidence:') for c in r[3:5])
assert all('Current comment:' not in c.comment.text and 'Current review:' not in c.comment.text for c in r[3:5])
assert s['E1'].comment is None
"""#, arguments: [outputURL.path], in: root)

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
        XCTAssertEqual(object["sheets"] as? [String], ["Genotype Matrix", "Haplotype Calls", "Export Metadata"])
        XCTAssertEqual(object["headers"] as? [String], ["SyntheticSubjectB", "SyntheticSubjectA"])
        XCTAssertEqual(
            object["labels"] as? [String],
            ["Mafa-DQB1_02:01:01:01", "Mafa-DQB1_01:01:01:01 / Mafa-DQB1_01:01:02:01"],
            "projected rows keep viewport order even though the current workbook stores display aliases"
        )
        let rows = try XCTUnwrap(object["rows"] as? [[Any]])
        XCTAssertEqual(rows[0][3] as? Int, 9)
        XCTAssertTrue(rows[0][4] is NSNull)
        XCTAssertEqual(rows[1][3] as? Int, 6)
        XCTAssertEqual(rows[1][4] as? Int, 11)
        let calls = try XCTUnwrap(object["calls"] as? [String: [String]])
        XCTAssertTrue(calls.isEmpty, "a captured projection with no haplotype rows must not rerun inference or inject a sidecar override")
        let falsePositive = try XCTUnwrap(object["falsePositive"] as? [String: Any])
        XCTAssertEqual(falsePositive["value"] as? Int, 9)
        XCTAssertFalse((falsePositive["comment"] as? String ?? "").contains("Current review:"), "legacy display values are not attested raw support")
        XCTAssertTrue((falsePositive["comment"] as? String)?.contains("Projected second allele cell note") == true)
        let falseNegative = try XCTUnwrap(object["falseNegative"] as? [String: Any])
        XCTAssertEqual(falseNegative["value"] as? Int, 11)
        XCTAssertFalse((falseNegative["comment"] as? String ?? "").contains("Current review:"), "a positive captured value cannot become a false negative")
        XCTAssertNil(object["sampleAComment"] as? String)
        XCTAssertTrue((object["sampleBComment"] as? String)?.contains("Projected sample note") == true)
        XCTAssertTrue((object["firstAlleleComment"] as? String)?.contains("Projected first allele note") == true)
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
