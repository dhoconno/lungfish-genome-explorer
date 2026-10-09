// CondaManager.swift - Micromamba-based package management for bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "CondaManager")

// MARK: - ToolProcess adapter shared by the conda family

/// What the conda family of runners shares when it runs a process through
/// ``ToolProcess``. `CondaManager`, the streaming micromamba run in
/// `ManagedMappingPipeline`, `ManagedToolSourceInstaller.run` and
/// `ProcessGATKCommandRunner` use it.
enum CondaFamilyProcess {
    /// How long a micromamba run's captured streams, and the process group of
    /// a run that writes stdout to a file, get to settle after micromamba exits.
    ///
    /// `micromamba run` starts the tool as its child and exits once that child
    /// exits, so in a normal run end of file arrives with the exit and this
    /// time is never spent. It matters only when something the tool started
    /// outlives it, such as a helper that a launcher script forked and that is
    /// still flushing its last lines on a loaded Mac. Five seconds gives such
    /// a late flush room that the 2 second ToolProcess default may not, and
    /// still bounds a daemonized grandchild that never closes the pipe, which
    /// used to hang the run forever.
    static let micromambaDrainGracePeriod: Duration = .seconds(5)

    /// The ToolProcess limit for a timeout in seconds. A value that is not
    /// finite, or too large to count in nanoseconds, means no limit. A value at
    /// or below zero becomes the smallest limit, so the run stops at once, as
    /// the timer it replaces did.
    static func limit(seconds: TimeInterval) -> Duration? {
        guard seconds.isFinite, seconds < 9e9 else { return nil }
        return .nanoseconds(max(Int64((seconds * 1e9).rounded()), 1))
    }

    /// Captured bytes as UTF-8 text, or the empty string when they are not
    /// valid UTF-8, which is what `String(data:encoding:)` gave these runners.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    /// An event observer that hands each captured line to the handler for its
    /// stream, or nil when there is no handler, so output is not framed at all.
    static func lineForwarder(
        stdout stdoutHandler: (@Sendable (String) -> Void)?,
        stderr stderrHandler: (@Sendable (String) -> Void)?
    ) -> (@Sendable (ToolProcessEvent) -> Void)? {
        guard stdoutHandler != nil || stderrHandler != nil else { return nil }
        return { event in
            guard case .output(let stream, let line) = event else { return }
            switch stream {
            case .stdout: stdoutHandler?(line)
            case .stderr: stderrHandler?(line)
            }
        }
    }

    /// Why a run's output is incomplete, for an error message, or nil when it
    /// is complete.
    static func incompleteOutputReason(_ result: ToolProcessResult, drainGrace: Duration) -> String? {
        if result.outputDrainTimedOut {
            let waited = drainGrace.components.seconds
            return "The output of \(result.label) is incomplete because a child process kept it open after \(result.label) exited. LGE waited \(waited) seconds for it, then stopped it."
        }
        if result.outputReadFailed {
            return "The output of \(result.label) is incomplete because reading it failed."
        }
        return nil
    }

