import XCTest
import LungfishKit
import LungfishIO
@testable import LungfishGenotypeUI

/// Covers routing the viewport's "Export Filtered Pivot" action to
/// `genotype export-pivot-xlsx` with the analyst's Min Reads and Min Percent
/// already applied.
///
/// Context: analysts were exporting the unfiltered pivot and stripping
/// low-support background by hand in Excel. Carrying the viewport thresholds
/// into the export removes that manual step.
final class GenotypeViewportPivotExportTests: XCTestCase {

    func testProjectionSerializesExactOrderedCallsAndRevisionContext() throws {
        let call = GenotypeViewProjectionHaplotypeCall(
            sample: "A1",
            locus: "MHC-DRB",
            haplotype1: "M4DR",
            haplotype2: "M4DR",
            haplotype1Status: "called",
            haplotype2Status: "called",
            haplotype1Source: "pipeline",
            haplotype2Source: "pipeline",
            baselineHaplotype1: "M4DR",
            baselineHaplotype2: "-",
            comment: "confirmed"
        )
        let sourceRevision = GenotypeViewProjectionSourceRevision(
            assayID: "assay",
            analysisRevisionID: "revision-7",
            definitionSetID: "definitions"
        )
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/run.lungfishgenotype"),
            analysisName: "Run",
            lens: "comparison",
            filters: ["matrixMinimumReads": "5"],
            sampleNames: ["A1"],
            rows: [],
            haplotypeCalls: [call],
            sourceRevision: sourceRevision
        )

