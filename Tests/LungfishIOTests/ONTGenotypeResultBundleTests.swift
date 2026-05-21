import Foundation
import XCTest
@testable import LungfishIO

final class ONTGenotypeResultBundleTests: XCTestCase {
    func testWritesAndLoadsPrimaryWorkbookManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTGenotypeResultBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc_vs_Illumina-31262.xlsx")
        try Data("workbook".utf8).write(to: workbookURL)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: "barcode08-mhc.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "barcode08-mhc.retained-demux-samples.csv",
            statsJSONPath: "barcode08-mhc.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertTrue(ONTGenotypeResultBundle.isBundleURL(bundleURL))
        XCTAssertEqual(try ONTGenotypeResultBundle.loadManifest(from: bundleURL), manifest)
        XCTAssertEqual(
            try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundleURL),
            workbookURL.standardizedFileURL
        )
    }
}
