import Darwin
import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ProjectOperationHistoryWriterTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectOperationHistoryWriterTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Example.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreatesExclusiveAppendOnlyUUIDDirectoryAndPayloads() throws {
        let operationID = UUID()
        let writer = ProjectOperationHistoryWriter(projectURL: project)
        let directory = try writer.createOperation(
            operationID: operationID,
            payloads: [
                "failure.json": Data(#"{"status":"failed"}"#.utf8),
                "stderr.txt": Data("problem\n".utf8),
            ]
        )

        XCTAssertEqual(directory.lastPathComponent, operationID.uuidString.lowercased())
        XCTAssertEqual(
            directory.deletingLastPathComponent().lastPathComponent,
            ProjectOperationHistoryWriter.historyDirectoryName
        )
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("stderr.txt"), encoding: .utf8),
            "problem\n"
        )

        XCTAssertThrowsError(
            try writer.createOperation(operationID: operationID, payloads: [:])
        )
        XCTAssertThrowsError(
            try writer.append(
                Data("replacement".utf8),
                named: "stderr.txt",
                toOperation: operationID
            )
        )
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("stderr.txt"), encoding: .utf8),
            "problem\n",
            "History payloads are immutable once published"
        )
    }

    func testAppendCreatesNewPayloadButNeverCreatesMissingOperation() throws {
        let operationID = UUID()
        let writer = ProjectOperationHistoryWriter(projectURL: project)
        _ = try writer.createOperation(operationID: operationID, payloads: [:])
        let appended = try writer.append(
            Data("disposed".utf8),
            named: "disposition.json",
            toOperation: operationID
        )
        XCTAssertEqual(try Data(contentsOf: appended), Data("disposed".utf8))

        XCTAssertThrowsError(
            try writer.append(
                Data(),
                named: "orphan.json",
                toOperation: UUID()
            )
        )
    }

    func testRejectsTraversalSymlinksAndSpecialFiles() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let history = project.appendingPathComponent(ProjectOperationHistoryWriter.historyDirectoryName)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: outside)
        let writer = ProjectOperationHistoryWriter(projectURL: project)
        XCTAssertThrowsError(try writer.createOperation(operationID: UUID(), payloads: [:]))

        try FileManager.default.removeItem(at: history)
        XCTAssertEqual(mkfifo(history.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(try writer.createOperation(operationID: UUID(), payloads: [:]))
    }

    func testRejectsProjectRootSymlink() throws {
        let outside = root.appendingPathComponent("outside-project", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedProject = root.appendingPathComponent("Linked.lungfish", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProject,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try ProjectOperationHistoryWriter(projectURL: linkedProject)
                .createOperation(operationID: UUID(), payloads: [:])
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty
        )
    }

    func testPayloadFailureRollsBackNewOperationDirectory() throws {
        let store = DurableAtomicFileStore(operations: .init(
            syncFile: { Darwin.fsync($0) },
            syncDirectory: { _ in
                errno = EIO
                return -1
            }
        ))
        let operationID = UUID()
        let writer = ProjectOperationHistoryWriter(
            projectURL: project,
            atomicFileStore: store
        )

        XCTAssertThrowsError(
            try writer.createOperation(
                operationID: operationID,
                payloads: ["failure.json": Data("{}".utf8)]
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: writer.operationDirectoryURL(for: operationID).path
            )
        )
        let visibleOperations = try FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent(
                ProjectOperationHistoryWriter.historyDirectoryName,
                isDirectory: true
            ),
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertTrue(visibleOperations.isEmpty)
    }

    func testInitialPayloadsStayHiddenUntilWholeOperationPublishes() throws {
        let operationID = UUID()
        let observation = HistoryPublicationObservation()
        let writer = ProjectOperationHistoryWriter(
            projectURL: project,
            operations: .init(beforePublish: { staging, final in
                observation.record(
                    stagingExists: FileManager.default.fileExists(atPath: staging.path),
                    finalExists: FileManager.default.fileExists(atPath: final.path),
                    payload: try? Data(contentsOf: staging.appendingPathComponent("failure.json")),
                    stagingPath: staging.path
                )
            })
        )

        _ = try writer.createOperation(
            operationID: operationID,
            payloads: ["failure.json": Data("complete".utf8)]
        )

        XCTAssertTrue(observation.stagingExists)
        XCTAssertFalse(observation.finalExists)
        XCTAssertEqual(observation.payload, Data("complete".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: observation.stagingPath ?? "")
        )
    }

    func testChildProcessPublicationWinnerAndAppendAreNeverDeleted() throws {
        let operationID = UUID()
        let writer = ProjectOperationHistoryWriter(
            projectURL: project,
            operations: .init(beforePublish: { _, final in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [
                    "-c",
                    "import os,sys; os.mkdir(sys.argv[1]); open(os.path.join(sys.argv[1], 'child.txt'), 'wb').write(b'child-winner')",
                    final.path,
                ]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ChildProcessFailure(status: process.terminationStatus)
                }
            })
        )

        XCTAssertThrowsError(
            try writer.createOperation(
                operationID: operationID,
                payloads: ["parent.txt": Data("parent-loser".utf8)]
            )
        )
        let final = writer.operationDirectoryURL(for: operationID)
        XCTAssertEqual(
            try Data(contentsOf: final.appendingPathComponent("child.txt")),
            Data("child-winner".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: final.appendingPathComponent("parent.txt").path)
        )
        let staging = try FileManager.default.contentsOfDirectory(
            at: final.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".")
                && $0.lastPathComponent.contains(operationID.uuidString.lowercased())
        }
        XCTAssertTrue(staging.isEmpty)
    }

    func testStagingRollbackNeverMutatesAReplacementOrMovedOriginal() throws {
        let operationID = UUID()
        let held = project.appendingPathComponent(
            ProjectOperationHistoryWriter.historyDirectoryName,
            isDirectory: true
        ).appendingPathComponent(".held-original", isDirectory: true)
        let observation = HistoryRollbackSwap(heldOriginal: held)
        let writer = ProjectOperationHistoryWriter(
            projectURL: project,
            operations: .init(beforePublish: { staging, _ in
                try observation.replace(staging: staging)
                throw ForcedHistoryFailure()
            })
        )

        XCTAssertThrowsError(
            try writer.createOperation(
                operationID: operationID,
                payloads: ["parent.txt": Data("parent-original".utf8)]
            )
        )

        let replacement = try XCTUnwrap(observation.replacementURL)
        XCTAssertEqual(
            try Data(contentsOf: replacement.appendingPathComponent("replacement.txt")),
            Data("replacement".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: held.appendingPathComponent("parent.txt")),
            Data("parent-original".utf8),
            "Rollback must leave the moved staging directory complete and recoverable"
        )
    }

    func testRejectsEmbeddedNULInPayloadName() {
        XCTAssertThrowsError(
            try ProjectOperationHistoryWriter(projectURL: project).createOperation(
                operationID: UUID(),
                payloads: ["bad\u{0}.json": Data()]
            )
        )
    }
}

private final class HistoryPublicationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (Bool, Bool, Data?, String?) = (false, true, nil, nil)

    var stagingExists: Bool { lock.withLock { values.0 } }
    var finalExists: Bool { lock.withLock { values.1 } }
    var payload: Data? { lock.withLock { values.2 } }
    var stagingPath: String? { lock.withLock { values.3 } }

    func record(
        stagingExists: Bool,
        finalExists: Bool,
        payload: Data?,
        stagingPath: String
    ) {
        lock.withLock {
            values = (stagingExists, finalExists, payload, stagingPath)
        }
    }
}

private struct ChildProcessFailure: Error {
    let status: Int32
}

private struct ForcedHistoryFailure: Error {}

private final class HistoryRollbackSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let heldOriginal: URL
    private var replacement: URL?

    var replacementURL: URL? { lock.withLock { replacement } }

    init(heldOriginal: URL) {
        self.heldOriginal = heldOriginal
    }

    func replace(staging: URL) throws {
        try lock.withLock {
            try FileManager.default.moveItem(at: staging, to: heldOriginal)
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            try Data("replacement".utf8).write(
                to: staging.appendingPathComponent("replacement.txt")
            )
            replacement = staging
        }
    }
}
