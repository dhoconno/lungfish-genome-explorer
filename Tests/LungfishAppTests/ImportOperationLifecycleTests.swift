import XCTest
import SQLite3
@testable import LungfishApp
@testable import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ImportOperationLifecycleTests: XCTestCase {
    func testReferenceImportSuccessAttachesFinalBundleAndDeliversOnce() async throws {
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        let source = URL(fileURLWithPath: "/tmp/synthetic.fa")
        let output = URL(fileURLWithPath: "/tmp/synthetic.lungfishref", isDirectory: true)
        var deliveries: [[URL]] = []
        center.onBundleReady = { deliveries.append($0) }
        // The sidebar drop's route since A48 M4, `import fasta` on the Reference Import row.
        let result = await MainSplitViewController.importDroppedReference(
            sourceURL: source, projectURL: output.deletingLastPathComponent(), routeContext: nil, reporter: center
        ) { _, _ in
            CLISubprocessTransport.Result(outputs: [output.path], message: "Reference import complete", artifacts: [])
        }
        XCTAssertEqual(result, .imported(output))
        XCTAssertEqual(center.items.count, 1)
        XCTAssertEqual(center.items.first?.state, .completed)
        XCTAssertEqual(center.items.first?.bundleURLs, [output])
        XCTAssertEqual(deliveries, [[output]])
    }

    func testReferenceImportFailureAfterCleanupLeavesNoRunningRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stage = directory.appendingPathComponent("staged")
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        let result = await MainSplitViewController.importDroppedReference(
            sourceURL: directory.appendingPathComponent("synthetic.fa"), projectURL: directory, routeContext: nil, reporter: center
        ) { _, _ in
            try Data("synthetic".utf8).write(to: stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            throw CocoaError(.fileReadCorruptFile)
        }
        guard case .failed = result else { return XCTFail("a failed run fails the drop, got \(result)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(center.items.count, 1)
        XCTAssertEqual(center.items.first?.state, .failed)
        XCTAssertTrue(center.items.first?.bundleURLs.isEmpty == true)
    }

    func testOldImportStagingCleanupCannotRemoveReplacementDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let replacement = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let final = root.appendingPathComponent("same.db")
        try Data("old".utf8).write(to: old.directory.appendingPathComponent("same.db"))
        let publication = try replacement.prepareSQLiteCopy(filename: "same.db", from: final)
        var staged: OpaquePointer?
        guard sqlite3_open(publication.stagedURL.path, &staged) == SQLITE_OK, let staged else { throw CocoaError(.fileWriteUnknown) }
        let status = sqlite3_exec(staged, "CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES('new');", nil, nil, nil)
        sqlite3_close(staged)
        XCTAssertEqual(status, SQLITE_OK)
        try old.cleanup()
        try publication.publish {}
        try old.cleanup()
        var reader: OpaquePointer?
        guard sqlite3_open(final.path, &reader) == SQLITE_OK, let reader else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(reader) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(reader, "SELECT value FROM fixture", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let value = try XCTUnwrap(sqlite3_column_text(statement, 0))
        XCTAssertEqual(String(cString: value), "new")
    }

}
