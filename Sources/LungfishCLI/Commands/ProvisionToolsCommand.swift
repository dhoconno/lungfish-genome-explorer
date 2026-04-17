// ProvisionToolsCommand.swift
// LungfishCLI
//
// Command for provisioning the bundled micromamba bootstrap tool.

import ArgumentParser
import Foundation
import LungfishWorkflow

/// Command for provisioning the bundled micromamba bootstrap tool.
struct ProvisionToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provision-tools",
        abstract: "Provision the bundled micromamba bootstrap tool",
        discussion: """
            Provisions the bundled micromamba bootstrap binary used by Lungfish.

            This copies the version pinned in the application resources into the
            managed tools directory so conda-based workflows can bootstrap their
            own environments consistently.
            """
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Option(name: .long, help: "Target architecture (arm64, x86_64, or current)")
    var arch: String = "current"

    @Flag(name: .long, help: "Force rebuild even if tools are already installed")
    var forceRebuild: Bool = false

    @Flag(name: .long, help: "List the bundled bootstrap tool without provisioning")
    var listTools: Bool = false

    @Flag(name: .long, help: "Check installation status of the bundled bootstrap tool")
    var status: Bool = false

    func validate() throws {
        _ = try resolvedArchitecture()
    }

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

        let targetArch = try resolvedArchitecture()

        if !globalOptions.quiet {
            print(formatter.header("Provisioning Bundled Bootstrap Tool"))
            print("Target architecture: \(targetArch.rawValue)")
            print("Output directory: \(await orchestrator.getOutputDirectory().path)")
            print("")
        }

        let manifest = ToolManifest.defaultBundledManifest

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
                    successful: result.successful.keys.sorted(),
                    failed: Dictionary(
                        uniqueKeysWithValues: result.failed.keys.sorted().map { key in
                            (key, result.failed[key]?.localizedDescription ?? "")
                        }
                    ),
                    skipped: result.skipped,
                    duration: result.duration
                )
                let handler = JSONOutputHandler()
                handler.writeData(summary, label: nil)
            } else if !globalOptions.quiet {
                print("")
                print(formatter.header("Bootstrap Tool Provisioning Complete"))
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
        let tools = ToolManifest.defaultBundledManifest.tools

        if globalOptions.outputFormat == .json {
            let toolInfos = tools.map { tool in
                ToolInfo(
                    name: tool.name,
                    displayName: tool.displayName,
                    version: tool.version,
                    license: tool.license.spdxId,
                    executables: tool.executables.sorted(),
                    dependencies: tool.dependencies.sorted(),
                    provisioningMethod: provisioningMethodString(tool.provisioningMethod)
                )
            }
            let handler = JSONOutputHandler()
            handler.writeData(toolInfos, label: nil)
        } else {
            print(formatter.header("Bundled Bootstrap Tool"))
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
            handler.writeData(InstallationStatusSummary(status: status), label: nil)
        } else {
            print(formatter.header("Bundled Bootstrap Tool Status"))
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

    private func resolvedArchitecture() throws -> Architecture {
        switch arch.lowercased() {
        case "arm64":
            return .arm64
        case "x86_64", "x64", "intel":
            return .x86_64
        case "current", "native":
            return .current
        default:
            throw ValidationError("Unknown architecture: \(arch)")
        }
    }
}

// MARK: - Supporting Types

struct ProvisioningSummary: Encodable {
    let successful: [String]
    let failed: [String: String]
    let skipped: [String]
    let duration: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case successful
        case failed
        case skipped
        case duration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(successful.sorted(), forKey: .successful)

        var failedContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .failed)
        for key in failed.keys.sorted() {
            try failedContainer.encode(failed[key], forKey: DynamicCodingKey(key))
        }

        try container.encode(skipped.sorted(), forKey: .skipped)
        try container.encode(duration, forKey: .duration)
    }
}

struct InstallationStatusSummary: Encodable {
    let status: [String: Bool]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for key in status.keys.sorted() {
            try container.encode(status[key], forKey: DynamicCodingKey(key))
        }
    }
}

struct ToolInfo: Codable {
    let name: String
    let displayName: String
    let version: String
    let license: String
    let executables: [String]
    let dependencies: [String]
    let provisioningMethod: String
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}
