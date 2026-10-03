// PluginManagerViewModelOperationTests.swift - begin() sites in PluginManagerViewModel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Plugin Manager registers two rows through static begin helpers (R4). A
// pack install records `lungfish-cli conda install --pack`, and a database
// update records `lungfish-cli conda db update`. Both commands must parse with
// the values the run uses. A pack reinstall has no command, because `conda
// install` has no option that reinstalls a pack, so its row records no
// command and its test pins the CLI parity gap. Neither row locks a bundle, so a
// reporter that refuses every begin stands in for a refusal and proves each
// launch closure sits behind the `.started` case.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class PluginManagerViewModelOperationTests: XCTestCase {
    private func makePack() throws -> PluginPack {
        try XCTUnwrap(PluginPack.builtInPack(id: "multiple-sequence-alignment"))
    }

    // MARK: - Pack install and reinstall (site 46)

    func testPackInstallRecordsItsRowAndARunnableCondaInstallCommand() throws {
        let reporter = RecordingOperationReporter()
        let pack = try makePack()
        var launchedID: UUID?

        let result = PluginManagerViewModel.beginPluginPackOperation(
            pack: pack,
            reinstall: false,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Plugin Pack: \(pack.name)")
        XCTAssertEqual(item.initialDetail, "Preparing to install \(pack.name)")
        XCTAssertEqual(item.operationType, .condaPluginPack)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: CondaCommand.InstallSubcommand.self)
        XCTAssertTrue(command.isPack)
        XCTAssertEqual(command.packages, [pack.id])
        XCTAssertFalse(command.offline)
        XCTAssertNil(command.fromBundle)
        XCTAssertFalse(command.overwrite)
    }

    func testPackReinstallRecordsNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let pack = try makePack()
        var launchedID: UUID?

        PluginManagerViewModel.beginPluginPackOperation(
            pack: pack,
            reinstall: true,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Plugin Pack: \(pack.name)")
        XCTAssertEqual(item.initialDetail, "Preparing to reinstall \(pack.name)")
        XCTAssertEqual(item.operationType, .condaPluginPack)
        // The run passes `reinstall: true`, which recreates the pack's
        // environments. `conda install --pack` always passes `false`, and its
        // `--overwrite` flag applies only with `--offline`, so no option
        // expresses a reinstall and the row records no command.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "plugin-reinstall")
    }

    // MARK: - Database update (site 47)

    func testDatabaseUpdateRecordsItsRowAndARunnableCondaDbUpdateCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = PluginManagerViewModel.beginDatabaseUpdateOperation(
            name: "Standard-8",
            catalogID: "kraken2-standard-8",
            targetVersion: "2026-09-04",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Update Database: Standard-8")
        XCTAssertEqual(item.initialDetail, "Updating Standard-8 to 2026-09-04")
        XCTAssertEqual(item.operationType, .download)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)

        // `db` is a subcommand of `conda`, so the recorded string resolves to
        // `DbCommand.DbUpdateSubcommand`, which calls the same registry method
        // with the same catalog id as the run.
        XCTAssertEqual(item.cliCommand, "lungfish-cli conda db update kraken2-standard-8 --yes")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: DbCommand.DbUpdateSubcommand.self)
        XCTAssertEqual(command.catalogID, "kraken2-standard-8")
        XCTAssertTrue(command.yes)
        XCTAssertFalse(command.all)
    }

    // MARK: - Sites with no lock launch nothing when the begin is refused

    func testSitesWithNoLockLaunchNothingWhenTheBeginIsRefused() throws {
        // No real center refuses these rows, because they request no lock. A
        // reporter that refuses every begin proves each launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let pack = try makePack()
        var launched: [String] = []

        func check(_ name: String, _ result: OperationStartResult) {
            guard case .refused = result else { return XCTFail("\(name) must report the refusal") }
        }

        check("pack install", PluginManagerViewModel.beginPluginPackOperation(
            pack: pack, reinstall: false, reporter: reporter
        ) { _ in launched.append("pack install") })
        check("pack reinstall", PluginManagerViewModel.beginPluginPackOperation(
            pack: pack, reinstall: true, reporter: reporter
        ) { _ in launched.append("pack reinstall") })
        check("database update", PluginManagerViewModel.beginDatabaseUpdateOperation(
            name: "Standard-8", catalogID: "kraken2-standard-8", targetVersion: "latest", reporter: reporter
        ) { _ in launched.append("database update") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 3)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
