import Darwin
import Foundation
import XCTest
@testable import LungfishIO

final class OwnedRunLockTests: XCTestCase {
    private var root: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnedRunLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockURL = root.appendingPathComponent(".analysis.run.lock")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAcquireIsSharedNonblockingPrimitive() throws {
        let fullLength = try OwnedRunLock.acquire(at: lockURL)
        defer { fullLength.release() }

        XCTAssertEqual(try OwnedRunLock.probe(at: lockURL), .held)
        XCTAssertThrowsError(try OwnedRunLock.acquire(at: lockURL)) { error in
            XCTAssertEqual(error as? OwnedRunLockError, .lockHeld(lockURL.path))
        }

        fullLength.release()
        let miseq = try OwnedRunLock.acquire(at: lockURL)
        XCTAssertEqual(try OwnedRunLock.probe(at: lockURL), .held)
        miseq.release()
        XCTAssertEqual(try OwnedRunLock.probe(at: lockURL), .unlocked)
    }

    func testProbeMissingDoesNotCreateLock() throws {
        XCTAssertEqual(try OwnedRunLock.probe(at: lockURL), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testAcquireAndProbeRejectSymlinkAndSpecialFile() throws {
        let target = root.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
        XCTAssertThrowsError(try OwnedRunLock.acquire(at: lockURL))
        XCTAssertThrowsError(try OwnedRunLock.probe(at: lockURL))

        try FileManager.default.removeItem(at: lockURL)
        XCTAssertEqual(mkfifo(lockURL.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try OwnedRunLock.acquire(at: lockURL))
        XCTAssertThrowsError(try OwnedRunLock.probe(at: lockURL))
    }

    func testRejectsEmbeddedNULInLockName() {
        let invalid = root.appendingPathComponent("run\u{0}.lock")
        XCTAssertThrowsError(try OwnedRunLock.acquire(at: invalid))
        XCTAssertThrowsError(try OwnedRunLock.probe(at: invalid))
    }
}
