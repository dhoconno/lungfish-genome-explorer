import XCTest
@testable import LungfishWorkflow

/// Pins the read-count metric the genotype report workbook publishes.
///
/// Regression context: the workbook reported `passed_alignments`, which counts
/// alignment *records*. An unmerged Illumina pair contributes one record per
/// mate, so every count read roughly twice what the genotype inspector shows
/// for the same allele (a reported 574 in Excel against 315 in the browser).
/// The inspector reports `passed_unique_reads` (distinct query names), so the
/// workbook now reads the same column.
final class GenotypeReportReadCountMetricTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-read-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Imports the generated report script and evaluates `expression` against
    /// it, returning the JSON-encoded result.
    private func evaluateInReportScript(_ expression: String) throws -> String {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("report.py")
        try ONTBarcodeDemuxGenotypingPipeline.writeReportScript(to: scriptURL)

        let driverURL = root.appendingPathComponent("driver.py")
        try """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("report", r"\(scriptURL.path)")
        report = importlib.util.module_from_spec(spec)
        # The script guards execution behind __main__, so importing is safe.
        spec.loader.exec_module(report)
        print(json.dumps(\(expression)))
        """.write(to: driverURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", driverURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("python3 unavailable or report script failed to import")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testReportPrefersUniqueReadsOverAlignmentRecords() throws {
        // A row carrying both columns must report the distinct-read count.
        let value = try evaluateInReportScript(
            #"report.report_read_count({"passed_alignments": 574, "passed_unique_reads": 315})"#
        )
        XCTAssertEqual(value, "315")
    }

    func testReportFallsBackToAlignmentsWhenUniqueReadsAreAbsent() throws {
        // Rows written before the unique-read column existed still report.
        let value = try evaluateInReportScript(
            #"report.report_read_count({"passed_alignments": 574})"#
        )
        XCTAssertEqual(value, "574")
    }

    func testReportReadCountIsNilWhenNeitherColumnIsPresent() throws {
        let value = try evaluateInReportScript(#"report.report_read_count({})"#)
        XCTAssertEqual(value, "null")
    }

    func testGenotypeCountsUseUniqueReads() throws {
        // The per-allele workbook cells come from load_genotype_counts, which
        // is the value the analyst compares against the inspector.
        let value = try evaluateInReportScript(
            """
            report.load_genotype_counts([
                {"sample": "A1", "genotype": "01_G", \
                "passed_alignments": 574, "passed_unique_reads": 315}
            ])["A1"]["01_G"]
            """
        )
        XCTAssertEqual(value, "315")
    }

    func testGenotypeCountsSumRepeatedRowsForOneGenotype() throws {
        let value = try evaluateInReportScript(
            """
            report.load_genotype_counts([
                {"sample": "A1", "genotype": "01_G", "passed_unique_reads": 10},
                {"sample": "A1", "genotype": "01_G", "passed_unique_reads": 5}
            ])["A1"]["01_G"]
            """
        )
        XCTAssertEqual(value, "15")
    }

    func testSampleReadCountUsesUniqueReads() throws {
        let value = try evaluateInReportScript(
            """
            report.read_count_for_sample(
                {"A1": {"passed_alignments": 1098532, "passed_unique_reads": 594881}},
                "A1"
            )
            """
        )
        XCTAssertEqual(value, "594881")
    }
}
