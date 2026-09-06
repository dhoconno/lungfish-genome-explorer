import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class ProjectLockResolutionDialogTests: XCTestCase {
    func testActiveLockOffersReadOnlyAndCancelWithSelectableOwnerDetails() throws {
        let state = warning(status: .active)
        let alert = ProjectLockResolutionDialog.makeAlert(for: state)
        XCTAssertTrue(alert.messageText.contains("Shared Study"))
        XCTAssertTrue(alert.messageText.contains("may already be open"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Open Read-Only", "Cancel"])
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
        XCTAssertTrue(alert.informativeText.contains("Close the other session"))
        let metadata = try XCTUnwrap(alert.accessoryView as? NSTextField)
        XCTAssertTrue(metadata.isSelectable)
        XCTAssertFalse(metadata.isEditable)
        for value in ["Lungfish Preview", "2026.9.11", "alex", "lab-mac", "321", "2026-09-06T09:00:00Z"] {
            XCTAssertTrue(metadata.stringValue.contains(value), value)
        }
    }

    func testRecoveryRequiresAnActualNonactiveLockAndResponsesFailClosed() {
        for status in [ProjectLockStatus.unknown, .stale, .corrupted] {
            let state = warning(status: status, hasRecord: status != .corrupted)
            let alert = ProjectLockResolutionDialog.makeAlert(for: state)
            XCTAssertEqual(alert.buttons.map(\.title), ["Open Read-Only", "Cancel", "Recover and Open"])
            XCTAssertEqual(ProjectLockResolutionDialog.choice(for: .alertFirstButtonReturn, state: state), .readOnly)
            XCTAssertEqual(ProjectLockResolutionDialog.choice(for: .alertSecondButtonReturn, state: state), .cancel)
            XCTAssertEqual(ProjectLockResolutionDialog.choice(for: .alertThirdButtonReturn, state: state), .recover)
            XCTAssertEqual(ProjectLockResolutionDialog.choice(for: .abort, state: state), .cancel)
        }
        for state in [warning(status: .active), warning(status: .unknown, hasRecord: false)] {
            XCTAssertEqual(ProjectLockResolutionDialog.makeAlert(for: state).buttons.count, 2)
            XCTAssertEqual(ProjectLockResolutionDialog.choice(for: .alertThirdButtonReturn, state: state), .cancel)
        }
    }

    func testUncertainRecoveryConfirmationDefaultsToCancelAndExplainsCrossVersionRisk() {
        for status in [ProjectLockStatus.unknown, .corrupted] {
            let alert = ProjectLockResolutionDialog.makeRecoveryConfirmation(for: warning(status: status))
            XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Recover and Open"])
            XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
            XCTAssertNotEqual(alert.buttons.last?.keyEquivalent, "\r")
            for phrase in ["other Lungfish versions", "CLI", "other computers", "archive"] {
                XCTAssertTrue(alert.informativeText.contains(phrase), phrase)
            }
        }
        XCTAssertEqual(ProjectLockResolutionDialog.recoveryChoice(for: .alertFirstButtonReturn), .cancel)
        XCTAssertEqual(ProjectLockResolutionDialog.recoveryChoice(for: .alertSecondButtonReturn), .recover)
        XCTAssertEqual(ProjectLockResolutionDialog.recoveryChoice(for: .alertThirdButtonReturn), .cancel)
        XCTAssertEqual(ProjectLockResolutionDialog.recoveryChoice(for: .abort), .cancel)
    }

    func testUnknownAndCorruptLockMessagesExplainDifferentUncertainty() {
        let unknown = ProjectLockResolutionDialog.makeAlert(for: warning(status: .unknown))
        XCTAssertTrue(unknown.informativeText.contains("could not confirm"))
        let corrupted = ProjectLockResolutionDialog.makeAlert(for: warning(status: .corrupted, hasRecord: false))
        XCTAssertTrue(corrupted.informativeText.contains("damaged"))
        let unreadable = ProjectLockResolutionDialog.makeAlert(for: warning(status: .unknown, hasRecord: false))
        XCTAssertTrue(unreadable.informativeText.contains("could not read"))
    }

    func testRecoveryChoiceRequiresSecondApprovalForUnknownAndCorruptOwners() async {
        for status in [ProjectLockStatus.unknown, .corrupted] {
            var presentations = 0
            let result = await ProjectLockResolutionDialog.resolve(for: warning(status: status)) { _ in
                presentations += 1
                return presentations == 1 ? .alertThirdButtonReturn : .alertFirstButtonReturn
            }
            XCTAssertEqual(presentations, 2)
            XCTAssertEqual(result, .cancel)
        }
        var presentations = 0
        let result = await ProjectLockResolutionDialog.resolve(for: warning(status: .unknown)) { _ in
            presentations += 1
            return presentations == 1 ? .alertThirdButtonReturn : .alertSecondButtonReturn
        }
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(result, .recover)
    }

    func testCancellationBeforePresentationDoesNotOpenADialog() async {
        var presentations = 0
        let state = warning(status: .unknown)
        let task = Task { @MainActor in
            await ProjectLockResolutionDialog.resolve(for: state) { _ in
                presentations += 1
                return .alertFirstButtonReturn
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancel)
        XCTAssertEqual(presentations, 0)
    }

    func testCancellationAfterRecoverChoiceDoesNotOpenConfirmation() async {
        var presentations = 0
        let state = warning(status: .unknown)
        let task = Task { @MainActor in
            await ProjectLockResolutionDialog.resolve(for: state) { _ in
                presentations += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return .alertThirdButtonReturn
            }
        }
        let result = await task.value
        XCTAssertEqual(result, .cancel)
        XCTAssertEqual(presentations, 1)
    }

    private func warning(status: ProjectLockStatus, hasRecord: Bool = true) -> ProjectOpenWarningState {
        let project = URL(fileURLWithPath: "/tmp/Shared Study.lungfish")
        let record = ProjectLockRecord(schemaVersion: 1, toolName: "Lungfish Preview", appVersion: "2026.9.11",
            projectPath: project.path, mode: "write", user: "alex", host: "lab-mac", pid: 321,
            processStartTime: "2026-09-06T08:00:00Z", cwd: "/tmp", createdAt: "2026-09-06T09:00:00Z")
        return ProjectOpenWarningState(projectURL: project, lockRecord: hasRecord ? record : nil,
            lockStatus: status, readErrorDescription: hasRecord ? nil : "Unable to decode lock metadata.")
    }
}
