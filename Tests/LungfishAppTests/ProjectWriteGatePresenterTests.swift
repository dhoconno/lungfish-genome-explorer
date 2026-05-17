import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectWriteGatePresenterTests: XCTestCase {
    func testBuildsSharedReadOnlyWriteGateAlert() {
        let alert = ProjectWriteGatePresenter.makeAlertForTest(workflowName: "FASTQ import")

        XCTAssertEqual(alert.messageText, "Project Is Open Read Only")
        XCTAssertEqual(
            alert.informativeText,
            "FASTQ import writes files into the project. Close the other writer or reopen the project after the lock is released before running this workflow."
        )
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
    }

    func testChoosesSheetWhenPresentationWindowExists() {
        XCTAssertEqual(
            ProjectWriteGatePresenter.presentationModeForTest(hasPresentationWindow: true),
            .sheet
        )
    }

    func testChoosesApplicationErrorPresentationWithoutWindow() {
        XCTAssertEqual(
            ProjectWriteGatePresenter.presentationModeForTest(hasPresentationWindow: false),
            .applicationErrorPresentation
        )
    }

    func testNoWindowWarningCarriesAlertTitleAndMessage() {
        let warning = ProjectWriteGatePresenter.noWindowWarningForTest(workflowName: "Tree inference")

        XCTAssertEqual(warning.errorDescription, "Project Is Open Read Only")
        XCTAssertEqual(
            warning.recoverySuggestion,
            "Tree inference writes files into the project. Close the other writer or reopen the project after the lock is released before running this workflow."
        )
    }
}
