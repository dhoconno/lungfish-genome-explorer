import XCTest

final class IQTreeInferenceOptionsDialogTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func testIQTreeInferenceDialogExposesCuratedAndAdvancedOptions() throws {
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceOptionsDialog.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Sequence Type"))
        XCTAssertTrue(source.contains("Branch Support"))
        XCTAssertTrue(source.contains("Ultrafast Bootstrap"))
        XCTAssertTrue(source.contains("SH-aLRT"))
        XCTAssertTrue(source.contains("Safe numerical mode"))
        XCTAssertTrue(source.contains("Keep identical sequences"))
        XCTAssertTrue(source.contains("Advanced Options"))
        XCTAssertTrue(source.contains("IQ-TREE Parameters"))
    }

    func testMSATreeInferenceRoutesThroughDialogBeforeRunner() throws {
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("IQTreeInferenceOptionsDialog.present"))
        XCTAssertTrue(source.contains("runIQTreeInferenceViaCLI"))
    }
}
