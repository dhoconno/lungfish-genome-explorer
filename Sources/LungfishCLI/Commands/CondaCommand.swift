// CondaCommand.swift - CLI commands for managing conda/micromamba plugins
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishCore

/// Manage bioconda tool plugins via micromamba.
///
/// Install, remove, and run bioinformatics tools from the bioconda and
/// conda-forge package repositories.
struct CondaCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "conda",
            abstract: "Manage bioconda tool plugins via micromamba",
            discussion: """
            Install bioinformatics tools from bioconda and conda-forge using micromamba.
            Each tool is installed in its own isolated environment to prevent dependency
            conflicts. Tools are stored in \(managedStorageRootDescription()).
            """,
            subcommands: [
                InstallSubcommand.self,
                RemoveSubcommand.self,
                ListSubcommand.self,
                SearchSubcommand.self,
                RunSubcommand.self,
                EnvsSubcommand.self,
                SetupSubcommand.self,
                PacksSubcommand.self,
                OfflineExportSubcommand.self,
                OfflineInstallSubcommand.self,
                ClassifyCommand.self,
                DbCommand.self,
                ExtractSubcommand.self,
            ]
        )
    }
}

extension CondaCommand {
    nonisolated(unsafe) static var storageRootOverride: URL?
    nonisolated(unsafe) static var packStatusServiceOverride: (any PluginPackStatusProviding)?

    static func visiblePacksForTesting() -> [PluginPack] {
        PluginPack.visibleForCLI
    }

    static func storageUnavailableValidationError(for root: URL) -> ArgumentParser.ValidationError {
        ArgumentParser.ValidationError("Storage location unavailable: \(root.path)")
    }

    private static func managedStorageRootDescription() -> String {
        if let storageRootOverride {
            return storageRootOverride.path
        }
        return ManagedStorageConfigStore().currentCondaRootURL().path
    }
}

// MARK: - Install

extension CondaCommand {
    struct InstallSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a tool or plugin pack from bioconda"
        )

        @Argument(help: "Package name(s) to install (e.g., 'samtools' 'bwa-mem2')")
        var packages: [String]

        @Option(name: .shortAndLong, help: "Environment name (default: package name)")
        var env: String?

        @Flag(name: .customLong("pack"), help: "Install a plugin pack instead of individual packages")
        var isPack: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let manager = CondaManager.shared
            let packStatusService = CondaCommand.packStatusServiceOverride ?? PluginPackStatusService.shared

            if isPack {
                // Install a plugin pack
                for packID in packages {
                    guard let pack = CondaCommand.visiblePacksForTesting().first(where: { $0.id == packID }) else {
                        print(formatter.error("Unknown tool pack: \(packID)"))
                        print("Available packs: \(CondaCommand.visiblePacksForTesting().map(\.id).joined(separator: ", "))")
                        throw ExitCode.failure
                    }

                    print(formatter.header("Installing Tool Pack: \(pack.name)"))
                    print("Packages: \(pack.packages.joined(separator: ", "))")
                    print("")

                    do {
                        try await packStatusService.install(pack: pack, reinstall: false) { event in
                            if !globalOptions.quiet {
                                print("\r\(formatter.info(event.message))", terminator: "")
                            }
                        }
                        print("")
                        print(formatter.success("Tool pack '\(pack.name)' installed"))
                    } catch let error as PluginPackStatusServiceError {
                        switch error {
                        case .storageUnavailable(let root):
                            throw CondaCommand.storageUnavailableValidationError(for: root)
                        }
                    } catch {
                        print("")
                        print(formatter.error("Tool pack '\(pack.name)' failed: \(error.localizedDescription)"))
                        throw ExitCode.failure
                    }
                }
            } else {
                // Install individual packages
                let envName = env ?? packages.first ?? "default"

                print(formatter.header("Installing: \(packages.joined(separator: ", "))"))
                print("Environment: \(envName)")
                print("")

                try await manager.install(
                    packages: packages,
                    environment: envName
                ) { fraction, message in
                    if !globalOptions.quiet {
                        print("\r\(formatter.info(message))", terminator: "")
                    }
                }

                print("")
                print(formatter.success("Installation complete"))
            }
        }
    }
}

