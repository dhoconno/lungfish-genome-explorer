// NativeToolRunner.swift - Execute native bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

// MARK: - NativeToolResult

/// Result of running a native tool.
public struct NativeToolResult: Sendable {
    /// Exit code from the process.
    public let exitCode: Int32
    
    /// Standard output from the process.
    public let stdout: String
    
    /// Standard error from the process.
    public let stderr: String
    
    /// Whether the command succeeded (exit code 0).
    public var isSuccess: Bool { exitCode == 0 }
    
    /// Combined output (stdout + stderr).
    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - NativeToolError

/// Errors that can occur when running native tools.
public enum NativeToolError: Error, LocalizedError, Sendable {
    /// Tool not found in the expected installation location.
    case toolNotFound(String)

    /// Tool execution failed.
    case executionFailed(String, Int32, String)

    /// Tool timed out.
    case timeout(String, TimeInterval)

    /// Invalid arguments provided.
    case invalidArguments(String)

    /// Tools directory not found in app bundle.
    case toolsDirectoryNotFound

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Required tool '\(tool)' was not found in the expected location."
        case .executionFailed(let tool, let code, let stderr):
            return "Tool '\(tool)' failed with exit code \(code): \(stderr)"
        case .timeout(let tool, let seconds):
            return "Tool '\(tool)' timed out after \(Int(seconds)) seconds"
        case .invalidArguments(let reason):
            return "Invalid arguments: \(reason)"
        case .toolsDirectoryNotFound:
            return "Tools directory not found in app bundle. The app may need to be reinstalled."
        }
    }
}

// MARK: - NativeToolLocation

public enum NativeToolLocation: Sendable, Hashable {
    case bundled(relativePath: String)
    case managed(environment: String, executableName: String)
}


// MARK: - DataBox

/// Thread-safe box for collecting Data from a single GCD block.
/// Each box is written by exactly one block, eliminating data races
/// that would occur when multiple GCD blocks mutate a shared Array<Data>.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}

// MARK: - TailBuffer

/// Ring buffer that retains only the last `capacity` bytes of appended data.
/// Used to bound stderr capture for long-running tools like BBTools.
private final class TailBuffer: @unchecked Sendable {
    private let capacity: Int
    private var buffer: Data

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Data()
        self.buffer.reserveCapacity(capacity)
    }

    func append(_ chunk: Data) {
        buffer.append(chunk)
        if buffer.count > capacity {
            buffer = buffer.suffix(capacity)
        }
    }

    var data: Data { buffer }
}

// MARK: - NativeTool

/// Represents a native bioinformatics tool required by the app.
///
/// Most tools are bundled with the app. Core workflow launchers and BBTools are
/// resolved from managed environments under `~/.lungfish/conda/envs`.
public enum NativeTool: String, CaseIterable, Sendable {
    case samtools
    case bcftools
    case bgzip
    case tabix
    case bedToBigBed
    case bedGraphToBigWig
    case pigz
    case seqkit
    case fastp
    case vsearch
    case cutadapt
    case clumpify
    case bbduk
    case bbmerge
    case repair
    case tadpole
    case reformat
    case java
    // SRA human-read scrubber
    case alignsTo
    case scrubSh
    // SRA toolkit
    case fasterqDump
    case prefetch
    // Deacon human-read scrubber (conda-installed, not bundled)
    case deacon

    /// The executable name for this tool.
    public var executableName: String {
        switch self {
        case .samtools: return "samtools"
        case .bcftools: return "bcftools"
        case .bgzip: return "bgzip"
        case .tabix: return "tabix"
        case .bedToBigBed: return "bedToBigBed"
        case .bedGraphToBigWig: return "bedGraphToBigWig"
        case .pigz: return "pigz"
        case .seqkit: return "seqkit"
        case .fastp: return "fastp"
        case .vsearch: return "vsearch"
        case .cutadapt: return "cutadapt"
        case .clumpify: return "clumpify.sh"
        case .bbduk: return "bbduk.sh"
        case .bbmerge: return "bbmerge.sh"
        case .repair: return "repair.sh"
        case .tadpole: return "tadpole.sh"
        case .reformat: return "reformat.sh"
        case .java: return "java"
        case .alignsTo: return "aligns_to"
        case .scrubSh: return "scrub.sh"
        case .fasterqDump: return "fasterq-dump"
        case .prefetch: return "prefetch"
        case .deacon: return "deacon"
        }
    }

