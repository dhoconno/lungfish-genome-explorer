// ManagedToolRowsParsedBackPinTests.swift - The three managed-tool begin helpers' rows, parsed back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M1 (family L10, QA 1). The Update Tools run, the Plugin Manager's pack
// install and reinstall, and its database update each register an Operations row through a begin
// helper. This suite reads the four rows the helpers register today the way a user's Copy CLI
// Command does, with the exact words and the command each one records, so the lane's route changes
// one visible fact at a time. The install and the database update rows record a command that
// parses back to its leaf. The Update Tools row and the reinstall row recorded none at the base,
// which were the two CLI parity gaps `tools-update-subset` and `plugin-reinstall`. Lane A52 M3
// closes both: the Update Tools row passes the command its CLI route runs, and the reinstall row
// records `conda install --pack <id> --reinstall`. Every row now records the argv its route runs,
// `--format json` included, and the suite parses each back.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ManagedToolRowsParsedBackPinTests: XCTestCase {
    func testTheRowsRecordTodaysWordsAndTodaysCommands() throws {
        let reporter = RecordingOperationReporter()
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))

        OperationCenterDependencySink.beginDependencyOperation(
            title: "Update tools to 2026.10.1", detail: "3 tool(s), 1 database(s)",
            cliCommand: CLIManagedToolsRunner.updateTools(ids: ["pigz", "samtools", "kraken2-viral"]).recordedCommand,
            reporter: reporter
        ) { _ in }
        PluginManagerViewModel.beginPluginPackOperation(pack: pack, reinstall: false, reporter: reporter) { _ in }
        PluginManagerViewModel.beginPluginPackOperation(pack: pack, reinstall: true, reporter: reporter) { _ in }
        PluginManagerViewModel.beginDatabaseUpdateOperation(
            name: "Viral", catalogID: "kraken2-viral", targetVersion: "2026-09-04", reporter: reporter
        ) { _ in }

        let rows = reporter.items
        XCTAssertEqual(rows.map(\.title), [
            "Update tools to 2026.10.1",
            "Plugin Pack: \(pack.name)",
            "Plugin Pack: \(pack.name)",
            "Update Database: Viral",
        ])
        XCTAssertEqual(rows.map(\.initialDetail), [
            "3 tool(s), 1 database(s)",
            "Preparing to install \(pack.name)",
            "Preparing to reinstall \(pack.name)",
            "Updating Viral to 2026-09-04",
        ])
        XCTAssertEqual(rows.map(\.operationType), [.condaPluginPack, .condaPluginPack, .condaPluginPack, .download])
        XCTAssertTrue(rows.allSatisfy { $0.targetBundleURL == nil && $0.additionalLockedBundleURLs.isEmpty })

        XCTAssertEqual(
            rows[0].cliCommand,
            "lungfish-cli tools update --apply --yes --only pigz --only samtools --only kraken2-viral --format json"
        )
        let tools = try RecordedCLICommand.parse(rows[0].cliCommand, as: ToolsCommand.UpdateSubcommand.self)
        XCTAssertTrue(tools.apply && tools.yes)
        XCTAssertEqual(tools.only, ["pigz", "samtools", "kraken2-viral"])

        XCTAssertEqual(rows[1].cliCommand, "lungfish-cli conda install --pack \(pack.id) --format json")
        let install = try RecordedCLICommand.parse(rows[1].cliCommand, as: CondaCommand.InstallSubcommand.self)
        XCTAssertTrue(install.isPack)
        XCTAssertEqual(install.packages, [pack.id])
        XCTAssertFalse(install.reinstall)

        XCTAssertEqual(rows[2].cliCommand, "lungfish-cli conda install --pack \(pack.id) --reinstall --format json")
        let reinstall = try RecordedCLICommand.parse(rows[2].cliCommand, as: CondaCommand.InstallSubcommand.self)
        XCTAssertTrue(reinstall.isPack)
        XCTAssertTrue(reinstall.reinstall)

        XCTAssertEqual(rows[3].cliCommand, "lungfish-cli conda db update kraken2-viral --yes --format json")
        let update = try RecordedCLICommand.parse(rows[3].cliCommand, as: DbCommand.DbUpdateSubcommand.self)
        XCTAssertEqual(update.catalogID, "kraken2-viral")
        XCTAssertTrue(update.yes)
        XCTAssertFalse(update.all)
    }
}
