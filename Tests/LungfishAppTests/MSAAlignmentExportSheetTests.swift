import XCTest
@testable import LungfishApp

final class MSAAlignmentExportSheetTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/a.lungfishmsa")
    private let outputURL = URL(fileURLWithPath: "/tmp/out.fasta")

    private func configuration(
        destination: MSAExportDestination,
        layout: MSAExportLayout = .aligned,
        format: String = "aligned-fasta",
        scope: MSAExportScope = .entireAlignment
    ) -> MSAAlignmentExportConfiguration {
        MSAAlignmentExportConfiguration(
            destination: destination, layout: layout, format: format, scope: scope, name: "Subset"
        )
    }

    func testAlignedBundleLegProducesAnAlignmentBundleNotAReference() {
        let args = MSAAlignmentExportSheet.cliArguments(
            for: configuration(destination: .bundle, layout: .aligned),
            bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
        )
        XCTAssertEqual(Array(args.prefix(2)), ["msa", "extract"])
        XCTAssertTrue(args.contains("--output-kind"))
        XCTAssertTrue(args.contains("msa"), "aligned bundle must stay a .lungfishmsa; 'reference' ungaps")
        XCTAssertFalse(args.contains("reference"))
    }

    func testUnalignedBundleLegProducesAReferenceBundle() {
        let args = MSAAlignmentExportSheet.cliArguments(
            for: configuration(destination: .bundle, layout: .unaligned, format: "fasta"),
            bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
        )
        XCTAssertTrue(args.contains("reference"))
    }

    func testFileAndClipboardLegsUseExportWithTheChosenFormat() {
        for destination in [MSAExportDestination.file, .clipboard] {
            let args = MSAAlignmentExportSheet.cliArguments(
                for: configuration(destination: destination),
                bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
            )
            XCTAssertEqual(Array(args.prefix(2)), ["msa", "export"])
            XCTAssertTrue(args.contains("aligned-fasta"))
        }
    }

    func testFileLegCarriesTheOtherAlignmentFormats() {
        for format in ["phylip", "nexus", "clustal", "stockholm", "a2m", "a3m"] {
            let args = MSAAlignmentExportSheet.cliArguments(
                for: configuration(destination: .file, format: format),
                bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
            )
            XCTAssertTrue(args.contains(format))
        }
    }

    func testSelectedRowsScopePassesRowsAndEntireAlignmentDoesNot() {
        let selected = MSAAlignmentExportSheet.cliArguments(
            for: configuration(destination: .file, scope: .selectedRows),
            bundleURL: bundleURL, outputURL: outputURL, rows: "r1,r2", columns: "10-40"
        )
        XCTAssertTrue(selected.contains("--rows"))
        XCTAssertTrue(selected.contains("r1,r2"))
        XCTAssertTrue(selected.contains("10-40"))

        let entire = MSAAlignmentExportSheet.cliArguments(
            for: configuration(destination: .file, scope: .entireAlignment),
            bundleURL: bundleURL, outputURL: outputURL, rows: "r1,r2", columns: "10-40"
        )
        XCTAssertFalse(entire.contains("--rows"))
        XCTAssertFalse(entire.contains("--columns"))
    }

    @MainActor
    func testExportStartsWithTheSelectedSubalignmentScope() {
        let model = MSAAlignmentExportModel(
            name: "Subset", estimatedBytes: 100, hasSelection: true,
            selectedRowCount: 2, totalRowCount: 2
        )
        let arguments = MSAAlignmentExportSheet.cliArguments(
            for: model.configuration, bundleURL: bundleURL, outputURL: outputURL,
            rows: "r1,r2", columns: "10-40"
        )
        XCTAssertTrue(arguments.contains("--rows"))
        XCTAssertTrue(arguments.contains("10-40"))
    }

    func testClipboardIsUnavailableAboveTheCap() {
        XCTAssertTrue(MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: 4_000_000))
        XCTAssertFalse(MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: 6_000_000))
    }

    func testDestinationLabelsMatchTheClassifierDialogVocabulary() {
        XCTAssertEqual(MSAExportDestination.bundle.label, "Save as Bundle")
        XCTAssertEqual(MSAExportDestination.file.label, "Save to File…")
        XCTAssertEqual(MSAExportDestination.clipboard.label, "Copy to Clipboard")
        XCTAssertEqual(MSAExportDestination.bundle.primaryButtonTitle, "Create Bundle")
        XCTAssertEqual(MSAExportDestination.file.primaryButtonTitle, "Save")
        XCTAssertEqual(MSAExportDestination.clipboard.primaryButtonTitle, "Copy")
    }
}