    public var location: NativeToolLocation {
        switch self {
        case .clumpify:
            return .managed(environment: "bbtools", executableName: "clumpify.sh")
        case .bbduk:
            return .managed(environment: "bbtools", executableName: "bbduk.sh")
        case .bbmerge:
            return .managed(environment: "bbtools", executableName: "bbmerge.sh")
        case .repair:
            return .managed(environment: "bbtools", executableName: "repair.sh")
        case .tadpole:
            return .managed(environment: "bbtools", executableName: "tadpole.sh")
        case .reformat:
            return .managed(environment: "bbtools", executableName: "reformat.sh")
        case .java:
            return .managed(environment: "bbtools", executableName: "java")
        case .fastp:
            return .managed(environment: "fastp", executableName: "fastp")
        case .alignsTo:
            return .bundled(relativePath: "scrubber/bin/aligns_to")
        case .scrubSh:
            return .bundled(relativePath: "scrubber/scripts/scrub.sh")
        case .fasterqDump:
            return .bundled(relativePath: "sra-tools/fasterq-dump")
        case .prefetch:
            return .bundled(relativePath: "sra-tools/prefetch")
        case .deacon:
            return .managed(environment: "deacon", executableName: "deacon")
        default:
            return .bundled(relativePath: executableName)
        }
    }

    public var isBundled: Bool {
        if case .bundled = location {
            return true
        }
        return false
    }

    /// Relative path from the tools root directory.
    ///
    /// Most tools are rooted directly under `Tools/`. Multi-file distributions
    /// (BBTools and bundled JRE) are nested under subdirectories.
    public var relativeExecutablePath: String {
        switch self {
        case .clumpify:
            return "bbtools/clumpify.sh"
        case .bbduk:
            return "bbtools/bbduk.sh"
        case .bbmerge:
            return "bbtools/bbmerge.sh"
        case .repair:
            return "bbtools/repair.sh"
        case .tadpole:
            return "bbtools/tadpole.sh"
        case .reformat:
            return "bbtools/reformat.sh"
        case .java:
            return "jre/bin/java"
        case .alignsTo:
            return "scrubber/bin/aligns_to"
        case .scrubSh:
            return "scrubber/scripts/scrub.sh"
        case .fasterqDump:
            return "sra-tools/fasterq-dump"
        case .prefetch:
            return "sra-tools/prefetch"
        default:
            return executableName
        }
    }

    /// The source package this tool comes from.
    public var sourcePackage: String {
        switch self {
        case .samtools: return "samtools"
        case .bcftools: return "bcftools"
        case .bgzip, .tabix: return "htslib"
        case .bedToBigBed, .bedGraphToBigWig: return "ucsc-tools"
        case .pigz: return "pigz"
        case .seqkit: return "seqkit"
        case .fastp: return "fastp"
        case .vsearch: return "vsearch"
        case .cutadapt: return "cutadapt"
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat: return "bbmap"
        case .java: return "openjdk"
        case .alignsTo, .scrubSh: return "sra-human-scrubber"
        case .fasterqDump, .prefetch: return "sra-tools"
        case .deacon: return "deacon"
        }
    }

    /// Whether this tool is a BBTools shell script that doesn't properly quote `$@`.
    /// These scripts require paths without spaces; NativeToolRunner will create
    /// temporary symlinks for any arguments containing spaces.
    public var isBBToolsShellScript: Bool {
        switch self {
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat: return true
        default: return false
        }
    }

    /// License information for this tool.
    public var license: String {
        switch self {
        case .samtools, .bcftools, .bgzip, .tabix:
            return "MIT/Expat"
        case .bedToBigBed, .bedGraphToBigWig:
            return "MIT (UCSC Genome Browser)"
        case .pigz:
            return "zlib License"
        case .seqkit:
            return "MIT License"
        case .fastp:
            return "MIT License"
        case .vsearch:
            return "GPL-3.0 or BSD-2-Clause (dual)"
        case .cutadapt:
            return "MIT License"
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat:
            return "BBMap License"
        case .java:
            return "GPL-2.0-with-classpath-exception"
        case .alignsTo, .scrubSh:
            return "Public Domain (NCBI)"
        case .fasterqDump, .prefetch:
            return "Public Domain (NCBI)"
        case .deacon:
            return "MIT License"
        }
    }

    /// Whether this tool is part of htslib (bgzip, tabix).
    public var isHtslib: Bool {
        self == .bgzip || self == .tabix
    }
}

// MARK: - NativeToolRunner

