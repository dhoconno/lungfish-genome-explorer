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
    static let configuration = CommandConfiguration(
        commandName: "conda",
        abstract: "Manage bioconda tool plugins via micromamba",
        discussion: """
        Install bioinformatics tools from bioconda and conda-forge using micromamba.
        Each tool is installed in its own isolated environment to prevent dependency
        conflicts. Tools are stored in ~/Library/Application Support/Lungfish/conda/.
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
        ]
    )
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

            if isPack {
                // Install a plugin pack
                for packID in packages {
                    guard let pack = PluginPack.builtIn.first(where: { $0.id == packID }) else {
                        print(formatter.error("Unknown plugin pack: \(packID)"))
                        print("Available packs: \(PluginPack.builtIn.map(\.id).joined(separator: ", "))")
                        throw ExitCode.failure
                    }

                    print(formatter.header("Installing Plugin Pack: \(pack.name)"))
                    print("Packages: \(pack.packages.joined(separator: ", "))")
                    print("")

                    for pkg in pack.packages {
                        print(formatter.info("Installing \(pkg)..."))
                        do {
                            try await manager.install(
                                packages: [pkg],
                                environment: pkg
                            ) { fraction, message in
                                if !globalOptions.quiet {
                                    print("\r\(formatter.info(message))", terminator: "")
                                }
                            }
                            print(formatter.success("  \(pkg) installed"))
                        } catch {
                            print(formatter.warning("  \(pkg) failed: \(error.localizedDescription)"))
                        }
                    }
                    print("")
                    print(formatter.success("Plugin pack '\(pack.name)' installed"))
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

            print(formatter.header("Available Plugin Packs"))
            print("")
            for pack in PluginPack.builtIn {
                print(formatter.bold("\(pack.name)") + " (\(pack.id))")
                print("  \(pack.description)")
                print("  Packages: \(pack.packages.joined(separator: ", "))")
                print("")
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
