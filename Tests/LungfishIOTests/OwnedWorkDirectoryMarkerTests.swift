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

private final class SyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFileSyncs = 0
    private var recordedDirectorySyncs = 0

    var fileSyncs: Int { lock.withLock { recordedFileSyncs } }
    var directorySyncs: Int { lock.withLock { recordedDirectorySyncs } }

    func recordFileSync() { lock.withLock { recordedFileSyncs += 1 } }
    func recordDirectorySync() { lock.withLock { recordedDirectorySyncs += 1 } }
}
