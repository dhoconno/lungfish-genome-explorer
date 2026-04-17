// ToolProvisioningOrchestrator.swift
// LungfishWorkflow
//
// Orchestrates the provisioning of all tools.

import Foundation
import os
import LungfishCore

// MARK: - ToolProvisioningOrchestrator

/// Orchestrates the provisioning of bundled tools.
///
/// This class manages the entire tool provisioning process, including:
/// - Dependency resolution
/// - Parallel and sequential builds
/// - Progress reporting
/// - Caching of built tools
public actor ToolProvisioningOrchestrator {

    // MARK: - Types

    /// Overall provisioning status.
    public struct Status: Sendable {
        public let phase: Phase
        public let overallProgress: Double
        public let currentTool: String?
        public let message: String
        public let completedTools: [String]
        public let failedTools: [String: Error]

        public enum Phase: String, Sendable {
            case idle = "Idle"
            case analyzing = "Analyzing"
            case provisioning = "Provisioning"
            case complete = "Complete"
            case failed = "Failed"
        }
    }

    /// Result of provisioning.
    public struct Result: Sendable {
        public let successful: [String: [URL]]
        public let failed: [String: Error]
        public let skipped: [String]  // Already installed
        public let duration: TimeInterval
    }

    // MARK: - Properties

    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "ToolProvisioningOrchestrator"
    )

    /// Default build directory.
    private let defaultBuildDirectory: URL

    /// Default output directory for tools.
    private let defaultOutputDirectory: URL

    /// Architecture associated with the most recent provisioning operation.
    private var lastProvisionedArchitecture: Architecture

    /// Tool specs associated with the most recent provisioning manifest.
    private var lastProvisionedToolsByName: [String: BundledToolSpec]

    /// Tool ordering associated with the most recent provisioning manifest.
    private var lastProvisionedToolOrder: [String]

    /// Cached provisioners.
    private var provisioners: [String: any ToolProvisioner] = [:]

    // MARK: - Initialization

    public init(
        buildDirectory: URL? = nil,
        outputDirectory: URL? = nil
    ) {
        let projectRoot = Self.findProjectRoot() ?? FileManager.default.temporaryDirectory

        self.defaultBuildDirectory = buildDirectory ??
            projectRoot.appendingPathComponent(".build/tools")

        self.defaultOutputDirectory = outputDirectory ??
            projectRoot.appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools")

        self.lastProvisionedArchitecture = .current
        self.lastProvisionedToolsByName = [:]
        self.lastProvisionedToolOrder = []
    }

    // MARK: - Public API

    /// Provisions all tools defined in the manifest.
    ///
    /// - Parameters:
    ///   - manifest: Tool manifest describing tools to provision.
    ///   - architecture: Target architecture (default: current machine).
    ///   - forceRebuild: If true, rebuilds even if tools are already installed.
    ///   - progress: Callback for progress updates.
    /// - Returns: Result of provisioning.
    public func provisionAll(
        manifest: ToolManifest = ToolManifest.defaultBundledManifest,
        architecture: Architecture = .current,
        forceRebuild: Bool = false,
        progress: @escaping @Sendable (Status) -> Void
    ) async throws -> Result {
        let startTime = Date()
        lastProvisionedArchitecture = architecture
        lastProvisionedToolsByName = Dictionary(uniqueKeysWithValues: manifest.tools.map { ($0.name, $0) })
        lastProvisionedToolOrder = manifest.tools.map(\.name)

        progress(Status(
            phase: .analyzing,
            overallProgress: 0.0,
            currentTool: nil,
            message: "Analyzing tool dependencies...",
            completedTools: [],
            failedTools: [:]
        ))

        // Resolve dependency order
        let orderedTools = try resolveDependencyOrder(manifest.tools)

        logger.info("Provisioning \(orderedTools.count) tools: \(orderedTools.map { $0.name })")

        // Check what's already installed
        var skipped: [String] = []
        var toProvision: [BundledToolSpec] = []

        for tool in orderedTools {
            let provisioner = try createProvisioner(for: tool)
            if !forceRebuild && provisioner.isInstalled(in: defaultOutputDirectory) {
                logger.info("\(tool.name) already installed, skipping")
                skipped.append(tool.name)
            } else {
                toProvision.append(tool)
            }
        }

        if toProvision.isEmpty {
            logger.info("All tools already installed")
            progress(Status(
                phase: .complete,
                overallProgress: 1.0,
                currentTool: nil,
                message: "All tools already installed",
                completedTools: skipped,
                failedTools: [:]
            ))

            return Result(
                successful: [:],
                failed: [:],
                skipped: skipped,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Provision tools in dependency order
        var successful: [String: [URL]] = [:]
        var failed: [String: Error] = [:]
        var dependencyPaths: [String: URL] = [:]

        // Add paths for already-installed tools
        for toolName in skipped {
            if let tool = manifest.tools.first(where: { $0.name == toolName }) {
                if let firstExecutable = tool.executables.first {
                    dependencyPaths[toolName] = defaultOutputDirectory.appendingPathComponent(firstExecutable)
                }
            }
        }

        let totalTools = toProvision.count

        for (index, tool) in toProvision.enumerated() {
            let toolProgress = Double(index) / Double(totalTools)

            progress(Status(
                phase: .provisioning,
                overallProgress: toolProgress,
                currentTool: tool.name,
                message: "Provisioning \(tool.displayName)...",
                completedTools: Array(successful.keys) + skipped,
                failedTools: failed
            ))

            do {
                let provisioner = try createProvisioner(for: tool)

                // Capture current state for progress callback
                let currentCompleted = Array(successful.keys) + skipped
                let currentFailed = failed

                let executables = try await provisioner.provision(
                    to: defaultOutputDirectory,
                    buildDirectory: defaultBuildDirectory,
                    architecture: architecture,
                    dependencyPaths: dependencyPaths
                ) { toolStatus in
                    let overallProgress = toolProgress + (toolStatus.progress / Double(totalTools))
                    progress(Status(
                        phase: .provisioning,
                        overallProgress: overallProgress,
                        currentTool: tool.name,
                        message: toolStatus.message,
                        completedTools: currentCompleted,
                        failedTools: currentFailed
                    ))
                }

                successful[tool.name] = executables

                // Add to dependency paths for subsequent tools
                if let firstExecutable = executables.first {
                    dependencyPaths[tool.name] = firstExecutable
                }

                logger.info("Successfully provisioned \(tool.name)")

            } catch {
                logger.error("Failed to provision \(tool.name): \(error.localizedDescription)")
                failed[tool.name] = error

                // Don't continue if a dependency failed
                // Check if any remaining tools depend on this one
                let dependentTools = toProvision[(index + 1)...].filter { $0.dependencies.contains(tool.name) }
                for dependent in dependentTools {
                    failed[dependent.name] = ToolProvisioningError.dependencyNotFound(
                        tool: dependent.name,
                        dependency: tool.name
                    )
                }
            }
        }

        let finalPhase: Status.Phase = failed.isEmpty ? .complete : .failed
        let message = failed.isEmpty
            ? "All tools provisioned successfully"
            : "\(failed.count) tool(s) failed to provision"

        progress(Status(
            phase: finalPhase,
            overallProgress: 1.0,
            currentTool: nil,
            message: message,
            completedTools: Array(successful.keys) + skipped,
            failedTools: failed
        ))

        return Result(
            successful: successful,
            failed: failed,
            skipped: skipped,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Provisions a single tool.
    public func provision(
        tool: BundledToolSpec,
        architecture: Architecture = .current,
        forceRebuild: Bool = false,
        progress: @escaping @Sendable (ProvisioningProgress) -> Void
    ) async throws -> [URL] {
        lastProvisionedArchitecture = architecture
        let provisioner = try createProvisioner(for: tool)

        if !forceRebuild && provisioner.isInstalled(in: defaultOutputDirectory) {
            progress(ProvisioningProgress(
                phase: .complete,
                progress: 1.0,
                message: "\(tool.name) already installed",
                toolName: tool.name
            ))
            return provisioner.expectedExecutables(in: defaultOutputDirectory)
        }

        return try await provisioner.provision(
            to: defaultOutputDirectory,
            buildDirectory: defaultBuildDirectory,
            architecture: architecture,
            dependencyPaths: [:],
            progress: progress
        )
    }

    /// Checks which tools are already installed.
    public func checkInstallationStatus() -> [String: Bool] {
        var status: [String: Bool] = [:]

        for tool in ToolManifest.defaultBundledManifest.tools {
            guard let provisioner = try? createProvisioner(for: tool) else {
                status[tool.name] = false
                continue
            }
            status[tool.name] = provisioner.isInstalled(in: defaultOutputDirectory)
        }

        return status
    }

    /// Returns the output directory for tools.
    public func getOutputDirectory() -> URL {
        defaultOutputDirectory
    }

    // MARK: - Private Methods

    /// Resolves dependencies and returns tools in build order.
    private func resolveDependencyOrder(_ tools: [BundledToolSpec]) throws -> [BundledToolSpec] {
        var result: [BundledToolSpec] = []
        var visited: Set<String> = []
        var visiting: Set<String> = []

        let toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        func visit(_ tool: BundledToolSpec) throws {
            if visited.contains(tool.name) {
                return
            }
            if visiting.contains(tool.name) {
                throw ToolProvisioningError.dependencyNotFound(
                    tool: tool.name,
                    dependency: "circular dependency detected"
                )
            }

            visiting.insert(tool.name)

            for depName in tool.dependencies {
                if let dep = toolMap[depName] {
                    try visit(dep)
                }
                // If dependency not in manifest, assume it's external or already installed
            }

            visiting.remove(tool.name)
            visited.insert(tool.name)
            result.append(tool)
        }

        for tool in tools {
            try visit(tool)
        }

        return result
    }

    /// Creates a provisioner for the given tool definition.
    private func createProvisioner(for tool: BundledToolSpec) throws -> any ToolProvisioner {
        if let cached = provisioners[tool.name] {
            return cached
        }

        let provisioner: any ToolProvisioner

        switch tool.provisioningMethod {
        case .downloadBinary(let download):
            provisioner = BinaryDownloadProvisioner(
                toolSpec: tool,
                download: download
            )

        case .compileFromSource(let compilation):
            provisioner = SourceCompilationProvisioner(
                toolSpec: tool,
                compilation: compilation
            )

        case .custom:
            // Custom provisioners require a registry which is not yet implemented.
            // Throw a descriptive error instead of crashing.
            throw ToolProvisioningError.installationFailed(
                tool: tool.name,
                reason: "Custom provisioners are not yet implemented"
            )
        }

        provisioners[tool.name] = provisioner
        return provisioner
    }

    /// Finds the project root directory.
    private static func findProjectRoot() -> URL? {
        let fileManager = FileManager.default
        var currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        for _ in 0..<10 {
            let packageSwift = currentDir.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: packageSwift.path) {
                return currentDir
            }
            currentDir = currentDir.deletingLastPathComponent()
        }

        return nil
    }
}

// MARK: - Convenience Extensions

extension ToolProvisioningOrchestrator {
    /// Creates a version info file in the tools directory.
    public func createVersionInfo(for result: Result) async throws {
        let timestamp = DateFormatter.versionSummaryTimestamp.string(from: Self.resolvedVersionSummaryDate())
        let entries = versionInfoEntries(for: result)

        var content = """
        Lungfish Bundled Bootstrap Tools
        =================================

        This directory contains the bundled bootstrap binary used by Lungfish.
        Only micromamba remains bundled here; all other bioinformatics tools are
        managed separately.

        Versions:

        """

        for entry in entries {
            if let tool = entry.tool {
                content += "- \(tool.displayName): \(tool.version) (\(tool.license.spdxId) license)\n"
            } else {
                content += "- \(entry.name): provisioned\n"
            }
        }

        content += """

        Build date: \(timestamp)
        Build architecture: \(lastProvisionedArchitecture.rawValue)

        Source URLs:

        """

        for entry in entries {
            if let tool = entry.tool, let url = preferredSourceURL(forVersionInfo: tool) {
                content += "- \(entry.name): \(url.absoluteString)\n"
            } else {
                content += "- \(entry.name): custom provisioner\n"
            }
        }

        content += """

        Licenses:

        """

        for entry in entries {
            if let tool = entry.tool, let url = tool.license.url {
                content += "- \(entry.name): \(url.absoluteString)\n"
            } else if let tool = entry.tool {
                content += "- \(entry.name): \(tool.license.spdxId)\n"
            } else {
                content += "- \(entry.name): unknown\n"
            }
        }

        let versionFile = defaultOutputDirectory.appendingPathComponent("VERSIONS.txt")
        try content.write(to: versionFile, atomically: true, encoding: .utf8)
        logger.info("Created version info at \(versionFile.path)")
    }

    private struct VersionInfoEntry {
        let name: String
        let tool: BundledToolSpec?
    }

    private func versionInfoEntries(for result: Result) -> [VersionInfoEntry] {
        let resultNames = Set(result.successful.keys)
            .union(result.skipped)
            .union(result.failed.keys)

        let orderedNames = lastProvisionedToolOrder.filter { resultNames.contains($0) }
        let remainingNames = resultNames.subtracting(orderedNames).sorted()

        return (orderedNames + remainingNames).map { name in
            VersionInfoEntry(
                name: name,
                tool: lastProvisionedToolsByName[name] ?? ToolManifest.defaultBundledManifest.tools.first(where: { $0.name == name })
            )
        }
    }

    func preferredSourceURL(forVersionInfo tool: BundledToolSpec) -> URL? {
        if tool.name == "micromamba" {
            return URL(string: "https://github.com/mamba-org/mamba")
        }

        switch tool.provisioningMethod {
        case .compileFromSource(let compilation):
            return compilation.sourceURL
        case .downloadBinary(let download):
            return download.urls[lastProvisionedArchitecture]
                ?? download.urls.values.sorted(by: { $0.absoluteString < $1.absoluteString }).first
        case .custom:
            return nil
        }
    }

    private static func resolvedVersionSummaryDate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date {
        if let timestamp = environment["LUNGFISH_BUILD_TIMESTAMP"] {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime]

            if let date = formatter.date(from: timestamp) {
                return date
            }
        }

        if let epoch = environment["SOURCE_DATE_EPOCH"],
           let seconds = TimeInterval(epoch) {
            return Date(timeIntervalSince1970: seconds)
        }

        return Date()
    }
}

private extension DateFormatter {
    static let versionSummaryTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter
    }()
}
