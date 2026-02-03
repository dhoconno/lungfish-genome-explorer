// DebugCommand.swift - Debug and troubleshooting commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Debug and troubleshooting commands
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Debugging and troubleshooting tools",
        subcommands: [
            EnvSubcommand.self,
            ContainerSubcommand.self,
            WorkflowLogSubcommand.self,
        ],
        defaultSubcommand: EnvSubcommand.self
    )
}

// MARK: - Environment Check

/// Check environment and dependencies
struct EnvSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env",
        abstract: "Check environment and dependencies",
        discussion: """
            Verify that all required tools and dependencies are available.

            Examples:
              lungfish debug env
              lungfish debug env --check-tools
            """
    )

    @Flag(
        name: .customLong("check-tools"),
        help: "Check bioinformatics tools availability"
    )
    var checkTools: Bool = false

    @Option(
        name: .customLong("tool"),
        help: "Check specific tool"
    )
    var tool: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        print(formatter.header("Environment Check"))
        print("")

        // System info
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

        print(formatter.keyValueTable([
            ("macOS Version", osVersion),
            ("CPU Cores", "\(cpuCount)"),
            ("Physical Memory", "\(memory) GB"),
            ("Architecture", "arm64"),
        ]))
        print("")

        // Container support
        print(formatter.header("Container Support"))
        if #available(macOS 26, *) {
            print(formatter.success("Apple Containerization available (macOS 26+)"))
        } else {
            print(formatter.warning("Apple Containerization requires macOS 26 or later"))
        }
        print("")

        // Check tools if requested
        if checkTools {
            print(formatter.header("Bioinformatics Tools"))

            let tools = [
                ("nextflow", "Workflow engine"),
                ("snakemake", "Workflow engine"),
                ("bwa", "Sequence aligner"),
                ("samtools", "SAM/BAM utilities"),
                ("bcftools", "VCF utilities"),
                ("bedtools", "BED utilities"),
                ("blast", "Sequence search"),
                ("fastqc", "QC analysis"),
            ]

            for (toolName, description) in tools {
                let status = checkToolAvailability(toolName)
                if status.available {
                    print(formatter.success("\(toolName): \(status.version ?? "available") - \(description)"))
                } else {
                    print(formatter.dim("  \(toolName): not found - \(description)"))
                }
            }
        }

        // Check specific tool
        if let toolName = tool {
            print(formatter.header("Tool Check: \(toolName)"))
            let status = checkToolAvailability(toolName)
            if status.available {
                print(formatter.success("\(toolName) is available"))
                if let version = status.version {
                    print("  Version: \(version)")
                }
                if let path = status.path {
                    print("  Path: \(path)")
                }
            } else {
                print(formatter.error("\(toolName) not found"))
                print("  Try installing with: conda install -c bioconda \(toolName)")
            }
        }

        // JSON output
        if globalOptions.outputFormat == .json {
            let envInfo = EnvironmentInfo(
                macOSVersion: osVersion,
                cpuCores: cpuCount,
                memoryGB: Int(memory),
                containerSupport: {
                    if #available(macOS 26, *) {
                        return true
                    }
                    return false
                }()
            )
            let handler = JSONOutputHandler()
            handler.writeData(envInfo, label: nil)
        }
    }

    private func checkToolAvailability(_ tool: String) -> (available: Bool, version: String?, path: String?) {
        // Check if tool is in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Try to get version
                let versionProcess = Process()
                versionProcess.executableURL = URL(fileURLWithPath: path ?? tool)
                versionProcess.arguments = ["--version"]

                let versionPipe = Pipe()
                versionProcess.standardOutput = versionPipe
                versionProcess.standardError = versionPipe

                do {
                    try versionProcess.run()
                    versionProcess.waitUntilExit()
                    let versionData = versionPipe.fileHandleForReading.readDataToEndOfFile()
                    let versionOutput = String(data: versionData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "\n")
                        .first
                        .map(String.init)

                    return (true, versionOutput, path)
                } catch {
                    return (true, nil, path)
                }
            }
        } catch {
            // Tool not found
        }

        return (false, nil, nil)
    }
}

