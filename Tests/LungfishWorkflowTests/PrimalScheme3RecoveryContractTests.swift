import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimalScheme3RecoveryContractTests: XCTestCase {
    func testGapCompletionRejectsMissingReports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2, terminalGapPolicy: .legacy, gapCompletionParent: root)
        XCTAssertThrowsError(try PrimalScheme3RecoveryContract.validate(at: root, options: options, configuration: [:]))
    }

    func testGapCompletionRejectsNegativeFreshValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report: [String: Any] = ["schemaVersion": "primalscheme3.gap-completion/v1", "followup": ["poolCount": 2]]
        let coverage: [String: Any] = ["schemaVersion": "primalscheme3.gap-completion-coverage/v1", "freshValidation": ["status": "failed"]]
        try JSONSerialization.data(withJSONObject: report).write(to: root.appendingPathComponent("gap-completion.json"))
        try JSONSerialization.data(withJSONObject: coverage).write(to: root.appendingPathComponent("gap-completion-coverage.json"))
        let options = PrimalScheme3DesignOptions(ampliconSize: 200, poolCount: 2, terminalGapPolicy: .legacy, gapCompletionParent: root)
        XCTAssertThrowsError(try PrimalScheme3RecoveryContract.validate(at: root, options: options, configuration: ["gap_completion_report": "gap-completion.json", "gap_completion_coverage": "gap-completion-coverage.json"]))
    }
}
