// NativeToolRunner.swift - Execute native bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

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
    /// Tool not found in app bundle.
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
            return "Bundled tool '\(tool)' not found. The app bundle may be incomplete or corrupted."
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

// MARK: - NativeTool

/// Represents a native bioinformatics tool bundled with the app.
///
/// All tools are bundled with the app to ensure consistent versions across all users.
/// Tools are compiled for both arm64 (Apple Silicon) and x86_64 (Intel via Rosetta).
public enum NativeTool: String, CaseIterable, Sendable {
    case samtools
    case bcftools
    case bgzip
    case tabix
    case bedToBigBed
    case bedGraphToBigWig
    case pigz
    case seqkit
    case clumpify
    case java

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
        case .clumpify: return "clumpify.sh"
        case .java: return "java"
        }
    }

    /// Relative path from the tools root directory.
    ///
    /// Most tools are rooted directly under `Tools/`. Multi-file distributions
    /// (BBTools and bundled JRE) are nested under subdirectories.
    public var relativeExecutablePath: String {
        switch self {
        case .clumpify:
            return "bbtools/clumpify.sh"
        case .java:
            return "jre/bin/java"
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
        case .clumpify: return "bbtools"
        case .java: return "openjdk"
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
        case .clumpify:
            return "BBMap License"
        case .java:
            return "GPL-2.0-with-classpath-exception"
        }
    }

    /// Whether this tool is part of htslib (bgzip, tabix).
    public var isHtslib: Bool {
        self == .bgzip || self == .tabix
    }
}

// MARK: - NativeToolRunner

