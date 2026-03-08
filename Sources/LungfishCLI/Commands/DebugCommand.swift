// DebugCommand.swift - Debug and troubleshooting commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Debug and troubleshooting commands
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Debugging and troubleshooting tools",
        subcommands: [
            EnvSubcommand.self,
            ContainerSubcommand.self,
            FASTQIngestSubcommand.self,
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
        help: "Image to use for testing (must have arm64/linux support)"
    )
    var testImage: String = "docker.io/condaforge/miniforge3:latest"

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
                print(formatter.info("Note: Uses miniforge3 which supports linux/arm64 for Apple Silicon"))
                print(formatter.info("Bioinformatics tools are installed via mamba at container startup"))
                do {
                    // Ensure image reference has domain
                    let fullReference: String
                    if testImage.contains(".") {
                        // Already has domain (e.g., docker.io/library/alpine)
                        fullReference = testImage
                    } else if testImage.contains("/") {
                        // Has path but no domain (e.g., library/alpine)
                        fullReference = "docker.io/\(testImage)"
                    } else {
                        // Just image name (e.g., alpine)
                        fullReference = "docker.io/library/\(testImage)"
                    }
                    print(formatter.dim("  Full reference: \(fullReference)"))
                    
                    let runtime = try await AppleContainerRuntime()
                    print(formatter.success("Container runtime initialized"))
                    
                    print(formatter.info("Pulling image (this may take a while)..."))
                    let image = try await runtime.pullImage(reference: fullReference)
                    print(formatter.success("Successfully pulled image: \(image.reference)"))
                    print(formatter.dim("  Digest: \(image.digest)"))
                } catch {
                    print(formatter.error("Pull test failed: \(error.localizedDescription)"))
                    fputs("DEBUG: \(error)\n", stderr)
                }
            }
        } else {
            print(formatter.error("Apple Containerization requires macOS 26 or later"))
            print("\nCurrent macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Please upgrade to macOS 26 (Tahoe) or later for container support.")
        }
    }
}

// MARK: - FASTQ Ingestion Diagnostics

