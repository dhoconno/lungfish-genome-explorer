// NativeToolRunner.swift - Execute native bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log
import LungfishCore
import LungfishIO

/// UI diagnostics for native subprocesses. Observers must return promptly; stdout
/// and stderr can arrive concurrently. Captured process results remain unchanged.
public enum NativeProcessEvent: Sendable {
    case started(argv: [String])
    case output(stream: Stream, line: String)

    public enum Stream: Sendable, Equatable { case stdout, stderr }
}

/// An optional task-scoped observer lets workflow callers expose native activity
/// without changing every pipeline's public progress callback or runner mocks.
public enum NativeProcessObservation {
    @TaskLocal public static var onEvent: (@Sendable (NativeProcessEvent) -> Void)?
}

// MARK: - NativeToolResult

/// Result of running a native tool.
public struct NativeToolResult: Sendable {
    /// Exit code from the process.
    public let exitCode: Int32
    
    /// Standard output from the process.
    public let stdout: String
    
    /// Standard error from the process. When ``stderrTruncated`` is true it holds
    /// whole lines only, since the first line of the capture has been dropped.
    public let stderr: String

    /// True when the capture limit dropped the start of the standard error.
    public let stderrTruncated: Bool

    /// Exact argv used to launch the process, including the executable path as argv[0].
    public let arguments: [String]

    public init(
        exitCode: Int32, stdout: String, stderr: String, stderrTruncated: Bool = false, arguments: [String] = []
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.stderrTruncated = stderrTruncated
        self.arguments = arguments
    }
    
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

    /// Native tool execution was attempted without a provenance policy.
    case missingProvenancePolicy(String)

