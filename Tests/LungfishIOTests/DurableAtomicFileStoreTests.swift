import Darwin
import Foundation
import XCTest
@testable import LungfishIO

final class DurableAtomicFileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableAtomicFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDirectoryFsyncFailureNeverUnlinksSubstitutedDestination() throws {
        let destination = root.appendingPathComponent("record.json")
        let recoveredOriginal = root.appendingPathComponent("record.recovery.json")
        let swap = FsyncFailureSwap(
            destination: destination,
            recoveredOriginal: recoveredOriginal
        )
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { descriptor in swap.sync(descriptor: descriptor) }
        ))

        XCTAssertThrowsError(
            try store.create(Data("published".utf8), named: "record.json", in: root)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("substitute".utf8),
            "Rollback must preserve a destination that no longer has the published inode"
        )
        XCTAssertEqual(
            try Data(contentsOf: recoveredOriginal),
            Data("published".utf8),
            "Ambiguous published data must remain recoverable"
        )
    }

    func testRollbackDetachRevalidatesAfterIdentityCheckBeforeRemovingAnything() throws {
        let destination = root.appendingPathComponent("record.json")
        let recoveredOriginal = root.appendingPathComponent("record.recovery.json")
        let swap = RollbackDetachSwap(
            destination: destination,
            recoveredOriginal: recoveredOriginal
        )
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = EIO
                return -1
            },
            beforeRollbackDetach: {
                swap.installSubstitute()
            }
        ))

        XCTAssertThrowsError(
            try store.create(Data("published".utf8), named: "record.json", in: root)
        )
        XCTAssertNil(swap.mutationFailure)
        XCTAssertEqual(try Data(contentsOf: destination), Data("substitute".utf8))
        XCTAssertEqual(try Data(contentsOf: recoveredOriginal), Data("published".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.contains("rollback-pending") }
        )
    }

    func testRejectsEmbeddedNULBeforeAnyFilesystemMutation() throws {
        XCTAssertThrowsError(
            try DurableAtomicFileStore().create(
                Data("unsafe".utf8),
                named: "record\u{0}.json",
                in: root
            )
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

private final class RollbackDetachSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let recoveredOriginal: URL
    private var swapped = false
    private var failure: Error?

    var mutationFailure: Error? { lock.withLock { failure } }

    init(destination: URL, recoveredOriginal: URL) {
        self.destination = destination
        self.recoveredOriginal = recoveredOriginal
    }

    func installSubstitute() {
        lock.withLock {
            guard !swapped else { return }
            swapped = true
            do {
                try FileManager.default.moveItem(at: destination, to: recoveredOriginal)
                try Data("substitute".utf8).write(to: destination)
            } catch {
                failure = error
            }
        }
    }
}

private final class FsyncFailureSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let recoveredOriginal: URL
    private var hasFailed = false

    init(destination: URL, recoveredOriginal: URL) {
        self.destination = destination
        self.recoveredOriginal = recoveredOriginal
    }

    func sync(descriptor: Int32) -> Int32 {
        lock.withLock {
            if !hasFailed {
                hasFailed = true
                do {
                    try FileManager.default.moveItem(at: destination, to: recoveredOriginal)
                    try Data("substitute".utf8).write(to: destination)
                } catch {
                    errno = EIO
                    return -1
                }
                errno = EIO
                return -1
            }
            return Darwin.fsync(descriptor)
        }
    }
}
