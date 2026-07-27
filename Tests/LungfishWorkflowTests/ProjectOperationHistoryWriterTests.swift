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
    }
}
