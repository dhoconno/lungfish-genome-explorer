// OperationCenterDependencySinkOperationTests.swift - begin() site in OperationCenterDependencySink
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The dependency reconciler reports its rows through the sink adapter, which
// registers each one with a static begin helper (R4). The row locks no bundle,
// so a reporter that refuses every begin stands in for a refusal and proves
// the launch closure, which records the sink's handle, runs only for a started
// row. The reconciler's item rows know only a title and a detail, so they record
// no command. The Update Tools run on the CLI route (Phase 2.10 lane A52) begins
// its one row through the same helper with the command it runs, which names the
// items the user chose (`tools update --only`), and the test parses it back.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class OperationCenterDependencySinkOperationTests: XCTestCase {
    func testDependencyRowRecordsTheUpdateCommandItIsGivenAndItParsesBack() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?
        let invocation = CLIManagedToolsRunner.updateTools(ids: ["pigz", "samtools"])

        let result = OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools to 2026.10.1",
            detail: "3 environments, 1 database",
            cliCommand: invocation.recordedCommand,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Update tools to 2026.10.1")
        XCTAssertEqual(item.initialDetail, "3 environments, 1 database")
        XCTAssertEqual(item.operationType, .condaPluginPack)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli tools update --apply --yes --only pigz --only samtools --format json"
        )
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ToolsCommand.UpdateSubcommand.self)
        XCTAssertTrue(command.apply && command.yes)
        XCTAssertEqual(command.only, ["pigz", "samtools"])
    }

    func testItemRowsUseTheSameRowShape() throws {
        // The reconciler registers one row per item with the item's title and
        // the item identifier as the detail.
        let reporter = RecordingOperationReporter()

        OperationCenterDependencySink.beginDependencyOperation(
            title: "Update micromamba to 2.0.5",
            detail: "micromamba",
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Update micromamba to 2.0.5")
        XCTAssertEqual(item.initialDetail, "micromamba")
        XCTAssertEqual(item.operationType, .condaPluginPack)
        XCTAssertNil(item.cliCommand)
    }

    func testRefusedDependencyRowLeavesTheHandleUnrecorded() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure, which
        // records the sink's handle, sits behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools to 2026.10.1",
            detail: "3 environments",
            reporter: reporter
        ) { _ in launched = true }

        XCTAssertNil(result.startedID)
        XCTAssertFalse(launched, "a refused row must not record a handle")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }
}