/// Runs the FASTQ ingestion pipeline outside the app UI.
struct FASTQIngestSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fastq-ingest",
        abstract: "Run FASTQ clumpify/compress/index + optional stats",
        discussion: """
            Executes the same FASTQ ingestion pipeline used by app imports.

            Examples:
              lungfish debug fastq-ingest ./SRR1770413_1.fastq.gz --stats --sample-limit 0
              lungfish debug fastq-ingest ./R1.fastq.gz --pair ./R2.fastq.gz --delete-originals
            """
    )

    @Argument(help: "Input FASTQ file (R1 for paired-end)")
    var input: String

    @Option(name: .customLong("pair"), help: "Optional R2 FASTQ file for paired-end mode")
    var pair: String?

    @Option(name: .customLong("output-dir"), help: "Output directory for processed FASTQ")
    var outputDir: String = "."

    @Option(
        name: .customLong("binning"),
        help: "Quality binning scheme (illumina4, eightLevel, none)"
    )
    var binning: String = QualityBinningScheme.illumina4.rawValue

    @Flag(name: .customLong("skip-clumpify"), help: "Skip read clumpification step")
    var skipClumpify: Bool = false

    @Flag(name: .customLong("delete-originals"), help: "Delete original FASTQ file(s) after success")
    var deleteOriginals: Bool = false

    @Flag(name: .customLong("stats"), help: "Compute FASTQ statistics on processed output")
    var stats: Bool = false

    @Option(name: .customLong("sample-limit"), help: "Read sample limit for stats (0 = full dataset)")
    var sampleLimit: Int = 10_000

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputFileNotFound(path: inputURL.path)
        }

        let pairingMode: FASTQIngestionConfig.PairingMode
        var inputs: [URL] = [inputURL]
        if let pair {
            let pairURL = URL(fileURLWithPath: pair)
            guard FileManager.default.fileExists(atPath: pairURL.path) else {
                throw CLIError.inputFileNotFound(path: pairURL.path)
            }
            inputs.append(pairURL)
            pairingMode = .pairedEnd
        } else {
            pairingMode = .singleEnd
        }

        guard let qualityBinning = QualityBinningScheme(rawValue: binning) else {
            throw CLIError.validationFailed(errors: [
                "Invalid binning scheme '\(binning)'. Expected one of: \(QualityBinningScheme.allCases.map(\.rawValue).joined(separator: ", "))"
            ])
        }

        let outputURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let config = FASTQIngestionConfig(
            inputFiles: inputs,
            pairingMode: pairingMode,
            outputDirectory: outputURL,
            threads: max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount),
            deleteOriginals: deleteOriginals,
            qualityBinning: qualityBinning,
            skipClumpify: skipClumpify
        )

        if !globalOptions.quiet {
            print(formatter.header("FASTQ Ingestion Diagnostics"))
            print("input: \(inputURL.path)")
            if let pair { print("pair:  \(pair)") }
            print("output dir: \(outputURL.path)")
            print("pairing: \(pairingMode.rawValue)")
            print("binning: \(qualityBinning.rawValue)")
            print("skip clumpify: \(skipClumpify)")
            print("delete originals: \(deleteOriginals)")
            print("")
        }

        let pipeline = FASTQIngestionPipeline()
        let result = try await pipeline.run(config: config) { fraction, message in
            if !globalOptions.quiet {
                let pct = Int((fraction * 100).rounded())
                print("[\(pct)%] \(message)")
            }
        }

        if globalOptions.outputFormat == .json {
            let payload = FastqIngestResultPayload(
                outputFile: result.outputFile.path,
                wasClumpified: result.wasClumpified,
                qualityBinning: result.qualityBinning.rawValue,
                originalFilenames: result.originalFilenames,
                originalSizeBytes: result.originalSizeBytes,
                finalSizeBytes: result.finalSizeBytes,
                pairingMode: result.pairingMode.rawValue
            )
            JSONOutputHandler().writeData(payload, label: nil)
        } else {
            print(formatter.success("Pipeline completed"))
            print("output: \(result.outputFile.path)")
            print("clumpified: \(result.wasClumpified)")
            print("size: \(result.originalSizeBytes) -> \(result.finalSizeBytes) bytes")
        }

        if stats {
            let statsLimit = max(0, sampleLimit)
            if !globalOptions.quiet {
                print("")
                print(formatter.info("Computing statistics (sampleLimit=\(statsLimit))..."))
            }
            let reader = FASTQReader()
            let (summary, _) = try await reader.computeStatistics(
                from: result.outputFile,
                sampleLimit: statsLimit,
                progress: { count in
                    guard !globalOptions.quiet else { return }
                    if count > 0, count % 100_000 == 0 {
                        print("  processed \(count) reads")
                    }
                }
            )
            if globalOptions.outputFormat == .json {
                let statsPayload = FastqStatsPayload(
                    readCount: summary.readCount,
                    baseCount: summary.baseCount,
                    meanReadLength: summary.meanReadLength,
                    q30Percentage: summary.q30Percentage,
                    gcPercentage: summary.gcContent * 100.0
                )
                JSONOutputHandler().writeData(statsPayload, label: nil)
            } else {
                print(formatter.success("Stats complete"))
                print("reads: \(summary.readCount)")
                print("bases: \(summary.baseCount)")
                print(String(format: "mean read length: %.2f", summary.meanReadLength))
                print(String(format: "Q30 %%: %.2f", summary.q30Percentage))
                print(String(format: "GC %%: %.2f", summary.gcContent * 100.0))
            }
        }
    }
}

private struct FastqIngestResultPayload: Codable {
    let outputFile: String
    let wasClumpified: Bool
    let qualityBinning: String
    let originalFilenames: [String]
    let originalSizeBytes: Int64
    let finalSizeBytes: Int64
    let pairingMode: String
}

private struct FastqStatsPayload: Codable {
    let readCount: Int
    let baseCount: Int64
    let meanReadLength: Double
    let q30Percentage: Double
    let gcPercentage: Double
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
