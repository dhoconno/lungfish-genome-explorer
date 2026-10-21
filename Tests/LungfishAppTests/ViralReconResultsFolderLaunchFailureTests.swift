// ViralReconResultsFolderLaunchFailureTests.swift - A refused results folder reaches the user as a failed row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.21 STALE-OUT, M3 (UX 1, UX 4, QA 2). The request refuses a results folder that already holds files,
// and the launch failure path turns the refusal into a failed row with the title and the text UX fixed (W1). It is a
// failure the user can act on, never a cancel, so the row is failed and the words are asserted verbatim.

import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class ViralReconResultsFolderLaunchFailureTests: XCTestCase {
    private let w1Title = "Choose an empty results folder"

    private func w1Text(folder: String) -> String {
        "\"\(folder)\" already holds files, and a Viral Recon run would leave its results beside them. "
            + "Choose an empty folder or a new one."
    }

    func testARefusedResultsFolderMakesAFailedRowWithTheTitleAndTextUXFixed() throws {
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        let folder = URL(fileURLWithPath: "/tmp/runs/viralrecon-results-a1b2c3d4", isDirectory: true)

        let reported = AppDelegate.reportViralReconLaunchFailure(
            ViralReconRunRequest.ValidationError.resultsFolderHoldsFiles(folder),
            operationCenter: center,
            routeContext: nil
        )

        XCTAssertNotNil(reported, "a refusal is reported, it is not dropped as a cancel")
        XCTAssertEqual(center.items.count, 1)
        let item = try XCTUnwrap(center.items.first)
        let text = w1Text(folder: "viralrecon-results-a1b2c3d4")
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.title, "Viral Recon")
        XCTAssertEqual(item.errorMessage, w1Title)
        XCTAssertEqual(item.detail, text)
        XCTAssertEqual(item.errorDetail, text)
        XCTAssertTrue(item.logEntries.contains { $0.level == .error && $0.message.contains(text) })
    }

    func testAUsedFolderTheRequestRefusedReachesTheRowWithTheSameWords() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-refused-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = temp.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try "an earlier run\n".write(
            to: outputs.appendingPathComponent("multiqc_report.html"),
            atomically: true,
            encoding: .utf8
        )

        var refusal: Error?
        XCTAssertThrowsError(try ViralReconAppTestFixtures.illuminaRequest(root: temp)) { refusal = $0 }
        let error = try XCTUnwrap(refusal)

        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        AppDelegate.reportViralReconLaunchFailure(error, operationCenter: center, routeContext: nil)

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, w1Title)
        XCTAssertEqual(item.detail, w1Text(folder: "outputs"))
    }

    func testAnotherLaunchFailureKeepsTheGenericTitle() throws {
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()

        AppDelegate.reportViralReconLaunchFailure(
            ViralReconWorkflowExecutionError.missingWorkflowDefinition,
            operationCenter: center,
            routeContext: nil
        )

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, "Viral Recon could not start")
    }
}
