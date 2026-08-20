import Darwin
import Foundation
import XCTest
@testable import LungfishIO

final class OwnedWorkDirectoryMarkerTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var workParent: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnedWorkDirectoryMarkerTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Example.lungfish", isDirectory: true)
        workParent = project.appendingPathComponent(".tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: workParent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreationWritesSchemaTwoIdentityBoundMarker() throws {
        let runID = UUID()
        let process = OwnedProcessIdentity(
            processIdentifier: 8123,
            processStartTime: 9_876_543,
            bootSessionID: "boot-A"
        )
        let request = OwnedWorkDirectoryCreationRequest(
            projectURL: project,
            parentDirectoryURL: workParent,
            prefix: "classify-",
            runID: runID,
            processIdentity: process,
            state: .active,
            lockRelativePath: "Analyses/.sample.run.lock",
            keepIntermediates: true,
            toolName: "lungfish-cli classify",
            toolVersion: "7.2.1"
        )

        let created = try OwnedWorkDirectoryMarkerStore.createDirectory(request)
        let marker = try OwnedWorkDirectoryMarkerStore.load(
            from: created,
            expectedProjectURL: project
        )

        XCTAssertEqual(marker.schemaVersion, 2)
        XCTAssertEqual(marker.projectIdentity, try FileSystemObjectIdentity.noFollow(project))
        XCTAssertEqual(marker.directoryIdentity, try FileSystemObjectIdentity.noFollow(created))
        XCTAssertEqual(marker.runID, runID)
        XCTAssertEqual(marker.processIdentifier, process.processIdentifier)
        XCTAssertEqual(marker.processStartTime, process.processStartTime)
        XCTAssertEqual(marker.bootSessionID, process.bootSessionID)
        XCTAssertEqual(marker.state, .active)
        XCTAssertEqual(marker.lockRelativePath, "Analyses/.sample.run.lock")
        XCTAssertTrue(marker.keepIntermediates)
        XCTAssertEqual(marker.toolName, "lungfish-cli classify")
        XCTAssertEqual(marker.toolVersion, "7.2.1")
    }

    func testCurrentProcessIdentityIncludesStartAndBootIdentity() throws {
        let identity = try OwnedProcessIdentity.current()
        XCTAssertEqual(identity.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertGreaterThan(identity.processStartTime, 0)
        XCTAssertFalse(identity.bootSessionID.isEmpty)
        XCTAssertNotNil(
            UUID(uuidString: identity.bootSessionID),
            "Boot authority must use the stable macOS boot-session UUID"
        )
        XCTAssertNil(try OwnedProcessIdentity.inspect(processIdentifier: Int32.max))
    }

    func testProcessIdentityRejectsPIDReuseAndReboot() {
        let marker = marker(
            process: OwnedProcessIdentity(
                processIdentifier: 42,
                processStartTime: 100,
                bootSessionID: "boot-A"
            )
        )

        XCTAssertTrue(marker.matchesProcessIdentity(.init(
            processIdentifier: 42,
            processStartTime: 100,
            bootSessionID: "boot-A"
        )))
        XCTAssertFalse(marker.matchesProcessIdentity(.init(
            processIdentifier: 42,
            processStartTime: 101,
            bootSessionID: "boot-A"
        )), "A reused PID is not the creating process")
        XCTAssertFalse(marker.matchesProcessIdentity(.init(
            processIdentifier: 42,
            processStartTime: 100,
            bootSessionID: "boot-B"
        )), "The same PID/start tuple after reboot is not authoritative")
    }

    func testTerminalCompletionStateIsPreserved() throws {
        let base = request(prefix: "completed-")
        let completed = OwnedWorkDirectoryCreationRequest(
            projectURL: base.projectURL,
            parentDirectoryURL: base.parentDirectoryURL,
            prefix: base.prefix,
            runID: base.runID,
            processIdentity: base.processIdentity,
            state: .completed,
            lockRelativePath: base.lockRelativePath,
            keepIntermediates: base.keepIntermediates,
            toolName: base.toolName,
            toolVersion: base.toolVersion
        )
        let directory = try OwnedWorkDirectoryMarkerStore.createDirectory(completed)
        XCTAssertEqual(
            try OwnedWorkDirectoryMarkerStore.load(
                from: directory,
                expectedProjectURL: project
            ).state,
            .completed
        )
    }

    func testBindExistingDirectoryAndDurablyTransitionItsMarker() throws {
        let directory = workParent.appendingPathComponent("pipeline-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let creation = request(prefix: "unused-")

        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            directory,
            request: creation
        )
        let active = try OwnedWorkDirectoryMarkerStore.load(
            from: directory,
            expectedProjectURL: project
        )
        XCTAssertEqual(active.state, .active)
        XCTAssertEqual(active.runID, creation.runID)

        try OwnedWorkDirectoryMarkerStore.transition(
            directory,
            expectedProjectURL: project,
            expectedRunID: creation.runID,
            to: .completed
        )
        let completed = try OwnedWorkDirectoryMarkerStore.load(
            from: directory,
            expectedProjectURL: project
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.directoryIdentity, active.directoryIdentity)
        XCTAssertEqual(completed.runID, active.runID)
    }

    func testBindExistingDirectoryMarkerDurabilityFailureRollsBackNewDirectory() throws {
        let directory = workParent.appendingPathComponent(
            "pipeline-marker-failure",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = ENOSPC
                return -1
            }
        ))

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                directory,
                request: request(prefix: "unused-"),
                atomicFileStore: store
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "A newly created workflow root must not survive without a durable ownership marker."
        )
    }

    func testCreateDirectoryChildOpenFailureRollsBackUnmarkedRoot() throws {
        var operations = OwnedWorkDirectoryMarkerStore.RollbackOperations()
        operations.openChild = { _, _ in
            errno = EACCES
            return -1
        }

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.createDirectory(
                request(prefix: "open-failure-"),
                rollbackOperations: operations
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "open owned work directory"
                ),
                error.localizedDescription
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: workParent,
                includingPropertiesForKeys: nil
            ).isEmpty,
            "A child-open failure must not leave an unmarked root."
        )
    }

    func testBindExistingDirectoryChildOpenFailureRollsBackUnmarkedRoot() throws {
        let directory = workParent.appendingPathComponent(
            "bind-open-failure",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        var operations = OwnedWorkDirectoryMarkerStore.RollbackOperations()
        operations.openChild = { _, _ in
            errno = EACCES
            return -1
        }

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                directory,
                request: request(prefix: "unused-"),
                rollbackOperations: operations
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(directory.path),
                error.localizedDescription
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "Binding failure must remove the exact newly created root."
        )
    }

    func testChildOpenAndRollbackFailureReportsPrimaryAndRetainedQuarantine() throws {
        let directory = workParent.appendingPathComponent(
            "combined-open-rollback-failure",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        var operations = OwnedWorkDirectoryMarkerStore.RollbackOperations(
            removeDirectory: { _, _ in
                errno = EPERM
                return -1
            }
        )
        operations.openChild = { _, _ in
            errno = EACCES
            return -1
        }

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                directory,
                request: request(prefix: "unused-"),
                rollbackOperations: operations
            )
        ) { error in
            let description = error.localizedDescription
            XCTAssertTrue(description.contains(directory.path), description)
            XCTAssertTrue(
                description.contains("open owned work directory"),
                description
            )
            XCTAssertTrue(
                description.contains(
                    ".lungfish-owned-rollback-pending-"
                ),
                description
            )
            XCTAssertTrue(description.contains("retained"), description)
            XCTAssertTrue(description.contains("errno 13"), description)
            XCTAssertTrue(description.contains("errno 1"), description)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let retained = try FileManager.default.contentsOfDirectory(
            at: workParent,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(
            retained[0].lastPathComponent.hasPrefix(
                ".lungfish-owned-rollback-pending-"
            )
        )
    }

    func testTransitionRejectsRunMismatchAndTerminalRewrite() throws {
        let creation = request(prefix: "transition-")
        let directory = try OwnedWorkDirectoryMarkerStore.createDirectory(creation)

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.transition(
                directory,
                expectedProjectURL: project,
                expectedRunID: UUID(),
                to: .failed
            )
        )
        XCTAssertEqual(
            try OwnedWorkDirectoryMarkerStore.load(
                from: directory,
                expectedProjectURL: project
            ).state,
            .active
        )

        try OwnedWorkDirectoryMarkerStore.transition(
            directory,
            expectedProjectURL: project,
            expectedRunID: creation.runID,
            to: .failed
        )
        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.transition(
                directory,
                expectedProjectURL: project,
                expectedRunID: creation.runID,
                to: .completed
            )
        )
    }

    func testLoadRejectsMarkerSymlinkAndSpecialFile() throws {
        let symlinkRequest = request(prefix: "unsafe-")
        let symlinkDirectory = try OwnedWorkDirectoryMarkerStore.createDirectory(symlinkRequest)
        let symlinkMarker = symlinkDirectory.appendingPathComponent(OwnedWorkDirectoryMarker.fileName)
        try FileManager.default.removeItem(at: symlinkMarker)
        try FileManager.default.createSymbolicLink(
            at: symlinkMarker,
            withDestinationURL: root.appendingPathComponent("missing")
        )
        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.load(
                from: symlinkDirectory,
                expectedProjectURL: project
            )
        )

        let fifoDirectory = try OwnedWorkDirectoryMarkerStore.createDirectory(request(prefix: "fifo-"))
        let fifoMarker = fifoDirectory.appendingPathComponent(OwnedWorkDirectoryMarker.fileName)
        try FileManager.default.removeItem(at: fifoMarker)
        XCTAssertEqual(mkfifo(fifoMarker.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.load(
                from: fifoDirectory,
                expectedProjectURL: project
            )
        )
    }

    func testLoadRejectsDirectorySubstitutionAndWrongProject() throws {
        let created = try OwnedWorkDirectoryMarkerStore.createDirectory(request(prefix: "identity-"))
        let markerURL = created.appendingPathComponent(OwnedWorkDirectoryMarker.fileName)
        let markerData = try Data(contentsOf: markerURL)
        try FileManager.default.removeItem(at: created)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
        try markerData.write(to: markerURL)

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.load(from: created, expectedProjectURL: project)
        )

        let otherProject = root.appendingPathComponent("Other.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.load(from: created, expectedProjectURL: otherProject)
        )
    }

    func testMarkerCreationFsyncsFileAndParent() throws {
        let recorder = SyncRecorder()
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { descriptor in
                recorder.recordFileSync()
                return Darwin.fsync(descriptor)
            },
            syncDirectory: { descriptor in
                recorder.recordDirectorySync()
                return Darwin.fsync(descriptor)
            }
        ))

        _ = try OwnedWorkDirectoryMarkerStore.createDirectory(
            request(prefix: "durable-"),
            atomicFileStore: store
        )

        XCTAssertGreaterThanOrEqual(recorder.fileSyncs, 1)
        XCTAssertGreaterThanOrEqual(recorder.directorySyncs, 1)
    }

    func testMarkerDurabilityFailureRollsBackNewDirectory() throws {
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = EIO
                return -1
            }
        ))

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.createDirectory(
                request(prefix: "rollback-"),
                atomicFileStore: store
            )
        )
        let children = try FileManager.default.contentsOfDirectory(
            at: workParent,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(children.isEmpty, "An undurable owned directory must not survive creation")
    }

    func testMarkerRollbackNeverMutatesAReplacementOrMovedOriginal() throws {
        let heldOriginal = workParent.appendingPathComponent(
            "held-original",
            isDirectory: true
        )
        let swap = MarkerRollbackSwap(
            parent: workParent,
            heldOriginal: heldOriginal
        )
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { descriptor in
                swap.replaceCreatedChild()
                return Darwin.fsync(descriptor)
            }
        ))

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.createDirectory(
                request(prefix: "rollback-swap-"),
                atomicFileStore: store
            )
        )

        XCTAssertNil(swap.mutationFailure)
        let replacement = try XCTUnwrap(swap.replacementURL)
        XCTAssertEqual(
            try Data(contentsOf: replacement.appendingPathComponent("replacement.txt")),
            Data("replacement".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: heldOriginal
                    .appendingPathComponent(OwnedWorkDirectoryMarker.fileName).path
            ),
            "Rollback must leave the moved original complete and recoverable"
        )
    }

    func testMarkerRollbackDetachSyncFailureRetainsAndReportsQuarantine() throws {
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { _ in
                errno = EIO
                return -1
            }
        ))

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.createDirectory(
                request(prefix: "rollback-sync-"),
                atomicFileStore: store,
                rollbackOperations: .init(
                    syncParent: { _ in
                        errno = EIO
                        return -1
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.creationAndRollbackFailed(
                path,
                initiatingError,
                rollbackError
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("rollback-sync-"))
            XCTAssertTrue(initiatingError.contains("fsync durable file"))
            XCTAssertTrue(initiatingError.contains("errno \(EIO)"))
            XCTAssertTrue(rollbackError.contains(".lungfish-owned-rollback-pending-"))
            XCTAssertTrue(rollbackError.contains("fsync owned rollback quarantine parent"))
            XCTAssertTrue(rollbackError.contains("errno \(EIO)"))
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: workParent,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix(".lungfish-owned-rollback-pending-") }
        )
    }

    func testMarkerRollbackRmdirFailureRetainsAndReportsQuarantine() throws {
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { _ in
                errno = EIO
                return -1
            }
        ))

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.createDirectory(
                request(prefix: "rollback-rmdir-"),
                atomicFileStore: store,
                rollbackOperations: .init(
                    removeDirectory: { _, _ in
                        errno = EACCES
                        return -1
                    }
                )
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.creationAndRollbackFailed(
                path,
                initiatingError,
                rollbackError
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("rollback-rmdir-"))
            XCTAssertTrue(initiatingError.contains("fsync durable file"))
            XCTAssertTrue(initiatingError.contains("errno \(EIO)"))
            XCTAssertTrue(rollbackError.contains(".lungfish-owned-rollback-pending-"))
            XCTAssertTrue(rollbackError.contains("remove owned rollback quarantine"))
            XCTAssertTrue(rollbackError.contains("errno \(EACCES)"))
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: workParent,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix(".lungfish-owned-rollback-pending-") }
        )
    }

    func testMarkerRollbackRemovalSyncFailureReportsUncertainDisposition() throws {
        let sync = MarkerRollbackSyncSequence()
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { _ in
                errno = EIO
                return -1
            }
        ))

        XCTAssertThrowsError(
            try OwnedWorkDirectoryMarkerStore.createDirectory(
                request(prefix: "rollback-final-sync-"),
                atomicFileStore: store,
                rollbackOperations: .init(syncParent: { sync.sync($0) })
            )
        ) { error in
            guard case let OwnedWorkDirectoryMarkerError.creationAndRollbackFailed(
                path,
                initiatingError,
                rollbackError
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.contains("rollback-final-sync-"))
            XCTAssertTrue(initiatingError.contains("fsync durable file"))
            XCTAssertTrue(initiatingError.contains("errno \(EIO)"))
            XCTAssertTrue(rollbackError.contains(".lungfish-owned-rollback-pending-"))
            XCTAssertTrue(rollbackError.contains("fsync owned rollback quarantine removal"))
            XCTAssertTrue(rollbackError.contains("errno \(EIO)"))
        }
    }

    func testCreateClosesProjectDescriptorWhenParentOpenFails() throws {
        let unsafeParent = project.appendingPathComponent("unsafe-parent", isDirectory: true)
        let outside = root.appendingPathComponent("outside-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafeParent, withDestinationURL: outside)
        let projectIdentity = try FileSystemObjectIdentity.noFollow(project)
        let unrelatedDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(unrelatedDescriptor, 0)
        var unrelatedDescriptorIsOpen = true
        defer {
            if unrelatedDescriptorIsOpen {
                Darwin.close(unrelatedDescriptor)
            }
        }
        let baseline = openDescriptorCount(matching: projectIdentity)

        for _ in 0..<128 {
            var failing = request(prefix: "leak-")
            failing = OwnedWorkDirectoryCreationRequest(
                projectURL: failing.projectURL,
                parentDirectoryURL: unsafeParent,
                prefix: failing.prefix,
                runID: failing.runID,
                processIdentity: failing.processIdentity,
                state: failing.state,
                lockRelativePath: failing.lockRelativePath,
                keepIntermediates: failing.keepIntermediates,
                toolName: failing.toolName,
                toolVersion: failing.toolVersion
            )
            XCTAssertThrowsError(try OwnedWorkDirectoryMarkerStore.createDirectory(failing))
        }

        XCTAssertEqual(Darwin.close(unrelatedDescriptor), 0)
        unrelatedDescriptorIsOpen = false
        XCTAssertEqual(openDescriptorCount(matching: projectIdentity), baseline)
    }

    func testLoadClosesDirectoryDescriptorWhenProjectOpenFails() throws {
        let directory = try OwnedWorkDirectoryMarkerStore.createDirectory(request(prefix: "load-leak-"))
        let unsafeProject = root.appendingPathComponent("unsafe-project", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: unsafeProject, withDestinationURL: project)
        let directoryIdentity = try FileSystemObjectIdentity.noFollow(directory)
        let unrelatedDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(unrelatedDescriptor, 0)
        var unrelatedDescriptorIsOpen = true
        defer {
            if unrelatedDescriptorIsOpen {
                Darwin.close(unrelatedDescriptor)
            }
        }
        let baseline = openDescriptorCount(matching: directoryIdentity)

        for _ in 0..<128 {
            XCTAssertThrowsError(
                try OwnedWorkDirectoryMarkerStore.load(
                    from: directory,
                    expectedProjectURL: unsafeProject
                )
            )
        }

        XCTAssertEqual(Darwin.close(unrelatedDescriptor), 0)
        unrelatedDescriptorIsOpen = false
        XCTAssertEqual(openDescriptorCount(matching: directoryIdentity), baseline)
    }

    func testRequestRejectsEmbeddedNULInPrefixAndLockPath() throws {
        let base = request(prefix: "safe-")
        let nulPrefix = OwnedWorkDirectoryCreationRequest(
            projectURL: base.projectURL,
            parentDirectoryURL: base.parentDirectoryURL,
            prefix: "unsafe\u{0}prefix",
            runID: base.runID,
            processIdentity: base.processIdentity,
            state: base.state,
            lockRelativePath: nil,
            keepIntermediates: base.keepIntermediates,
            toolName: base.toolName,
            toolVersion: base.toolVersion
        )
        XCTAssertThrowsError(try OwnedWorkDirectoryMarkerStore.createDirectory(nulPrefix))

        let nulLock = OwnedWorkDirectoryCreationRequest(
            projectURL: base.projectURL,
            parentDirectoryURL: base.parentDirectoryURL,
            prefix: base.prefix,
            runID: base.runID,
            processIdentity: base.processIdentity,
            state: base.state,
            lockRelativePath: "locks/run\u{0}.lock",
            keepIntermediates: base.keepIntermediates,
            toolName: base.toolName,
            toolVersion: base.toolVersion
        )
        XCTAssertThrowsError(try OwnedWorkDirectoryMarkerStore.createDirectory(nulLock))
    }

    func testFileSystemObjectIdentityRejectsSymlinkedAncestor() throws {
        let real = root.appendingPathComponent("identity-real", isDirectory: true)
        let child = real.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("identity-linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        XCTAssertThrowsError(
            try FileSystemObjectIdentity.noFollow(linked.appendingPathComponent("child"))
        )
    }

    private func request(prefix: String) -> OwnedWorkDirectoryCreationRequest {
        OwnedWorkDirectoryCreationRequest(
            projectURL: project,
            parentDirectoryURL: workParent,
            prefix: prefix,
            runID: UUID(),
            processIdentity: .init(
                processIdentifier: 123,
                processStartTime: 456,
                bootSessionID: "test-boot"
            ),
            state: .active,
            lockRelativePath: nil,
            keepIntermediates: false,
            toolName: "LungfishTests",
            toolVersion: "1"
        )
    }

    private func marker(process: OwnedProcessIdentity) -> OwnedWorkDirectoryMarker {
        OwnedWorkDirectoryMarker(
            projectIdentity: .init(device: 1, inode: 2),
            directoryIdentity: .init(device: 1, inode: 3),
            runID: UUID(),
            processIdentifier: process.processIdentifier,
            processStartTime: process.processStartTime,
            bootSessionID: process.bootSessionID,
            state: .active,
            lockRelativePath: nil,
            keepIntermediates: false,
            toolName: "test",
            toolVersion: "1"
        )
    }
}

