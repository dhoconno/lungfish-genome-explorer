import XCTest
import LungfishKit
@testable import LungfishGenotypeUI

/// Covers routing the viewport's "Export Filtered Pivot" action to
/// `genotype export-pivot-xlsx` with the analyst's Min Reads and Min Percent
/// already applied.
///
/// Context: analysts were exporting the unfiltered pivot and stripping
/// low-support background by hand in Excel. Carrying the viewport thresholds
/// into the export removes that manual step.
final class GenotypeViewportPivotExportTests: XCTestCase {

    /// Records the argv the service would hand the CLI. The run deliberately
    /// throws so the test observes argument construction without needing the
    /// CLI to produce an output file and provenance sidecar.
    private final class RecordingRunner: GenotypeViewportExportRunning {
        private(set) var arguments: [String] = []
        struct Stop: Error {}

        func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
            self.arguments = arguments
            throw Stop()
        }
    }

    private func snapshot(filters: [String: String]) -> GenotypeViewportExportSnapshot {
        GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/run.lungfishgenotype", isDirectory: true),
            analysisName: "Run",
            lens: "comparison",
            filters: filters,
            sampleNames: ["A1", "A2"],
            rows: []
        )
    }

    @discardableResult
    private func capturedArguments(
        filters: [String: String],
        format: GenotypeViewportExportFormat
    ) throws -> [String] {
        let runner = RecordingRunner()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-\(UUID().uuidString).xlsx")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(
                at: outputURL.appendingPathExtension("view-projection.json")
            )
        }
        let service = GenotypeViewportExportService(runner: runner)
        XCTAssertThrowsError(
            try service.export(snapshot: snapshot(filters: filters), format: format, to: outputURL)
        )
        return runner.arguments
    }

    // MARK: - Format metadata

    func testPivotFormatUsesItsOwnSubcommandAndProvenanceIdentity() {
        XCTAssertTrue(GenotypeViewportExportFormat.pivotExcel.usesPivotSubcommand)
        XCTAssertEqual(
            GenotypeViewportExportFormat.pivotExcel.provenanceWorkflowName,
            "genotype.export.pivot-xlsx"
        )
        XCTAssertEqual(GenotypeViewportExportFormat.pivotExcel.fileExtension, "xlsx")
    }

    func testProjectionFormatsKeepTheExistingSubcommand() {
        for format: GenotypeViewportExportFormat in [.csv, .tsv, .excel] {
            XCTAssertFalse(format.usesPivotSubcommand, "\(format) must not use the pivot subcommand")
            XCTAssertEqual(format.provenanceWorkflowName, "lungfish genotype export")
        }
    }

    // MARK: - Argument construction

    func testPivotExportInvokesThePivotSubcommand() throws {
        let arguments = try capturedArguments(filters: [:], format: .pivotExcel)
        XCTAssertEqual(Array(arguments.prefix(2)), ["genotype", "export-pivot-xlsx"])
        // The pivot builder reads the bundle, so no rendered projection is sent.
        XCTAssertFalse(arguments.contains("--view-projection"))
    }

    func testPivotExportCarriesTheMatrixMinimumReads() throws {
        let arguments = try capturedArguments(
            filters: ["matrixMinimumReads": "50"],
            format: .pivotExcel
        )
        XCTAssertTrue(hasOption(arguments, "--min-reads", value: "50"))
    }

    func testPivotExportCarriesTheMatrixMinimumPercent() throws {
        let arguments = try capturedArguments(
            filters: ["matrixMinimumPercent": "1.5"],
            format: .pivotExcel
        )
        XCTAssertTrue(hasOption(arguments, "--min-percent", value: "1.5"))
    }

    func testDisabledThresholdsAreOmitted() throws {
        // "0" means the control is off; sending it would imply an active cut.
        let arguments = try capturedArguments(
            filters: ["matrixMinimumReads": "0", "matrixMinimumPercent": "0.0"],
            format: .pivotExcel
        )
        XCTAssertFalse(arguments.contains("--min-reads"))
        XCTAssertFalse(arguments.contains("--min-percent"))
    }

    func testProjectionExportStillUsesTheExportSubcommand() throws {
        let arguments = try capturedArguments(filters: [:], format: .excel)
        XCTAssertEqual(Array(arguments.prefix(2)), ["genotype", "export"])
        XCTAssertTrue(arguments.contains("--view-projection"))
    }

    private func hasOption(_ arguments: [String], _ name: String, value: String) -> Bool {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return false
        }
        return arguments[index + 1] == value
    }
}
