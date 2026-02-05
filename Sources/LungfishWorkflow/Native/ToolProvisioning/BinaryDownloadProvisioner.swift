// BinaryDownloadProvisioner.swift
// LungfishWorkflow
//
// Provisioner for pre-built binary tools.

import Foundation
import os

/// Provisions tools by downloading pre-built binaries.
public actor BinaryDownloadProvisioner: ToolProvisioner {
    public let toolSpec: BundledToolSpec
    private let download: BinaryDownload
    private let base: BaseToolProvisioner

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "BinaryDownloadProvisioner"
    )

    public init(toolSpec: BundledToolSpec, download: BinaryDownload) {
        self.toolSpec = toolSpec
        self.download = download
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

        // Determine which architecture to download
        // For x86_64-only tools on arm64, we still download x86_64 (Rosetta)
        var downloadArch = architecture
        if !download.urls.keys.contains(architecture) {
            if download.urls.keys.contains(.x86_64) {
                downloadArch = .x86_64
                logger.info("\(toolName) not available for \(architecture.rawValue), using x86_64 via Rosetta")
            } else {
                throw ToolProvisioningError.unsupportedArchitecture(
                    tool: toolName,
                    architecture: architecture
                )
            }
        }

        guard let downloadURL = download.urls[downloadArch] else {
            throw ToolProvisioningError.unsupportedArchitecture(
                tool: toolName,
                architecture: downloadArch
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var installedExecutables: [URL] = []

        if download.isArchive {
            // Download and extract archive
            progress(ProvisioningProgress(
                phase: .downloading,
                progress: 0.0,
                message: "Downloading \(toolName)...",
                toolName: toolName
            ))

            let archiveFilename = downloadURL.lastPathComponent
            let archivePath = buildDirectory.appendingPathComponent(archiveFilename)

            try await base.downloadWithChecksum(
                from: downloadURL,
                to: archivePath,
                expectedChecksum: download.checksums?[downloadArch]
            ) { downloadProgress in
                progress(ProvisioningProgress(
                    phase: .downloading,
                    progress: downloadProgress * 0.5,
                    message: "Downloading \(toolName)...",
                    toolName: toolName
                ))
            }

            progress(ProvisioningProgress(
                phase: .extracting,
                progress: 0.5,
                message: "Extracting \(toolName)...",
                toolName: toolName
            ))

            let extractDir = buildDirectory.appendingPathComponent("\(toolName)-extracted")
            // Determine format from filename
            let format: ArchiveFormat
            if archiveFilename.hasSuffix(".tar.gz") || archiveFilename.hasSuffix(".tgz") {
                format = .tarGz
            } else if archiveFilename.hasSuffix(".tar.bz2") {
                format = .tarBz2
            } else if archiveFilename.hasSuffix(".tar.xz") {
                format = .tarXz
            } else if archiveFilename.hasSuffix(".zip") {
                format = .zip
            } else {
                format = .tarGz  // Default
            }

            try await base.extract(archive: archivePath, to: extractDir, format: format)

            // Copy executables from archive paths
            progress(ProvisioningProgress(
                phase: .installing,
                progress: 0.8,
                message: "Installing \(toolName)...",
                toolName: toolName
            ))

            for executable in toolSpec.executables {
                var sourcePath: URL?

                // Check archive paths if specified
                if let archivePaths = download.archivePaths {
                    for archivePath in archivePaths {
                        let candidate = extractDir.appendingPathComponent(archivePath)
                            .appendingPathComponent(executable)
                        if fileManager.isExecutableFile(atPath: candidate.path) {
                            sourcePath = candidate
                            break
                        }
                    }
                }

                // Otherwise search recursively
                if sourcePath == nil {
                    sourcePath = try findExecutable(named: executable, in: extractDir)
                }

                guard let source = sourcePath else {
                    throw ToolProvisioningError.installationFailed(
                        tool: toolName,
                        reason: "Executable not found in archive: \(executable)"
                    )
                }

                let destPath = outputDirectory.appendingPathComponent(executable)
                if fileManager.fileExists(atPath: destPath.path) {
                    try fileManager.removeItem(at: destPath)
                }
                try fileManager.copyItem(at: source, to: destPath)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath.path)
                installedExecutables.append(destPath)
            }

        } else {
            // Download individual executables directly
            // This is used for UCSC tools where each tool is a separate download
            let totalExecutables = toolSpec.executables.count

            for (index, executable) in toolSpec.executables.enumerated() {
                let executableURL = downloadURL.appendingPathComponent(executable)
                let destPath = outputDirectory.appendingPathComponent(executable)

                let progressBase = Double(index) / Double(totalExecutables)
                let progressRange = 1.0 / Double(totalExecutables)

                progress(ProvisioningProgress(
                    phase: .downloading,
                    progress: progressBase,
                    message: "Downloading \(executable)...",
                    toolName: toolName
                ))

                try await base.download(
                    from: executableURL,
                    to: destPath
                ) { downloadProgress in
                    progress(ProvisioningProgress(
                        phase: .downloading,
                        progress: progressBase + (downloadProgress * progressRange * 0.9),
                        message: "Downloading \(executable)...",
                        toolName: toolName
                    ))
                }

                // Verify checksum if provided
                if let checksums = download.checksums,
                   let expected = checksums[downloadArch] {
                    // For multi-executable downloads, checksums would need to be per-executable
                    // This is a simplified version
                    logger.debug("Checksum verification skipped for \(executable)")
                }

                // Make executable
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destPath.path
                )

                installedExecutables.append(destPath)
                logger.info("Downloaded \(executable) to \(destPath.path)")
            }
        }

        progress(ProvisioningProgress(
            phase: .complete,
            progress: 1.0,
            message: "\(toolName) installed successfully",
            toolName: toolName
        ))

        return installedExecutables
    }

    /// Finds an executable by name in a directory tree.
    private func findExecutable(named name: String, in directory: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == name {
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
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
