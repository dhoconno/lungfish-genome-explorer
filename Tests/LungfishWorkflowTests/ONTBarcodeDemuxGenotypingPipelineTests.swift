import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTBarcodeDemuxGenotypingPipelineTests: XCTestCase {
    func testRequestDefaultsAnalysisNameToOutputBasenameAndAvoidsDuplicateWorkbookSuffix() {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "barcode08-mhc",
            comparisonWorkbookURL: URL(fileURLWithPath: "/data/pbaa.xlsx")
        )

        XCTAssertEqual(request.analysisName, "barcode08-mhc")
        XCTAssertEqual(request.workbookURL.lastPathComponent, "barcode08-mhc_vs_Illumina-31262.xlsx")
    }

    func testRequestArgvRecordsRerunnableCLIArguments() {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "barcode08-mhc",
            demuxManifestURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq/demux-manifest.json"),
            analysisName: "ONT08",
            comparisonWorkbookURL: URL(fileURLWithPath: "/data/pbaa.xlsx"),
            comparisonName: "Illumina-31262",
            threads: 14,
            sortThreads: 4,
            minSupport: 2,
            extraArguments: ["-N", "50"]
        )

        XCTAssertEqual(request.reportCSVURL.lastPathComponent, "barcode08-mhc.retained-demux-genotypes.csv")
        XCTAssertEqual(request.sampleSummaryCSVURL.lastPathComponent, "barcode08-mhc.retained-demux-samples.csv")
        XCTAssertEqual(request.workbookURL.lastPathComponent, "barcode08-mhc_ONT08_vs_Illumina-31262.xlsx")
        XCTAssertEqual(request.retainedBAMURL.lastPathComponent, "barcode08-mhc.retained.demuxed.bam")
        XCTAssertTrue(request.argv.contains("ont-barcode-genotype"))
        XCTAssertTrue(request.argv.contains("--analysis-name"))
        XCTAssertTrue(request.argv.contains("ONT08"))
        XCTAssertTrue(request.argv.contains("--comparison-workbook"))
        XCTAssertTrue(request.argv.contains("/data/pbaa.xlsx"))
        XCTAssertTrue(request.argv.contains("--comparison-name"))
        XCTAssertTrue(request.argv.contains("Illumina-31262"))
        XCTAssertFalse(request.argv.contains("--require-both-end-softclips"))
        XCTAssertFalse(request.argv.contains("--require-full-reference-span"))
        XCTAssertFalse(request.argv.contains("--allow-indels"))
        XCTAssertFalse(request.argv.contains("--max-mismatches"))
        XCTAssertFalse(request.argv.contains("--demux-retained-reads-only"))
        XCTAssertTrue(request.argv.contains("--extra-args"))
        XCTAssertTrue(request.argv.contains("-N 50"))
    }

    func testRequestDefinesSaneWorkbookNameWithoutComparison() {
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/barcode08.lungfishfastq"),
            referenceSourceURL: URL(fileURLWithPath: "/data/reference.lungfishref"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/data/fluidigm_barcode8.txt"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "barcode08 mhc retained",
            analysisName: "ONT 08"
        )

        XCTAssertEqual(request.outputName, "barcode08-mhc-retained")
        XCTAssertEqual(request.analysisName, "ONT08")
        XCTAssertEqual(request.workbookURL.lastPathComponent, "barcode08-mhc-retained_ONT08.xlsx")
        XCTAssertFalse(request.argv.contains("--comparison-workbook"))
    }

    func testResolveInputFASTQURLsUsesOriginalPathWhenBundleChunksAreMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-barcode-demux-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundle = root.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let original0 = root.appendingPathComponent("original-0.fastq.gz")
        let original1 = root.appendingPathComponent("original-1.fastq.gz")
        try Data("@r0\nACGT\n+\nIIII\n".utf8).write(to: original0)
        try Data("@r1\nTGCA\n+\nIIII\n".utf8).write(to: original1)
        let copied1 = chunks.appendingPathComponent("copied-1.fastq.gz")
        try Data("@r1\nTGCA\n+\nIIII\n".utf8).write(to: copied1)

        let manifest = FASTQSourceFileManifest(files: [
            .init(
                filename: "chunks/missing-0.fastq.gz",
                originalPath: original0.path,
                sizeBytes: 18,
                isSymlink: false
            ),
            .init(
                filename: "chunks/copied-1.fastq.gz",
                originalPath: original1.path,
                sizeBytes: 18,
                isSymlink: false
            ),
        ])
        try manifest.save(to: bundle)

        let resolved = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: bundle)

        XCTAssertEqual(resolved, [original0.standardizedFileURL, copied1.standardizedFileURL])
    }

    func testResolveInputFASTQURLsAcceptsRawFastqPassDirectoryAndSkipsAppleDoubleFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-barcode-demux-fastq-pass-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fastq0 = root.appendingPathComponent("FBC_pass_barcode08_0.fastq.gz")
        let fastq1 = root.appendingPathComponent("FBC_pass_barcode08_1.fastq.gz")
        let appleDouble = root.appendingPathComponent("._FBC_pass_barcode08_1.fastq.gz")
        try Data("@r0\nACGT\n+\nIIII\n".utf8).write(to: fastq0)
        try Data("@r1\nTGCA\n+\nIIII\n".utf8).write(to: fastq1)
        try Data("not a fastq\n".utf8).write(to: appleDouble)

        let resolved = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: root)

        XCTAssertEqual(resolved, [fastq0.standardizedFileURL, fastq1.standardizedFileURL])
    }

    func testReportWorkbookUsesRunBasenameAndFiltersZeroAlleleRows() throws {
        try XCTSkipIf(!pythonCanImportOpenpyxl(), "openpyxl is required for workbook report verification")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("write-report.py")
        let templateURL = root.appendingPathComponent("template.xlsx")
        let genotypesCSV = root.appendingPathComponent("genotypes.csv")
        let samplesCSV = root.appendingPathComponent("samples.csv")
        let statsJSON = root.appendingPathComponent("stats.json")
        let referenceFASTA = root.appendingPathComponent("reference.fa")
        let barcodesCSV = root.appendingPathComponent("barcodes.csv")
        let outputXLSX = root.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        let provenanceJSON = root.appendingPathComponent("report-provenance.json")

        try ONTBarcodeDemuxGenotypingPipeline.writeReportScript(to: scriptURL)
        try makeMinimalComparisonWorkbook(at: templateURL)
        try """
        sample,genotype,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_reads,overall_unique_retained_percent
        DW472,Mafa_F_01_w_06,7,7,100,7,7.0,100,7,7.0
        unassigned,Mafa_F_01_w_06,3,3,,3,,100,10,10.0
        """.write(to: genotypesCSV, atomically: true, encoding: .utf8)
        try """
        sample,passed_alignments,passed_unique_reads,sample_total_reads,sample_unique_retained_percent,overall_input_reads,overall_unique_retained_percent
        DW472,7,7,100,7.0,100,7.0
        DW473,0,0,100,0.0,100,7.0
        unassigned,3,3,,100.0,100,10.0
        """.write(to: samplesCSV, atomically: true, encoding: .utf8)
        try #"{"passedAlignments":7}"#.write(to: statsJSON, atomically: true, encoding: .utf8)
        try ">Mafa_F_01_w_06\nACGT\n>Mafa_F_02\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)
        try "sample,barcode\nDW472,ACGT\nDW473,TGCA\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)

        _ = try runPython([
            scriptURL.path,
            "--genotypes-csv", genotypesCSV.path,
            "--samples-csv", samplesCSV.path,
            "--stats-json", statsJSON.path,
            "--reference-fasta", referenceFASTA.path,
            "--barcode-definitions", barcodesCSV.path,
            "--output-xlsx", outputXLSX.path,
            "--provenance-json", provenanceJSON.path,
            "--analysis-name", "barcode08-mhc",
            "--run-name", "barcode08-mhc",
            "--comparison-workbook", templateURL.path,
            "--comparison-name", "Illumina-31262",
        ])

        let inspection = try inspectWorkbook(outputXLSX)
        XCTAssertEqual(inspection["sheetnames"] as? [String], [
            "barcode08-mhc",
            "Illumina-31262",
            "barcode08-mhc Long Summary",
            "barcode08-mhc Sample Summary",
            "Illumina-31262 Audit",
            "Run Stats",
        ])
        XCTAssertEqual(inspection["readCountLabel"] as? String, "Filtered exact-match read count")
        XCTAssertEqual(inspection["hasTotalReadCountRow"] as? Bool, false)
        XCTAssertEqual(inspection["hasPercentRetainedRow"] as? Bool, false)
        XCTAssertEqual(inspection["haplotypeSampleCellsAreBlank"] as? Bool, true)
        XCTAssertEqual(inspection["commentsSampleCellsAreBlank"] as? Bool, true)
        XCTAssertEqual(inspection["hasKeptAllele"] as? Bool, true)
        XCTAssertEqual(inspection["hasZeroAllele"] as? Bool, false)
        XCTAssertEqual(inspection["hasEmptyLocusHeader"] as? Bool, false)
        XCTAssertEqual(inspection["analysisSampleColumns"] as? [String], ["DW472"])
        XCTAssertEqual(inspection["keptAlleleDW472Count"] as? Int, 7)
        XCTAssertEqual(inspection["readCountTotal"] as? Int, 7)
        XCTAssertEqual(inspection["readCountAverage"] as? Double, 7.0)
        XCTAssertEqual(inspection["keptAlleleSubtotal"] as? Int, 7)
        XCTAssertEqual(inspection["keptAlleleObservedSamples"] as? Int, 1)
        XCTAssertEqual(inspection["formulaCellsInAnalysisSummary"] as? [String], [])
        XCTAssertEqual(inspection["containsUnassignedInWorkbook"] as? Bool, false)
    }

    private func pythonCanImportOpenpyxl() -> Bool {
        (try? runPython(["-c", "import openpyxl"])) != nil
    }

    private func makeMinimalComparisonWorkbook(at url: URL) throws {
        let code = #"""
import sys
from openpyxl import Workbook
from openpyxl.styles import Font

path = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "31262_MiSeq255_Kenyon20_pivot"
values = {
    (1, 1): "Animal ID", (1, 4): "Animal A", (1, 5): "Animal B",
    (2, 1): "GS ID", (2, 2): "Total", (2, 3): "Average", (2, 4): "DW472", (2, 5): "DW473",
    (3, 1): "Mapped Read Count", (3, 2): "=SUM(D3:E3)", (3, 3): "=AVERAGE(D3:E3)", (3, 4): 10, (3, 5): 20,
    (4, 1): "total_read_count", (4, 4): 100, (4, 5): 100,
    (5, 1): "percent_reads_unmapped", (5, 4): 90, (5, 5): 80,
    (6, 1): "MHC-A Haplotype 1", (6, 4): "M1A", (6, 5): "M2A",
    (7, 1): "MHC-A Haplotype 2", (7, 4): "M1A", (7, 5): "M2A",
    (8, 1): "MHC-B Haplotype 1", (9, 1): "MHC-B Haplotype 2",
    (10, 1): "MHC-DRB Haplotype 1", (11, 1): "MHC-DRB Haplotype 2",
    (12, 1): "MHC-DQA Haplotype 1", (13, 1): "MHC-DQA Haplotype 2",
    (14, 1): "MHC-DQB Haplotype 1", (15, 1): "MHC-DQB Haplotype 2",
    (16, 1): "MHC-DPA Haplotype 1", (17, 1): "MHC-DPA Haplotype 2",
    (18, 1): "MHC-DPB Haplotype 1", (19, 1): "MHC-DPB Haplotype 2",
    (20, 1): "Comments", (20, 2): "Subtotal", (20, 3): "# Obs.", (20, 4): "template comment",
    (21, 1): "Mafa-F alleles",
    (22, 1): "01_M1_F_01_w_06", (22, 2): "=SUM(D22:E22)", (22, 3): "=COUNT(D22:E22)",
    (23, 1): "01_M2_F_02", (23, 2): "=SUM(D23:E23)", (23, 3): "=COUNT(D23:E23)",
    (24, 1): "Mafa-G alleles",
    (25, 1): "02_M1_G_01", (25, 2): "=SUM(D25:E25)", (25, 3): "=COUNT(D25:E25)",
}
for (row, col), value in values.items():
    ws.cell(row, col).value = value
for row in [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,24]:
    ws.cell(row, 1).font = Font(bold=True)
wb.save(path)
"""#
        _ = try runPython(["-c", code, url.path])
    }

    private func inspectWorkbook(_ url: URL) throws -> [String: Any] {
        let code = #"""
import json
import sys
from openpyxl import load_workbook

wb = load_workbook(sys.argv[1], data_only=False)
ws = wb[wb.sheetnames[0]]

def row_for(label):
    for row in range(1, ws.max_row + 1):
        if ws.cell(row, 1).value == label:
            return row
    return None

kept = row_for("01_M1_F_01_w_06")
hap = row_for("MHC-A Haplotype 1")
comments = row_for("Comments")
payload = {
    "sheetnames": wb.sheetnames,
    "readCountLabel": ws.cell(3, 1).value,
    "hasTotalReadCountRow": row_for("total_read_count") is not None,
    "hasPercentRetainedRow": row_for("percent_reads_retained_after_filtering") is not None,
    "haplotypeSampleCellsAreBlank": all(ws.cell(hap, col).value is None for col in range(4, 6)) if hap else False,
    "commentsSampleCellsAreBlank": all(ws.cell(comments, col).value is None for col in range(4, 6)) if comments else False,
    "hasKeptAllele": kept is not None,
    "hasZeroAllele": row_for("01_M2_F_02") is not None,
    "hasEmptyLocusHeader": row_for("Mafa-G alleles") is not None,
    "analysisSampleColumns": [
        ws.cell(2, col).value
        for col in range(4, ws.max_column + 1)
        if ws.cell(2, col).value is not None
    ],
    "keptAlleleDW472Count": ws.cell(kept, 4).value if kept else None,
    "readCountTotal": ws.cell(3, 2).value,
    "readCountAverage": ws.cell(3, 3).value,
    "keptAlleleSubtotal": ws.cell(kept, 2).value if kept else None,
    "keptAlleleObservedSamples": ws.cell(kept, 3).value if kept else None,
    "formulaCellsInAnalysisSummary": [
        f"{cell.coordinate}:{cell.value}"
        for row in ws.iter_rows()
        for cell in row
        if isinstance(cell.value, str) and cell.value.startswith("=")
    ],
    "containsUnassignedInWorkbook": any(
        str(cell.value).strip().lower() == "unassigned"
        for sheet in wb.worksheets
        for row in sheet.iter_rows()
        for cell in row
        if cell.value is not None
    ),
}
print(json.dumps(payload))
"""#
        let output = try runPython(["-c", code, url.path])
        let data = Data(output.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func runPython(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ONTBarcodeDemuxGenotypingPipelineTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err]
            )
        }
        return out
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTBarcodeDemuxGenotypingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
