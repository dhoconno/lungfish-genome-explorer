// ToolProvisioner.swift
// LungfishWorkflow
//
// Protocol and base implementation for tool provisioning.

import Foundation
import os

// MARK: - ToolProvisioningError

/// Errors that can occur during tool provisioning.
public enum ToolProvisioningError: Error, LocalizedError, Sendable {
    case downloadFailed(tool: String, reason: String)
    case extractionFailed(tool: String, reason: String)
    case compilationFailed(tool: String, reason: String)
    case checksumMismatch(tool: String, expected: String, actual: String)
    case unsupportedArchitecture(tool: String, architecture: Architecture)
    case dependencyNotFound(tool: String, dependency: String)
    case toolAlreadyExists(tool: String)
    case installationFailed(tool: String, reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let tool, let reason):
            return "Failed to download \(tool): \(reason)"
        case .extractionFailed(let tool, let reason):
            return "Failed to extract \(tool): \(reason)"
        case .compilationFailed(let tool, let reason):
            return "Failed to compile \(tool): \(reason)"
        case .checksumMismatch(let tool, let expected, let actual):
            return "Checksum mismatch for \(tool): expected \(expected), got \(actual)"
        case .unsupportedArchitecture(let tool, let arch):
            return "\(tool) does not support \(arch.rawValue) architecture"
        case .dependencyNotFound(let tool, let dep):
            return "\(tool) requires \(dep), which is not available"
        case .toolAlreadyExists(let tool):
            return "\(tool) is already installed"
        case .installationFailed(let tool, let reason):
            return "Failed to install \(tool): \(reason)"
        case .cancelled:
            return "Provisioning was cancelled"
        }
    }
}

// MARK: - ProvisioningProgress

/// Progress information for tool provisioning.
public struct ProvisioningProgress: Sendable {
    /// Current phase of provisioning.
    public let phase: Phase

    /// Overall progress (0.0 to 1.0).
    public let progress: Double

    /// Human-readable status message.
    public let message: String

    /// Tool being provisioned.
    public let toolName: String

    public enum Phase: String, Sendable {
        case downloading = "Downloading"
        case extracting = "Extracting"
        case configuring = "Configuring"
        case compiling = "Compiling"
        case installing = "Installing"
        case verifying = "Verifying"
        case complete = "Complete"
        case failed = "Failed"
    }

    public init(phase: Phase, progress: Double, message: String, toolName: String) {
        self.phase = phase
        self.progress = progress
        self.message = message
        self.toolName = toolName
    }
}

// MARK: - ToolProvisionerDelegate

/// Delegate for receiving provisioning progress updates.
public protocol ToolProvisionerDelegate: AnyObject, Sendable {
    func provisionerDidUpdateProgress(_ progress: ProvisioningProgress)
    func provisionerDidComplete(tool: String, executables: [URL])
    func provisionerDidFail(tool: String, error: Error)
}

// MARK: - ToolProvisioner

/// Protocol for tool provisioners.
public protocol ToolProvisioner: Sendable {
    /// The tool specification this provisioner handles.
    var toolSpec: BundledToolSpec { get }

    /// Provisions the tool to the specified output directory.
    ///
    /// - Parameters:
    ///   - outputDirectory: Directory where executables should be placed.
    ///   - buildDirectory: Temporary directory for build artifacts.
    ///   - architecture: Target architecture.
    ///   - dependencyPaths: Paths to dependency installations (keyed by tool name).
    ///   - progress: Callback for progress updates.
    /// - Returns: URLs of installed executables.
    func provision(
        to outputDirectory: URL,
        buildDirectory: URL,
        architecture: Architecture,
        dependencyPaths: [String: URL],
        progress: @escaping @Sendable (ProvisioningProgress) -> Void
    ) async throws -> [URL]

    /// Checks if the tool is already installed and valid.
    func isInstalled(in directory: URL) -> Bool

    /// Returns the expected executable paths for this tool.
    func expectedExecutables(in directory: URL) -> [URL]
}

// MARK: - Default Implementation

extension ToolProvisioner {
    public func isInstalled(in directory: URL) -> Bool {
        let executables = expectedExecutables(in: directory)
        let fileManager = FileManager.default
        return executables.allSatisfy { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public func expectedExecutables(in directory: URL) -> [URL] {
        toolSpec.executables.map { directory.appendingPathComponent($0) }
    }
}

// MARK: - BaseToolProvisioner

/// Base class with common provisioning utilities.
public actor BaseToolProvisioner {
    public let toolSpec: BundledToolSpec

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ToolProvisioner"
    )

    public init(toolSpec: BundledToolSpec) {
        self.toolSpec = toolSpec
    }

    // MARK: - Download Utilities

    /// Downloads a file from URL to destination.
    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        logger.info("Downloading \(url.absoluteString) to \(destination.path)")

        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ToolProvisioningError.downloadFailed(
                tool: toolSpec.name,
                reason: "HTTP status \(statusCode)"
            )
        }

