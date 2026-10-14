// ManagedToolsRouteTests.swift - The hidden key of the managed tools route, and the commands the runner builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M3 (family L10, panel decision C4). The Update Tools run, the Plugin Manager's
// pack install and reinstall, and its database update take the CLI route or, behind a hidden key for
// one release, the in-process route. The test reads each value of the key from a defaults suite of
// its own, checks that a test override wins, and checks that each command the runner builds is the
// argv its row records and parses back to its leaf.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

final class ManagedToolsRouteTests: XCTestCase {
    private func route(holding value: Any?) -> ManagedToolsRoute {
        let suite = makeTestDefaultsSuite(prefix: "managed-tools-route")
        if let value { suite.defaults.set(value, forKey: ManagedToolsRouteSettings.defaultsKey) }
        return ManagedToolsRouteSettings(defaults: suite.defaults).route
    }

    func testTheKeyReadsEachValueAndAnUnknownOneTakesTheDefault() {
        XCTAssertEqual(route(holding: nil), ManagedToolsRouteSettings.defaultRoute, "an unset key")
        XCTAssertEqual(route(holding: "cli"), .cli)
        XCTAssertEqual(route(holding: "CLI"), .cli)
        XCTAssertEqual(route(holding: "legacy"), .legacy)
        XCTAssertEqual(route(holding: true), .cli)
        XCTAssertEqual(route(holding: false), .legacy)
        XCTAssertEqual(route(holding: "in-process"), ManagedToolsRouteSettings.defaultRoute, "a value nothing reads")
        XCTAssertEqual(route(holding: 7), ManagedToolsRouteSettings.defaultRoute, "a number is not a route")
        XCTAssertEqual(ManagedToolsRoute.allCases.count, 2)
    }

    /// Lane A52's last commit (panel decision C4). Side A against C holds only declared differences
    /// (ManagedToolsCLIGUIParityReplayTests), so the three launches take the CLI route unless the
    /// key names the in-process route, which stays for one release.
    func testTheDefaultRouteIsTheCLIAndTheKeyStillKeepsTheInProcessRoute() {
        XCTAssertEqual(ManagedToolsRouteSettings.defaultRoute, .cli)
        XCTAssertEqual(route(holding: nil), .cli, "an unset key takes the CLI route")
        XCTAssertEqual(route(holding: "in-process"), .cli, "a value nothing reads takes the CLI route")
        XCTAssertEqual(route(holding: "legacy"), .legacy, "the key keeps the in-process route")
        XCTAssertEqual(route(holding: false), .legacy)
    }

    func testAnOverrideWinsOverTheKeyAndClearsAfterwards() {
        defer { ManagedToolsRouteSettings.testOverride = nil }
        ManagedToolsRouteSettings.testOverride = .legacy
        XCTAssertEqual(ManagedToolsRouteSettings.currentRoute, .legacy)
        ManagedToolsRouteSettings.testOverride = .cli
        XCTAssertEqual(ManagedToolsRouteSettings.currentRoute, .cli)
        ManagedToolsRouteSettings.testOverride = nil
        XCTAssertEqual(
            ManagedToolsRouteSettings.currentRoute,
            ManagedToolsRouteSettings(defaults: .standard).route
        )
    }

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
