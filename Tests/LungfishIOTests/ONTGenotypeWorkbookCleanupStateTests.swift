@testable import LungfishIO
import Darwin
import Foundation
import XCTest

final class ONTGenotypeWorkbookCleanupStateTests: XCTestCase {
    func testZeroByteRebaseClassifierAcceptsDifferingBeforeAndAgreedPostSnapshots() {
        let before = snapshot(
            device: 9,
            inode: 10,
            type: mode_t(S_IFREG),
            size: 0
        )
        let postDescriptor = snapshot(
            device: 9,
            inode: 11,
            type: mode_t(S_IFREG),
            size: 0
        )
        let postPath = postDescriptor

        XCTAssertEqual(
            ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: before,
                postDescriptor: postDescriptor,
                postPath: postPath,
                mechanism: .reservationFallback,
                originalNameIsAbsent: true
            ),
            .rebased(device: 9, inode: 11)
        )
    }

    func testFallbackCleanupAcceptsOnlyWitnessedZeroByteRegularFileInodeRebase() throws {
        let before = snapshot(inode: 101, type: mode_t(S_IFREG), size: 0)
        let post = snapshot(inode: 202, type: mode_t(S_IFREG), size: 0)

        XCTAssertEqual(
            ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: before,
                postDescriptor: post,
                postPath: post,
                mechanism: .reservationFallback,
                originalNameIsAbsent: true
            ),
            .rebased(device: post.st_dev, inode: post.st_ino)
        )
        XCTAssertEqual(
            ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: before,
                postDescriptor: post,
                postPath: post,
                mechanism: .nativeExclusive,
                originalNameIsAbsent: true
            ),
            .reject
        )
        XCTAssertEqual(
            ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: before,
                postDescriptor: post,
                postPath: post,
                mechanism: .reservationFallback,
                originalNameIsAbsent: false
            ),
            .reject
        )

        let fixture = try directoryFixture(fileContents: Data())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receivedBorrowedWitness = LockedFlag()
        let operations = forcedFallbackOperations { witness in
            receivedBorrowedWitness.value = witness != nil
        }

        try ONTGenotypeWorkbookCleanupStateStore
            .removeContentsNoFollowForTesting(
                at: fixture.directory,
                cleanupOperations: operations
            )

        XCTAssertTrue(receivedBorrowedWitness.value)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.directory.path
            ).isEmpty
        )
    }

    func testFallbackCleanupRejectsNonzeroRegularFileInodeRebase() throws {
        let before = snapshot(inode: 101, type: mode_t(S_IFREG), size: 7)
        let post = snapshot(inode: 202, type: mode_t(S_IFREG), size: 7)

        XCTAssertEqual(
            ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: before,
                postDescriptor: post,
                postPath: post,
                mechanism: .reservationFallback,
                originalNameIsAbsent: true
            ),
            .reject
        )

        let bytes = Data("nonzero".utf8)
        let fixture = try directoryFixture(fileContents: bytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = fixture.root.appendingPathComponent("held-nonzero")
        let swapped = LockedFlag()
        var operations = ONTGenotypeWorkbookCleanupOperations.darwin
        operations.renameExclusive = {
            sourceParent,
            source,
            destinationParent,
            destination,
            flags,
            witness in
            let sourceName = String(cString: source)
            var renameOperations = PortableExclusiveRename.Operations()
            renameOperations.nativeRename = { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
            renameOperations.afterFinalWitnessValidation = {
                guard !swapped.value else { return }
                swapped.value = true
                let sourceURL = fixture.directory.appendingPathComponent(
                    sourceName
                )
                try? FileManager.default.moveItem(at: sourceURL, to: held)
                try? bytes.write(to: sourceURL)
            }
            return PortableExclusiveRename.renameatxNPReporting(
                sourceParent,
                source,
                destinationParent,
                destination,
                flags,
                sourceWitness: witness,
                operations: renameOperations
            )
        }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookCleanupStateStore
                .removeContentsNoFollowForTesting(
                    at: fixture.directory,
                    cleanupOperations: operations
                )
        )

        XCTAssertEqual(try Data(contentsOf: held), bytes)
        let preserved = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0]), bytes)
    }

    func testFallbackCleanupRejectsZeroByteMetadataChangeBeforeDetach() throws {
        let before = snapshot(inode: 101, type: mode_t(S_IFREG), size: 0)
        var post = snapshot(inode: 202, type: mode_t(S_IFREG), size: 0)
        post.st_mtimespec.tv_nsec += 1

        XCTAssertEqual(
            ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                before: before,
                postDescriptor: post,
                postPath: post,
                mechanism: .reservationFallback,
                originalNameIsAbsent: true
            ),
            .reject
        )

        let fixture = try directoryFixture(fileContents: Data())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renameWasCalled = LockedFlag()
        let operations = forcedFallbackOperations { _ in
            renameWasCalled.value = true
        }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookCleanupStateStore
                .removeContentsNoFollowForTesting(
                    at: fixture.directory,
                    failureInjector: { checkpoint in
                        guard checkpoint.hasPrefix(
                            "before-workbook-cleanup-nondirectory-detach:"
                        ) else { return }
                        try FileManager.default.setAttributes(
                            [.posixPermissions: NSNumber(value: 0o700)],
                            ofItemAtPath: fixture.entry.path
                        )
                    },
                    cleanupOperations: operations
                )
        )

        XCTAssertFalse(renameWasCalled.value)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.entry.path)
        )
    }

    func testFallbackCleanupRejectsDirectorySymlinkAndSpecialEntryRebase() throws {
        for type in [mode_t(S_IFDIR), mode_t(S_IFLNK), mode_t(S_IFIFO)] {
            let before = snapshot(inode: 101, type: type, size: 0)
            let post = snapshot(inode: 202, type: type, size: 0)
            XCTAssertEqual(
                ONTGenotypeWorkbookCleanupRebaseClassifier.classify(
                    before: before,
                    postDescriptor: post,
                    postPath: post,
                    mechanism: .reservationFallback,
                    originalNameIsAbsent: true
                ),
                .reject
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lungfish-cleanup-entry-types-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        let child = directory.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: true
        )
        try Data("nested".utf8).write(
            to: child.appendingPathComponent("entry.txt")
        )
        let outside = root.appendingPathComponent("outside.txt")
        let outsideBytes = Data("must-survive".utf8)
        try outsideBytes.write(to: outside)
        let link = directory.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )
        let fifo = directory.appendingPathComponent("entry.fifo")
        guard Darwin.mkfifo(fifo.path, 0o600) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }

        try ONTGenotypeWorkbookCleanupStateStore
            .removeContentsNoFollowForTesting(at: directory)

        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).isEmpty
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    func testFallbackCleanupRejectsSourceSubstitutionBeforeDetach() throws {
        let fixture = try directoryFixture(fileContents: Data())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = fixture.root.appendingPathComponent("held-original")
        let replacement = Data("replacement".utf8)
        var operations = ONTGenotypeWorkbookCleanupOperations.darwin
        operations.renameExclusive = {
            sourceParent,
            source,
            destinationParent,
            destination,
            flags,
            witness in
            var renameOperations = PortableExclusiveRename.Operations()
            renameOperations.nativeRename = { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
            return PortableExclusiveRename.renameatxNPReporting(
                sourceParent,
                source,
                destinationParent,
                destination,
                flags,
                sourceWitness: witness,
                operations: renameOperations
            )
        }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookCleanupStateStore
                .removeContentsNoFollowForTesting(
                    at: fixture.directory,
                    failureInjector: { checkpoint in
                        guard checkpoint.hasPrefix(
                            "before-workbook-cleanup-nondirectory-detach:"
                        ) else { return }
                        try FileManager.default.moveItem(
                            at: fixture.entry,
                            to: held
                        )
                        try replacement.write(to: fixture.entry)
                    },
                    cleanupOperations: operations
                )
        )

        XCTAssertEqual(try Data(contentsOf: held), Data())
        XCTAssertEqual(try Data(contentsOf: fixture.entry), replacement)
    }

    func testFallbackCleanupRejectsMetadataIdenticalSourceSubstitutionAfterFinalValidationBeforeRename() throws {
        let fixture = try directoryFixture(fileContents: Data())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = fixture.root.appendingPathComponent("held-original")
        let replacement = Data()
        let swapped = LockedFlag()

        var operations = ONTGenotypeWorkbookCleanupOperations.darwin
        operations.renameExclusive = {
            sourceParent,
            source,
            destinationParent,
            destination,
            flags,
            witness in
            let sourceName = String(cString: source)
            var renameOperations = PortableExclusiveRename.Operations()
            renameOperations.nativeRename = { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
            renameOperations.afterFinalWitnessValidation = {
                guard !swapped.value else { return }
                swapped.value = true
                let sourceURL = fixture.directory.appendingPathComponent(
                    sourceName
                )
                try? FileManager.default.moveItem(at: sourceURL, to: held)
                try? replacement.write(to: sourceURL)
            }
            return PortableExclusiveRename.renameatxNPReporting(
                sourceParent,
                source,
                destinationParent,
                destination,
                flags,
                sourceWitness: witness,
                operations: renameOperations
            )
        }

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookCleanupStateStore
                .removeContentsNoFollowForTesting(
                    at: fixture.directory,
                    cleanupOperations: operations
                )
        )

        XCTAssertEqual(try Data(contentsOf: held), Data())
        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(try Data(contentsOf: entries[0]), replacement)
    }

    func testFallbackCleanupRejectsTombstoneSubstitutionBeforeUnlink() throws {
        let fixture = try directoryFixture(
            fileContents: Data("original".utf8)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = fixture.root.appendingPathComponent("held-tombstone")
        let replacement = Data("replacement".utf8)

        XCTAssertThrowsError(
            try ONTGenotypeWorkbookCleanupStateStore
                .removeContentsNoFollowForTesting(
                    at: fixture.directory,
                    failureInjector: { checkpoint in
                        guard checkpoint.hasPrefix(
                            "before-workbook-cleanup-nondirectory-unlink:"
                        ) else { return }
                        let path = String(
                            checkpoint.dropFirst(
                                "before-workbook-cleanup-nondirectory-unlink:"
                                    .count
                            )
                        )
                        let tombstone = URL(fileURLWithPath: path)
                        try FileManager.default.moveItem(
                            at: tombstone,
                            to: held
                        )
                        try replacement.write(to: tombstone)
                    }
                )
        )

        XCTAssertEqual(
            try Data(contentsOf: held),
            Data("original".utf8)
        )
        let remaining = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try Data(contentsOf: remaining[0]), replacement)
    }

    func testCleanupOrderingHasNoCallbackBetweenFinalTombstoneWitnessAndUnlink() throws {
        let fixture = try directoryFixture(fileContents: Data())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = LockedStrings()
        var operations = ONTGenotypeWorkbookCleanupOperations.darwin
        operations.checkpoint = { event in events.append(event) }

        try ONTGenotypeWorkbookCleanupStateStore
            .removeContentsNoFollowForTesting(
                at: fixture.directory,
                cleanupOperations: operations
            )

        let final = try XCTUnwrap(
            events.values.firstIndex {
                $0.hasPrefix("before-final-tombstone-witness:")
            }
        )
        XCTAssertEqual(
            events.values[(final + 1)...].map {
                $0.split(separator: ":", maxSplits: 1).first.map(String.init)
            },
            ["after-nondirectory-unlink"]
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.directory.path
            ).isEmpty
        )
    }

    private func snapshot(
        device: dev_t = 7,
        inode: ino_t,
        type: mode_t,
        size: off_t
    ) -> stat {
        var value = stat()
        value.st_dev = device
        value.st_ino = inode
        value.st_mode = type | 0o640
        value.st_size = size
        value.st_mtimespec = timespec(tv_sec: 100, tv_nsec: 200)
        value.st_ctimespec = timespec(tv_sec: 300, tv_nsec: 400)
        return value
    }

    private func forcedFallbackOperations(
        observeWitness: @escaping @Sendable (
            PortableExclusiveRename.RegularSourceWitness?
        ) -> Void = { _ in }
    ) -> ONTGenotypeWorkbookCleanupOperations {
        var operations = ONTGenotypeWorkbookCleanupOperations.darwin
        operations.renameExclusive = {
            sourceParent,
            source,
            destinationParent,
            destination,
            flags,
            witness in
            observeWitness(witness)
            var renameOperations = PortableExclusiveRename.Operations()
            renameOperations.nativeRename = { _, _, _, _, _ in
                errno = ENOTSUP
                return -1
            }
            return PortableExclusiveRename.renameatxNPReporting(
                sourceParent,
                source,
                destinationParent,
                destination,
                flags,
                sourceWitness: witness,
                operations: renameOperations
            )
        }
        return operations
    }

    private func directoryFixture(
        fileContents: Data
    ) throws -> (root: URL, directory: URL, entry: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lungfish-cleanup-state-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let directory = root.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let entry = directory.appendingPathComponent("entry.tsv")
        try fileContents.write(to: entry)
        return (root, directory, entry)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
