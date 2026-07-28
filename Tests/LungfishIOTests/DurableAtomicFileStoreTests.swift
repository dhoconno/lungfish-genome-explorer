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

    func testRollbackDetachSyncFailureRetainsAndReportsQuarantine() throws {
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = EIO
                return -1
            },
            syncRollbackDirectory: { _ in
                errno = EIO
                return -1
            }
        ))

        XCTAssertThrowsError(
            try store.create(Data("recoverable".utf8), named: "record.json", in: root)
        ) { error in
            guard case let DurableAtomicFileStore.StoreError.rollbackQuarantineRetained(
                path,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("rollback-pending"))
            XCTAssertEqual(operation, "fsync durable rollback quarantine parent")
            XCTAssertEqual(code, EIO)
        }
        let quarantine = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.contains("rollback-pending") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("recoverable".utf8))
    }

    func testRollbackUnlinkFailureRetainsAndReportsQuarantine() throws {
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = EIO
                return -1
            },
            removeRollbackFile: { _, _ in
                errno = EACCES
                return -1
            }
        ))

        XCTAssertThrowsError(
            try store.create(Data("recoverable".utf8), named: "record.json", in: root)
        ) { error in
            guard case let DurableAtomicFileStore.StoreError.rollbackQuarantineRetained(
                path,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("rollback-pending"))
            XCTAssertEqual(operation, "remove durable rollback quarantine")
            XCTAssertEqual(code, EACCES)
        }
        let quarantine = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.contains("rollback-pending") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantine), Data("recoverable".utf8))
    }

    func testRollbackRemovalSyncFailureReportsUncertainDisposition() throws {
        let rollbackSync = DurableRollbackSyncSequence()
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = EIO
                return -1
            },
            syncRollbackDirectory: { rollbackSync.sync($0) }
        ))

        XCTAssertThrowsError(
            try store.create(Data("published".utf8), named: "record.json", in: root)
        ) { error in
            guard case let DurableAtomicFileStore.StoreError.rollbackRemovalDurabilityUncertain(
                path,
                operation,
                code
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("rollback-pending"))
            XCTAssertEqual(operation, "fsync durable rollback quarantine removal")
            XCTAssertEqual(code, EIO)
        }
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

    func testUnsupportedExclusiveRenameFallsBackToExclusiveFileCreation() throws {
        let store = DurableAtomicFileStore(operations: .init(
            renameExclusive: { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
        ))

        let destination = try store.create(
            Data("portable".utf8),
            named: "record.json",
            in: root
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("portable".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["record.json"]
        )
    }

    func testUnsupportedExclusiveRenamePreservesExistingDestination() throws {
        let destination = root.appendingPathComponent("record.json")
        try Data("existing".utf8).write(to: destination)
        let store = DurableAtomicFileStore(operations: .init(
            renameExclusive: { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
        ))

        XCTAssertThrowsError(
            try store.create(Data("replacement".utf8), named: "record.json", in: root)
        ) { error in
            guard case DurableAtomicFileStore.StoreError.destinationExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["record.json"]
        )
    }

    func testExclusiveRenameFallbackPublishesDirectoryContents() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))

        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                PortableExclusiveRename.fallbackExclusiveRename(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath
                )
            }
        }

        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload.txt")),
            Data("payload".utf8)
        )
    }

    func testExclusiveRenameFallbackPreservesExistingDirectory() throws {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appendingPathComponent("source.txt"))
        try Data("destination".utf8).write(
            to: destination.appendingPathComponent("destination.txt")
        )

        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                PortableExclusiveRename.fallbackExclusiveRename(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath
                )
            }
        }

        XCTAssertEqual(status, -1)
        XCTAssertEqual(errno, EEXIST)
        XCTAssertEqual(
            try Data(contentsOf: source.appendingPathComponent("source.txt")),
            Data("source".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("destination.txt")),
            Data("destination".utf8)
        )
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

private final class DurableRollbackSyncSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func sync(_ descriptor: Int32) -> Int32 {
        lock.withLock {
            callCount += 1
            if callCount == 2 {
                errno = EIO
                return -1
            }
            return Darwin.fsync(descriptor)
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