    /// The `Process` termination reason that matches a ToolProcess termination.
    static func terminationReason(_ termination: ToolProcessTermination) -> Process.TerminationReason {
        switch termination {
        case .exited: return .exit
        case .signaled: return .uncaughtSignal
        }
    }
}

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
    case micromambaUnusable(path: String, reason: String)

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
        case .micromambaUnusable(let path, let reason):
            return "Micromamba at \(path) is unusable: \(reason)"
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
    private struct EnvironmentMutationLease {
        let transaction: CondaEnvironmentMutationTransaction
        let ownsTransaction: Bool
    }


    typealias BundledMicromambaProvider = @Sendable () -> URL?
    typealias BundledMicromambaVersionProvider = @Sendable () -> String?
    typealias RootPrefixProvider = @Sendable () -> URL

    /// Shared singleton instance.
    public static let shared = CondaManager()

    /// Root directory for all conda data.
    public nonisolated var rootPrefix: URL {
        rootPrefixProvider()
    }

    /// Path to the micromamba binary.
    public var micromambaPath: URL {
        rootPrefix.appendingPathComponent("bin/micromamba")
    }

    /// Default channels for bioconda packages.
    public let defaultChannels: [String] = ["conda-forge", "bioconda"]

    public func environmentURL(named name: String) -> URL {
        rootPrefix.appendingPathComponent("envs/\(name)", isDirectory: true)
    }

    /// Returns the version from a durable, integrity-checked managed source
    /// overlay. Consumers use this before conda metadata so an obsolete package
    /// record cannot become scientific provenance for a source-installed tool.
    public func validatedSourceOverlayVersion(
        kind: PackToolSourceOverlay.Kind,
        environment: String
    ) -> String? {
        let environmentURL = environmentURL(named: environment)
        let recordURL = environmentURL
            .appendingPathComponent("share/lungfish/managed-tools/\(kind.rawValue).json")
        guard let record = try? ManagedToolSourceInstallationRecord.load(from: recordURL),
              record.source.kind == kind,
              record.validatesIntegrity(environmentURL: environmentURL) else {
            return nil
        }
        return record.source.version
    }

    private let rootPrefixProvider: RootPrefixProvider
    private let bundledMicromambaProvider: BundledMicromambaProvider
    private let bundledMicromambaVersionProvider: BundledMicromambaVersionProvider
    /// Points this root's micromamba at the cross-channel package cache. Test
    /// and CLI-override instances leave it unset so a temporary root never
    /// writes outside itself.
    private let sharedPackageCache: CondaSharedPackageCache?

    private init() {
        let storageConfigStore = ManagedStorageConfigStore()
        self.rootPrefixProvider = {
            storageConfigStore.currentCondaRootURL()
        }
        self.bundledMicromambaProvider = Self.defaultBundledMicromambaURL
        self.bundledMicromambaVersionProvider = Self.defaultBundledMicromambaVersion
        self.sharedPackageCache = CondaSharedPackageCache()
    }

    init(
        rootPrefix: URL,
        bundledMicromambaProvider: @escaping BundledMicromambaProvider,
        bundledMicromambaVersionProvider: @escaping BundledMicromambaVersionProvider,
        sharedPackageCache: CondaSharedPackageCache? = nil
    ) {
        let resolvedRootPrefix = rootPrefix.standardizedFileURL
        self.rootPrefixProvider = { resolvedRootPrefix }
        self.bundledMicromambaProvider = bundledMicromambaProvider
        self.bundledMicromambaVersionProvider = bundledMicromambaVersionProvider
        self.sharedPackageCache = sharedPackageCache
    }

    init(rootPrefix: URL) {
        self.init(
            rootPrefix: rootPrefix,
            bundledMicromambaProvider: Self.defaultBundledMicromambaURL,
            bundledMicromambaVersionProvider: Self.defaultBundledMicromambaVersion
        )
    }

    init(
        storageConfigStore: ManagedStorageConfigStore,
        bundledMicromambaProvider: @escaping BundledMicromambaProvider,
        bundledMicromambaVersionProvider: @escaping BundledMicromambaVersionProvider
    ) {
        self.rootPrefixProvider = {
            storageConfigStore.currentCondaRootURL()
        }
        self.bundledMicromambaProvider = bundledMicromambaProvider
        self.bundledMicromambaVersionProvider = bundledMicromambaVersionProvider
        self.sharedPackageCache = nil
    }

    static func defaultRootPrefix(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ManagedStorageConfigStore(homeDirectory: homeDirectory)
            .currentCondaRootURL(environment: environment)
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
        configureSharedPackageCache()

        guard let bundledMicromambaPath = bundledMicromambaProvider(),
              FileManager.default.fileExists(atPath: bundledMicromambaPath.path) else {
            // The bundled binary lives inside the app bundle, so it is absent
            // in every context that is not a running app: `swift test`, the
            // CLI, and the toolset-conformance CI job. An already-installed
            // micromamba under the conda root is a perfectly good substitute
            // there, and throwing instead made tool-backed suites fail on
            // machines that were in fact fully provisioned. There is nothing
            // to compare versions against in this path, so the installed copy
            // is used as-is.
            return try await useInstalledMicromamba()
        }

        let binDir = rootPrefix.appendingPathComponent("bin")
        // Probe the bundled binary itself. When it cannot run (for example a
        // build left it with an invalid code signature and macOS kills it on
        // launch) the lock's version string must NOT be used to justify
        // replacing a working installed copy with a dead one.
        let bundledProbe: String?
        do {
            bundledProbe = try await runMicromambaVersion(at: bundledMicromambaPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error(
                "Bundled micromamba at \(bundledMicromambaPath.path, privacy: .public) does not run: \(String(describing: error), privacy: .public)"
            )
            bundledProbe = nil
        }
        let bundledVersion = bundledProbe
            ?? bundledMicromambaVersionProvider()
            ?? ""

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        var previousInstall: URL?
        if FileManager.default.fileExists(atPath: micromambaPath.path) {
            do {
                let installedVersion = try await resolveMicromambaVersion(at: micromambaPath)
                if Self.micromambaVersionsMatch(installedVersion, bundledVersion) {
                    try ensureMicromambaExecutable(at: micromambaPath)
                    logger.info("Micromamba already available at \(self.micromambaPath.path, privacy: .public)")
                    return micromambaPath
                }
                if bundledProbe == nil {
                    // The installed copy works and the bundled one does not:
                    // keep the machine in its working state.
                    logger.error(
                        "Keeping installed micromamba \(installedVersion, privacy: .public); bundled binary is unusable so it will not replace a working install"
                    )
                    try ensureMicromambaExecutable(at: micromambaPath)
                    return micromambaPath
                }
                logger.info("Replacing micromamba \(installedVersion, privacy: .public) with bundled \(bundledVersion, privacy: .public)")
                progress?(0.0, "Updating micromamba\u{2026}")
                previousInstall = micromambaPath
            } catch {
                if bundledProbe == nil {
                    throw CondaError.micromambaUnusable(
                        path: micromambaPath.path,
                        reason: "neither the installed nor the bundled micromamba can run: \(error.localizedDescription)"
                    )
                }
                logger.info("Replacing unreadable micromamba at \(self.micromambaPath.path, privacy: .public)")
                progress?(0.0, "Updating micromamba\u{2026}")
            }
        } else {
            guard bundledProbe != nil else {
                throw CondaError.micromambaUnusable(
                    path: bundledMicromambaPath.path,
                    reason: "the bundled micromamba does not run and no installed copy exists"
                )
            }
            logger.info("Installing bundled micromamba...")
            progress?(0.0, "Installing micromamba\u{2026}")
        }

        // Keep the previous working binary until the new copy has proven it runs.
        let backupURL = micromambaPath.appendingPathExtension("previous")
        try? FileManager.default.removeItem(at: backupURL)
        if let previousInstall {
            try FileManager.default.moveItem(at: previousInstall, to: backupURL)
        } else if FileManager.default.fileExists(atPath: micromambaPath.path) {
            try FileManager.default.removeItem(at: micromambaPath)
        }
        try FileManager.default.copyItem(at: bundledMicromambaPath, to: micromambaPath)

        try ensureMicromambaExecutable(at: micromambaPath)

        let version: String
        do {
            version = try await runMicromamba(["--version"])
        } catch {
            try? FileManager.default.removeItem(at: micromambaPath)
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: micromambaPath)
                logger.error("Freshly installed micromamba failed to run; restored the previous binary")
            }
            throw CondaError.micromambaUnusable(
                path: micromambaPath.path,
                reason: "the freshly installed micromamba failed to run: \(error.localizedDescription)"
            )
        }
        try? FileManager.default.removeItem(at: backupURL)
        logger.info("Micromamba \(version.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public) installed successfully")
        progress?(1.0, "Micromamba ready")

        return micromambaPath
    }

    /// Whether two micromamba version strings denote the same release.
    ///
    /// The lock records the conda build string (`2.9.0-0`) while the binary
    /// reports only the release (`2.9.0`); a build suffix alone is not a reason
    /// to replace an installed binary.
    static func micromambaVersionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dash = trimmed.firstIndex(of: "-") {
                return String(trimmed[..<dash])
            }
            return trimmed
        }
        let left = normalized(lhs)
        let right = normalized(rhs)
        return !left.isEmpty && left == right
    }

    /// Resolves an already-installed micromamba under the conda root, for use
    /// when no bundled binary is available to install or compare against.
    ///
    /// The binary must actually report a version: a leftover, truncated, or
    /// non-executable file at that path is not a usable fallback and is
    /// reported as ``CondaError/micromambaNotFound`` rather than accepted.
    ///
    /// - Returns: URL of the installed micromamba binary.
    /// - Throws: ``CondaError/micromambaNotFound`` when no usable binary exists.
    private func useInstalledMicromamba() async throws -> URL {
        guard FileManager.default.fileExists(atPath: micromambaPath.path) else {
            throw CondaError.micromambaNotFound
        }

        let installedVersion: String
        do {
            installedVersion = try await resolveMicromambaVersion(at: micromambaPath)
        } catch {
            logger.error(
                "Installed micromamba at \(self.micromambaPath.path, privacy: .public) is unusable: \(String(describing: error), privacy: .public)"
            )
            throw CondaError.micromambaNotFound
        }

        try ensureMicromambaExecutable(at: micromambaPath)
        logger.info(
            "Using installed micromamba \(installedVersion, privacy: .public); bundled binary unavailable"
        )
        return micromambaPath
    }

    private static func defaultBundledMicromambaURL() -> URL? {
        RuntimeResourceLocator.path("Tools/micromamba", in: .workflow)
    }

    private static func defaultBundledMicromambaVersion() -> String? {
        ManagedToolLock.bundled.bootstrap?.micromamba.version ?? NativeToolRunner.bundledVersions["micromamba"]
    }

    /// Writes `<root>/.mambarc` so micromamba caches packages once for every
    /// channel. Failure is logged, never fatal: the root's own cache still works.
    private func configureSharedPackageCache() {
        guard let sharedPackageCache else { return }
        do {
            if let shared = try sharedPackageCache.configure(rootPrefix: rootPrefix) {
                logger.info("micromamba package cache shared at \(shared.path, privacy: .public)")
            }
        } catch {
            logger.error("Could not configure the shared package cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureMicromambaExecutable(at path: URL) throws {
        try Self.makeExecutableIfNeeded(at: path)
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

        let spec = ToolProcessSpec(
            executableURL: path,
            arguments: ["--version"],
            environment: ToolProcessSpec.inheritedEnvironment(),
            drainGracePeriod: CondaFamilyProcess.micromambaDrainGracePeriod,
            label: "micromamba"
        )
        // An unstructured task does not inherit cancellation, so the probe
        // runs to its end even when the caller is cancelled, as it always has.
        let result = try await Task { try await ToolProcess.run(spec) }.value
        guard result.termination == .exited(code: 0) else {
            throw CondaError.executionFailed(
                tool: "micromamba",
                exitCode: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if let reason = CondaFamilyProcess.incompleteOutputReason(
            result, drainGrace: CondaFamilyProcess.micromambaDrainGracePeriod
        ) {
            throw CondaError.executionFailed(tool: "micromamba", exitCode: result.status, stderr: reason)
        }
        return String(decoding: result.stdout, as: UTF8.self)
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
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        let lease = try await acquireEnvironmentMutationLease(
            environment: name,
            reusing: mutationTransaction
        )
        defer {
            if lease.ownsTransaction {
                lease.transaction.release()
            }
        }
        try await createEnvironmentUnlocked(
            name: name,
            packages: packages,
            channels: channels,
            progress: progress
        )
    }

    private func createEnvironmentUnlocked(
        name: String,
        packages: [String],
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try await ensureMicromamba()

        let effectiveChannels = channels ?? defaultChannels
        logger.info("Creating environment '\(name, privacy: .public)' with packages: \(packages.joined(separator: ", "), privacy: .public)")
        progress?(0.1, "Creating environment '\(name)'\u{2026}")

        var args = ["create", "-n", name, "--yes", "--override-channels"]
        for ch in effectiveChannels {
            args += ["-c", ch]
        }
        args += packages

        let output = try await runMicromamba(args)
        logger.debug("Environment creation output: \(output, privacy: .public)")
        progress?(1.0, "Environment '\(name)' ready")
    }

    /// Removes a conda environment and all its packages.
    public func removeEnvironment(
        name: String,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        let lease = try await acquireEnvironmentMutationLease(
            environment: name,
            reusing: mutationTransaction
        )
        defer {
            if lease.ownsTransaction {
                lease.transaction.release()
            }
        }
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
        packageSpec: String,
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        try await installPackageSpecs(
            packages: [packageSpec],
            environment: environment,
            channels: channels,
            progress: progress,
            mutationTransaction: mutationTransaction
        )
    }

    public func install(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        try await installPackageSpecs(
            packages: packages,
            environment: environment,
            channels: channels,
            progress: progress,
            mutationTransaction: mutationTransaction
        )
    }

    private func installPackageSpecs(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        let lease = try await acquireEnvironmentMutationLease(
            environment: environment,
            reusing: mutationTransaction
        )
        defer {
            if lease.ownsTransaction {
                lease.transaction.release()
            }
        }
        try await installPackageSpecsUnlocked(
            packages: packages,
            environment: environment,
            channels: channels,
            progress: progress
        )
    }

    private func installPackageSpecsUnlocked(
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
            try await createEnvironmentUnlocked(
                name: environment,
                packages: packages,
                channels: effectiveChannels,
                progress: progress
            )
        } else {
            // Install into existing environment
            logger.info("Installing \(packages.joined(separator: ", "), privacy: .public) into '\(environment, privacy: .public)'")
            progress?(0.1, "Installing \(packages.joined(separator: ", "))\u{2026}")

            var args = ["install", "-n", environment, "--yes", "--override-channels"]
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
        packageSpec: String,
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        try await reinstallPackageSpecs(
            packages: [packageSpec],
            environment: environment,
            channels: channels,
            progress: progress,
            mutationTransaction: mutationTransaction
        )
    }

    public func reinstall(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        try await reinstallPackageSpecs(
            packages: packages,
            environment: environment,
            channels: channels,
            progress: progress,
            mutationTransaction: mutationTransaction
        )
    }

    private func reinstallPackageSpecs(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        let lease = try await acquireEnvironmentMutationLease(
            environment: environment,
            reusing: mutationTransaction
        )
        defer {
            if lease.ownsTransaction {
                lease.transaction.release()
            }
        }
        let envPath = environmentURL(named: environment)
        if FileManager.default.fileExists(atPath: envPath.path) {
            try FileManager.default.removeItem(at: envPath)
        }

        try await installPackageSpecsUnlocked(
            packages: packages,
            environment: environment,
            channels: channels,
            progress: progress
        )
    }

    /// Uninstalls packages from an environment.
    public func uninstall(
        packages: [String],
        from environment: String,
        mutationTransaction: CondaEnvironmentMutationTransaction? = nil
    ) async throws {
        let lease = try await acquireEnvironmentMutationLease(
            environment: environment,
            reusing: mutationTransaction
        )
        defer {
            if lease.ownsTransaction {
                lease.transaction.release()
            }
        }
        try await ensureMicromamba()
        logger.info("Uninstalling \(packages.joined(separator: ", "), privacy: .public) from '\(environment, privacy: .public)'")

        let args = ["remove", "-n", environment, "--yes"] + packages
        _ = try await runMicromamba(args)
    }

    /// Reuses a caller-owned pack/offline transaction when it covers the
    /// requested environment. Direct public calls create the same shared
    /// environment-then-root transaction, so they cannot enter a pack's
    /// overlay/final-readiness critical section mid-mutation.
    private func acquireEnvironmentMutationLease(
        environment: String,
        reusing transaction: CondaEnvironmentMutationTransaction?
    ) async throws -> EnvironmentMutationLease {
        if let transaction {
            guard transaction.covers(root: rootPrefix, environment: environment) else {
                throw CondaError.environmentCreationFailed(
                    "Mutation transaction does not cover environment '\(environment)'."
                )
            }
            return EnvironmentMutationLease(transaction: transaction, ownsTransaction: false)
        }
        return EnvironmentMutationLease(
            transaction: try await CondaEnvironmentMutationTransaction.acquire(
                root: rootPrefix,
                environments: [environment]
            ),
            ownsTransaction: true
        )
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
    /// The run goes through ``ToolProcess``, which reads both streams while
    /// the process runs, so more than 64 KB of output never blocks it, and
    /// which stops the whole micromamba process tree on cancellation or
    /// timeout. Output that a child process still holds open
    /// ``CondaFamilyProcess/micromambaDrainGracePeriod`` after micromamba
    /// exits is incomplete, and the run throws ``CondaError/executionFailed(tool:exitCode:stderr:)``
    /// saying so.
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
    ///   - stdoutHandler: Optional live stdout line callback. Each pipe frames UTF-8,
    ///     LF, CRLF, CR updates and its final unterminated line independently.
    ///     Both callbacks finish before this method returns or throws after launch.
    ///     Callbacks run one at a time on the run's event queue, and output is
    ///     not read while one runs, so they should enqueue expensive work.
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
        try await runTool(name: name, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, environmentVariables: environmentVariables,
            timeout: timeout, stdoutHandler: nil, stderrHandler: stderrHandler)
    }

    /// Streams stdout in addition to stderr. The explicit stdout argument preserves
    /// the original overload's unlabeled trailing-closure binding to stderr.
    public func runTool(
        name: String,
        arguments: [String] = [],
        environment: String,
        workingDirectory: URL? = nil,
        environmentVariables: [String: String]? = nil,
        timeout: TimeInterval = 3600,
        stdoutHandler: (@Sendable (String) -> Void)?,
        stderrHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        repairManagedLaunchers(environment: environment)
        try await ensureMicromamba()

        let args = ["run", "-n", environment, name] + arguments
        logger.info("Running conda tool: micromamba \(args.joined(separator: " "), privacy: .public)")

        // Hermetic: nothing from the caller's shell beyond TMPDIR.
        var processEnvironment: [String: String] = [
            "MAMBA_ROOT_PREFIX": rootPrefix.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        if let tempDirectory = ProcessInfo.processInfo.environment["TMPDIR"] {
            processEnvironment["TMPDIR"] = tempDirectory
        }
        if let environmentVariables {
            processEnvironment.merge(environmentVariables) { _, new in new }
        }
        // ToolProcess has one grace period for a cancellation and a timeout.
        // A cancellation keeps the immediate kill it has always had, so a
        // timeout now gets no grace either, where it had 0.5 seconds.
        let spec = ToolProcessSpec(
            executableURL: micromambaPath,
            arguments: args,
            environment: processEnvironment,
            workingDirectory: workingDirectory,
            timeout: CondaFamilyProcess.limit(seconds: timeout),
            terminationGracePeriod: .zero,
            drainGracePeriod: CondaFamilyProcess.micromambaDrainGracePeriod,
            label: name
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(
                spec,
                onEvent: CondaFamilyProcess.lineForwarder(stdout: stdoutHandler, stderr: stderrHandler)
            )
        } catch ToolProcessError.timedOut {
            logger.warning("Tool '\(name, privacy: .public)' timed out after \(Int(timeout))s and was terminated")
            throw CondaError.timeout(tool: name, seconds: timeout)
        } catch ToolProcessError.cancelled {
            throw CancellationError()
        }
        // A SIGTERM from outside LGE reads as a timeout, as it always has.
        if result.termination == .signaled(signal: SIGTERM) {
            throw CondaError.timeout(tool: name, seconds: timeout)
        }
        let stderr = CondaFamilyProcess.text(result.stderr)
        if let reason = CondaFamilyProcess.incompleteOutputReason(
            result, drainGrace: CondaFamilyProcess.micromambaDrainGracePeriod
        ) {
            logger.error("\(reason, privacy: .public)")
            throw CondaError.executionFailed(
                tool: name,
                exitCode: result.status,
                stderr: stderr.isEmpty ? reason : "\(reason)\n\(stderr)"
            )
        }
        return (CondaFamilyProcess.text(result.stdout), stderr, result.status)
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

    /// Builds a failure message that always says what ran and how it died,
    /// even when micromamba produced no output at all (a SIGKILLed binary with
    /// an invalid code signature prints nothing, which used to surface as the
    /// bare "Failed to install package: ").
    static func micromambaFailureMessage(
        executable: URL,
        arguments: [String],
        status: Int32,
        reason: Process.TerminationReason,
        stdout: String,
        stderr: String
    ) -> String {
        let command = ([executable.path] + arguments).joined(separator: " ")
        var parts: [String] = []
        switch reason {
        case .uncaughtSignal:
            parts.append("micromamba was killed by signal \(status)")
        default:
            parts.append("micromamba exited with status \(status)")
        }
        parts.append("command: \(command)")
        let output = stderr.isEmpty ? stdout : stderr
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parts.append("no output was produced")
        } else {
            parts.append("output: \(trimmed.suffix(2000))")
        }
        if reason == .uncaughtSignal || status == 137 {
            parts.append(
                "hint: a signal-killed micromamba usually means the binary at \(executable.path) has an invalid code signature; run `codesign --verify` on it"
            )
        }
        return parts.joined(separator: "; ")
    }

    /// Runs micromamba with the given arguments and returns stdout.
    ///
    /// The run goes through ``ToolProcess``, so more than 64 KB of output,
    /// as an environment creation with many packages writes, never blocks it.
    /// It has no timeout, and it runs to its end even when the calling task
    /// is cancelled, because stopping micromamba partway through a create or
    /// install can leave an environment half written.
    private func runMicromamba(_ arguments: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: micromambaPath.path) else {
            throw CondaError.micromambaNotFound
        }

        let executablePath = micromambaPath
        let spec = ToolProcessSpec(
            executableURL: executablePath,
            arguments: arguments,
            environment: [
                "MAMBA_ROOT_PREFIX": rootPrefix.path,
                "MAMBA_NO_BANNER": "1",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp",
            ],
            drainGracePeriod: CondaFamilyProcess.micromambaDrainGracePeriod,
            label: "micromamba"
        )
        // An unstructured task does not inherit cancellation.
        let result = try await Task { try await ToolProcess.run(spec) }.value
        let stdout = CondaFamilyProcess.text(result.stdout)
        let stderr = CondaFamilyProcess.text(result.stderr)
        if result.status != 0 {
            let message = Self.micromambaFailureMessage(
                executable: executablePath,
                arguments: arguments,
                status: result.status,
                reason: CondaFamilyProcess.terminationReason(result.termination),
                stdout: stdout,
                stderr: stderr
            )
            logger.error("\(message, privacy: .public)")
            throw CondaError.packageInstallFailed(message)
        }
        if let reason = CondaFamilyProcess.incompleteOutputReason(
            result, drainGrace: CondaFamilyProcess.micromambaDrainGracePeriod
        ) {
            let command = ([executablePath.path] + arguments).joined(separator: " ")
            logger.error("\(reason, privacy: .public)")
            throw CondaError.packageInstallFailed("\(reason) command: \(command)")
        }
        return stdout
    }
}
