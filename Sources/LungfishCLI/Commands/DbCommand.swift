// DbCommand.swift - CLI commands for managing metagenomics databases
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishCore
import Synchronization

/// Manage metagenomics reference databases.
///
/// List, download, remove, and get recommendations for Kraken2 databases
/// used in taxonomic classification.
///
/// ## Examples
///
/// ```
/// lungfish conda db list
/// lungfish conda db info Standard-8
/// lungfish conda db download Viral
/// lungfish conda db remove Standard-8
/// lungfish conda db recommend
/// ```
struct DbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage metagenomics reference databases",
        discussion: """
        Manage Kraken2 databases for taxonomic classification. Databases may
        be downloaded or prepared from managed upstream sources and are stored
        in Lungfish's managed database storage.
        """,
        subcommands: [
            DbListSubcommand.self,
            DbInfoSubcommand.self,
            DbDownloadSubcommand.self,
            DbRemoveSubcommand.self,
            DbRecommendSubcommand.self,
            DbUpdateSubcommand.self,
            DbInstallManagedSubcommand.self,
        ]
    )
}

// MARK: - db install-managed

extension DbCommand {

    /// Installs a managed user-data database (the `managedData` entries in the
    /// dependency manifest) by its identifier.
    ///
    /// These are not Kraken2 catalog databases, so `db download` does not cover
    /// them: they are host-depletion and rRNA indexes that the app installs on
    /// demand through `DatabaseRegistry.installManagedDatabase`. Provisioning
    /// them from a script (the `toolset-conformance` CI job needs
    /// `deacon-panhuman` before `RecipeIntegrationTests` can run) previously had
    /// no CLI entry point at all.
    struct DbInstallManagedSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install-managed",
            abstract: "Install a managed user-data database by identifier",
            discussion: """
            Installs one of the managed user-data databases declared in the
            dependency manifest's managedData section, such as the Deacon
            panhuman host-depletion index.

            Already-installed databases are reported and left alone unless
            --reinstall is given. Use --list to print the known identifiers
            without installing anything.

            Exit codes:
              0   the database is installed (or was already)
              2   usage error, such as an unknown identifier
              1   the installation failed

            Examples:
              lungfish-cli conda db install-managed --list
              lungfish-cli conda db install-managed deacon-panhuman
            """
        )

        @Argument(help: "Managed database identifier (e.g., 'deacon-panhuman')")
        var databaseID: String?

        @Flag(name: .customLong("list"), help: "List the known managed database identifiers and exit")
        var list: Bool = false

        @Flag(name: .customLong("reinstall"), help: "Reinstall even if the database is already present")
        var reinstall: Bool = false

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = DatabaseRegistry.shared

            if list {
                for id in DatabaseRegistry.knownIDs {
                    print(id)
                }
                return
            }

            guard let databaseID else {
                print(formatter.error("Specify a managed database identifier, or --list to see them"))
                throw CLIExitCode.usage.exitCode
            }

            let canonicalID = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
            guard DatabaseRegistry.knownIDs.contains(canonicalID) else {
                print(formatter.error("Unknown managed database '\(databaseID)'"))
                print(formatter.info("Known identifiers: \(DatabaseRegistry.knownIDs.joined(separator: ", "))"))
                throw CLIExitCode.inputError.exitCode
            }

            if !reinstall, let existing = await registry.effectiveDatabasePath(for: canonicalID) {
                print(formatter.success("Managed database '\(canonicalID)' is already installed"))
                print(formatter.info("Location: \(existing.path)"))
                return
            }

            print(formatter.header("Installing managed database: \(canonicalID)"))
            do {
                let installed = try await registry.installManagedDatabase(
                    canonicalID,
                    reinstall: reinstall
                ) { fraction, message in
                    guard !globalOptions.quiet else { return }
                    print("\r\(formatter.info("[\(Int((fraction * 100).rounded()))%] \(message)"))", terminator: "")
                }
                print("")
                print(formatter.success("Managed database '\(canonicalID)' installed"))
                print(formatter.info("Location: \(installed.path)"))
            } catch {
                print("")
                print(formatter.error("Failed to install '\(canonicalID)': \(error.localizedDescription)"))
                throw CLIExitCode.dependency.exitCode
            }
        }
    }
}

// MARK: - db list

extension DbCommand {