    /// Tools directory not found in app bundle.
    case toolsDirectoryNotFound

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Required tool '\(tool)' was not found in the expected location."
        case .executionFailed(let tool, let code, let stderr):
            return "Tool '\(tool)' failed with exit code \(code): \(stderr)"
        case .timeout(let tool, let seconds):
            return CondaToolTimeLimit.stoppedWords("Tool '\(tool)'", seconds: seconds)
        case .invalidArguments(let reason):
            return "Invalid arguments: \(reason)"
        case .missingProvenancePolicy(let tool):
            return "Native tool '\(tool)' is missing a scientific provenance policy."
        case .toolsDirectoryNotFound:
            return "Tools directory not found in app bundle. The app may need to be reinstalled."
        }
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
    let homeDirectory: URL

    /// App identity used to resolve the managed-storage namespace (injectable for tests).
    let appIdentity: LungfishAppIdentity

    /// A run whose caller passes no timeout has no wall-clock limit (SCOPE-AND-DELIVERY.md, Tool run time). A probe sets its own.
    private let defaultTimeout: TimeInterval = .infinity

    /// Bundled tool versions, loaded from tool-versions.json at launch.
    public static let bundledVersions: [String: String] = {
        if let manifest = loadBundledToolManifest() {
            return Dictionary(uniqueKeysWithValues: manifest.tools.map { ($0.name, $0.version) })
        }
        return [:]
    }()

    /// Full tool manifest with license and source info, loaded from tool-versions.json.
    public static let toolManifest: ToolVersionsManifest? = loadBundledToolManifest()

    private static func loadBundledToolManifest() -> ToolVersionsManifest? {
        if let url = RuntimeResourceLocator.path("Tools/tool-versions.json", in: .workflow),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(ToolVersionsManifest.self, from: data) {
            return manifest
        }
        return ToolVersionsManifest.loadFromBundle()
    }

    // MARK: - Initialization

    public init() {
        self.toolsDirectory = Self.findToolsDirectory()
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.appIdentity = .current
        if let dir = self.toolsDirectory {
            logger.info("Tools directory resolved: \(dir.path, privacy: .public)")
        } else {
            logger.error("Tools directory could not be resolved from any search path")
        }
    }

    /// Creates a runner with an explicit tools directory (for testing).
    public init(
        toolsDirectory: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appIdentity: LungfishAppIdentity = .current
    ) {
        self.toolsDirectory = toolsDirectory
        self.homeDirectory = homeDirectory
        self.appIdentity = appIdentity
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
        // Run the tool's version probe and parse output. Most tools respond to
        // --version, but each tool can override `versionArguments` if needed
        // (e.g., iVar rejects --version and uses the `version` subcommand).
        guard let result = try? await run(tool, arguments: tool.versionArguments, timeout: 10),
              let version = Self.parseVersionProbe(
                  exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                  storageRoot: CoreToolLocator.condaRoot(homeDirectory: homeDirectory, appIdentity: appIdentity))
        else {
            return nil
        }
        runtimeVersionCache[tool] = version
        return version
    }

    /// The version a probe printed, or nil when it printed none: a tool
    /// that rejects the probe ("FATAL ... Unrecognized command", usage text,
    /// a non-zero exit with no version number) is recorded as unknown rather
    /// than as its error message.
    ///
    /// The first lines of stdout and then stderr are scanned for a dotted
    /// number, so `samtools 1.24`, `version: 2.1.5` (lofreq), `BBMap version
    /// 40.02` on stderr and bwa's `Version: 0.7.17-r1188` after a usage exit
    /// all resolve. An error line never contributes, nor does a path token, an echoed
    /// `java` command or anything from a usage line on. The native call site of
    /// `ProbeVersionText.reading(exitCode:stdout:stderr:storageRoot:)`, which holds every rule.
    public static func parseVersionProbe(
        exitCode: Int32, stdout: String, stderr: String, storageRoot: URL? = nil
    ) -> String? {
        ProbeVersionText.reading(exitCode: exitCode, stdout: stdout, stderr: stderr, storageRoot: storageRoot)?.version
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
        _ = try requireProvenancePolicy(for: tool)
        let toolPath = try findTool(tool)

        // BBTools ships wrapper scripts that end in `eval $CMD`, so the shell
        // re-splits every argument on whitespace no matter how carefully this
        // argv array was built. Rewrite path arguments onto a clean staging
        // root first; a clean path plans to a no-op and runs unchanged.
        let staging = try bbToolsStaging(for: tool, arguments: arguments)
        defer { staging.cleanUp() }
        let resolvedArgs = staging.arguments

        logger.info("Running \(tool.rawValue): \(resolvedArgs.joined(separator: " "))")

        let effectiveEnvironment = managedToolEnvironment(for: tool, overriding: environment)

        let result = try await runProcess(
            executableURL: toolPath,
            arguments: resolvedArgs,
            workingDirectory: bbToolsWorkingDirectory(
                for: tool,
                requested: workingDirectory,
                staging: staging
            ),
            environment: effectiveEnvironment,
            timeout: timeout ?? defaultTimeout,
            toolName: tool.rawValue
        )
        // Move outputs home before returning, and before inspecting the exit
        // code: a failed run's partial output is more useful to the caller than
        // a temp directory that is about to be deleted.
        staging.adoptResults()
        return result
    }

    /// Plans whitespace staging for a bbtools invocation.
    ///
    /// Non-bbtools tools quote their argv correctly, so they are never staged:
    /// rewriting their paths would hand them a location their caller does not
    /// expect for no benefit.
    private func bbToolsStaging(
        for tool: NativeTool,
        arguments: [String]
    ) throws -> BBToolsArgumentStaging.Plan {
        guard tool.isBBToolsShellScript else {
            return BBToolsArgumentStaging.Plan(
                arguments: arguments,
                temporaryRoot: nil,
                outputMoves: []
            )
        }
        return try BBToolsArgumentStaging.plan(arguments: arguments)
    }

    /// Keeps the process out of a whitespace-bearing working directory.
    ///
    /// bbtools resolves relative paths against the working directory and passes
    /// them back through the same `eval`, and several scripts shell out to
    /// pigz with the cwd interpolated. When the caller's directory contains
    /// whitespace and a staging root already exists, run there instead. The
    /// caller's outputs are absolute and adopted explicitly, so nothing lands
    /// in the wrong place.
    private func bbToolsWorkingDirectory(
        for tool: NativeTool,
        requested: URL?,
        staging: BBToolsArgumentStaging.Plan
    ) -> URL? {
        guard tool.isBBToolsShellScript,
              let requested,
              BBToolsArgumentStaging.containsWhitespace(requested.path),
              let root = staging.temporaryRoot
        else { return requested }
        return root
    }

    /// The environment a managed tool runs under.
    ///
    /// Every conda environment's `bin` must lead `PATH` for the tool that
    /// lives in it: `run_clair3.sh` is `exec python3 run_clair3.py`, which
    /// then spawns `pypy3`, `parallel`, `samtools` and `whatshap` by bare
    /// name, and `medaka_variant` calls `medaka`, `mini_align`, `minimap2`
    /// and `bcftools` the same way. Under the app's inherited PATH those
    /// resolve to the Mac's own python or to nothing ("pypy3: command not
    /// found"). BBTools additionally needs its bundled JVM, so it keeps its
    /// own layout.
    private func managedToolEnvironment(
        for tool: NativeTool,
        overriding environment: [String: String]?
    ) -> [String: String]? {
        let existingPath = environment?["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        guard tool.isBBToolsShellScript else {
            guard case .managed(let managedEnvironmentName, _) = tool.location else { return environment }
            let binDirectory = CoreToolLocator.environmentURL(
                named: managedEnvironmentName,
                homeDirectory: homeDirectory,
                appIdentity: appIdentity
            ).appendingPathComponent("bin", isDirectory: true)
            var merged = environment ?? [:]
            merged["PATH"] = "\(binDirectory.path):\(existingPath)"
            return merged
        }

        var managedEnvironment = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: homeDirectory,
            existingPath: existingPath,
            appIdentity: appIdentity
        )
        if let environment {
            for (key, value) in environment where key != "PATH"
                && key != "JAVA_HOME"
                && key != "BBMAP_JAVA"
            {
                managedEnvironment[key] = value
            }
        }
        return managedEnvironment
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
        maxStderrBytes: Int? = nil,
        onEvent: (@Sendable (NativeProcessEvent) -> Void)? = nil
    ) async throws -> NativeToolResult {
        let onEvent = onEvent ?? NativeProcessObservation.onEvent
        let name = toolName ?? executableURL.lastPathComponent
        let actualTimeout = timeout ?? defaultTimeout

        try Task.checkCancellation()

        let spec = ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(overriding: environment ?? [:]),
            workingDirectory: workingDirectory,
            stdout: .capture(),
            stderr: .capture(limit: maxStderrBytes ?? ToolProcessSpec.defaultStderrCaptureLimit),
            timeout: try NativeToolProcessAdapter.limit(actualTimeout, name: name),
            label: name,
            environmentChange: observedEnvironmentChange(overriding: environment),
            identityHint: Self.nativeToolName(toolName)
        )
        let processResult = try await NativeToolProcessAdapter.run(spec, timeout: actualTimeout, onEvent: onEvent)
        let result = NativeToolResult(
            exitCode: processResult.status,
            stdout: processResult.stdoutText,
            stderr: processResult.stderrWholeLines,
            stderrTruncated: processResult.stderrTruncated,
            arguments: spec.argv
        )
        if result.isSuccess {
            logger.info("\(name) completed successfully")
        } else {
            logger.warning("\(name) exited with code \(result.exitCode)")
        }
        return result
    }

    private func requireProvenancePolicy(for tool: NativeTool) throws -> ProvenancePolicyEntry {
        guard let policy = ScientificProvenancePolicy.nativeTool(tool),
              policy.requiresProvenance else {
            throw NativeToolError.missingProvenancePolicy(tool.rawValue)
        }
        return policy
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
        _ = try requireProvenancePolicy(for: tool)
        let toolPath = try findTool(tool)
        let actualTimeout = timeout ?? defaultTimeout
        let effectiveEnvironment = managedToolEnvironment(for: tool, overriding: environment)
        logger.info("Running \(tool.rawValue): \(arguments.joined(separator: " ")) > \(outputFile.path, privacy: .public)")
        let name = tool.rawValue
        let temporaryOutputFile = temporaryOutputURL(for: outputFile)

        try Task.checkCancellation()

        // Stdout goes to a sibling temporary file, published only after success.
        guard FileManager.default.createFile(atPath: temporaryOutputFile.path, contents: nil) else {
            throw NativeToolError.executionFailed(
                name, -1, "Cannot open temporary output file for writing: \(temporaryOutputFile.path)"
            )
        }
        let processResult: ToolProcessResult
        do {
            let spec = ToolProcessSpec(
                executableURL: toolPath,
                arguments: arguments,
                environment: ToolProcessSpec.inheritedEnvironment(overriding: effectiveEnvironment ?? [:]),
                workingDirectory: workingDirectory,
                stdout: .file(temporaryOutputFile),
                timeout: try NativeToolProcessAdapter.limit(actualTimeout, name: name),
                label: name,
                environmentChange: observedEnvironmentChange(overriding: effectiveEnvironment),
                identityHint: name
            )
            processResult = try await NativeToolProcessAdapter.run(spec, timeout: actualTimeout, onEvent: nil)
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutputFile)
            throw error
        }

        let result = NativeToolResult(
            exitCode: processResult.status,
            stdout: "",
            stderr: processResult.stderrWholeLines,
            stderrTruncated: processResult.stderrTruncated,
            arguments: [toolPath.path] + arguments
        )
        guard result.isSuccess else {
            try? FileManager.default.removeItem(at: temporaryOutputFile)
            logger.warning("\(name) exited with code \(result.exitCode)")
            return result
        }
        do {
            try Self.publishTemporaryOutput(temporaryOutputFile, to: outputFile)
        } catch {
            try? FileManager.default.removeItem(at: temporaryOutputFile)
            throw NativeToolError.executionFailed(name, -1, error.localizedDescription)
        }
        logger.info("\(name) completed successfully (output: \(outputFile.lastPathComponent))")
        return result
    }

    private nonisolated func temporaryOutputURL(for outputFile: URL) -> URL {
        outputFile.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputFile.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
    }

    private nonisolated static func publishTemporaryOutput(_ temporaryOutputFile: URL, to outputFile: URL) throws {
        if FileManager.default.fileExists(atPath: outputFile.path) {
            _ = try FileManager.default.replaceItemAt(
                outputFile,
                withItemAt: temporaryOutputFile,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporaryOutputFile, to: outputFile)
        }
    }

    // MARK: - Private Methods

    private func discoverToolPath(_ tool: NativeTool) throws -> URL {
        switch tool.location {
        case .managed(let environment, let executableName):
            let managedToolPath = CoreToolLocator.managedExecutableURL(
                environment: environment,
                executableName: executableName,
                homeDirectory: homeDirectory,
                appIdentity: appIdentity
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
        let bundledTools = NativeTool.allCases.filter(\.isBundled)
        guard !bundledTools.isEmpty else {
            return (true, [])
        }

        guard let toolsDir = toolsDirectory else {
            return (false, bundledTools)
        }

        var missingTools: [NativeTool] = []
        for tool in bundledTools {
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

    /// Standard error from each stage (in order), whole lines only. A stage whose
    /// capture hit its limit has lost its first line, as ``NativeToolResult/stderr`` says.
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
        try stages.forEach { _ = try requireProvenancePolicy(for: $0.tool) }

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
        let toolPaths: [URL] = try stages.map { try findTool($0.tool) }

        let actualTimeout = timeout ?? defaultTimeout
        let stageNames = stages.map(\.tool.rawValue).joined(separator: " | ")
        logger.info("Running pipeline: \(stageNames)")
        let specs = stages.enumerated().map { index, stage in
            let stageEnvironment = managedToolEnvironment(for: stage.tool, overriding: environment)
            return ToolProcessSpec(
                executableURL: toolPaths[index],
                arguments: stage.arguments,
                environment: ToolProcessSpec.inheritedEnvironment(overriding: stageEnvironment ?? [:]),
                workingDirectory: workingDirectory,
                label: stage.tool.rawValue,
                environmentChange: observedEnvironmentChange(overriding: stageEnvironment),
                identityHint: stage.tool.rawValue
            )
        }

        try Task.checkCancellation()

        let pipeline = try await NativeToolProcessAdapter.runPipeline(specs, name: stageNames, timeout: actualTimeout)
        let result = NativePipelineResult(
            exitCodes: pipeline.stages.map(\.status),
            stderrByStage: pipeline.stages.map(\.stderrWholeLines),
            stdout: pipeline.stages.last?.stdoutText ?? ""
        )
        if result.isSuccess {
            logger.info("Pipeline completed successfully: \(stageNames)")
        } else {
            logger.warning("Pipeline failed: \(stageNames), exit codes: \(result.exitCodes)")
        }
        return result
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
    
}
