// DbCommand.swift - CLI commands for managing metagenomics databases
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishCore

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
              lungfish conda db install-managed --list
              lungfish conda db install-managed deacon-panhuman
            """
        )

        @Argument(help: "Managed database identifier (e.g., 'deacon-panhuman')")
        var databaseID: String?

        @Flag(name: .customLong("list"), help: "List the known managed database identifiers and exit")
        var list: Bool = false

        @Flag(name: .customLong("reinstall"), help: "Reinstall even if the database is already present")
        var reinstall: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

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

        @OptionGroup var globalOptions: GlobalOptions

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

private func formatDatabaseBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
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

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            guard let db = try await registry.database(named: name) else {
                print(formatter.error("Database '\(name)' not found in catalog"))
                print(formatter.info("Use 'lungfish conda db list' to see available databases"))
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
                ("Current version", db.version ?? "unknown"),
                ("Installed", installed),
                ("Last updated", lastUpdated),
                ("Available update", availableUpdate),
                ("Location", path),
                ("Disk size", formatDatabaseBytes(size)),
                ("Recommended RAM", formatDatabaseBytes(db.recommendedRAM)),
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

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            guard let db = try await registry.database(named: name) else {
                print(formatter.error("Database '\(name)' not found in catalog"))
                print(formatter.info("Use 'lungfish conda db list' to see available databases"))
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

        @OptionGroup var globalOptions: GlobalOptions

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

        @OptionGroup var globalOptions: GlobalOptions

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
                print(formatter.info("Download with: lungfish conda db download \(recommended.name)"))
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

            Name one database by its catalog identifier, or pass --all to update every
            installed database that has an update available. Either way --yes is required,
            because the update replaces the installed copy.

            Databases that are built locally rather than downloaded cannot be updated in
            place; they are reported as skipped and are refreshed by reinstalling instead.

            Exit codes:
              0   nothing to update, or every selected database updated
              2   usage error, such as a missing target or --yes
              1   a database failed to update

            Examples:
              lungfish conda db update kraken2-viral --yes
              lungfish conda db update --all --yes
            """
        )

        @Argument(help: "Catalog identifier of the database to update (e.g., 'kraken2-viral')")
        var catalogID: String?

        @Flag(name: .customLong("all"), help: "Update every installed database with an update available")
        var all: Bool = false

        @Flag(name: .customLong("yes"), help: "Confirm the update (required)")
        var yes: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let registry = MetagenomicsDatabaseRegistry.shared

            // How the command was invoked, not what it found: these are the same class of
            // mistake `tools update` reports as a usage error, and a script branching on exit
            // codes should not have to learn a different convention for each command.
            guard catalogID != nil || all else {
                print(formatter.error("Specify a database catalog identifier or --all"))
                throw CLIExitCode.usage.exitCode
            }
            guard !(catalogID != nil && all) else {
                print(formatter.error("Specify either a database catalog identifier or --all, not both"))
                throw CLIExitCode.usage.exitCode
            }
            guard yes else {
                print(formatter.error("Updating a database replaces the installed copy; re-run with --yes to confirm"))
                throw CLIExitCode.usage.exitCode
            }

            let targets = try await resolveTargets(registry: registry)
            if targets.isEmpty {
                print(formatter.info("No databases have an update available."))
                return
            }

            var failures: [(String, String)] = []
            for target in targets {
                print(formatter.header("Updating \(target)"))
                do {
                    try await registry.updateDatabase(catalogID: target) { fraction, message in
                        if !globalOptions.quiet {
                            print("\r\(formatter.info("[\(Int((fraction * 100).rounded()))%] \(message)"))", terminator: "")
                        }
                    }
                    print("")
                    print(formatter.success("Database '\(target)' updated"))
                } catch let error as MetagenomicsDatabaseRegistryError {
                    print("")
                    // A database that cannot be updated in place (locally built, or on a volume
                    // that is not mounted) is a skip, not a failure: the user is told what to do
                    // instead and the remaining databases still update.
                    if case .updateNotSupported = error {
                        print(formatter.warning("Skipped '\(target)': \(error.localizedDescription)"))
                    } else {
                        print(formatter.error("Failed '\(target)': \(error.localizedDescription)"))
                        failures.append((target, error.localizedDescription))
                    }
                } catch {
                    print("")
                    print(formatter.error("Failed '\(target)': \(error.localizedDescription)"))
                    failures.append((target, error.localizedDescription))
                }
            }

            if !failures.isEmpty {
                throw CLIExitCode.failure.exitCode
            }
        }

        /// The catalog identifiers this invocation should update.
        private func resolveTargets(
            registry: MetagenomicsDatabaseRegistry
        ) async throws -> [String] {
            if let catalogID {
                return [catalogID]
            }
            let databases = try await registry.availableDatabases()
            return databases
                .filter { $0.isUpdateAvailable }
                .compactMap(\.catalogID)
                .sorted()
        }
    }
}