private final class MarkerRollbackSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let heldOriginal: URL
    private var replacement: URL?
    private var failure: Error?

    var replacementURL: URL? { lock.withLock { replacement } }
    var mutationFailure: Error? { lock.withLock { failure } }

    init(parent: URL, heldOriginal: URL) {
        self.parent = parent
        self.heldOriginal = heldOriginal
    }

    func replaceCreatedChild() {
        lock.withLock {
            guard replacement == nil,
                  let child = try? FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: nil
                  ).first(where: { $0.lastPathComponent.hasPrefix("rollback-swap-") }) else {
                return
            }
            do {
                try FileManager.default.moveItem(at: child, to: heldOriginal)
                try FileManager.default.createDirectory(
                    at: child,
                    withIntermediateDirectories: false
                )
                try Data("replacement".utf8).write(
                    to: child.appendingPathComponent("replacement.txt")
                )
                replacement = child
            } catch {
                failure = error
            }
        }
    }
}

private final class MarkerRollbackSyncSequence: @unchecked Sendable {
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

private func openDescriptorCount(matching identity: FileSystemObjectIdentity) -> Int {
    let limit = Int(getdtablesize())
    return (0..<limit).reduce(into: 0) { count, descriptor in
        var info = stat()
        if Darwin.fstat(Int32(descriptor), &info) == 0,
           info.st_dev >= 0,
           info.st_ino >= 0,
           FileSystemObjectIdentity(from: info) == identity {
            count += 1
        }
    }
}

private final class SyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFileSyncs = 0
    private var recordedDirectorySyncs = 0

    var fileSyncs: Int { lock.withLock { recordedFileSyncs } }
    var directorySyncs: Int { lock.withLock { recordedDirectorySyncs } }

    func recordFileSync() { lock.withLock { recordedFileSyncs += 1 } }
    func recordDirectorySync() { lock.withLock { recordedDirectorySyncs += 1 } }
}