    /// Lists available and installed metagenomics databases.
    struct DbListSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List available and installed databases"
        )

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            let databases = try await registry.availableDatabases()

            if databases.isEmpty {
                print(formatter.info("No databases registered."))
                return
            }

            print(formatter.header("Metagenomics Databases (\(databases.count))"))
            print("")

            let rows = databases.map { db -> [String] in
                let sizeGB = String(format: "%.1f GB", Double(db.sizeBytes) / 1_073_741_824)
                let ramGB = String(format: "%.0f GB", Double(db.recommendedRAM) / 1_073_741_824)
                let update = db.isUpdateAvailable ? "yes (\(db.availableUpdateVersion ?? "unknown"))" : "no"
                return [db.name, db.status.rawValue, sizeGB, ramGB, update, db.description]
            }

            print(formatter.table(
                headers: ["Name", "Status", "Size", "RAM", "Update", "Description"],
                rows: rows
            ))
        }
    }
}

// MARK: - db info

extension DbCommand {

    /// Shows installed version, install date, and update status for one database.
    struct DbInfoSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show installed database version and update status"
        )

        @Argument(help: "Database name (e.g., 'Viral', 'Standard-8', 'PlusPF')")
        var name: String

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            guard let db = try await registry.database(named: name) else {
                print(formatter.error("Database '\(name)' not found in catalog"))
                print(formatter.info("Use 'lungfish-cli conda db list' to see available databases"))
                throw CLIExitCode.inputError.exitCode
            }

            let installedDate = db.installedAt ?? db.lastUpdated
            let installed = installedDate.map(Self.formatDate) ?? "not installed"
            let lastUpdated = db.lastUpdated.map(Self.formatDate) ?? "unknown"
            let availableUpdate = db.availableUpdateVersion ?? "none"
            let path = db.path?.path ?? "not installed"
            let size = db.sizeOnDisk ?? db.sizeBytes

            print(formatter.header("Database: \(db.name)"))
            print("")
            print(formatter.keyValueTable([
                ("Tool", db.tool),
                ("Status", db.status.rawValue),
                ("Current version", db.currentVersionLabel),
                ("Installed", installed),
                ("Last updated", lastUpdated),
                ("Available update", availableUpdate),
                ("Location", path),
                ("Disk size", LungfishFormatters.formatBytes(size)),
                ("Recommended RAM", LungfishFormatters.formatBytes(db.recommendedRAM)),
                ("Description", db.description),
            ]))
        }

        private static func formatDate(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }
    }
}

// MARK: - db download

extension DbCommand {

    /// Downloads or prepares a database from the built-in catalog.
    struct DbDownloadSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Download or prepare a database from the catalog"
        )

        @Argument(help: "Database name (e.g., 'Viral', 'SILVA', 'Greengenes')")
        var name: String

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            guard let db = try await registry.database(named: name) else {
                print(formatter.error("Database '\(name)' not found in catalog"))
                print(formatter.info("Use 'lungfish-cli conda db list' to see available databases"))
                throw CLIExitCode.inputError.exitCode
            }

            if db.status == .ready {
                print(formatter.success("Database '\(name)' is already installed"))
                if let path = db.path {
                    print(formatter.info("Location: \(path.path)"))
                }
                return
            }

            let sizeGB = String(format: "%.1f GB", Double(db.sizeBytes) / 1_073_741_824)
            print(formatter.header("Downloading Database: \(name)"))
            print(formatter.info("Size: \(sizeGB)"))
            print("")

            let _ = try await registry.downloadDatabase(name: name) { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }

            print("")
            print(formatter.success("Database '\(name)' downloaded and verified"))
        }
    }
}

// MARK: - db remove

extension DbCommand {

    /// Removes a database from the registry.
    struct DbRemoveSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a database from the registry"
        )

        @Argument(help: "Database name to remove")
        var name: String

        @Flag(name: .customLong("delete-files"), help: "Also delete database files from disk")
        var deleteFiles: Bool = false

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            guard let db = try await registry.database(named: name) else {
                print(formatter.error("Database '\(name)' not found"))
                throw CLIExitCode.inputError.exitCode
            }

            if deleteFiles, let path = db.path {
                print(formatter.info("Removing database files at \(path.path)..."))
                try? FileManager.default.removeItem(at: path)
            }

            try await registry.removeDatabase(name: name)
            print(formatter.success("Database '\(name)' removed from registry"))
        }
    }
}

