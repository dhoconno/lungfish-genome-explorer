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

    /// The executable name for this tool.
    public var executableName: String {
        switch self {
        case .samtools: return "samtools"
        case .bcftools: return "bcftools"
        case .bgzip: return "bgzip"
        case .tabix: return "tabix"
        case .bedToBigBed: return "bedToBigBed"
        case .bedGraphToBigWig: return "bedGraphToBigWig"
        }
    }

    /// The source package this tool comes from.
    public var sourcePackage: String {
        switch self {
        case .samtools: return "samtools"
        case .bcftools: return "bcftools"
        case .bgzip, .tabix: return "htslib"
        case .bedToBigBed, .bedGraphToBigWig: return "ucsc-tools"
        }
    }

    /// License information for this tool.
    public var license: String {
        switch self {
        case .samtools, .bcftools, .bgzip, .tabix:
            return "MIT/Expat"
        case .bedToBigBed, .bedGraphToBigWig:
            return "MIT (UCSC Genome Browser)"
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
        "ucsc-tools": "469"
    ]

    // MARK: - Initialization

    public init() {
        self.toolsDirectory = Self.findToolsDirectory()
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
    
    // MARK: - Private Methods

    private func discoverToolPath(_ tool: NativeTool) throws -> URL {
        guard let toolsDir = toolsDirectory else {
            logger.error("Tools directory not found")
            throw NativeToolError.toolsDirectoryNotFound
        }

        let executable = tool.executableName
        let toolPath = toolsDir.appendingPathComponent(executable)

        guard FileManager.default.isExecutableFile(atPath: toolPath.path) else {
            logger.error("Bundled tool not found: \(toolPath.path)")
            throw NativeToolError.toolNotFound(tool.rawValue)
        }

        logger.info("Found bundled \(tool.rawValue) at \(toolPath.path)")
        return toolPath
    }

    /// Finds the Tools directory in the app bundle.
    ///
    /// Searches in order:
    /// 1. Main bundle Resources/Tools (macOS app)
    /// 2. Executable directory/../Resources/Tools (CLI)
    /// 3. Executable directory/Tools (development)
    /// 4. Source directory Resources/Tools (SwiftPM development)
    private static func findToolsDirectory() -> URL? {
        let fileManager = FileManager.default

        // 1. Check main bundle Resources/Tools (macOS app bundle)
        if let resourceURL = Bundle.main.resourceURL {
            let toolsPath = resourceURL.appendingPathComponent("Tools")
            if fileManager.fileExists(atPath: toolsPath.path) {
                return toolsPath
            }
        }

        // 2. Check relative to executable (CLI tool)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let executableDir = executableURL.deletingLastPathComponent()

        // Try ../Resources/Tools (standard CLI layout)
        let cliResourcesTools = executableDir
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("Tools")
        if fileManager.fileExists(atPath: cliResourcesTools.path) {
            return cliResourcesTools
        }

        // 3. Try ./Tools (development/testing)
        let localTools = executableDir.appendingPathComponent("Tools")
        if fileManager.fileExists(atPath: localTools.path) {
            return localTools
        }

        // 4. Try source directory (SwiftPM development)
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
                    return sourceTools
                }
                break
            }
            currentDir = currentDir.deletingLastPathComponent()
        }

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
            let toolPath = toolsDir.appendingPathComponent(tool.executableName)
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
        keepOriginal: Bool = false
    ) async throws -> NativeToolResult {
        var args = ["-f"]  // Force overwrite
        if keepOriginal {
            args.append("-k")  // Keep original
        }
        args.append(inputPath.path)
        
        return try await run(
            .bgzip,
            arguments: args,
            workingDirectory: inputPath.deletingLastPathComponent()
        )
    }
    
    /// Creates a FASTA index using samtools faidx.
    ///
    /// - Parameter fastaPath: Path to the FASTA file (can be compressed).
    /// - Returns: Result of the indexing.
    public func indexFASTA(fastaPath: URL) async throws -> NativeToolResult {
        return try await run(
            .samtools,
            arguments: ["faidx", fastaPath.path],
            workingDirectory: fastaPath.deletingLastPathComponent()
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
        outputPath: URL
    ) async throws -> NativeToolResult {
        // Convert to BCF
        let convertResult = try await run(
            .bcftools,
            arguments: [
                "view",
                "-O", "b",  // Output BCF
                "-o", outputPath.path,
                vcfPath.path
            ],
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
        return try await run(
            .bedToBigBed,
            arguments: [
                bedPath.path,
                chromSizesPath.path,
                outputPath.path
            ],
            workingDirectory: bedPath.deletingLastPathComponent()
        )
    }
    
    /// Converts bedGraph to BigWig using bedGraphToBigWig.
    ///
    /// - Parameters:
    ///   - bedGraphPath: Path to the input bedGraph file.
    ///   - chromSizesPath: Path to the chromosome sizes file.
    ///   - outputPath: Path for the output BigWig file.
    /// - Returns: Result of the conversion.
    public func convertBedGraphToBigWig(
        bedGraphPath: URL,
        chromSizesPath: URL,
        outputPath: URL
    ) async throws -> NativeToolResult {
        return try await run(
            .bedGraphToBigWig,
            arguments: [
                bedGraphPath.path,
                chromSizesPath.path,
                outputPath.path
            ],
            workingDirectory: bedGraphPath.deletingLastPathComponent()
        )
    }
    
    /// Creates a tabix index for a bgzipped file.
    ///
    /// - Parameters:
    ///   - filePath: Path to the bgzipped file.
    ///   - preset: Tabix preset (gff, bed, sam, vcf).
    /// - Returns: Result of the indexing.
    public func tabixIndex(
        filePath: URL,
        preset: String? = nil
    ) async throws -> NativeToolResult {
        var args = ["-f"]  // Force overwrite
        if let preset {
            args.append(contentsOf: ["-p", preset])
        }
        args.append(filePath.path)
        
        return try await run(
            .tabix,
            arguments: args,
            workingDirectory: filePath.deletingLastPathComponent()
        )
    }
}
