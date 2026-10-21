// ManagedToolsCommandTests.swift - The commands the managed tools runner builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3 (family L10, panel decision C4). The Update Tools run, the Plugin Manager's
// pack install and reinstall, and its database update run the CLI. The tests check that each command
// the runner builds is the argv its row records and parses back to its leaf. The hidden key and the
// in-process route went in Phase 2.11 (K3).

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

final class ManagedToolsCommandTests: XCTestCase {

    func testEachCommandIsTheArgvItsRowRecordsAndParsesBackToItsLeaf() throws {
        let tools = CLIManagedToolsRunner.updateTools(ids: ["pigz", "samtools"])
        XCTAssertEqual(
            tools.argv,
            ["tools", "update", "--apply", "--yes", "--only", "pigz", "--only", "samtools", "--format", "json"]
        )
        XCTAssertEqual(tools.recordedCommand, "lungfish-cli " + tools.argv.joined(separator: " "))
        XCTAssertEqual(try RecordedCLICommand.parse(tools.recordedCommand, as: ToolsCommand.UpdateSubcommand.self).only, ["pigz", "samtools"])

        let requiredOnly = CLIManagedToolsRunner.updateToolsRequiredOnly()
        XCTAssertEqual(requiredOnly.argv, ["tools", "update", "--apply", "--yes", "--required-only", "--format", "json"])
        XCTAssertEqual(requiredOnly.recordedCommand, "lungfish-cli " + requiredOnly.argv.joined(separator: " "))
        let parsedRequiredOnly = try RecordedCLICommand.parse(requiredOnly.recordedCommand, as: ToolsCommand.UpdateSubcommand.self)
        XCTAssertTrue(parsedRequiredOnly.requiredOnly, "an empty selection runs the required work")
        XCTAssertEqual(parsedRequiredOnly.only, [], "and names no item")

        for reinstall in [false, true] {
            let pack = CLIManagedToolsRunner.installPack(packID: "read-mapping", reinstall: reinstall)
            XCTAssertEqual(pack.recordedCommand, "lungfish-cli " + pack.argv.joined(separator: " "))
            let parsed = try RecordedCLICommand.parse(pack.recordedCommand, as: CondaCommand.InstallSubcommand.self)
            XCTAssertEqual(parsed.packages, ["read-mapping"])
            XCTAssertEqual(parsed.reinstall, reinstall)
        }

        let database = CLIManagedToolsRunner.updateDatabase(catalogID: "kraken2-viral")
        XCTAssertEqual(database.argv, ["conda", "db", "update", "kraken2-viral", "--yes", "--format", "json"])
        XCTAssertEqual(database.recordedCommand, "lungfish-cli " + database.argv.joined(separator: " "))
        XCTAssertEqual(try RecordedCLICommand.parse(database.recordedCommand, as: DbCommand.DbUpdateSubcommand.self).catalogID, "kraken2-viral")
    }

    func testTheSheetsSelectionNamesItsEnvironmentsDatabasesAndRetiredEnvironments() {
        var plan = ReconciliationPlan(
            installEnvironments: [], reinstallEnvironments: [], removeEnvironments: ["old-tool"],
            databaseUpdates: [], pipelinePrefetch: [], bootstrapUpdate: nil,
            targetDependencySet: "2026.2", estimatedDownloadBytes: 0
        )
        plan.removeEnvironments = ["old-tool"]
        let selection = PlanSelection(environments: ["samtools", "pigz"], databases: ["kraken2-viral"], includeRemovals: true)
        XCTAssertEqual(
            CLIManagedToolsRunner.itemIDs(of: selection, in: plan),
            ["kraken2-viral", "old-tool", "pigz", "samtools"]
        )
        let withoutRemovals = PlanSelection(environments: ["samtools"], databases: [], includeRemovals: false)
        XCTAssertEqual(CLIManagedToolsRunner.itemIDs(of: withoutRemovals, in: plan), ["samtools"])
    }
}
