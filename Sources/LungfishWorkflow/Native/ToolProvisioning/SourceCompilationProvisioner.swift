// SourceCompilationProvisioner.swift
// LungfishWorkflow
//
// Provisioner for tools that need to be compiled from source.

import Foundation
import os

/// Provisions tools by compiling from source.
public actor SourceCompilationProvisioner: ToolProvisioner {
    public let toolSpec: BundledToolSpec
    private let compilation: SourceCompilation
    private let base: BaseToolProvisioner

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "SourceCompilationProvisioner"
    )

    public init(toolSpec: BundledToolSpec, compilation: SourceCompilation) {
        self.toolSpec = toolSpec
        self.compilation = compilation
        self.base = BaseToolProvisioner(toolSpec: toolSpec)
    }

    public func provision(
        to outputDirectory: URL,
        buildDirectory: URL,
        architecture: Architecture,
        dependencyPaths: [String: URL],
        progress: @escaping @Sendable (ProvisioningProgress) -> Void
    ) async throws -> [URL] {
        let toolName = toolSpec.name
        let version = toolSpec.version

        // Check architecture support
        guard toolSpec.supportedArchitectures.contains(architecture) else {
            throw ToolProvisioningError.unsupportedArchitecture(
                tool: toolName,
                architecture: architecture
            )
        }

        // Check dependencies
        for dep in toolSpec.dependencies {
            guard dependencyPaths[dep] != nil else {
                throw ToolProvisioningError.dependencyNotFound(
                    tool: toolName,
                    dependency: dep
                )
            }
        }

        let fileManager = FileManager.default

        // Setup directories
        let archBuildDir = buildDirectory.appendingPathComponent(architecture.rawValue)
        let srcDir = buildDirectory.appendingPathComponent("src")
        let installDir = archBuildDir.appendingPathComponent("install")

        try fileManager.createDirectory(at: archBuildDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)

        // Download source
        progress(ProvisioningProgress(
            phase: .downloading,
            progress: 0.0,
            message: "Downloading \(toolName) \(version)...",
            toolName: toolName
        ))

        let archiveFilename = compilation.sourceURL.lastPathComponent
        let archivePath = srcDir.appendingPathComponent(archiveFilename)

        if !fileManager.fileExists(atPath: archivePath.path) {
            try await base.downloadWithChecksum(
                from: compilation.sourceURL,
                to: archivePath,
                expectedChecksum: compilation.sourceChecksum
            ) { downloadProgress in
                progress(ProvisioningProgress(
                    phase: .downloading,
                    progress: downloadProgress * 0.2,
                    message: "Downloading \(toolName)...",
                    toolName: toolName
                ))
            }
        }

        // Extract
        progress(ProvisioningProgress(
            phase: .extracting,
            progress: 0.2,
            message: "Extracting \(toolName)...",
            toolName: toolName
        ))

        let extractedName = "\(toolName)-\(version)"
        let sourceDir = archBuildDir.appendingPathComponent(extractedName)

        if !fileManager.fileExists(atPath: sourceDir.path) {
            try await base.extract(
                archive: archivePath,
                to: archBuildDir,
                format: compilation.archiveFormat
            )
        }

        // Configure and build
        progress(ProvisioningProgress(
            phase: .configuring,
            progress: 0.3,
            message: "Configuring \(toolName)...",
            toolName: toolName
        ))

        // Build environment with dependency paths
        var buildEnv = compilation.buildEnvironment
        if let htslibPath = dependencyPaths["htslib"] {
            // For tools that depend on htslib, set the path
            let htslibInstall = htslibPath.deletingLastPathComponent()  // Go from bin to install dir
            buildEnv["HTSLIB_DIR"] = htslibInstall.path
        }

        // Additional configure flags for dependencies
        var configFlags = compilation.configureFlags
        if let htslibPath = dependencyPaths["htslib"] {
            let htslibInstall = htslibPath.deletingLastPathComponent()
            configFlags.append("--with-htslib=\(htslibInstall.path)")
        }

        progress(ProvisioningProgress(
            phase: .compiling,
            progress: 0.4,
            message: "Compiling \(toolName)...",
            toolName: toolName
        ))

        try await base.buildAutotools(
            sourceDirectory: sourceDir,
            installPrefix: installDir,
            architecture: architecture,
            configureFlags: configFlags,
            environment: buildEnv
        )

        // Copy executables to output
        progress(ProvisioningProgress(
            phase: .installing,
            progress: 0.9,
            message: "Installing \(toolName)...",
            toolName: toolName
        ))

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var installedExecutables: [URL] = []
        let binDir = installDir.appendingPathComponent("bin")

        for executable in toolSpec.executables {
            let sourcePath = binDir.appendingPathComponent(executable)
            let destPath = outputDirectory.appendingPathComponent(executable)

            guard fileManager.fileExists(atPath: sourcePath.path) else {
                throw ToolProvisioningError.installationFailed(
                    tool: toolName,
                    reason: "Executable not found: \(executable)"
                )
            }

            // Remove existing
            if fileManager.fileExists(atPath: destPath.path) {
                try fileManager.removeItem(at: destPath)
            }

            try fileManager.copyItem(at: sourcePath, to: destPath)

            // Ensure executable
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destPath.path
            )

            installedExecutables.append(destPath)
            logger.info("Installed \(executable) to \(destPath.path)")
        }

        progress(ProvisioningProgress(
            phase: .complete,
            progress: 1.0,
            message: "\(toolName) installed successfully",
            toolName: toolName
        ))

        return installedExecutables
    }

    nonisolated public func isInstalled(in directory: URL) -> Bool {
        let executables = expectedExecutables(in: directory)
        let fileManager = FileManager.default
        return executables.allSatisfy { fileManager.isExecutableFile(atPath: $0.path) }
    }

    nonisolated public func expectedExecutables(in directory: URL) -> [URL] {
        toolSpec.executables.map { directory.appendingPathComponent($0) }
    }
}
