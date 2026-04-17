// CondaManager.swift - Micromamba-based package management for bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "CondaManager")

// MARK: - CondaError

/// Errors that can occur during conda operations.
public enum CondaError: Error, LocalizedError, Sendable {
    case micromambaNotFound
    case micromambaDownloadFailed(String)
    case environmentCreationFailed(String)
    case environmentNotFound(String)
    case packageInstallFailed(String)
    case packageNotFound(String)
    case toolNotFound(tool: String, environment: String)
    case executionFailed(tool: String, exitCode: Int32, stderr: String)
    case linuxOnlyPackage(String)
    case networkError(String)
    case diskSpaceError(String)
    case timeout(tool: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .micromambaNotFound:
            return "Micromamba binary not found in the bundled resources."
        case .micromambaDownloadFailed(let msg):
            return "Failed to download micromamba: \(msg)"
        case .environmentCreationFailed(let msg):
            return "Failed to create conda environment: \(msg)"
        case .environmentNotFound(let name):
            return "Conda environment '\(name)' not found"
        case .packageInstallFailed(let msg):
            return "Failed to install package: \(msg)"
        case .packageNotFound(let name):
            return "Package '\(name)' not found in bioconda or conda-forge"
        case .toolNotFound(let tool, let env):
            return "Tool '\(tool)' not found in environment '\(env)'"
        case .executionFailed(let tool, let code, let stderr):
            return "Tool '\(tool)' failed with exit code \(code): \(stderr)"
        case .linuxOnlyPackage(let name):
            return "Package '\(name)' is only available for Linux. Use Apple Containers to run it."
        case .networkError(let msg):
            return "Network error during conda operation: \(msg)"
        case .diskSpaceError(let msg):
            return "Insufficient disk space: \(msg)"
        case .timeout(let tool, let seconds):
            return "Tool '\(tool)' timed out after \(Int(seconds)) seconds"
        }
    }
}

// MARK: - CondaEnvironment

/// Represents a micromamba/conda environment.
public struct CondaEnvironment: Sendable, Codable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let path: URL
    public let packageCount: Int

    public init(name: String, path: URL, packageCount: Int = 0) {
        self.name = name
        self.path = path
        self.packageCount = packageCount
    }
}

// MARK: - CondaPackageInfo

/// Information about an installed or available conda package.
public struct CondaPackageInfo: Sendable, Codable, Identifiable, Hashable {
    public var id: String { "\(name)-\(version)-\(channel)" }
    public let name: String
    public let version: String
    public let channel: String
    public let buildString: String
    public let subdir: String
    public let license: String?
    public let description: String?
    public let sizeBytes: Int64?

    public init(
        name: String, version: String, channel: String,
        buildString: String = "", subdir: String = "",
        license: String? = nil, description: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.name = name
        self.version = version
        self.channel = channel
        self.buildString = buildString
        self.subdir = subdir
        self.license = license
        self.description = description
        self.sizeBytes = sizeBytes
    }

    /// Whether this package has a native macOS arm64 build.
    public var isNativeMacOS: Bool {
        subdir == "osx-arm64" || subdir == "noarch"
    }
}

// MARK: - CondaManager