/// Runs native bioinformatics tools resolved from bundled resources or managed environments.
public actor NativeToolRunner {

    // MARK: - Shared Instance

    public static let shared = NativeToolRunner()

    // MARK: - Properties

    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "NativeToolRunner"
    )

    /// Cache of discovered tool paths.
    private var toolPaths: [NativeTool: URL] = [:]

    /// Cache of runtime-detected tool versions (populated on first query per tool).
    private var runtimeVersionCache: [NativeTool: String] = [:]

    /// The directory containing bundled tools.
    private var toolsDirectory: URL?

    /// Home directory used for managed tool resolution.
    private let homeDirectory: URL

    /// Default timeout for tool execution (5 minutes).
    private let defaultTimeout: TimeInterval = 300

    /// Bundled tool versions, loaded from tool-versions.json at launch.
    public static let bundledVersions: [String: String] = {
        if let url = RuntimeResourceLocator.path("Tools/tool-versions.json", in: .workflow),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(ToolVersionsManifest.self, from: data) {
            return Dictionary(uniqueKeysWithValues: manifest.tools.map { ($0.name, $0.version) })
        }
        return [:]
    }()

    /// Full tool manifest with license and source info, loaded from tool-versions.json.
    public static let toolManifest: ToolVersionsManifest? = {
        guard let url = RuntimeResourceLocator.path("Tools/tool-versions.json", in: .workflow),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ToolVersionsManifest.self, from: data)
    }()

    // MARK: - Initialization

    public init() {
        self.toolsDirectory = Self.findToolsDirectory()
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        if let dir = self.toolsDirectory {
            logger.info("Tools directory resolved: \(dir.path, privacy: .public)")
        } else {
            logger.error("Tools directory could not be resolved from any search path")
        }
    }

    /// Creates a runner with an explicit tools directory (for testing).
    public init(
        toolsDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.toolsDirectory = toolsDirectory
        self.homeDirectory = homeDirectory
    }
    
    // MARK: - Tool Discovery
    
    /// Finds the path to a native tool.
    /// 
    /// - Parameter tool: The tool to find.
    /// - Returns: URL to the tool executable.
    /// - Throws: `NativeToolError.toolNotFound` if not found.
    public func findTool(_ tool: NativeTool) throws -> URL {
        // Check cache first
        if let cached = toolPaths[tool] {
            return cached
        }
        
        let path = try discoverToolPath(tool)
        toolPaths[tool] = path
        return path
    }
    
    /// Checks if a tool is available.
    public func isToolAvailable(_ tool: NativeTool) -> Bool {
        do {
            _ = try findTool(tool)
            return true
        } catch {
            return false
        }
    }
    
    /// Returns the availability status of all tools.
    public func checkAllTools() -> [NativeTool: Bool] {
        var results: [NativeTool: Bool] = [:]
        for tool in NativeTool.allCases {
            results[tool] = isToolAvailable(tool)
        }
        return results
    }
    
    /// Clears the tool path cache.
    public func clearCache() {
        toolPaths.removeAll()
        runtimeVersionCache.removeAll()
    }

    /// Returns the version string of a tool, caching the result.
    /// First checks the bundled tool-versions.json manifest, then falls back to
    /// running `tool --version` and parsing the first line of output.
    public func getToolVersion(_ tool: NativeTool) async -> String? {
        // Check runtime cache
        if let cached = runtimeVersionCache[tool] {
            return cached
        }
        // Check bundled manifest
        if tool.isBundled, let bundled = Self.bundledVersions[tool.rawValue] {
            runtimeVersionCache[tool] = bundled
            return bundled
        }
        // Run tool --version and parse output
        guard let result = try? await run(tool, arguments: ["--version"], timeout: 10) else {
            return nil
        }
        let output = result.isSuccess ? result.stdout : result.stderr
        guard let firstLine = output.split(separator: "\n").first else { return nil }
        // Extract version: look for a pattern like "1.2.3" or "v1.2.3" in the first line
        let versionPattern = /v?(\d+\.\d+(?:\.\d+)?)/
        if let match = String(firstLine).firstMatch(of: versionPattern) {
            let version = String(match.1)
            runtimeVersionCache[tool] = version
            return version
        }
        // Fallback: use the entire first line trimmed
        let version = String(firstLine).trimmingCharacters(in: .whitespaces)
        runtimeVersionCache[tool] = version
        return version
    }
    
    // MARK: - Tool Execution
    
    /// Runs a native tool with the given arguments.
    ///
    /// - Parameters:
    ///   - tool: The tool to run.
    ///   - arguments: Command-line arguments.
    ///   - workingDirectory: Working directory for the process.
    ///   - environment: Additional environment variables.
    ///   - timeout: Maximum execution time.
    /// - Returns: Result containing exit code and output.
    public func run(
        _ tool: NativeTool,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> NativeToolResult {
        let toolPath = try findTool(tool)

        // BBTools shell scripts use unquoted $@ which causes word-splitting on spaces.
        // Create temporary symlinks for any key=value arguments whose paths contain spaces.
        var resolvedArgs = arguments
        var symlinks: [URL] = []
        if tool.isBBToolsShellScript {
            let fm = FileManager.default
            for (i, arg) in arguments.enumerated() {
                guard let eqIdx = arg.firstIndex(of: "=") else { continue }
                let value = String(arg[arg.index(after: eqIdx)...])
                guard value.contains(" ") else { continue }
                let key = String(arg[..<eqIdx])
                let originalURL = URL(fileURLWithPath: value)
                let linkDir = try ProjectTempDirectory.create(
                    prefix: "lungfish-bbtools-",
                    contextURL: originalURL,
                    policy: .systemOnly
                )
                let linkURL = linkDir.appendingPathComponent(Self.bbToolsShellSafeLeafName(for: originalURL))
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: URL(fileURLWithPath: value))
                resolvedArgs[i] = "\(key)=\(linkURL.path)"
                symlinks.append(linkDir)
            }
        }
        defer {
            for link in symlinks {
                try? FileManager.default.removeItem(at: link)
            }
        }

        logger.info("Running \(tool.rawValue): \(resolvedArgs.joined(separator: " "))")

        return try await runProcess(
            executableURL: toolPath,
            arguments: resolvedArgs,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout ?? defaultTimeout,
            toolName: tool.rawValue
        )
    }
    
    /// Runs an arbitrary executable with the given arguments.
    ///
    /// - Parameters:
    ///   - executableURL: Path to the executable.
    ///   - arguments: Command-line arguments.
    ///   - workingDirectory: Working directory for the process.
    ///   - environment: Additional environment variables.
    ///   - timeout: Maximum execution time.
    ///   - toolName: Name for logging purposes.
    /// - Returns: Result containing exit code and output.
    public func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        toolName: String? = nil,
        maxStderrBytes: Int? = nil
    ) async throws -> NativeToolResult {
        let name = toolName ?? executableURL.lastPathComponent
        let actualTimeout = timeout ?? defaultTimeout
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }
            
            // Merge environment
            var processEnvironment = ProcessInfo.processInfo.environment
            if let environment {
                for (key, value) in environment {
                    processEnvironment[key] = value
                }
            }
            process.environment = processEnvironment
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            // Timeout handling
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + actualTimeout,
                execute: timeoutWorkItem
            )
            
            do {
                try process.run()

                // Drain pipes concurrently to avoid deadlock when output exceeds
                // the ~64 KB kernel pipe buffer.
                let stdoutBox = DataBox()
                let stderrBox = DataBox()
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global().async {
                    stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global().async {
                    if let maxBytes = maxStderrBytes {
                        let tailBuf = TailBuffer(capacity: maxBytes)
                        let handle = stderrPipe.fileHandleForReading
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            tailBuf.append(chunk)
                        }
                        stderrBox.value = tailBuf.data
                    } else {
                        stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    }
                    drainGroup.leave()
                }

                process.waitUntilExit()
                drainGroup.wait()
                timeoutWorkItem.cancel()

                let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""

                let result = NativeToolResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                )

                if result.isSuccess {
                    self.logger.info("\(name) completed successfully")
                } else {
                    self.logger.warning("\(name) exited with code \(result.exitCode)")
                }

                continuation.resume(returning: result)

            } catch {
                timeoutWorkItem.cancel()
                continuation.resume(throwing: NativeToolError.executionFailed(
                    name, -1, error.localizedDescription
                ))
            }
        }
    }

    private static func bbToolsShellSafeLeafName(for originalURL: URL) -> String {
        let suffix: String
        if originalURL.pathExtension.isEmpty {
            suffix = ""
        } else {
            suffix = ".\(originalURL.pathExtension)"
        }
        return "bbtools-\(UUID().uuidString.lowercased())\(suffix)"
    }
    
    /// Returns the path to a tool if available, or nil.
    public func toolPath(for tool: NativeTool) throws -> URL {
        return try findTool(tool)
    }

    /// Runs a native tool, redirecting stdout to a file.
    ///
    /// Used for tools like pigz/bgzip that write binary data to stdout.
    public func runWithFileOutput(
        _ tool: NativeTool,
        arguments: [String],
        outputFile: URL,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> NativeToolResult {
        let toolPath = try findTool(tool)
        let actualTimeout = timeout ?? defaultTimeout
        logger.info("Running \(tool.rawValue): \(arguments.joined(separator: " ")) > \(outputFile.path, privacy: .public)")

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = toolPath
            process.arguments = arguments

            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            var processEnvironment = ProcessInfo.processInfo.environment
            if let environment {
                for (key, value) in environment {
                    processEnvironment[key] = value
                }
            }
            process.environment = processEnvironment

            // Redirect stdout to file
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            guard let outputHandle = FileHandle(forWritingAtPath: outputFile.path) else {
                continuation.resume(throwing: NativeToolError.executionFailed(
                    tool.rawValue, -1, "Cannot open output file for writing: \(outputFile.path)"
                ))
                return
            }
            process.standardOutput = outputHandle

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + actualTimeout,
                execute: timeoutWorkItem
            )

            do {
                try process.run()

                // Drain stderr concurrently to avoid deadlock on large output.
                let stderrBox = DataBox()
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global().async {
                    stderrBox.value = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }

                process.waitUntilExit()
                drainGroup.wait()
                timeoutWorkItem.cancel()

                try? outputHandle.close()
                let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""

                let result = NativeToolResult(
                    exitCode: process.terminationStatus,
                    stdout: "",
                    stderr: stderr
                )

                if result.isSuccess {
                    self.logger.info("\(tool.rawValue) completed successfully (output: \(outputFile.lastPathComponent))")
                } else {
                    self.logger.warning("\(tool.rawValue) exited with code \(result.exitCode)")
                }

                continuation.resume(returning: result)

            } catch {
                timeoutWorkItem.cancel()
                try? outputHandle.close()
                continuation.resume(throwing: NativeToolError.executionFailed(
                    tool.rawValue, -1, error.localizedDescription
                ))
            }
        }
    }

    // MARK: - Private Methods

    private func discoverToolPath(_ tool: NativeTool) throws -> URL {
        switch tool.location {
        case .managed(let environment, let executableName):
            let managedToolPath = CoreToolLocator.executableURL(
                environment: environment,
                executableName: executableName,
                homeDirectory: homeDirectory
            )
            if FileManager.default.isExecutableFile(atPath: managedToolPath.path) {
                logger.info("Found managed \(tool.rawValue) at \(managedToolPath.path)")
                return managedToolPath
            }
            logger.error("Managed tool not executable at expected path: \(managedToolPath.path)")
            throw NativeToolError.toolNotFound(tool.rawValue)

        case .bundled(let relativePath):
            guard let toolsDir = toolsDirectory else {
                logger.error("Tools directory not found in bundled resources")
                throw NativeToolError.toolsDirectoryNotFound
            }

            let bundledToolPath = toolsDir.appendingPathComponent(relativePath)
            if FileManager.default.isExecutableFile(atPath: bundledToolPath.path) {
                logger.info("Found bundled \(tool.rawValue) at \(bundledToolPath.path)")
                return bundledToolPath
            }

            logger.error("Bundled tool not executable at expected path: \(bundledToolPath.path)")
            throw NativeToolError.toolNotFound(tool.rawValue)
        }
    }

    /// Finds the Tools directory in the app bundle.
    ///
    /// Searches in order:
    /// 1. Nested workflow bundle inside the installed app
    /// 2. Main bundle Resources/Tools
    /// 3. Executable-adjacent resource bundles for CLI layouts
    /// 4. Development workspace resources discovered from the current executable or cwd
    private static func findToolsDirectory() -> URL? {
        let fileManager = FileManager.default
        let log = Logger(subsystem: LogSubsystem.workflow, category: "NativeToolRunner")

        for resourceRoot in RuntimeResourceLocator.resourceRoots(for: .workflow) {
            let toolsDirectory = resourceRoot.appendingPathComponent("Tools")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: toolsDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                log.debug("findToolsDirectory: Found via runtime resource root: \(toolsDirectory.path, privacy: .public)")
                return toolsDirectory
            }
        }

        log.error("findToolsDirectory: No Tools directory found in any search path")
        return nil
    }

    /// Returns the path to the tools directory, if found.
    public func getToolsDirectory() -> URL? {
        return toolsDirectory
    }

    /// Checks if the tools directory exists and contains expected tools.
    public func validateBundledToolsInstallation() -> (valid: Bool, missing: [NativeTool]) {
        guard let toolsDir = toolsDirectory else {
            return (false, NativeTool.allCases.filter(\.isBundled))
        }

        var missingTools: [NativeTool] = []
        for tool in NativeTool.allCases where tool.isBundled {
            let toolPath = toolsDir.appendingPathComponent(tool.relativeExecutablePath)
            if !FileManager.default.isExecutableFile(atPath: toolPath.path) {
                missingTools.append(tool)
            }
        }

        return (missingTools.isEmpty, missingTools)
    }

    public func validateToolsInstallation() -> (valid: Bool, missing: [NativeTool]) {
        validateBundledToolsInstallation()
    }
}

