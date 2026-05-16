import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class CzIdImportSheetTests: XCTestCase {
    func testPresentationDisablesPrimaryActionUntilSelectionHasPreview() {
        let noSelection = CzIdImportDialogPresentation(
            selectedPath: nil,
            isScanning: false,
            scanError: nil,
            preview: nil,
            projectURL: URL(fileURLWithPath: "/project/demo.lungfish", isDirectory: true),
            datasetURL: URL(fileURLWithPath: "/project/demo.lungfish/Samples/sample-a.lungfishfastq", isDirectory: true)
        )

        XCTAssertEqual(noSelection.accessoryText, "sample-a")
        XCTAssertEqual(noSelection.selectedPathText, "No file or folder selected")
        XCTAssertEqual(noSelection.statusText, "Select a CZ-ID export.")
        XCTAssertFalse(noSelection.isPrimaryEnabled)

        let scanning = CzIdImportDialogPresentation(
            selectedPath: URL(fileURLWithPath: "/tmp/czid-export.zip"),
            isScanning: true,
            scanError: nil,
            preview: nil,
            projectURL: nil,
            datasetURL: nil
        )

        XCTAssertEqual(scanning.statusText, "Scanning CZ-ID export...")
        XCTAssertFalse(scanning.isPrimaryEnabled)

        let ready = CzIdImportDialogPresentation(
            selectedPath: URL(fileURLWithPath: "/tmp/taxon_report.tsv"),
            isScanning: false,
            scanError: nil,
            preview: Self.preview,
            projectURL: URL(fileURLWithPath: "/project/demo.lungfish", isDirectory: true),
            datasetURL: nil
        )

        XCTAssertEqual(ready.selectedPathText, "/tmp/taxon_report.tsv")
        XCTAssertEqual(ready.statusText, "Ready to import CZ-ID report.")
        XCTAssertTrue(ready.isPrimaryEnabled)
        XCTAssertTrue(ready.destinationText.contains("/project/demo.lungfish/Analyses/cz-id-"))
    }

    func testActionsOnlyImportReadySelectionAndAlwaysCancelScan() {
        var importedURLs: [URL] = []
        var cancelCount = 0
        let selectedURL = URL(fileURLWithPath: "/tmp/taxon_report.tsv")

        CzIdImportDialogActions.importIfReady(
            selectedPath: nil,
            isPrimaryEnabled: false,
            onImport: { importedURLs.append($0) }
        )
        CzIdImportDialogActions.importIfReady(
            selectedPath: selectedURL,
            isPrimaryEnabled: true,
            onImport: { importedURLs.append($0) }
        )
        CzIdImportDialogActions.cancel(
            cancelScan: { cancelCount += 1 },
            onCancel: { cancelCount += 10 }
        )

        XCTAssertEqual(importedURLs, [selectedURL])
        XCTAssertEqual(cancelCount, 11)
    }

    private static let preview = CzIdImportPreview(
        sourceURL: URL(fileURLWithPath: "/tmp/taxon_report.tsv"),
        sourceKind: .taxonReportFile,
        sourceArchiveURL: nil,
        reportURL: URL(fileURLWithPath: "/tmp/taxon_report.tsv"),
        reportFileName: "taxon_report.tsv",
        sampleName: "sample-a",
        projectId: "42",
        pipelineVersion: "v1",
        ntDatabaseVersion: "nt-2026",
        nrDatabaseVersion: "nr-2026",
        rowCount: 12,
        topTaxa: []
    )
}
