// ProvisionToolsCommand.swift
// LungfishCLI
//
// Command for provisioning native bioinformatics tools.

import ArgumentParser
import Foundation
import LungfishWorkflow

/// Command for provisioning native bioinformatics tools.
struct ProvisionToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision-tools",
        abstract: "Download and build bioinformatics tools for bundling",
        discussion: """
            Provisions the native bioinformatics tools that are bundled with Lungfish.
            
            Tools are compiled from source or downloaded as pre-built binaries
            depending on the tool. This ensures consistent versions across all users.
            
            Supported tools:
            - samtools (v1.21) - SAM/BAM file manipulation
            - bcftools (v1.21) - VCF/BCF file manipulation
            - htslib (v1.21) - bgzip, tabix utilities
            - UCSC tools (v469) - bedToBigBed, bedGraphToBigWig
            """
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Option(name: .long, help: "Target architecture (arm64, x86_64, or universal)")
    var arch: String = "current"

    @Flag(name: .long, help: "Force rebuild even if tools are already installed")
    var forceRebuild: Bool = false

    @Flag(name: .long, help: "List available tools without provisioning")
    var listTools: Bool = false

    @Flag(name: .long, help: "Check installation status of tools")
    var status: Bool = false

    mutating func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if listTools {
            await listAvailableTools(formatter: formatter)
            return
        }

        let orchestrator = ToolProvisioningOrchestrator()

        if status {
            await checkStatus(orchestrator: orchestrator, formatter: formatter)
            return
        }

        // Determine architecture
        let targetArch: Architecture
        switch arch.lowercased() {
        case "arm64":
            targetArch = .arm64
        case "x86_64", "x64", "intel":
            targetArch = .x86_64
        case "current", "native":
            targetArch = .current
        case "universal":
            // For universal, we'd need to run provisioning twice
            // For now, just use current
            if !globalOptions.quiet {
                print(formatter.warning("Universal builds not yet supported via CLI. Using current architecture."))
            }
            targetArch = .current
        default:
            throw ValidationError("Unknown architecture: \(arch)")
        }

        if !globalOptions.quiet {
            print(formatter.header("Provisioning Native Tools"))
            print("Target architecture: \(targetArch.rawValue)")
            print("Output directory: \(await orchestrator.getOutputDirectory().path)")
            print("")
        }

        let manifest = ToolManifest(tools: BundledToolSpec.defaultTools)

        // Capture values before async closure to avoid self capture issues
        let isQuiet = globalOptions.quiet
        let outputFormat = globalOptions.outputFormat

        do {
            let result = try await orchestrator.provisionAll(
                manifest: manifest,
                architecture: targetArch,
                forceRebuild: forceRebuild
            ) { status in
                if !isQuiet && outputFormat == .text {
                    Self.printProgress(status, formatter: formatter)
                }
            }

            // Create version info
            try await orchestrator.createVersionInfo(for: result)

            // Print summary
            if globalOptions.outputFormat == .json {
                let summary = ProvisioningSummary(
                    successful: Array(result.successful.keys),
                    failed: result.failed.mapValues { $0.localizedDescription },
                    skipped: result.skipped,
                    duration: result.duration
                )
                let handler = JSONOutputHandler()
                handler.writeData(summary, label: nil)
            } else if !globalOptions.quiet {
                print("")
                print(formatter.header("Provisioning Complete"))
                print("Duration: \(String(format: "%.1f", result.duration)) seconds")
                print("")

                if !result.successful.isEmpty {
                    print(formatter.success("Successfully provisioned:"))
                    for (name, executables) in result.successful.sorted(by: { $0.key < $1.key }) {
                        print("  - \(name): \(executables.map { $0.lastPathComponent }.joined(separator: ", "))")
                    }
                }

                if !result.skipped.isEmpty {
                    print("")
                    print("Already installed (skipped):")
                    for name in result.skipped.sorted() {
                        print("  - \(name)")
                    }
                }

                if !result.failed.isEmpty {
                    print("")
                    print(formatter.error("Failed to provision:"))
                    for (name, error) in result.failed.sorted(by: { $0.key < $1.key }) {
                        print("  - \(name): \(error.localizedDescription)")
                    }
                }
            }

            // Exit with error if any tools failed
            if !result.failed.isEmpty {
                throw ExitCode.failure
            }

        } catch {
            if globalOptions.outputFormat == .text && !globalOptions.quiet {
                print(formatter.error("Provisioning failed: \(error.localizedDescription)"))
            }
            throw error
        }
    }

    private static func printProgress(_ status: ToolProvisioningOrchestrator.Status, formatter: TerminalFormatter) {
        let percentage = Int(status.overallProgress * 100)
        let progressBar = String(repeating: "█", count: percentage / 5) +
                         String(repeating: "░", count: 20 - percentage / 5)

        // Clear line and print progress
        print("\r[\(progressBar)] \(percentage)% \(status.message)", terminator: "")
        fflush(stdout)

        if status.phase == .complete || status.phase == .failed {
            print("")  // New line when done
        }
    }

    private func listAvailableTools(formatter: TerminalFormatter) async {
        let tools = BundledToolSpec.defaultTools

        if globalOptions.outputFormat == .json {
            let toolInfos = tools.map { tool in
                ToolInfo(
                    name: tool.name,
                    displayName: tool.displayName,
                    version: tool.version,
                    license: tool.license.spdxId,
                    executables: tool.executables,
                    dependencies: tool.dependencies,
                    provisioningMethod: provisioningMethodString(tool.provisioningMethod)
                )
            }
            let handler = JSONOutputHandler()
            handler.writeData(toolInfos, label: nil)
        } else {
            print(formatter.header("Available Tools"))
            print("")

            for tool in tools {
                print("\(formatter.bold(tool.displayName)) (v\(tool.version))")
                print("  License: \(tool.license.spdxId)")
                print("  Executables: \(tool.executables.joined(separator: ", "))")
                if !tool.dependencies.isEmpty {
                    print("  Dependencies: \(tool.dependencies.joined(separator: ", "))")
                }
                print("  Method: \(provisioningMethodString(tool.provisioningMethod))")
                if let notes = tool.notes {
                    print("  Note: \(notes)")
                }
                print("")
            }
        }
    }

    private func checkStatus(orchestrator: ToolProvisioningOrchestrator, formatter: TerminalFormatter) async {
        let status = await orchestrator.checkInstallationStatus()

        if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData(status, label: nil)
        } else {
            print(formatter.header("Tool Installation Status"))
            print("")

            for (name, installed) in status.sorted(by: { $0.key < $1.key }) {
                let statusIcon = installed ? "✓" : "✗"
                let statusText = installed ? "installed" : "not installed"
                let coloredIcon = installed ? formatter.colored(statusIcon, .green) : formatter.colored(statusIcon, .red)
                print("  \(coloredIcon) \(name): \(statusText)")
            }
        }
    }

    private func provisioningMethodString(_ method: ProvisioningMethod) -> String {
        switch method {
        case .downloadBinary:
            return "pre-built binary"
        case .compileFromSource:
            return "compile from source"
        case .custom(let name):
            return "custom (\(name))"
        }
    }
}

// MARK: - Supporting Types

private struct ProvisioningSummary: Codable {
    let successful: [String]
    let failed: [String: String]
    let skipped: [String]
    let duration: TimeInterval
}

private struct ToolInfo: Codable {
    let name: String
    let displayName: String
    let version: String
    let license: String
    let executables: [String]
    let dependencies: [String]
    let provisioningMethod: String
}