// MARK: - Pipeline Execution

/// Result of running a multi-process pipeline.
public struct NativePipelineResult: Sendable {
    /// Exit codes from each stage (in order).
    public let exitCodes: [Int32]

    /// Standard error from each stage (in order).
    public let stderrByStage: [String]

    /// Standard output from the final stage.
    public let stdout: String

    /// Whether all stages succeeded (exit code 0).
    public var isSuccess: Bool { exitCodes.allSatisfy { $0 == 0 } }

    /// The first non-zero exit code, if any.
    public var firstFailureCode: Int32? { exitCodes.first { $0 != 0 } }

    /// Combined stderr from all stages.
    public var combinedStderr: String {
        stderrByStage.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A single stage in a tool pipeline.
public struct NativePipelineStage: Sendable {
    public let tool: NativeTool
    public let arguments: [String]

    public init(_ tool: NativeTool, arguments: [String]) {
        self.tool = tool
        self.arguments = arguments
    }
}

extension NativeToolRunner {

    /// Runs a pipeline of tools connected by pipes (stdout → stdin).
    ///
    /// Each stage's stdout is piped to the next stage's stdin.
    /// The final stage's stdout is captured and returned.
    ///
    /// Example: `seqkit grep -f ids.txt input.fq | seqkit subseq -r 10:100`
    ///
    /// - Parameters:
    ///   - stages: Ordered pipeline stages. Must contain at least one stage.
    ///   - workingDirectory: Working directory for all processes.
    ///   - environment: Additional environment variables for all processes.
    ///   - timeout: Maximum execution time for the entire pipeline.
    /// - Returns: Pipeline result with per-stage exit codes and stderr.
    public func runPipeline(
        _ stages: [NativePipelineStage],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> NativePipelineResult {
        guard !stages.isEmpty else {
            throw NativeToolError.invalidArguments("Pipeline must have at least one stage")
        }

        // Single stage: delegate to regular run
        if stages.count == 1 {
            let result = try await run(
                stages[0].tool,
                arguments: stages[0].arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout
            )
            return NativePipelineResult(
                exitCodes: [result.exitCode],
                stderrByStage: [result.stderr],
                stdout: result.stdout
            )
        }

        // Resolve all tool paths upfront
        var toolPaths: [URL] = []
        for stage in stages {
            toolPaths.append(try findTool(stage.tool))
        }

        let actualTimeout = timeout ?? defaultTimeout
        let stageNames = stages.map(\.tool.rawValue).joined(separator: " | ")
        logger.info("Running pipeline: \(stageNames)")

        return try await withCheckedThrowingContinuation { continuation in
            var processes: [Process] = []
            var interStagePipes: [Pipe] = []
            var stderrPipes: [Pipe] = []
            let stdoutPipe = Pipe() // Captures final stage stdout

            // Build merged environment
            var processEnvironment = ProcessInfo.processInfo.environment
            if let environment {
                for (key, value) in environment {
                    processEnvironment[key] = value
                }
            }

            // Create processes and wire pipes
            for (index, stage) in stages.enumerated() {
                let process = Process()
                process.executableURL = toolPaths[index]
                process.arguments = stage.arguments
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }
                process.environment = processEnvironment

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                stderrPipes.append(stderrPipe)

                // Wire stdin from previous stage's pipe
                if index > 0 {
                    process.standardInput = interStagePipes[index - 1]
                }

                // Wire stdout
                if index < stages.count - 1 {
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    interStagePipes.append(pipe)
                } else {
                    process.standardOutput = stdoutPipe
                }

                processes.append(process)
            }

            // Timeout for the whole pipeline
            let timeoutWorkItem = DispatchWorkItem {
                for process in processes where process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + actualTimeout,
                execute: timeoutWorkItem
            )

            do {
                // Launch all processes (first to last)
                for process in processes {
                    try process.run()
                }

                // Drain all stderr pipes and final stdout concurrently to avoid
                // deadlock when output exceeds the ~64 KB kernel pipe buffer.
                let stderrBoxes = (0..<stages.count).map { _ in DataBox() }
                let stdoutBox = DataBox()
                let drainGroup = DispatchGroup()

                for i in 0..<stages.count {
                    let pipe = stderrPipes[i]
                    let box = stderrBoxes[i]
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }
                }
                drainGroup.enter()
                DispatchQueue.global().async {
                    stdoutBox.value = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }

                // Wait last-to-first for proper pipe back-pressure propagation
                for process in processes.reversed() {
                    process.waitUntilExit()
                }
                drainGroup.wait()
                timeoutWorkItem.cancel()

                let exitCodes = processes.map(\.terminationStatus)
                let stderrStrings = stderrBoxes.map { String(data: $0.value, encoding: .utf8) ?? "" }
                let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""

                let result = NativePipelineResult(
                    exitCodes: exitCodes,
                    stderrByStage: stderrStrings,
                    stdout: stdout
                )

                if result.isSuccess {
                    self.logger.info("Pipeline completed successfully: \(stageNames)")
                } else {
                    self.logger.warning("Pipeline failed: \(stageNames), exit codes: \(exitCodes)")
                }

                continuation.resume(returning: result)

            } catch {
                timeoutWorkItem.cancel()
                for process in processes where process.isRunning {
                    process.terminate()
                }
                continuation.resume(throwing: NativeToolError.executionFailed(
                    stageNames, -1, error.localizedDescription
                ))
            }
        }
    }

    /// Runs a pipeline of tools and redirects the final output to a file.
    ///
    /// Useful for `seqkit grep | seqkit subseq > output.fq` patterns.
    public func runPipelineWithFileOutput(
        _ stages: [NativePipelineStage],
        outputFile: URL,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> NativePipelineResult {
        guard !stages.isEmpty else {
            throw NativeToolError.invalidArguments("Pipeline must have at least one stage")
        }

        // Resolve all tool paths upfront
        var toolPaths: [URL] = []
        for stage in stages {
            toolPaths.append(try findTool(stage.tool))
        }

        let actualTimeout = timeout ?? defaultTimeout
        let stageNames = stages.map(\.tool.rawValue).joined(separator: " | ")
        logger.info("Running pipeline (file output): \(stageNames) > \(outputFile.lastPathComponent)")

        return try await withCheckedThrowingContinuation { continuation in
            var processes: [Process] = []
            var interStagePipes: [Pipe] = []
            var stderrPipes: [Pipe] = []
            var outputHandle: FileHandle?

            var processEnvironment = ProcessInfo.processInfo.environment
            if let environment {
                for (key, value) in environment {
                    processEnvironment[key] = value
                }
            }

            // Create output file and handle before building processes
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: outputFile.path) else {
                continuation.resume(throwing: NativeToolError.executionFailed(
                    stageNames, -1, "Cannot open output file for writing: \(outputFile.path)"
                ))
                return
            }
            outputHandle = handle

            for (index, stage) in stages.enumerated() {
                let process = Process()
                process.executableURL = toolPaths[index]
                process.arguments = stage.arguments
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }
                process.environment = processEnvironment

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                stderrPipes.append(stderrPipe)

                if index > 0 {
                    process.standardInput = interStagePipes[index - 1]
                }

                if index < stages.count - 1 {
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    interStagePipes.append(pipe)
                } else {
                    // Last stage: write directly to file
                    process.standardOutput = handle
                }

                processes.append(process)
            }

            let timeoutWorkItem = DispatchWorkItem {
                for process in processes where process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + actualTimeout,
                execute: timeoutWorkItem
            )

            do {
                for process in processes {
                    try process.run()
                }

                // Drain all stderr pipes concurrently to avoid deadlock.
                let stderrBoxes = (0..<stages.count).map { _ in DataBox() }
                let drainGroup = DispatchGroup()
                for i in 0..<stages.count {
                    let pipe = stderrPipes[i]
                    let box = stderrBoxes[i]
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }
                }

                for process in processes.reversed() {
                    process.waitUntilExit()
                }
                drainGroup.wait()
                timeoutWorkItem.cancel()

                try? outputHandle?.close()

                let exitCodes = processes.map(\.terminationStatus)
                let stderrStrings = stderrBoxes.map { String(data: $0.value, encoding: .utf8) ?? "" }

                let result = NativePipelineResult(
                    exitCodes: exitCodes,
                    stderrByStage: stderrStrings,
                    stdout: ""
                )

                if result.isSuccess {
                    self.logger.info("Pipeline completed (file output): \(stageNames)")
                } else {
                    self.logger.warning("Pipeline failed (file output): \(stageNames), exit codes: \(exitCodes)")
                }

                continuation.resume(returning: result)

            } catch {
                timeoutWorkItem.cancel()
                try? outputHandle?.close()
                for process in processes where process.isRunning {
                    process.terminate()
                }
                continuation.resume(throwing: NativeToolError.executionFailed(
                    stageNames, -1, error.localizedDescription
                ))
            }
        }
    }
}