        let fileManager = FileManager.default

        // Create destination directory if needed
        let destDir = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Remove existing file if present
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        // Move downloaded file to destination
        try fileManager.moveItem(at: tempURL, to: destination)

        progress(1.0)
        logger.info("Download complete: \(destination.path)")
    }

    /// Downloads a file with checksum verification.
    public func downloadWithChecksum(
        from url: URL,
        to destination: URL,
        expectedChecksum: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await download(from: url, to: destination, progress: progress)

        if let expected = expectedChecksum {
            let actual = try computeSHA256(of: destination)
            if actual.lowercased() != expected.lowercased() {
                throw ToolProvisioningError.checksumMismatch(
                    tool: toolSpec.name,
                    expected: expected,
                    actual: actual
                )
            }
            logger.info("Checksum verified for \(destination.lastPathComponent)")
        }
    }

    // MARK: - Extraction Utilities

    /// Extracts an archive to a directory.
    public func extract(
        archive: URL,
        to directory: URL,
        format: ArchiveFormat
    ) async throws {
        logger.info("Extracting \(archive.lastPathComponent) to \(directory.path)")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.currentDirectoryURL = directory

        switch format {
        case .zip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archive.path, "-d", directory.path]

        case .tarGz, .tarBz2, .tarXz:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            var args = ["-x"]
            if let flag = format.tarFlag {
                args.append(flag)
            }
            args.append(contentsOf: ["-f", archive.path, "-C", directory.path])
            process.arguments = args
        }

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ToolProvisioningError.extractionFailed(
                tool: toolSpec.name,
                reason: errorMessage
            )
        }

        logger.info("Extraction complete")
    }

    // MARK: - Build Utilities

    /// Runs a shell command and returns the output.
    public func runCommand(
        _ command: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = [:]
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        // Merge environment
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Runs configure && make && make install.
    public func buildAutotools(
        sourceDirectory: URL,
        installPrefix: URL,
        architecture: Architecture,
        configureFlags: [String],
        environment: [String: String] = [:]
    ) async throws {
        let cc = "clang \(architecture.clangFlag)"
        let cflags = "-O2 \(architecture.clangFlag)"

        var env = environment
        env["CC"] = cc
        env["CFLAGS"] = cflags

        // Configure
        let toolName = self.toolSpec.name
        logger.info("Running configure for \(toolName)...")
        var configArgs = ["--prefix=\(installPrefix.path)"]
        configArgs.append(contentsOf: configureFlags)

        let configResult = try await runCommand(
            "./configure",
            arguments: configArgs,
            workingDirectory: sourceDirectory,
            environment: env
        )

        if configResult.exitCode != 0 {
            throw ToolProvisioningError.compilationFailed(
                tool: toolName,
                reason: "Configure failed: \(configResult.stderr)"
            )
        }

        // Make
        logger.info("Running make for \(toolName)...")
        let cpuCount = ProcessInfo.processInfo.processorCount
        let makeResult = try await runCommand(
            "/usr/bin/make",
            arguments: ["-j\(cpuCount)"],
            workingDirectory: sourceDirectory,
            environment: env
        )

        if makeResult.exitCode != 0 {
            throw ToolProvisioningError.compilationFailed(
                tool: toolName,
                reason: "Make failed: \(makeResult.stderr)"
            )
        }

        // Make install
        logger.info("Running make install for \(toolName)...")
        let installResult = try await runCommand(
            "/usr/bin/make",
            arguments: ["install"],
            workingDirectory: sourceDirectory,
            environment: env
        )

        if installResult.exitCode != 0 {
            throw ToolProvisioningError.compilationFailed(
                tool: toolName,
                reason: "Make install failed: \(installResult.stderr)"
            )
        }

        logger.info("Build complete for \(toolName)")
    }

    // MARK: - Checksum

    /// Computes SHA256 checksum of a file.
    private func computeSHA256(of url: URL) throws -> String {
        let toolName = self.toolSpec.name
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw ToolProvisioningError.downloadFailed(
                tool: toolName,
                reason: "Failed to compute checksum"
            )
        }

        // shasum output format: "hash  filename"
        return output.split(separator: " ").first.map(String.init) ?? ""
    }
}
