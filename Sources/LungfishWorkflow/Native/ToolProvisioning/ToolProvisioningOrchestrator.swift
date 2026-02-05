// ToolProvisioningOrchestrator.swift
// LungfishWorkflow
//
// Orchestrates the provisioning of all tools.

import Foundation
import os

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
        subsystem: "com.lungfish.workflow",
        category: "ToolProvisioningOrchestrator"
    )

    /// Default build directory.
    private let defaultBuildDirectory: URL

    /// Default output directory for tools.
    private let defaultOutputDirectory: URL

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
        manifest: ToolManifest = ToolManifest(tools: BundledToolSpec.defaultTools),
        architecture: Architecture = .current,
        forceRebuild: Bool = false,
        progress: @escaping @Sendable (Status) -> Void
    ) async throws -> Result {
        let startTime = Date()

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
            let provisioner = createProvisioner(for: tool)
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
                let provisioner = createProvisioner(for: tool)

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
        let provisioner = createProvisioner(for: tool)

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

        for tool in BundledToolSpec.defaultTools {
            let provisioner = createProvisioner(for: tool)
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
    private func createProvisioner(for tool: BundledToolSpec) -> any ToolProvisioner {
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
            // For custom provisioners, we'd need a registry
            // For now, fall back to a no-op provisioner
            fatalError("Custom provisioners not yet implemented")
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
        let manifest = ToolManifest(tools: BundledToolSpec.defaultTools)

        var content = """
        Lungfish Bundled Bioinformatics Tools
        ======================================

        This directory contains pre-built bioinformatics tools bundled with Lungfish.
        All tools are open source and distributed under MIT-compatible licenses.

        Versions:

        """

        for tool in manifest.tools {
            let status = result.successful.keys.contains(tool.name) ? "installed" :
                         result.skipped.contains(tool.name) ? "already installed" :
                         result.failed.keys.contains(tool.name) ? "failed" : "unknown"
            content += "- \(tool.displayName): \(tool.version) (\(tool.license.spdxId)) - \(status)\n"
        }

        content += """

        Build date: \(ISO8601DateFormatter().string(from: Date()))
        Build architecture: \(Architecture.current.rawValue)
        Build duration: \(String(format: "%.1f", result.duration)) seconds

        Source URLs:

        """

        for tool in manifest.tools {
            switch tool.provisioningMethod {
            case .compileFromSource(let compilation):
                content += "- \(tool.name): \(compilation.sourceURL.absoluteString)\n"
            case .downloadBinary(let download):
                for (arch, url) in download.urls {
                    content += "- \(tool.name) (\(arch.rawValue)): \(url.absoluteString)\n"
                }
            case .custom:
                content += "- \(tool.name): custom provisioner\n"
            }
        }

        content += """

        Licenses:

        """

        for tool in manifest.tools {
            if let url = tool.license.url {
                content += "- \(tool.name): \(url.absoluteString)\n"
            } else {
                content += "- \(tool.name): \(tool.license.spdxId)\n"
            }
        }

        let versionFile = defaultOutputDirectory.appendingPathComponent("VERSIONS.txt")
        try content.write(to: versionFile, atomically: true, encoding: .utf8)
        logger.info("Created version info at \(versionFile.path)")
    }
}