/// Runs native bioinformatics tools bundled with the app.
///
/// Tools are ONLY loaded from the app bundle to ensure consistent versions
/// across all users. This prevents issues with different tool versions
/// producing different results.
///
/// Tools are expected to be in one of these locations:
/// - `<AppBundle>/Contents/Resources/Tools/<tool>` (macOS app)
/// - `<ExecutableDir>/../Resources/Tools/<tool>` (CLI tool)
/// - `<ExecutableDir>/Tools/<tool>` (development/testing)
public actor NativeToolRunner {

    // MARK: - Shared Instance

    public static let shared = NativeToolRunner()

    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "NativeToolRunner"
    )

    /// Cache of discovered tool paths.
    private var toolPaths: [NativeTool: URL] = [:]

    /// The directory containing bundled tools.
    private var toolsDirectory: URL?

    /// Default timeout for tool execution (5 minutes).
    private let defaultTimeout: TimeInterval = 300

    /// Bundled tool versions (set during build).
    public static let bundledVersions: [String: String] = [
        "samtools": "1.21",
        "bcftools": "1.21",
        "htslib": "1.21",
        "ucsc-tools": "469",
        "pigz": "2.8",
        "seqkit": "2.9.0",
        "bbtools": "39.13",
        "openjdk": "21.0.10"
    ]

    // MARK: - Initialization

    public init() {
        self.toolsDirectory = Self.findToolsDirectory()
        if let dir = self.toolsDirectory {
            logger.info("Tools directory resolved: \(dir.path, privacy: .public)")
        } else {
            logger.error("Tools directory could not be resolved from any search path")
        }
    }

    /// Creates a runner with an explicit tools directory (for testing).
    public init(toolsDirectory: URL?) {
        self.toolsDirectory = toolsDirectory
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
        
        logger.info("Running \(tool.rawValue): \(arguments.joined(separator: " "))")
        
        return try await runProcess(
            executableURL: toolPath,
            arguments: arguments,
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
        toolName: String? = nil
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
                process.waitUntilExit()
                timeoutWorkItem.cancel()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                
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
            let outputHandle = FileHandle(forWritingAtPath: outputFile.path)!
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
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                try? outputHandle.close()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

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
        let relativePath = tool.relativeExecutablePath

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

    /// Finds the Tools directory in the app bundle.
    ///
    /// Searches in order:
    /// 1. SwiftPM module bundle Resources/Tools
    /// 2. Main bundle Resources/Tools (macOS app)
    /// 3. Main bundle Resources/<WorkflowBundle>.bundle/Tools
    /// 4. Scan executable directory for *.bundle/Tools (most robust for SPM executables)
    /// 5. Executable directory/../Resources/Tools (CLI)
    /// 6. Executable directory/Tools (development)
    /// 7. Source directory Resources/Tools (SwiftPM development)
    private static func findToolsDirectory() -> URL? {
        let fileManager = FileManager.default
        let log = Logger(subsystem: "com.lungfish.workflow", category: "NativeToolRunner")

        // 1. Check SwiftPM module bundle resources.
        if let moduleResourceURL = Bundle.module.resourceURL {
            let moduleTools = moduleResourceURL.appendingPathComponent("Tools")
            if fileManager.fileExists(atPath: moduleTools.path) {
                log.debug("findToolsDirectory: Found via Bundle.module.resourceURL: \(moduleTools.path, privacy: .public)")
                return moduleTools
            }
            log.debug("findToolsDirectory: Not at Bundle.module.resourceURL/Tools: \(moduleTools.path, privacy: .public)")
        }

        // Some packaging layouts keep resources at the bundle root.
        let moduleBundleTools = Bundle.module.bundleURL.appendingPathComponent("Tools")
        if fileManager.fileExists(atPath: moduleBundleTools.path) {
            log.debug("findToolsDirectory: Found via Bundle.module.bundleURL: \(moduleBundleTools.path, privacy: .public)")
            return moduleBundleTools
        }
        log.debug("findToolsDirectory: Not at Bundle.module.bundleURL/Tools: \(moduleBundleTools.path, privacy: .public)")

        // 2. Check main bundle Resources/Tools (macOS app bundle)
        if let resourceURL = Bundle.main.resourceURL {
            let toolsPath = resourceURL.appendingPathComponent("Tools")
            if fileManager.fileExists(atPath: toolsPath.path) {
                log.debug("findToolsDirectory: Found via Bundle.main.resourceURL: \(toolsPath.path, privacy: .public)")
                return toolsPath
            }

            // 3. Check workflow resource bundle nested in main bundle resources.
            let workflowBundleCandidates = [
                resourceURL.appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle"),
                resourceURL.appendingPathComponent("LungfishWorkflow_LungfishWorkflow.bundle"),
                resourceURL.appendingPathComponent("LungfishWorkflow.bundle")
            ]
            for workflowBundle in workflowBundleCandidates {
                // Check both flat and hierarchical bundle layouts
                for toolsSubpath in ["Tools", "Contents/Resources/Tools"] {
                    let nestedTools = workflowBundle.appendingPathComponent(toolsSubpath)
                    if fileManager.fileExists(atPath: nestedTools.path) {
                        log.debug("findToolsDirectory: Found in nested bundle: \(nestedTools.path, privacy: .public)")
                        return nestedTools
                    }
                }
            }
        }

        // 4. Scan executable directory for any *LungfishWorkflow*.bundle containing Tools.
        //    This is the most robust fallback for SPM-built executables where
        //    Bundle.main and Bundle.module may resolve differently than expected.
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let executableDir = executableURL.deletingLastPathComponent()
        log.debug("findToolsDirectory: Executable directory: \(executableDir.path, privacy: .public)")

        if let contents = try? fileManager.contentsOfDirectory(atPath: executableDir.path) {
            for item in contents where item.hasSuffix(".bundle") && item.contains("LungfishWorkflow") {
                let bundleTools = executableDir
                    .appendingPathComponent(item)
                    .appendingPathComponent("Tools")
                if fileManager.fileExists(atPath: bundleTools.path) {
                    log.debug("findToolsDirectory: Found via executable dir scan: \(bundleTools.path, privacy: .public)")
                    return bundleTools
                }
            }
        }

        // 5. Check relative to executable (CLI tool: ../Resources/Tools)
        let cliResourcesTools = executableDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("Tools")
        if fileManager.fileExists(atPath: cliResourcesTools.path) {
            log.debug("findToolsDirectory: Found via CLI resources: \(cliResourcesTools.path, privacy: .public)")
            return cliResourcesTools
        }

        // 6. Try ./Tools (development/testing)
        let localTools = executableDir.appendingPathComponent("Tools")
        if fileManager.fileExists(atPath: localTools.path) {
            log.debug("findToolsDirectory: Found via local Tools: \(localTools.path, privacy: .public)")
            return localTools
        }

        // 7. Try source directory (SwiftPM development)
        // Look for Sources/LungfishWorkflow/Resources/Tools relative to repo root
        var currentDir = executableDir
        for _ in 0..<10 {  // Walk up at most 10 levels
            let packageSwift = currentDir.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: packageSwift.path) {
                // Found repo root
                let sourceTools = currentDir
                    .appendingPathComponent("Sources")
                    .appendingPathComponent("LungfishWorkflow")
                    .appendingPathComponent("Resources")
                    .appendingPathComponent("Tools")
                if fileManager.fileExists(atPath: sourceTools.path) {
                    log.debug("findToolsDirectory: Found via source tree: \(sourceTools.path, privacy: .public)")
                    return sourceTools
                }
                break
            }
            currentDir = currentDir.deletingLastPathComponent()
        }

        log.error("findToolsDirectory: No Tools directory found in any search path")
        return nil
    }

    /// Returns the path to the tools directory, if found.
    public func getToolsDirectory() -> URL? {
        return toolsDirectory
    }

    /// Checks if the tools directory exists and contains expected tools.
    public func validateToolsInstallation() -> (valid: Bool, missing: [NativeTool]) {
        guard let toolsDir = toolsDirectory else {
            return (false, NativeTool.allCases)
        }

        var missingTools: [NativeTool] = []
        for tool in NativeTool.allCases {
            let toolPath = toolsDir.appendingPathComponent(tool.relativeExecutablePath)
            if !FileManager.default.isExecutableFile(atPath: toolPath.path) {
                missingTools.append(tool)
            }
        }

        return (missingTools.isEmpty, missingTools)
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
