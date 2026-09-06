import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class ProjectLockOpenResolutionTests: XCTestCase {
    private func fixture() throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-dialog-\(UUID()).lungfish")
        do {
            let project = try ProjectFile.create(at: url, name: "Dialog fixture")
            try project.save()
            withExtendedLifetime(project) {}
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let record = ProjectLockRecord(schemaVersion: 1, toolName: "old session", appVersion: "test",
            projectPath: url.path, mode: "write", user: NSUserName(), host: "old-vpn.invalid",
            pid: 999_999, processStartTime: "old", cwd: "/", createdAt: "yesterday")
        let lock = ProjectLockManager.lockURL(for: url)
        try ProjectLockManager().writeLock(record, to: lock)
        return (url, try Data(contentsOf: lock))
    }

    func testCancelPreservesLockAndDoesNotPublishProject() async throws {
        let (url, bytes) = try fixture()
        let prepared = try ProjectSession.prepareProject(at: url)
        var prompted = false
        let result = try await ProjectLockOpenResolution.resolve(prepared, at: url, isCurrent: { true }) { state in
            prompted = true
            XCTAssertEqual(state.lockStatus, .unknown)
            return .cancel
        }
        XCTAssertTrue(prompted)
        XCTAssertNil(result)
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: url)), bytes)
    }

    func testReadOnlyChoicePreservesLockAndAccessMode() async throws {
        let (url, bytes) = try fixture()
        let prepared = try ProjectSession.prepareProject(at: url)
        let result = try await ProjectLockOpenResolution.resolve(prepared, at: url, isCurrent: { true }) { _ in .readOnly }
        let session = ProjectSession()
        let file = try session.acceptPreparedProject(XCTUnwrap(result))
        XCTAssertEqual(file.accessMode, .readOnly)
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: url)), bytes)
        session.closeProject()
    }

    func testRecoveryArchivesLegacyLockAndOpensWritable() async throws {
        let (url, _) = try fixture()
        let prepared = try ProjectSession.prepareProject(at: url)
        let result = try await ProjectLockOpenResolution.resolve(prepared, at: url, isCurrent: { true }) { _ in .recover }
        let session = ProjectSession()
        let file = try session.acceptPreparedProject(XCTUnwrap(result))
        XCTAssertEqual(file.accessMode, .writable)
        XCTAssertFalse(session.openWarningState.isReadOnlyRecommended)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(".lungfish/lock-recovery").path))
        session.closeProject()
    }

    func testSupersededDialogCannotRecoverLock() async throws {
        let (url, bytes) = try fixture()
        let prepared = try ProjectSession.prepareProject(at: url)
        var current = true
        do {
            _ = try await ProjectLockOpenResolution.resolve(prepared, at: url, isCurrent: { current }) { _ in
                current = false
                return .recover
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: url)), bytes)
    }

    func testChangedProjectLocationDuringDialogCannotRecover() async throws {
        let (url, bytes) = try fixture()
        let prepared = try ProjectSession.prepareProject(at: url)
        var changed = false
        do {
            _ = try await ProjectLockOpenResolution.resolve(prepared, at: url, isCurrent: { true },
                validateLocation: { if changed { throw CocoaError(.fileReadUnknown) } }) { _ in
                    changed = true
                    return .recover
                }
            XCTFail("Expected location change refusal")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: ProjectLockManager.lockURL(for: url)), bytes)
    }

    func testChangedLockDuringDialogIsPreserved() async throws {
        let (url, _) = try fixture()
        let prepared = try ProjectSession.prepareProject(at: url)
        let lock = ProjectLockManager.lockURL(for: url)
        let replacement = ProjectLockRecord.current(projectURL: url, mode: "write", toolName: "new writer", appVersion: "test")
        do {
            _ = try await ProjectLockOpenResolution.resolve(prepared, at: url, isCurrent: { true }) { _ in
                try! ProjectLockManager().writeLock(replacement, to: lock)
                return .recover
            }
            XCTFail("Expected changed lock refusal")
        } catch {}
        XCTAssertEqual(try ProjectLockManager().readLock(at: lock), replacement)
    }
}
