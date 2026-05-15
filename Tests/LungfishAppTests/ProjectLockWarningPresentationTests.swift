import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class ProjectLockWarningPresentationTests: XCTestCase {
    func testUnlockedStateHasNoBannerPresentation() {
        let state = ProjectOpenWarningState.unlocked(projectURL: URL(fileURLWithPath: "/tmp/Example.lungfish"))

        XCTAssertNil(ProjectLockWarningPresentation(state: state))
    }

    func testActiveLockFormatsOwnerModeStatusAndTimestamp() throws {
        let record = ProjectLockRecord(
            schemaVersion: 1,
            toolName: "lungfish project lock",
            appVersion: "lungfish-cli 0.4.0-alpha.16",
            projectPath: "/tmp/Locked.lungfish",
            mode: "exclusive",
            user: "dho",
            host: "raven.local",
            pid: 47779,
            processStartTime: "2026-05-14T01:01:00Z",
            cwd: "/tmp",
            createdAt: "2026-05-14T01:03:00Z"
        )
        let state = ProjectOpenWarningState(
            projectURL: URL(fileURLWithPath: "/tmp/Locked.lungfish"),
            lockRecord: record,
            lockStatus: .active,
            readErrorDescription: nil
        )

        let presentation = try XCTUnwrap(ProjectLockWarningPresentation(state: state))

        XCTAssertEqual(presentation.title, "Project opened read-only")
        XCTAssertTrue(presentation.detail.contains("exclusive"))
        XCTAssertTrue(presentation.detail.contains("active"))
        XCTAssertTrue(presentation.detail.contains("lungfish project lock"))
        XCTAssertTrue(presentation.detail.contains("dho@raven.local"))
        XCTAssertTrue(presentation.detail.contains("pid 47779"))
        XCTAssertTrue(presentation.detail.contains("2026-05-14T01:03:00Z"))
    }

    func testUnreadableLockFormatsReadError() throws {
        let state = ProjectOpenWarningState(
            projectURL: URL(fileURLWithPath: "/tmp/Broken.lungfish"),
            lockRecord: nil,
            lockStatus: .unknown,
            readErrorDescription: "The data could not be read."
        )

        let presentation = try XCTUnwrap(ProjectLockWarningPresentation(state: state))

        XCTAssertEqual(presentation.title, "Project opened read-only")
        XCTAssertTrue(presentation.detail.contains("lock metadata could not be read"))
        XCTAssertTrue(presentation.detail.contains("The data could not be read."))
    }
}