// MARK: - Remove

extension CondaCommand {
    struct RemoveSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a conda environment and its tools"
        )

        @Argument(help: "Environment name(s) to remove")
        var environments: [String]

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let manager = CondaManager.shared

            for envName in environments {
                print(formatter.info("Removing environment '\(envName)'..."))
                do {
                    try await manager.removeEnvironment(name: envName)
                    print(formatter.success("  Removed '\(envName)'"))
                } catch {
                    print(formatter.error("  Failed to remove '\(envName)': \(error.localizedDescription)"))
                }
            }
        }
    }
}

// MARK: - List

extension CondaCommand {
    struct ListSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List installed packages in an environment"
        )

        @Option(name: .shortAndLong, help: "Environment name (lists all envs if omitted)")
        var env: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let manager = CondaManager.shared

            if let envName = env {
                let packages = try await manager.listInstalled(in: envName)
                print(formatter.header("Packages in '\(envName)' (\(packages.count))"))
                for pkg in packages {
                    print("  \(pkg.name) \(pkg.version) [\(pkg.channel)]")
                }
            } else {
                let envs = try await manager.listEnvironments()
                if envs.isEmpty {
                    print(formatter.info("No conda environments installed."))
                    print("Use 'lungfish conda install <package>' to install tools.")
                } else {
                    print(formatter.header("Conda Environments (\(envs.count))"))
                    for env in envs {
                        print("  \(env.name) (\(env.packageCount) packages)")
                    }
                }
            }
        }
    }
}

// MARK: - Search

extension CondaCommand {
    struct SearchSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search for packages in bioconda and conda-forge"
        )

        @Argument(help: "Search query")
        var query: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let manager = CondaManager.shared

            print(formatter.info("Searching for '\(query)'..."))
            let results = try await manager.search(query: query)

            if results.isEmpty {
                print(formatter.warning("No packages found for '\(query)'"))
            } else {
                // Deduplicate by name, show latest version
                var latest: [String: CondaPackageInfo] = [:]
                for pkg in results {
                    if let existing = latest[pkg.name] {
                        if pkg.version > existing.version { latest[pkg.name] = pkg }
                    } else {
                        latest[pkg.name] = pkg
                    }
                }

                let sorted = latest.values.sorted { $0.name < $1.name }
                print(formatter.header("Results (\(sorted.count) packages)"))
                for pkg in sorted {
                    let native = pkg.isNativeMacOS ? "" : " [Linux only]"
                    let license = pkg.license.map { " (\($0))" } ?? ""
                    print("  \(pkg.name) \(pkg.version) [\(pkg.channel)]\(license)\(native)")
                }
            }
        }
    }
}

// MARK: - Run

extension CondaCommand {
    struct RunSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a tool from a conda environment"
        )

        @Option(name: .shortAndLong, help: "Environment name (default: tool name)")
        var env: String?

        @Argument(help: "Tool name followed by its arguments")
        var toolAndArgs: [String]

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            guard let toolName = toolAndArgs.first else {
                print("Error: No tool specified")
                throw ExitCode.failure
            }

            let toolArgs = Array(toolAndArgs.dropFirst())
            let envName = env ?? toolName

            let manager = CondaManager.shared
            let result = try await manager.runTool(
                name: toolName,
                arguments: toolArgs,
                environment: envName
            )

            if !result.stdout.isEmpty {
                print(result.stdout, terminator: "")
            }
            if !result.stderr.isEmpty {
                FileHandle.standardError.write(Data(result.stderr.utf8))
            }

            if result.exitCode != 0 {
                throw ExitCode(result.exitCode)
            }
        }
    }
}

// MARK: - Environments

extension CondaCommand {
    struct EnvsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "envs",
            abstract: "List conda environments"
        )

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let manager = CondaManager.shared

            let envs = try await manager.listEnvironments()
            if envs.isEmpty {
                print(formatter.info("No environments installed."))
            } else {
                print(formatter.header("Environments (\(envs.count))"))
                for env in envs {
                    let size = try? FileManager.default.allocatedSizeOfDirectory(at: env.path)
                    let sizeStr = size.map { formatBytes($0) } ?? "?"
                    print("  \(env.name)  \(env.packageCount) pkgs  \(sizeStr)")
                }
            }
        }
    }
}