        let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        XCTAssertEqual(projection.haplotypeCalls, [call])
        XCTAssertEqual(projection.sourceRevision, sourceRevision)
        XCTAssertEqual(projection.filterContext, ["matrixMinimumReads": "5"])
        let decoded = try JSONDecoder().decode(
            GenotypeViewProjection.self,
            from: JSONEncoder().encode(projection)
        )
        XCTAssertEqual(decoded, projection)
    }

    /// Records the argv the service would hand the CLI. The run deliberately
    /// throws so the test observes argument construction without needing the
    /// CLI to produce an output file and provenance sidecar.
    private final class RecordingRunner: GenotypeViewportExportRunning {
        private(set) var arguments: [String] = []
        private(set) var capturedAnnotationData: Data?
        struct Stop: Error {}

        func run(arguments: [String]) throws -> LungfishCLIRunner.Output {
            self.arguments = arguments
            if let index = arguments.firstIndex(of: "--annotations"),
               index + 1 < arguments.count {
                capturedAnnotationData = try? Data(
                    contentsOf: URL(fileURLWithPath: arguments[index + 1])
                )
            }
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
        XCTAssertTrue(
            arguments.contains("--view-projection"),
            "the filtered pivot must consume the exact rendered viewport"
        )
    }

    func testPivotExportCarriesAnnotationSidecarWithViewportProjection() throws {
        let runner = RecordingRunner()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-annotations-\(UUID().uuidString).xlsx")
        let sidecarURL = URL(fileURLWithPath: "/tmp/run.lungfishgenotype/annotations.json")
        let annotated = GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/run.lungfishgenotype", isDirectory: true),
            analysisName: "Run",
            lens: "comparison",
            filters: [:],
            sampleNames: ["A1"],
            rows: [],
            annotationSidecarURL: sidecarURL
        )
        XCTAssertThrowsError(
            try GenotypeViewportExportService(runner: runner).export(
                snapshot: annotated,
                format: .pivotExcel,
                to: outputURL
            )
        )
        XCTAssertTrue(hasOption(runner.arguments, "--view-projection", value: outputURL.appendingPathExtension("view-projection.json").path))
        XCTAssertTrue(hasOption(runner.arguments, "--annotations", value: sidecarURL.path))
    }

    func testPivotExportUsesCapturedSidecarBytesInsteadOfLivePath() {
        let runner = RecordingRunner()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-frozen-\(UUID().uuidString).xlsx")
        let frozen = Data(#"{"matrixReviews":[{"frozen":true}]}"#.utf8)
        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/run.lungfishgenotype"),
            analysisName: "Run",
            lens: "comparison",
            filters: [:],
            sampleNames: ["A1"],
            rows: [],
            annotationSidecarURL: URL(fileURLWithPath: "/tmp/live-annotations.json"),
            annotationSidecarData: frozen
        )

        XCTAssertThrowsError(
            try GenotypeViewportExportService(runner: runner).export(
                snapshot: snapshot,
                format: .pivotExcel,
                to: outputURL
            )
        )
        XCTAssertEqual(runner.capturedAnnotationData, frozen)
        XCTAssertTrue(runner.arguments.contains(
            outputURL.appendingPathExtension("annotations.json").path
        ))
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

    /// Min Percent is a percent of whatever the matrix's Percent Basis
    /// selects, so the export must carry that denominator too or it would
    /// drop different cells than the analyst is looking at.
    func testPivotExportCarriesTheMatrixPercentBasisWithMinimumPercent() throws {
        let viewedLocus = try capturedArguments(
            filters: ["matrixMinimumPercent": "1.5", "matrixPercentDenominator": "Viewed Locus"],
            format: .pivotExcel
        )
        XCTAssertTrue(hasOption(viewedLocus, "--percent-basis", value: "viewed-locus"))

        let sampleRetained = try capturedArguments(
            filters: ["matrixMinimumPercent": "1.5", "matrixPercentDenominator": "Sample Retained"],
            format: .pivotExcel
        )
        XCTAssertTrue(hasOption(sampleRetained, "--percent-basis", value: "sample-retained"))

        // Without an active percent threshold the basis is meaningless.
        let off = try capturedArguments(
            filters: ["matrixMinimumPercent": "0.0", "matrixPercentDenominator": "Viewed Locus"],
            format: .pivotExcel
        )
        XCTAssertFalse(off.contains("--percent-basis"))
    }

    func testPivotExportPairsActiveRowSupportPercentWithItsOwnBasis() throws {
        let arguments = try capturedArguments(
            filters: [
                "hideLowSupport": "true",
                "minimumSupportPercent": "7.5",
                "supportDenominator": "Sample Retained",
                "matrixMinimumPercent": "0.0",
                "matrixPercentDenominator": "Viewed Locus",
            ],
            format: .pivotExcel
        )

        XCTAssertTrue(hasOption(arguments, "--min-percent", value: "7.5"))
        XCTAssertTrue(hasOption(arguments, "--percent-basis", value: "sample-retained"))
    }

    func testPivotExportDoesNotActivateConfiguredRowSupportPercentWhileRowsAreShown() throws {
        let arguments = try capturedArguments(
            filters: [
                "hideLowSupport": "false",
                "minimumSupportPercent": "7.5",
                "supportDenominator": "Sample Retained",
                "matrixMinimumPercent": "0.0",
                "matrixPercentDenominator": "Viewed Locus",
            ],
            format: .pivotExcel
        )

        XCTAssertFalse(arguments.contains("--min-percent"))
        XCTAssertFalse(arguments.contains("--percent-basis"))
    }

    func testPivotExportKeepsMatrixPercentAndBasisPairedWhenBothFamiliesAreActive() throws {
        let arguments = try capturedArguments(
            filters: [
                "hideLowSupport": "true",
                "minimumSupportPercent": "7.5",
                "supportDenominator": "Sample Retained",
                "matrixMinimumPercent": "12.5",
                "matrixPercentDenominator": "Viewed Locus",
            ],
            format: .pivotExcel
        )

        XCTAssertTrue(hasOption(arguments, "--min-percent", value: "12.5"))
        XCTAssertTrue(hasOption(arguments, "--percent-basis", value: "viewed-locus"))
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