// MARK: - Convenience Methods for Common Operations

extension NativeToolRunner {
    
    /// Compresses a file using bgzip.
    ///
    /// - Parameters:
    ///   - inputPath: Path to the file to compress.
    ///   - keepOriginal: Whether to keep the original file (default: false).
    /// - Returns: Result of the compression.
    public func bgzipCompress(
        inputPath: URL,
        keepOriginal: Bool = false,
        threads: Int? = nil
    ) async throws -> NativeToolResult {
        var args = ["-f"]  // Force overwrite
        if keepOriginal {
            args.append("-k")  // Keep original
        }
        let threadCount = threads ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        if threadCount > 1 {
            args.append(contentsOf: ["-@", "\(threadCount)"])
        }
        args.append(inputPath.path)

        // bgzip on large genomes (3+ GB) can take 10+ minutes single-threaded
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputPath.path)[.size] as? Int64) ?? 0
        let estimatedTimeout: TimeInterval = max(600, Double(fileSize) / 10_000_000) // ~10 MB/s minimum

        return try await run(
            .bgzip,
            arguments: args,
            workingDirectory: inputPath.deletingLastPathComponent(),
            timeout: estimatedTimeout
        )
    }
    
    /// Decompresses a gzip/bgzip file using `bgzip -d`.
    ///
    /// This handles both standard gzip and bgzip-compressed files.
    /// The compressed file is replaced by the decompressed output.
    ///
    /// - Parameter inputPath: Path to the `.gz` file to decompress.
    /// - Returns: The tool result.
    public func bgzipDecompress(inputPath: URL) async throws -> NativeToolResult {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputPath.path)[.size] as? Int64) ?? 0
        // Decompression is faster than compression, but still needs generous timeout for large files
        let estimatedTimeout: TimeInterval = max(300, Double(fileSize) / 20_000_000)

        return try await run(
            .bgzip,
            arguments: ["-d", "-f", inputPath.path],
            workingDirectory: inputPath.deletingLastPathComponent(),
            timeout: estimatedTimeout
        )
    }

    /// Creates a FASTA index using samtools faidx.
    ///
    /// - Parameter fastaPath: Path to the FASTA file (can be compressed).
    /// - Returns: Result of the indexing.
    public func indexFASTA(fastaPath: URL) async throws -> NativeToolResult {
        // samtools faidx on large genomes can take several minutes
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fastaPath.path)[.size] as? Int64) ?? 0
        let estimatedTimeout: TimeInterval = max(600, Double(fileSize) / 10_000_000)

        return try await run(
            .samtools,
            arguments: ["faidx", fastaPath.path],
            workingDirectory: fastaPath.deletingLastPathComponent(),
            timeout: estimatedTimeout
        )
    }
    
    /// Converts VCF to indexed BCF using bcftools.
    ///
    /// - Parameters:
    ///   - vcfPath: Path to the input VCF file.
    ///   - outputPath: Path for the output BCF file.
    /// - Returns: Result of the conversion.
    public func convertVCFtoBCF(
        vcfPath: URL,
        outputPath: URL,
        threads: Int? = nil
    ) async throws -> NativeToolResult {
        let threadCount = threads ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        var args = [
            "view",
            "-O", "b",  // Output BCF
            "-o", outputPath.path,
        ]
        if threadCount > 1 {
            args.append(contentsOf: ["--threads", "\(threadCount)"])
        }
        args.append(vcfPath.path)

        // Convert to BCF
        let convertResult = try await run(
            .bcftools,
            arguments: args,
            workingDirectory: vcfPath.deletingLastPathComponent()
        )
        
        guard convertResult.isSuccess else {
            return convertResult
        }
        
        // Index the BCF
        return try await run(
            .bcftools,
            arguments: ["index", outputPath.path],
            workingDirectory: outputPath.deletingLastPathComponent()
        )
    }
    
    /// Converts BED to BigBed using bedToBigBed.
    ///
    /// - Parameters:
    ///   - bedPath: Path to the input BED file.
    ///   - chromSizesPath: Path to the chromosome sizes file.
    ///   - outputPath: Path for the output BigBed file.
    /// - Returns: Result of the conversion.
    public func convertBEDtoBigBed(
        bedPath: URL,
        chromSizesPath: URL,
        outputPath: URL
    ) async throws -> NativeToolResult {
        // bedToBigBed on millions of features can take several minutes
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: bedPath.path)[.size] as? Int64) ?? 0
        let estimatedTimeout: TimeInterval = max(600, Double(fileSize) / 5_000_000)

        return try await run(
            .bedToBigBed,
            arguments: [
                bedPath.path,
                chromSizesPath.path,
                outputPath.path
            ],
            workingDirectory: bedPath.deletingLastPathComponent(),
            timeout: estimatedTimeout
        )
    }
    
}