// MARK: - Setup

extension CondaCommand {
    struct SetupSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Download and set up micromamba"
        )

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let manager = CondaManager.shared

            print(formatter.header("Setting up micromamba"))
            let path = try await manager.ensureMicromamba { fraction, message in
                print(formatter.info(message))
            }
            print(formatter.success("Micromamba ready at: \(path.path)"))
        }
    }
}

// MARK: - Plugin Packs

extension CondaCommand {
    struct PacksSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "packs",
            abstract: "List available plugin packs"
        )

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            print(formatter.header("Available Tool Packs"))
            print("")
            for pack in CondaCommand.visiblePacksForTesting() {
                print(formatter.bold("\(pack.name)") + " (\(pack.id))")
                print("  \(pack.description)")
                print("  Packages: \(pack.packages.joined(separator: ", "))")
                print("")
            }
        }
    }
}

// MARK: - Offline Packs

extension CondaCommand {
    struct OfflineExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "offline-export",
            abstract: "Export installed conda environments for offline transfer"
        )

        @Option(name: .long, help: "Built-in tool pack ID to export")
        var pack: String

        @Option(name: .shortAndLong, help: "Directory where the offline pack directory will be written")
        var output: String

        @Option(name: .customLong("conda-root"), help: "Conda root to export from (default: managed storage conda root)")
        var condaRoot: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            guard let pluginPack = PluginPack.builtInPack(id: pack) else {
                print(formatter.error("Unknown tool pack: \(pack)"))
                print("Available packs: \(CondaCommand.visiblePacksForTesting().map(\.id).joined(separator: ", "))")
                throw ExitCode.failure
            }

            let root = condaRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? CondaManager.shared.rootPrefix
            let outputURL = URL(fileURLWithPath: output, isDirectory: true)

            do {
                let result = try await CondaOfflinePackService().exportPack(
                    pack: pluginPack,
                    condaRoot: root,
                    outputDirectory: outputURL,
                    commandLine: CondaOfflinePackService.redactedCommandLine(CommandLine.arguments)
                )
                print(formatter.success("Offline pack exported: \(result.packDirectory.path)"))
                print("Manifest: \(result.manifestURL.path)")
                print("Provenance: \(result.provenanceURL.path)")
            } catch {
                print(formatter.error("Offline export failed: \(error.localizedDescription)"))
                throw ExitCode.failure
            }
        }
    }

    struct OfflineInstallSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "offline-install",
            abstract: "Install conda environments from an offline pack"
        )

        @Argument(help: "Path to an offline pack directory created by 'conda offline-export'")
        var packDirectory: String

        @Option(name: .customLong("conda-root"), help: "Conda root to install into (default: managed storage conda root)")
        var condaRoot: String?

        @Flag(name: .long, help: "Replace existing environments with matching names")
        var overwrite: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let root = condaRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? CondaManager.shared.rootPrefix
            let packURL = URL(fileURLWithPath: packDirectory, isDirectory: true)

            do {
                let result = try await CondaOfflinePackService().installPack(
                    from: packURL,
                    condaRoot: root,
                    overwrite: overwrite,
                    commandLine: CondaOfflinePackService.redactedCommandLine(CommandLine.arguments)
                )
                print(formatter.success("Offline pack installed"))
                for environment in result.installedEnvironments {
                    print("  \(environment.lastPathComponent): \(environment.path)")
                }
                print("Provenance: \(result.provenanceURL.path)")
            } catch {
                print(formatter.error("Offline install failed: \(error.localizedDescription)"))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Formatting Helpers

private func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
    return "\(bytes) B"
}

// MARK: - FileManager Extension

extension FileManager {
    /// Returns the allocated size of a directory and all its contents.
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var totalSize: Int64 = 0
        let enumerator = self.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        return totalSize
    }
}