// MARK: - db recommend

extension DbCommand {

    /// Shows the recommended database for this system's RAM.
    struct DbRecommendSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "recommend",
            abstract: "Show recommended database for this system"
        )

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            let ram = ProcessInfo.processInfo.physicalMemory
            let ramGB = String(format: "%.0f", Double(ram) / 1_073_741_824)

            print(formatter.header("Database Recommendation"))
            print("")

            guard let recommended = try await registry.recommendedDatabase() else {
                print(formatter.keyValueTable([
                    ("System RAM", "\(ramGB) GB"),
                    ("Recommended DB", "None"),
                    ("Reason", "No bundled database fits in available RAM"),
                ]))
                return
            }

            print(formatter.keyValueTable([
                ("System RAM", "\(ramGB) GB"),
                ("Recommended DB", recommended.name),
                ("DB Size", String(format: "%.1f GB", Double(recommended.sizeBytes) / 1_073_741_824)),
                ("Required RAM", String(format: "%.0f GB", Double(recommended.recommendedRAM) / 1_073_741_824)),
                ("Description", recommended.description),
                ("Status", recommended.status.rawValue),
            ]))

            if !recommended.isDownloaded {
                print("")
                print(formatter.info("Download with: lungfish-cli conda db download \(recommended.name)"))
            }
        }
    }
}

// MARK: - db update

extension DbCommand {

