import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AnnotationTableExportInterfaceTests: XCTestCase {
    func testMenuExposesAllFormatsForBothScopes() {
        XCTAssertEqual(AnnotationTableExportMenuModel.formats.map(\.0), [.xlsx, .csv, .tsv, .json])
        XCTAssertEqual(AnnotationTableExportMenuModel.scopeTitle(.allMatching, selectedCount: 0), "All Matching Rows…")
        XCTAssertEqual(AnnotationTableExportMenuModel.scopeTitle(.selected, selectedCount: 3), "Selected Rows (3)…")
    }

    func testSuggestedNamesIdentifyTabScopeAndRealExtension() {
        XCTAssertEqual(
            AnnotationTableExportMenuModel.suggestedFilename(tab: "variants", scope: .selected, format: .xlsx),
            "variants-selected.xlsx"
        )
        XCTAssertEqual(
            AnnotationTableExportMenuModel.suggestedFilename(tab: "annotations", scope: .allMatching, format: .csv),
            "annotations-all-matching.csv"
        )
    }

    func testValidatedSourcesIncludeRetainedVariantOverlayVCF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportSources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let annotationDB = directory.appendingPathComponent("annotations.db")
        let variantDB = directory.appendingPathComponent("variants.db")
        let retainedVCF = directory.appendingPathComponent("original-ivar.vcf")
        let manifest = directory.appendingPathComponent("manifest.json")
        for url in [annotationDB, variantDB, retainedVCF, manifest] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        let sources = try validatedScientificTableExportSourceURLs(
            annotationDatabaseURLs: [annotationDB], variantDatabaseURLs: [variantDB],
            overlaySourceURLs: [retainedVCF], additionalURLs: [manifest]
        )

        XCTAssertEqual(Set(sources.map(\.standardizedFileURL)), Set([
            annotationDB, variantDB, retainedVCF, manifest
        ].map(\.standardizedFileURL)))
    }
}