/// Manages micromamba environments and bioconda package installation.
///
/// Provides the core infrastructure for the plugin system:
/// - Installs and manages the bundled micromamba binary
/// - Creates per-tool conda environments
/// - Installs/uninstalls packages from bioconda and conda-forge
/// - Discovers tool executables in conda environments
/// - Integrates with Nextflow/Snakemake conda profiles
///
/// All operations are async and report progress via callbacks.
///
/// ## Storage
///
/// All conda data is stored in `~/.lungfish/conda/`:
/// - `bin/micromamba` -- the micromamba binary
/// - `envs/<name>/` -- per-tool environments
/// - `pkgs/` -- package cache (shared across environments)
///
/// ## Usage
///
/// ```swift
/// let manager = CondaManager.shared
/// try await manager.ensureMicromamba()
/// try await manager.install(packages: ["samtools"], environment: "samtools")
/// let path = try await manager.toolPath(name: "samtools", environment: "samtools")
/// ```
public actor CondaManager {

    typealias BundledMicromambaProvider = @Sendable () -> URL?
    typealias BundledMicromambaVersionProvider = @Sendable () -> String?

    /// Shared singleton instance.
    public static let shared = CondaManager()

    /// Root directory for all conda data.
    public let rootPrefix: URL

    /// Path to the micromamba binary.
    public var micromambaPath: URL {
        rootPrefix.appendingPathComponent("bin/micromamba")
    }

    /// Default channels for bioconda packages.
    public let defaultChannels: [String] = ["conda-forge", "bioconda"]

    public func environmentURL(named name: String) -> URL {
        rootPrefix.appendingPathComponent("envs/\(name)", isDirectory: true)
    }

    private let bundledMicromambaProvider: BundledMicromambaProvider
    private let bundledMicromambaVersionProvider: BundledMicromambaVersionProvider

    private init() {
        // Use ~/.lungfish/conda instead of ~/Library/Application Support/Lungfish/conda
        // because many bioinformatics tools break on paths containing spaces.
        // The "Application Support" space in the standard macOS location causes
        // samtools, bcftools, and other tools that use internal shell pipes to fail.
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.rootPrefix = home.appendingPathComponent(".lungfish/conda")
        self.bundledMicromambaProvider = Self.defaultBundledMicromambaURL
        self.bundledMicromambaVersionProvider = Self.defaultBundledMicromambaVersion
    }

    init(
        rootPrefix: URL,
        bundledMicromambaProvider: @escaping BundledMicromambaProvider,
        bundledMicromambaVersionProvider: @escaping BundledMicromambaVersionProvider
    ) {
        self.rootPrefix = rootPrefix
        self.bundledMicromambaProvider = bundledMicromambaProvider
        self.bundledMicromambaVersionProvider = bundledMicromambaVersionProvider
    }

    /// Migrates ~/.lungfish/conda from a symlink to a real directory.
    ///
    /// If the conda root is a symlink (typically pointing to
    /// ~/Library/Application Support/Lungfish/conda), moves the actual
    /// directory contents to the symlink location so tools don't see
    /// spaces in their prefix paths.
    ///
    /// **Why**: conda hardcodes the prefix path into installed scripts
    /// (e.g., Nextflow's NXF_DIST). If the prefix resolves to a path
    /// with spaces, bash scripts and Java classpaths break.
    private func migrateSymlinkToRealDirectory() {
        let fm = FileManager.default
        let path = rootPrefix.path

        // Check if it's a symlink
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
            return  // Already a real directory (or doesn't exist yet)
        }

        // Resolve the symlink target
        guard let realPath = try? fm.destinationOfSymbolicLink(atPath: path) else {
            return
        }

        let realURL = URL(fileURLWithPath: realPath)
        guard fm.fileExists(atPath: realURL.path) else { return }

        logger.info("Migrating conda from symlink to real directory: \(realPath) → \(path)")

        do {
            // Remove the symlink
            try fm.removeItem(atPath: path)
            // Move the real directory to the symlink location
            try fm.moveItem(at: realURL, to: rootPrefix)
            logger.info("Successfully migrated conda to space-free path")
        } catch {
            logger.error("Failed to migrate conda symlink: \(error.localizedDescription)")
            // Try to restore the symlink if move failed
            try? fm.createSymbolicLink(atPath: path, withDestinationPath: realPath)
        }
    }

    // MARK: - Micromamba Bootstrap

    /// Ensures micromamba is available by copying the bundled binary if needed.
    ///
    /// - Parameter progress: Optional progress callback (0.0 to 1.0).
    /// - Returns: URL to the micromamba binary.
    @discardableResult
    public func ensureMicromamba(
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        // Migration: if ~/.lungfish/conda is a symlink (pointing to a path with
        // spaces like ~/Library/Application Support/...), replace it with a real
        // directory. Spaces in conda prefix paths break bioinformatics tools.
        migrateSymlinkToRealDirectory()

        guard let bundledMicromambaPath = bundledMicromambaProvider(),
              FileManager.default.fileExists(atPath: bundledMicromambaPath.path) else {
            throw CondaError.micromambaNotFound
        }

        let binDir = rootPrefix.appendingPathComponent("bin")
        let bundledVersion = try await resolveMicromambaVersion(
            at: bundledMicromambaPath,
            fallbackVersion: bundledMicromambaVersionProvider()
        )

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: micromambaPath.path) {
            do {
                let installedVersion = try await resolveMicromambaVersion(at: micromambaPath)
                if installedVersion == bundledVersion {
                    try ensureMicromambaExecutable(at: micromambaPath)
                    logger.info("Micromamba already available at \(self.micromambaPath.path, privacy: .public)")
                    return micromambaPath
                }
                logger.info("Replacing micromamba \(installedVersion, privacy: .public) with bundled \(bundledVersion, privacy: .public)")
                progress?(0.0, "Updating micromamba\u{2026}")
            } catch {
                logger.info("Replacing unreadable micromamba at \(self.micromambaPath.path, privacy: .public)")
                progress?(0.0, "Updating micromamba\u{2026}")
            }
        } else {
            logger.info("Installing bundled micromamba...")
            progress?(0.0, "Installing micromamba\u{2026}")
        }

        if FileManager.default.fileExists(atPath: micromambaPath.path) {
            try FileManager.default.removeItem(at: micromambaPath)
        }
        try FileManager.default.copyItem(at: bundledMicromambaPath, to: micromambaPath)

        try ensureMicromambaExecutable(at: micromambaPath)

        let version = try await runMicromamba(["--version"])
        logger.info("Micromamba \(version.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public) installed successfully")
        progress?(1.0, "Micromamba ready")

        return micromambaPath
    }

    private static func defaultBundledMicromambaURL() -> URL? {
        RuntimeResourceLocator.path("Tools/micromamba", in: .workflow)
    }

    private static func defaultBundledMicromambaVersion() -> String? {
        NativeToolRunner.bundledVersions["micromamba"]
    }

    private func ensureMicromambaExecutable(at path: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
    }

    private func resolveMicromambaVersion(
        at path: URL,
        fallbackVersion: String? = nil
    ) async throws -> String {
        do {
            let version = try await runMicromambaVersion(at: path)
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if let fallbackVersion, !fallbackVersion.isEmpty {
                return fallbackVersion
            }
            throw error
        }
    }

    private func runMicromambaVersion(at path: URL) async throws -> String {
        try ensureMicromambaExecutable(at: path)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = path
            process.arguments = ["--version"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { terminatedProcess in
                let stdoutData = try? stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
                let stderrData = try? stderrPipe.fileHandleForReading.readToEnd() ?? Data()
                let stdout = String(decoding: stdoutData ?? Data(), as: UTF8.self)
                let stderr = String(decoding: stderrData ?? Data(), as: UTF8.self)

                if terminatedProcess.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(
                        throwing: CondaError.executionFailed(
                            tool: "micromamba",
                            exitCode: terminatedProcess.terminationStatus,
                            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Environment Management

    /// Creates a new conda environment with the specified packages.
    ///
    /// - Parameters:
    ///   - name: Environment name (used as directory name).
    ///   - packages: Packages to install.
    ///   - channels: Channels to use (defaults to bioconda + conda-forge).
    ///   - progress: Optional progress callback.
    public func createEnvironment(
        name: String,
        packages: [String],
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try await ensureMicromamba()

        let effectiveChannels = channels ?? defaultChannels
        logger.info("Creating environment '\(name, privacy: .public)' with packages: \(packages.joined(separator: ", "), privacy: .public)")
        progress?(0.1, "Creating environment '\(name)'\u{2026}")

        var args = ["create", "-n", name, "--yes"]
        for ch in effectiveChannels {
            args += ["-c", ch]
        }
        args += packages

        let output = try await runMicromamba(args)
        logger.debug("Environment creation output: \(output, privacy: .public)")
        progress?(1.0, "Environment '\(name)' ready")
    }

    /// Removes a conda environment and all its packages.
    public func removeEnvironment(name: String) async throws {
        try await ensureMicromamba()
        logger.info("Removing environment '\(name, privacy: .public)'")

        let envPath = environmentURL(named: name)
        if FileManager.default.fileExists(atPath: envPath.path) {
            try FileManager.default.removeItem(at: envPath)
            logger.info("Environment '\(name, privacy: .public)' removed")
        } else {
            throw CondaError.environmentNotFound(name)
        }
    }

    /// Lists all conda environments.
    public func listEnvironments() async throws -> [CondaEnvironment] {
        let envsDir = rootPrefix.appendingPathComponent("envs")
        guard FileManager.default.fileExists(atPath: envsDir.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: envsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }

            // Count installed packages by checking conda-meta
            let condaMeta = url.appendingPathComponent("conda-meta")
            let pkgCount = (try? FileManager.default.contentsOfDirectory(atPath: condaMeta.path)
                .filter { $0.hasSuffix(".json") }.count) ?? 0

            return CondaEnvironment(
                name: url.lastPathComponent,
                path: url,
                packageCount: pkgCount
            )
        }
    }

    // MARK: - Package Management

    /// Installs packages into an existing environment, creating it if needed.
    public func install(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try await ensureMicromamba()

        let envPath = environmentURL(named: environment)
        let effectiveChannels = channels ?? defaultChannels

        if !FileManager.default.fileExists(atPath: envPath.path) {
            // Create new environment
            try await createEnvironment(
                name: environment,
                packages: packages,
                channels: effectiveChannels,
                progress: progress
            )
        } else {
            // Install into existing environment
            logger.info("Installing \(packages.joined(separator: ", "), privacy: .public) into '\(environment, privacy: .public)'")
            progress?(0.1, "Installing \(packages.joined(separator: ", "))\u{2026}")

            var args = ["install", "-n", environment, "--yes"]
            for ch in effectiveChannels {
                args += ["-c", ch]
            }
            args += packages

            let output = try await runMicromamba(args)
            logger.debug("Install output: \(output, privacy: .public)")
            progress?(1.0, "Installation complete")
        }
    }

    /// Reinstalls packages into an environment by removing the existing one first.
    public func reinstall(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        let envPath = environmentURL(named: environment)
        if FileManager.default.fileExists(atPath: envPath.path) {
            try FileManager.default.removeItem(at: envPath)
        }

        try await install(
            packages: packages,
            environment: environment,
            channels: channels,
            progress: progress
        )
    }

    /// Uninstalls packages from an environment.
    public func uninstall(
        packages: [String],
        from environment: String
    ) async throws {
        try await ensureMicromamba()
        logger.info("Uninstalling \(packages.joined(separator: ", "), privacy: .public) from '\(environment, privacy: .public)'")

        let args = ["remove", "-n", environment, "--yes"] + packages
        _ = try await runMicromamba(args)
    }

    /// Lists installed packages in an environment.
    public func listInstalled(in environment: String) async throws -> [CondaPackageInfo] {
        // Scan conda-meta/*.json directly instead of running `micromamba list --json`
        // which hangs on large environments (198+ packages in freyja-env).
        let condaMetaDir = environmentURL(named: environment)
            .appendingPathComponent("conda-meta", isDirectory: true)

        guard FileManager.default.fileExists(atPath: condaMetaDir.path) else {
            throw CondaError.environmentNotFound(environment)
        }

        let metaFiles = try FileManager.default.contentsOfDirectory(
            at: condaMetaDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent != "history" }

        struct CondaMetaRecord: Codable {
            let name: String?
            let version: String?
            let channel: String?
            let build: String?
            let subdir: String?
        }

        var packages: [CondaPackageInfo] = []
        packages.reserveCapacity(metaFiles.count)

        for file in metaFiles {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(CondaMetaRecord.self, from: data),
                  let name = record.name,
                  let version = record.version else { continue }

            packages.append(CondaPackageInfo(
                name: name,
                version: version,
                channel: record.channel ?? "unknown",
                buildString: record.build ?? "",
                subdir: record.subdir ?? ""
            ))
        }

        return packages
    }

    /// Searches for packages across channels.
    public func search(
        query: String,
        channels: [String]? = nil
    ) async throws -> [CondaPackageInfo] {
        try await ensureMicromamba()

        let effectiveChannels = channels ?? defaultChannels
        var args = ["search", query, "--json"]
        for ch in effectiveChannels {
            args += ["-c", ch]
        }

        let output = try await runMicromamba(args)
        guard let data = output.data(using: .utf8) else { return [] }

        // Parse search results
        struct SearchResult: Codable {
            let result: SearchResultInner?
        }
        struct SearchResultInner: Codable {
            let pkgs: [SearchPkg]?
        }
        struct SearchPkg: Codable {
            let name: String?
            let version: String?
            let channel: String?
            let build: String?
            let subdir: String?
            let license: String?
            let size: Int64?
        }

        // Try to parse as search output
        if let result = try? JSONDecoder().decode(SearchResult.self, from: data),
           let pkgs = result.result?.pkgs {
            return pkgs.compactMap { pkg in
                guard let name = pkg.name, let version = pkg.version else { return nil }
                return CondaPackageInfo(
                    name: name,
                    version: version,
                    channel: pkg.channel ?? "bioconda",
                    buildString: pkg.build ?? "",
                    subdir: pkg.subdir ?? "",
                    license: pkg.license,
                    sizeBytes: pkg.size
                )
            }
        }

        return []
    }

    // MARK: - Tool Discovery

    /// Returns the path to a tool executable in a conda environment.
    public func toolPath(
        name: String,
        environment: String
    ) async throws -> URL {
        let binPath = environmentURL(named: environment)
            .appendingPathComponent("bin/\(name)")

        guard FileManager.default.isExecutableFile(atPath: binPath.path) else {
            throw CondaError.toolNotFound(tool: name, environment: environment)
        }

        return binPath
    }

    /// Checks whether a tool is installed in any conda environment.
    ///
    /// Searches all environments under the conda root prefix for an executable
    /// matching the given tool name. This is a lightweight filesystem check —
    /// no subprocess is spawned.
    ///
    /// - Parameter name: The tool executable name (e.g., "kraken2", "EsViritu").
    /// - Returns: `true` if the tool is found in any environment's `bin/` directory.
    public func isToolInstalled(_ name: String) async -> Bool {
        let envsDir = rootPrefix.appendingPathComponent("envs")
        guard let envDirs = try? FileManager.default.contentsOfDirectory(
            at: envsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for envDir in envDirs {
            let binPath = envDir.appendingPathComponent("bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: binPath.path) {
                return true
            }
        }
        return false
    }

    /// Returns the name of the conda environment containing a specific tool.
    ///
    /// Searches all environments under the conda root prefix for an executable
    /// matching the given tool name. Returns the environment name (directory name).
    ///
    /// - Parameter tool: The tool executable name (e.g., "nextflow").
    /// - Returns: The environment name, or `nil` if not found.
    public func environmentContaining(tool name: String) async -> String? {
        let envsDir = rootPrefix.appendingPathComponent("envs")
        guard let envDirs = try? FileManager.default.contentsOfDirectory(
            at: envsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for envDir in envDirs {
            let binPath = envDir.appendingPathComponent("bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: binPath.path) {
                return envDir.lastPathComponent
            }
        }
        return nil
    }

    /// Runs a tool from a conda environment.
    ///
    /// Uses `micromamba run -n <env> <tool> [args...]` to ensure the correct
    /// environment is activated, including library paths and Python venvs.
    ///
    /// Pipe reading is performed concurrently with the subprocess using
    /// `readabilityHandler` to avoid deadlocks when the process produces
    /// more than 64 KB of output. The actor thread is never blocked --
    /// the method suspends via `CheckedContinuation` until the process
    /// terminates or the timeout expires.
    ///
    /// - Parameters:
    ///   - name: The tool executable name (e.g., "kraken2").
    ///   - arguments: Command-line arguments to pass to the tool.
    ///   - environment: The conda environment name containing the tool.
    ///   - workingDirectory: Optional working directory for the process.
    ///   - timeout: Maximum execution time in seconds (default: 3600).
    ///   - stderrHandler: Optional callback that receives stderr lines in
    ///     real-time as they are written by the subprocess. Useful for parsing
    ///     progress output from tools like kraken2 that report progress to
    ///     stderr. The full stderr is still accumulated and returned in the
    ///     result tuple regardless of whether this handler is set.
    /// - Returns: A tuple of (stdout, stderr, exitCode).
    /// - Throws: ``CondaError`` on tool-not-found, timeout, or launch failure.
    public func runTool(
        name: String,
        arguments: [String] = [],
        environment: String,
        workingDirectory: URL? = nil,
        environmentVariables: [String: String]? = nil,
        timeout: TimeInterval = 3600,
        stderrHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        repairManagedLaunchers(environment: environment)
        try await ensureMicromamba()

        let args = ["run", "-n", environment, name] + arguments
        logger.info("Running conda tool: micromamba \(args.joined(separator: " "), privacy: .public)")

        let executablePath = micromambaPath
        let rootPath = rootPrefix.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tempDirectory = ProcessInfo.processInfo.environment["TMPDIR"]

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executablePath
            process.arguments = args
            var env: [String: String] = [
                "MAMBA_ROOT_PREFIX": rootPath,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": homePath,
            ]
            if let tempDirectory {
                env["TMPDIR"] = tempDirectory
            }
            if let extraVars = environmentVariables {
                env.merge(extraVars) { _, new in new }
            }
            process.environment = env
            if let wd = workingDirectory {
                process.currentDirectoryURL = wd
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Use nonisolated(unsafe) for mutable buffers accessed from
            // readabilityHandler callbacks and the termination handler.
            // These closures are serialized by Process: readabilityHandler
            // fires on the pipe's dispatch source queue, and the termination
            // handler fires after the process exits (after all pipe data has
            // been written). The asyncAfter delay ensures all pending
            // readabilityHandler calls have drained before we read the buffers.
            nonisolated(unsafe) let stdoutBuffer = NSMutableData()
            nonisolated(unsafe) let stderrBuffer = NSMutableData()
            nonisolated(unsafe) var continuationResumed = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                    // Forward lines to the stderrHandler if provided.
                    if let handler = stderrHandler,
                       let text = String(data: data, encoding: .utf8) {
                        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                            handler(String(line))
                        }
                    }
                }
            }

            // Timeout timer: terminates the process if it runs too long.
            // nonisolated(unsafe) because DispatchWorkItem is not Sendable,
            // but we only cancel it from the terminationHandler or catch
            // block, never concurrently with its execution.
            nonisolated(unsafe) let timeoutItem = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                logger.warning("Tool '\(name, privacy: .public)' timed out after \(Int(timeout))s, terminating")
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )

            process.terminationHandler = { terminatedProcess in
                // Cancel the timeout timer since the process finished.
                timeoutItem.cancel()

                // Small delay to let any remaining readabilityHandler
                // callbacks drain before we read the final buffer contents.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    // Nil out handlers to break retain cycles.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard !continuationResumed else { return }
                    continuationResumed = true

                    let stdout = String(data: stdoutBuffer as Data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer as Data, encoding: .utf8) ?? ""

                    // Check if this was a timeout (SIGTERM = exit 15 or 143).
                    if terminatedProcess.terminationReason == .uncaughtSignal
                        && (terminatedProcess.terminationStatus == 15
                            || terminatedProcess.terminationStatus == 143) {
                        continuation.resume(
                            throwing: CondaError.timeout(tool: name, seconds: timeout)
                        )
                    } else {
                        continuation.resume(
                            returning: (stdout, stderr, terminatedProcess.terminationStatus)
                        )
                    }
                }
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !continuationResumed else { return }
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Nextflow Integration

    /// Returns environment variables for Nextflow conda integration.
    public func nextflowCondaConfig() -> [String: String] {
        [
            "NXF_CONDA_CACHEDIR": rootPrefix.appendingPathComponent("envs").path,
            "NXF_CONDA_ENABLED": "true",
            "MAMBA_ROOT_PREFIX": rootPrefix.path,
        ]
    }

    /// Generates a Nextflow config snippet for conda profile.
    public func nextflowCondaConfigString() -> String {
        """
        conda {
            enabled = true
            useMicromamba = true
            cacheDir = '\(rootPrefix.appendingPathComponent("envs").path)'
            channels = ['conda-forge', 'bioconda']
            createOptions = '--override-channels'
        }

        env {
            MAMBA_ROOT_PREFIX = '\(rootPrefix.path)'
            PATH = '\(rootPrefix.appendingPathComponent("bin").path):$PATH'
        }
        """
    }

    // MARK: - Managed Launcher Repairs

    public func repairManagedLaunchers(environment: String) {
        let envURL = environmentURL(named: environment)
        guard FileManager.default.fileExists(atPath: envURL.path) else { return }

        switch environment {
        case "bracken":
            ensureBrackenLauncher(in: envURL)
        case "metaphlan":
            ensureMetaPhlAnLauncher(in: envURL)
        case "nextflow":
            patchNextflowLauncher(in: envURL)
        default:
            break
        }
    }

    // MARK: - Private Helpers

    private func ensureBrackenLauncher(in envURL: URL) {
        let binURL = envURL.appendingPathComponent("bin", isDirectory: true)
        let launcherURL = binURL.appendingPathComponent("bracken")
        let scriptURL = binURL.appendingPathComponent("est_abundance.py")

        guard !FileManager.default.isExecutableFile(atPath: launcherURL.path) else { return }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        guard let pythonExecutable = preferredPythonExecutable(in: binURL) else { return }

        let wrapper = launcherScript(
            command: "\"$TOOL_BIN/\(pythonExecutable)\" \"$TOOL_BIN/est_abundance.py\" \"$@\""
        )
        writeManagedLauncher(
            wrapper,
            to: launcherURL,
            description: "Created Bracken compatibility launcher"
        )
    }

    private func ensureMetaPhlAnLauncher(in envURL: URL) {
        let binURL = envURL.appendingPathComponent("bin", isDirectory: true)
        let launcherURL = binURL.appendingPathComponent("metaphlan")

        guard let pythonExecutable = preferredPythonExecutable(in: binURL) else { return }

        let currentScript = try? String(contentsOf: launcherURL, encoding: .utf8)
        let needsRepair = !FileManager.default.isExecutableFile(atPath: launcherURL.path)
            || currentScript?.contains("Application Support/Lungfish") == true

        guard needsRepair else { return }

        let wrapper = launcherScript(
            command: "\"$TOOL_BIN/\(pythonExecutable)\" -m metaphlan.metaphlan \"$@\""
        )
        writeManagedLauncher(
            wrapper,
            to: launcherURL,
            description: "Repaired MetaPhlAn launcher"
        )
    }

    private func patchNextflowLauncher(in envURL: URL) {
        let launcherURL = envURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("nextflow")

        guard FileManager.default.isExecutableFile(atPath: launcherURL.path),
              let content = try? String(contentsOf: launcherURL, encoding: .utf8),
              content.contains("NXF_DIST=/")
        else {
            return
        }

        let lines = content.components(separatedBy: "\n")
        var newLines: [String] = []
        var patched = false

        for line in lines {
            if line.hasPrefix("NXF_DIST=/") && !line.hasPrefix("NXF_DIST=\"") {
                let value = String(line.dropFirst("NXF_DIST=".count))
                if value.contains(" ") {
                    newLines.append("NXF_DIST=\"\(value)\"")
                    patched = true
                    continue
                }
            }

            if line == "NXF_BIN=${NXF_BIN:-$NXF_DIST/$NXF_VER/$NXF_JAR}" {
                newLines.append("NXF_BIN=${NXF_BIN:-\"$NXF_DIST/$NXF_VER/$NXF_JAR\"}")
                patched = true
                continue
            }

            newLines.append(line)
        }

        guard patched else { return }

        do {
            try newLines.joined(separator: "\n").write(
                to: launcherURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: launcherURL.path
            )
            logger.info("Patched Nextflow launcher for space-safe NXF_DIST handling")
        } catch {
            logger.warning(
                "Failed to patch Nextflow launcher at \(launcherURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func preferredPythonExecutable(in binURL: URL) -> String? {
        let preferred = ["python", "python3"]
        for candidate in preferred {
            let path = binURL.appendingPathComponent(candidate).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return candidate
            }
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: binURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("python") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })?
            .lastPathComponent
    }

    private func launcherScript(command: String) -> String {
        """
        #!/bin/sh
        set -e
        TOOL_BIN="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
        exec \(command)
        """
    }

    private func writeManagedLauncher(
        _ script: String,
        to url: URL,
        description: String
    ) {
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
            logger.info("\(description, privacy: .public): \(url.path, privacy: .public)")
        } catch {
            logger.warning(
                "Failed to write managed launcher '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Runs micromamba with the given arguments and returns stdout.
    ///
    /// Pipe reading is performed concurrently with the subprocess using
    /// `readabilityHandler` to avoid deadlocks when micromamba produces
    /// more than 64 KB of output (e.g. environment creation with many
    /// packages). The actor thread is never blocked.
    private func runMicromamba(_ arguments: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: micromambaPath.path) else {
            throw CondaError.micromambaNotFound
        }

        let executablePath = micromambaPath
        let rootPath = rootPrefix.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tempDirectory = ProcessInfo.processInfo.environment["TMPDIR"]

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executablePath
            process.arguments = arguments
            process.environment = [
                "MAMBA_ROOT_PREFIX": rootPath,
                "MAMBA_NO_BANNER": "1",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": homePath,
                "TMPDIR": tempDirectory ?? "/tmp",
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            nonisolated(unsafe) let stdoutBuffer = NSMutableData()
            nonisolated(unsafe) let stderrBuffer = NSMutableData()
            nonisolated(unsafe) var continuationResumed = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { terminatedProcess in
                // Small delay to let any remaining readabilityHandler
                // callbacks drain before we read the final buffer contents.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard !continuationResumed else { return }
                    continuationResumed = true

                    let stdout = String(data: stdoutBuffer as Data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer as Data, encoding: .utf8) ?? ""

                    if terminatedProcess.terminationStatus != 0 {
                        logger.error("micromamba failed (exit \(terminatedProcess.terminationStatus)): \(stderr, privacy: .public)")
                        continuation.resume(
                            throwing: CondaError.packageInstallFailed(stderr.isEmpty ? stdout : stderr)
                        )
                    } else {
                        continuation.resume(returning: stdout)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !continuationResumed else { return }
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}