    /// Updates an installed catalog database to the version pinned in the dependency manifest.
    ///
    /// This is the per-database counterpart to `lungfish tools update`: the reconciler routes
    /// manifest-wide database drift through the same registry call, and this subcommand exposes
    /// it for one database (or every database with an update available) on its own.
    struct DbUpdateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Update an installed database to the pinned version",
            discussion: """
            Replaces an installed database with the version pinned in the dependency manifest.

            Name one database by its catalog identifier ('kraken2-viral') or by the display
            name it is listed under ('Viral'), or pass --all to update every installed
            database that has an update available. Either way --yes is required, because
            the update replaces the installed copy.

            Databases that are built locally rather than downloaded cannot be updated in
            place; they are reported as skipped and are refreshed by reinstalling instead.
            A run in which every selected database was skipped updated nothing, so it
            exits non-zero rather than reporting success.

            Exit codes:
              0   nothing to update, or at least one selected database updated
              2   usage error, such as a missing target or --yes
              1   a database failed to update, --all found updates it could not apply, or
                  every selected database was skipped
              125 cancelled by SIGTERM; the installed database is left as it was and the
                  run is recorded as cancelled under provenance/databases in the storage root

            --format json prints progress as event lines on standard output and the text on
            standard error.

            Examples:
              lungfish-cli conda db update kraken2-viral --yes
              lungfish-cli conda db update Viral --yes
              lungfish-cli conda db update --all --yes
            """
        )

        @Argument(help: "Catalog identifier or display name of the database to update (e.g., 'kraken2-viral', 'Viral')")
        var catalogID: String?

        @Flag(name: .customLong("all"), help: "Update every installed database with an update available")
        var all: Bool = false

        @Flag(name: .customLong("yes"), help: "Confirm the update (required)")
        var yes: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        /// Test seam. A test hands the command a registry rooted in a scratch folder with a stand-in
        /// archive installer, because the real one downloads gigabytes.
        private static let registryOverrideStorage = Mutex<MetagenomicsDatabaseRegistry?>(nil)

        static var registryOverride: MetagenomicsDatabaseRegistry? {
            get { registryOverrideStorage.withLock { $0 } }
            set { registryOverrideStorage.withLock { $0 = newValue } }
        }

        /// What the databases of one run did, kept outside the run's task so a cancel can record the
        /// ones that finished before it.
        private final class RunLog: Sendable {
            private struct State {
                var failed: [(String, String)] = []
                var skipped: [(String, String)] = []
                var succeeded: [String] = []
            }
            private let state = Mutex(State())
            var failures: [(String, String)] { state.withLock { $0.failed } }
            var skipped: [(String, String)] { state.withLock { $0.skipped } }
            var succeeded: [String] { state.withLock { $0.succeeded } }
            func fail(_ target: String, _ message: String) { state.withLock { $0.failed.append((target, message)) } }
            func skip(_ target: String, _ message: String) { state.withLock { $0.skipped.append((target, message)) } }
            func succeed(_ target: String) { state.withLock { $0.succeeded.append(target) } }
        }

        func run() async throws {
            try await execute(eventsOn: globalOptions.outputFormat == .json, quiet: globalOptions.quiet, emit: printEventLine)
        }

        /// The run, with each event line handed to `emit`, so a test can keep them. With `--format
        /// json` standard output holds only `CLIEvent` lines. SIGTERM, the app's Cancel, cancels the
        /// update. The registry stages the new copy beside the installed one, so a cancel before the
        /// swap leaves the installed database as it was, and the run is recorded as cancelled under
        /// `<storage root>/provenance/databases` and the command exits 125 (Phase 2.10 lane A52).
        func execute(eventsOn: Bool, quiet: Bool, emit: @escaping (String) -> Void) async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = Self.registryOverride ?? MetagenomicsDatabaseRegistry.shared
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            let say: @Sendable (String) -> Void = { printHumanLine($0, eventsOn: eventsOn) }
            func refuse(_ message: String, _ exit: CLIExitCode) -> ExitCode {
                events.emitFailed(message)
                say(formatter.error(message))
                return exit.exitCode
            }

            // How the command was invoked, not what it found: these are the same class of
            // mistake `tools update` reports as a usage error, and a script branching on exit
            // codes should not have to learn a different convention for each command.
            guard catalogID != nil || all else {
                throw refuse("Specify a database catalog identifier or --all", .usage)
            }
            guard !(catalogID != nil && all) else {
                throw refuse("Specify either a database catalog identifier or --all, not both", .usage)
            }
            guard yes else {
                throw refuse("Updating a database replaces the installed copy; re-run with --yes to confirm", .usage)
            }

            let targets = try await resolveTargets(registry: registry)
            let storageRoot = ManagedToolLeaf.currentStorageRoot()
            if targets.isEmpty {
                // "Nothing to update" is only true if nothing is advertising an update.
                // If `db list` is showing updates that this command could not turn into
                // targets, saying "no updates" and exiting 0 is a silent false success:
                // a sweep script would record the databases as current when they are not.
                if all {
                    let advertised = try await registry.availableDatabases()
                        .filter(\.isUpdateAvailable)
                        .map(\.name)
                        .sorted()
                    if !advertised.isEmpty {
                        throw refuse(
                            "\(advertised.count) database(s) have an update available but none could be "
                            + "resolved to an update target: \(advertised.joined(separator: ", ")). "
                            + "Run 'lungfish-cli conda db info <name>' for details.",
                            .failure
                        )
                    }
                }
                events.emitStart("No databases have an update available.")
                say(formatter.info("No databases have an update available."))
                events.emitComplete(outputs: [storageRoot.path], message: "No databases have an update available.")
                return
            }

            events.emitStart("Updating \(targets.joined(separator: ", "))...")
            let startedAt = Date()
            let targetCount = Double(targets.count)
            let log = RunLog()
            let outcome = await ManagedToolLeaf.cancellingOnSIGTERM { () async throws -> Void in
                for (index, target) in targets.enumerated() {
                    say(formatter.header("Updating \(target)"))
                    do {
                        try await registry.updateDatabase(catalogID: target) { fraction, message in
                            if eventsOn {
                                let overall = (Double(index) + min(max(fraction, 0), 1)) / targetCount
                                events.emitProgress(overall, message: message)
                            } else if !quiet {
                                print("\r\(formatter.info("[\(Int((fraction * 100).rounded()))%] \(message)"))", terminator: "")
                            }
                        }
                        say("")
                        say(formatter.success("Database '\(target)' updated"))
                        log.succeed(target)
                    } catch let error as MetagenomicsDatabaseRegistryError {
                        if ManagedToolLeaf.endedOnCancel(error) { throw CancellationError() }
                        say("")
                        // A database that cannot be updated in place (locally built, or on a volume
                        // that is not mounted) is a skip, not a failure: the user is told what to do
                        // instead and the remaining databases still update.
                        if case .updateNotSupported = error {
                            say(formatter.warning("Skipped '\(target)': \(error.localizedDescription)"))
                            events.emitLog(.warning, "Skipped '\(target)': \(error.localizedDescription)")
                            log.skip(target, error.localizedDescription)
                        } else {
                            say(formatter.error("Failed '\(target)': \(error.localizedDescription)"))
                            log.fail(target, error.localizedDescription)
                        }
                    } catch {
                        if ManagedToolLeaf.endedOnCancel(error) { throw CancellationError() }
                        say("")
                        say(formatter.error("Failed '\(target)': \(error.localizedDescription)"))
                        log.fail(target, error.localizedDescription)
                    }
                }
            }

            func recordRun(_ status: RunStatus, _ failure: String?) {
                ManagedToolLeaf.writeRecord(
                    ManagedToolLeaf.Record(
                        workflowName: "conda-database-update",
                        folder: "databases",
                        label: targets.joined(separator: "+"),
                        argv: ["lungfish-cli", "conda", "db", "update"] + (all ? ["--all"] : targets) + ["--yes"],
                        explicit: ["databases": .array(targets.map { .string($0) })],
                        pluginPack: nil,
                        steps: log.succeeded.map { ManagedToolLeaf.Step(id: $0, version: "unknown", failure: nil) }
                            + log.failures.map { ManagedToolLeaf.Step(id: $0.0, version: "unknown", failure: $0.1) },
                        status: status,
                        failure: failure,
                        startedAt: startedAt,
                        endedAt: Date()
                    ),
                    storageRoot: storageRoot
                )
            }

            var runError: (any Error)?
            if case .failure(let error) = outcome { runError = error }
            if ManagedToolLeaf.endedOnCancel(runError) {
                recordRun(.cancelled, "Cancelled")
                let message = "Update cancelled. The installed database was left as it was."
                events.emitFailed(message)
                say(message)
                throw CLIExitCode.cancelled.exitCode
            }
            if let runError {
                events.emitFailed(CLIFailureWords.describe(runError))
                throw runError
            }

            if !log.failures.isEmpty {
                recordRun(.failed, log.failures.map { "\($0.0): \($0.1)" }.joined(separator: "; "))
                events.emitFailed(
                    "\(log.failures.count) database(s) failed to update",
                    detail: log.failures.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
                )
                throw CLIExitCode.failure.exitCode
            }

            // A run that applied nothing because every target was skipped is not a
            // success. Skipping is the right per-database behaviour when other
            // databases still update, but when it accounts for the entire run the
            // command has changed nothing while exiting 0, and a sweep script would
            // record the databases as current. This is the same false success as the
            // empty-target case above, reached by a different route: `--all` selecting
            // only locally built databases (SILVA, Greengenes), which are rebuilt by
            // reinstalling rather than updated in place.
            if log.succeeded.isEmpty, !log.skipped.isEmpty {
                let message = "No database was updated: all \(log.skipped.count) selected database(s) were skipped. "
                    + log.skipped.map { "'\($0.0)': \($0.1)" }.joined(separator: "; ")
                say("")
                events.emitFailed(message)
                say(formatter.error(message))
                throw CLIExitCode.failure.exitCode
            }

            let rows = (try? await registry.availableDatabases()) ?? []
            let updatedPaths = log.succeeded.compactMap { target in
                rows.first { $0.catalogID == target || $0.name == target }?.path?.path
            }
            events.emitComplete(
                outputs: updatedPaths.isEmpty ? [storageRoot.path] : updatedPaths,
                message: "Updated \(log.succeeded.count) database(s): \(log.succeeded.joined(separator: ", "))"
            )
        }

        /// The database identifiers this invocation should update.
        ///
        /// For `--all` this is exactly the set of rows `db list` marks as having an
        /// update available. The previous form mapped that set through `compactMap(\.catalogID)`,
        /// which silently dropped every row registered by `registerExisting` -- the way
        /// most real installs look, since those rows carry no catalog identity. With all
        /// such rows dropped the command printed "No databases have an update available"
        /// and exited 0 while `db list` was still advertising the update, so a scripted
        /// sweep recorded a successful update that never happened.
        ///
        /// A row without a catalogID is addressed by its display name, which
        /// `updateDatabase` resolves through the same name-and-tool match that decided
        /// the update was available in the first place.
        private func resolveTargets(
            registry: MetagenomicsDatabaseRegistry
        ) async throws -> [String] {
            if let catalogID {
                return [catalogID]
            }
            let databases = try await registry.availableDatabases()
            return databases
                .filter { $0.isUpdateAvailable }
                .map { $0.catalogID ?? $0.name }
                .sorted()
        }
    }
}
