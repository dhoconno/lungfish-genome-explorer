import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Native scientific counts and shared reports must agree even when alignment
/// records and distinct reads differ. No embedded legacy renderer is exercised.
final class GenotypeReportReadCountMetricTests: XCTestCase {
    func testReportPrefersUniqueReadsOverAlignmentRecords() throws {
        let snapshot = try capture(rows: "A1,01_G,574,315", columns: "sample,genotype,passed_alignments,passed_unique_reads")
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.displayValue, 315)
        XCTAssertEqual(snapshot.filteredMatrix.rows.first?.cells.first?.displayValue, 315)
    }

    func testMissingUniqueReadColumnPreservesNativeZeroWithoutInventingAlignmentCounts() throws {
        let snapshot = try capture(rows: "A1,01_G,574", columns: "sample,genotype,passed_alignments")
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.displayValue, 0)
        let result = try JSONDecoder().decode(ONTGenotypeResultBundleData.self, from: XCTUnwrap(snapshot.capturedScientificInputs?["result.json"]))
        XCTAssertEqual(result.calls.first?.passedUniqueReads, 0)
        XCTAssertEqual(result.calls.first?.passedAlignments, 574)
    }

    func testRepeatedKnownRowsPreserveNativeFirstOccurrenceAndRawAuthority() throws {
        let snapshot = try capture(rows: "A1,01_G,10,10\nA1,01_G,5,5", columns: "sample,genotype,passed_alignments,passed_unique_reads")
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.displayValue, 10)
        XCTAssertEqual(snapshot.allMatrix.rows.first?.cells.first?.rawSupport, 10)
        let result = try JSONDecoder().decode(ONTGenotypeResultBundleData.self, from: XCTUnwrap(snapshot.capturedScientificInputs?["result.json"]))
        XCTAssertEqual(result.calls.map(\.passedUniqueReads), [10, 5])
    }

    private func capture(rows: String, columns: String) throws -> GenotypeWorkbookPresentation.Snapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadCount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((columns + "\n" + rows + "\n").utf8).write(to: root.appendingPathComponent("calls.csv"))
        try Data("sample,passed_alignments,passed_unique_reads\nA1,1098532,594881\n".utf8).write(to: root.appendingPathComponent("samples.csv"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("stats.json"))
        let manifest = ONTGenotypeResultBundleManifest(outputName: "counts", analysisName: "counts",
            primaryWorkbookPath: "report.xlsx", longSummaryCSVPath: "calls.csv", sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json", provenancePath: "provenance.json")
        let result = try ONTGenotypeResultBundle.loadResult(from: root, manifest: manifest)
        XCTAssertEqual(result.samples.first?.passedUniqueReads, 594881)
        return try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: "test"),
            allProjection: nil, filteredProjection: nil, generatedAt: "test", authority: .init(analysis: nil, definitionSet: nil))
    }
}