/// Environment info for JSON output
struct EnvironmentInfo: Codable {
    let macOSVersion: String
    let cpuCores: Int
    let memoryGB: Int
    let containerSupport: Bool
}

// MARK: - Container Diagnostics

/// Container runtime diagnostics
struct ContainerSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "Apple Container runtime diagnostics"
    )

    @Flag(
        name: .customLong("pull-test"),
        help: "Test image pull capability"
    )
    var pullTest: Bool = false

    @Option(
        name: .customLong("test-image"),
        help: "Image to use for testing"
    )
    var testImage: String = "alpine:latest"

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        print(formatter.header("Apple Container Runtime"))
        print("")

        if #available(macOS 26, *) {
            print(formatter.success("Apple Containerization framework available"))
            print(formatter.keyValueTable([
                ("Status", "Ready"),
                ("VM Type", "Apple Virtualization"),
                ("Architecture", "arm64"),
            ]))

            if pullTest {
                print("\n" + formatter.info("Testing image pull: \(testImage)"))
                // TODO: Implement actual container pull test
                print(formatter.warning("Pull test not yet implemented"))
            }
        } else {
            print(formatter.error("Apple Containerization requires macOS 26 or later"))
            print("\nCurrent macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Please upgrade to macOS 26 (Tahoe) or later for container support.")
        }
    }
}

// MARK: - Workflow Log Parser

/// Parse workflow execution logs
struct WorkflowLogSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow-log",
        abstract: "Parse and analyze workflow logs",
        discussion: """
            Parse Nextflow or Snakemake execution logs for debugging.

            Examples:
              lungfish debug workflow-log ./work
              lungfish debug workflow-log ./work --errors-only
              lungfish debug workflow-log .nextflow.log --timeline
            """
    )

    @Argument(help: "Log file or work directory")
    var path: String

    @Flag(
        name: .customLong("errors-only"),
        help: "Show only error messages"
    )
    var errorsOnly: Bool = false

    @Flag(
        name: .customLong("timeline"),
        help: "Show execution timeline"
    )
    var timeline: Bool = false

    @Option(
        name: .customLong("process"),
        help: "Filter by process name"
    )
    var processFilter: String?

    @Flag(
        name: .customLong("resource-usage"),
        help: "Show resource usage statistics"
    )
    var resourceUsage: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.inputFileNotFound(path: path)
        }

        let url = URL(fileURLWithPath: path)

        print(formatter.header("Workflow Log Analysis"))
        print(formatter.keyValueTable([
            ("Path", path),
            ("Filter", errorsOnly ? "Errors only" : "All messages"),
        ]))
        print("")

        // Check if it's a directory (work dir) or file (log file)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            // Work directory - look for logs
            print(formatter.info("Scanning work directory for logs..."))

            let logFiles = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "log" || $0.lastPathComponent.contains("log") }

            print("Found \(logFiles.count) log file(s)")

            for logFile in logFiles.prefix(10) {
                print("  - \(logFile.lastPathComponent)")
            }
        } else {
            // Log file - parse it
            print(formatter.info("Parsing log file..."))

            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.split(separator: "\n")

            var errorCount = 0
            var warningCount = 0

            for line in lines {
                let lineStr = String(line)

                if errorsOnly {
                    if lineStr.contains("ERROR") || lineStr.contains("error") || lineStr.contains("failed") {
                        print(formatter.error(lineStr))
                        errorCount += 1
                    }
                } else {
                    if lineStr.contains("ERROR") {
                        print(formatter.error(lineStr))
                        errorCount += 1
                    } else if lineStr.contains("WARN") {
                        print(formatter.warning(lineStr))
                        warningCount += 1
                    } else if globalOptions.effectiveVerbosity > 0 {
                        print(lineStr)
                    }
                }
            }

            print("")
            print(formatter.header("Summary"))
            print(formatter.keyValueTable([
                ("Total lines", "\(lines.count)"),
                ("Errors", errorCount > 0 ? formatter.colored("\(errorCount)", .red) : "0"),
                ("Warnings", warningCount > 0 ? formatter.colored("\(warningCount)", .yellow) : "0"),
            ]))
        }
    }
}
