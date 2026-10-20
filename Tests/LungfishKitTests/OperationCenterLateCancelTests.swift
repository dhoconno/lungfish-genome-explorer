// OperationCenterLateCancelTests.swift - Which result a cancelling row settles with
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.47 (M842, UX W5). Only a CLI leaf that committed first, which the bridge reports with
// `committed`, settles a cancelling row Completed. Every other completion of a cancelling row reads Cancelled by user.

import Foundation
import XCTest
@testable import LungfishKit

@MainActor
final class OperationCenterLateCancelTests: XCTestCase {
    private static let output = URL(fileURLWithPath: "/tmp/lungfish-late-cancel/table.tsv")

    func testACancellingRowCompletedWithoutTheCommitStillReadsCancelled() throws {
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }
        OperationCenter.shared.cancel(id: id)
        XCTAssertEqual(row(id)?.state, .cancelling)

        OperationCenterCLIBridge.completeOperation(id, detail: "Exported table.tsv", outputURLs: [Self.output])

        XCTAssertEqual(row(id)?.state, .cancelled)
        XCTAssertEqual(row(id)?.detail, "Cancelled by user")
        XCTAssertEqual(row(id)?.outputURLs, [])
    }

    func testACommittedCompletionOfACancellingRowSettlesCompletedWithItsLinks() throws {
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }
        OperationCenter.shared.cancel(id: id)
        XCTAssertEqual(row(id)?.state, .cancelling)

        OperationCenterCLIBridge.completeOperation(
            id, detail: "Exported table.tsv", outputURLs: [Self.output], committed: true
        )

        XCTAssertEqual(row(id)?.state, .completed)
        XCTAssertEqual(row(id)?.detail, "Finished before Cancel took effect")
        XCTAssertEqual(row(id)?.outputURLs, [Self.output])
        XCTAssertEqual(row(id)?.progress, 1)
    }

    func testACommittedCompletionOfARunningRowKeepsItsOwnDetail() throws {
        let id = try beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }

        OperationCenterCLIBridge.completeOperation(
            id, detail: "Exported table.tsv", outputURLs: [Self.output], committed: true
        )

        XCTAssertEqual(row(id)?.state, .completed)
        XCTAssertEqual(row(id)?.detail, "Exported table.tsv")
        XCTAssertEqual(row(id)?.outputURLs, [Self.output])
    }

    // MARK: - Helpers

    private func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private func beginRow() throws -> UUID {
        let result = OperationCenter.shared.begin(
            title: "Export Table", detail: "Exporting table...", operationType: .export,
            cliCommand: "lungfish-cli test export table",
            onCancel: {}
        )
        guard case .started(let id) = result else {
            throw XCTSkip("the operation center refused the row")
        }
        return id
    }
}
