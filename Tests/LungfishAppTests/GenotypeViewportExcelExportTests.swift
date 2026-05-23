import XCTest
@testable import LungfishApp
import LungfishCore

final class GenotypeViewportExcelExportTests: XCTestCase {
    func testExcelExportWritesWorkbookAndProvenancePackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeViewportExcelExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceBundle = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: sourceBundle.appendingPathComponent("genotype-result.json"))

        let snapshot = GenotypeViewportExportSnapshot(
            bundleURL: sourceBundle,
            analysisName: "barcode05-mhc",
            lens: "analyst",
            filters: ["locus": "MHC-A", "minimumSupportPercent": "1.0"],
            sampleNames: ["AnimalA"],
            rows: [
                GenotypeViewportExportRow(
                    genotype: "01_M1_A_01",
                    locus: "MHC-A",
                    sampleCount: 1,
                    totalUniqueReads: 42,
                    sampleReads: ["AnimalA": 42],
                    rowStyle: GenotypeResultHighlightStyle(
                        fillColor: AnnotationColor(red: 0.2, green: 0.4, blue: 0.8),
                        borderColor: AnnotationColor(red: 0.9, green: 0.2, blue: 0.1)
                    ),
                    cellStyles: ["AnimalA": GenotypeResultHighlightStyle(fillColor: AnnotationColor(red: 0.6, green: 0.8, blue: 1.0))]
                )
            ]
        )

        let exportURL = root.appendingPathComponent("barcode05-mhc-review.lungfishexport", isDirectory: true)
        let result = try GenotypeViewportExcelExportService().export(snapshot: snapshot, to: exportURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.workbookURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
        let worksheetXML = try unzipEntry("xl/worksheets/sheet1.xml", from: result.workbookURL)
        XCTAssertTrue(worksheetXML.contains("01_M1_A_01"))
        XCTAssertTrue(worksheetXML.contains("AnimalA"))
        let styleXML = try unzipEntry("xl/styles.xml", from: result.workbookURL)
        XCTAssertTrue(styleXML.contains("FF3366CC"))
        XCTAssertTrue(styleXML.contains("FFE6331A"))
        let provenance = try String(contentsOf: result.provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenance.contains("Genotype viewport Excel export"))
        XCTAssertTrue(provenance.contains(result.workbookURL.lastPathComponent))
        XCTAssertFalse(provenance.contains(".xlsx-build"))
    }

    private func unzipEntry(_ entry: String, from archiveURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archiveURL.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
