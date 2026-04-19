// AssemblyProvenance.swift - Reproducibility metadata for assembly runs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishIO

public enum AssemblyExecutionBackend: String, Codable, Sendable, Equatable {
    case appleContainerization
    case micromamba
}

// MARK: - AssemblyProvenance

/// Full reproducibility record for a de novo assembly.
///
/// Captures everything needed to reproduce or audit an assembly:
/// assembler version, container image, host environment, command line,
/// input file checksums, and output statistics.
///
/// Stored as `assembly/provenance.json` in the `.lungfishref` bundle.
public struct AssemblyProvenance: Codable, Sendable, Equatable {

    // MARK: - Assembler

    /// Name of the assembler (e.g., "SPAdes").
    public let assembler: String

    /// Version of the assembler.
    public let assemblerVersion: String?

    /// Execution backend used for the assembly.
    public let executionBackend: AssemblyExecutionBackend

    /// Managed micromamba environment, when applicable.
    public let managedEnvironment: String?

    /// Launcher command used to start the tool.
    public let launcherCommand: String?

    // MARK: - Container

    /// OCI image reference (e.g., "lungfish/spades:4.0.0-arm64").
    public let containerImage: String?

    /// Image digest (sha256), if available.
    public let containerImageDigest: String?

    /// Container runtime used (e.g., "apple_containerization").
    public let containerRuntime: String?

    // MARK: - Host Environment

    /// Host OS version (e.g., "macOS 26.0").
    public let hostOS: String

    /// Host architecture (e.g., "arm64").
    public let hostArchitecture: String

    /// Lungfish app version.
    public let lungfishVersion: String

    // MARK: - Execution

    /// Date the assembly was started.
    public let assemblyDate: Date

    /// Total wall-clock time in seconds.
    public let wallTimeSeconds: TimeInterval

    /// The full command line used.
    public let commandLine: String

    /// Assembly parameters.
    public let parameters: AssemblyParameters

    // MARK: - Inputs

    /// Input file records with checksums.
    public let inputs: [InputFileRecord]

    // MARK: - Output Statistics

    /// Assembly statistics from the output.
    public let statistics: AssemblyStatistics?

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case assembler
        case assemblerVersion = "assembler_version"
        case executionBackend = "execution_backend"
        case managedEnvironment = "managed_environment"
        case launcherCommand = "launcher_command"
        case containerImage = "container_image"
        case containerImageDigest = "container_image_digest"
        case containerRuntime = "container_runtime"
        case hostOS = "host_os"
        case hostArchitecture = "host_architecture"
        case lungfishVersion = "lungfish_version"
        case assemblyDate = "assembly_date"
        case wallTimeSeconds = "wall_time_seconds"
        case commandLine = "command_line"
        case parameters
        case inputs
        case statistics
    }

    public init(
        assembler: String,
        assemblerVersion: String?,
        executionBackend: AssemblyExecutionBackend = .appleContainerization,
        managedEnvironment: String? = nil,
        launcherCommand: String? = nil,
        containerImage: String? = nil,
        containerImageDigest: String? = nil,
        containerRuntime: String? = nil,
        hostOS: String,
        hostArchitecture: String,
        lungfishVersion: String,
        assemblyDate: Date,
        wallTimeSeconds: TimeInterval,
        commandLine: String,
        parameters: AssemblyParameters,
        inputs: [InputFileRecord],
        statistics: AssemblyStatistics?
    ) {
        self.assembler = assembler
        self.assemblerVersion = assemblerVersion
        self.executionBackend = executionBackend
        self.managedEnvironment = managedEnvironment
        self.launcherCommand = launcherCommand
        self.containerImage = containerImage
        self.containerImageDigest = containerImageDigest
        self.containerRuntime = containerRuntime
        self.hostOS = hostOS
        self.hostArchitecture = hostArchitecture
        self.lungfishVersion = lungfishVersion
        self.assemblyDate = assemblyDate
        self.wallTimeSeconds = wallTimeSeconds
        self.commandLine = commandLine
        self.parameters = parameters
        self.inputs = inputs
        self.statistics = statistics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.assembler = try container.decode(String.self, forKey: .assembler)
        self.assemblerVersion = try container.decodeIfPresent(String.self, forKey: .assemblerVersion)
        self.executionBackend = try container.decodeIfPresent(AssemblyExecutionBackend.self, forKey: .executionBackend)
            ?? (try container.decodeIfPresent(String.self, forKey: .containerRuntime) != nil
                ? .appleContainerization
                : .micromamba)
        self.managedEnvironment = try container.decodeIfPresent(String.self, forKey: .managedEnvironment)
        self.launcherCommand = try container.decodeIfPresent(String.self, forKey: .launcherCommand)
        self.containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        self.containerImageDigest = try container.decodeIfPresent(String.self, forKey: .containerImageDigest)
        self.containerRuntime = try container.decodeIfPresent(String.self, forKey: .containerRuntime)
        self.hostOS = try container.decode(String.self, forKey: .hostOS)
        self.hostArchitecture = try container.decode(String.self, forKey: .hostArchitecture)
        self.lungfishVersion = try container.decode(String.self, forKey: .lungfishVersion)
        self.assemblyDate = try container.decode(Date.self, forKey: .assemblyDate)
        self.wallTimeSeconds = try container.decode(TimeInterval.self, forKey: .wallTimeSeconds)
        self.commandLine = try container.decode(String.self, forKey: .commandLine)
        self.parameters = try container.decode(AssemblyParameters.self, forKey: .parameters)
        self.inputs = try container.decode([InputFileRecord].self, forKey: .inputs)
        self.statistics = try container.decodeIfPresent(AssemblyStatistics.self, forKey: .statistics)
    }
}

// MARK: - AssemblyParameters

/// Captured assembly parameters for reproducibility.
public struct AssemblyParameters: Codable, Sendable, Equatable {
    /// Assembly mode (e.g., "isolate", "meta").
    public let mode: String
    /// K-mer sizes used ("auto" or comma-separated list).
    public let kmerSizes: String
    /// Memory limit in GB.
    public let memoryGB: Int
    /// Number of threads.
    public let threads: Int
    /// Whether error correction was skipped.
    public let skipErrorCorrection: Bool
    /// Minimum contig length filter.
    public let minContigLength: Int

    private enum CodingKeys: String, CodingKey {
        case mode
        case kmerSizes = "k_mer_sizes"
        case memoryGB = "memory_gb"
        case threads
        case skipErrorCorrection = "skip_error_correction"
        case minContigLength = "min_contig_length"
    }
}

// MARK: - InputFileRecord

/// Record of an input file with integrity checksum.
public struct InputFileRecord: Codable, Sendable, Equatable {
    /// Original filename.
    public let filename: String
    /// Original absolute input path when known.
    public let originalPath: String?
    /// SHA-256 checksum of the file.
    public let sha256: String?
    /// File size in bytes.
    public let sizeBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case filename
        case originalPath = "original_path"
        case sha256
        case sizeBytes = "size_bytes"
    }

    public init(filename: String, originalPath: String? = nil, sha256: String?, sizeBytes: Int64) {
        self.filename = filename
        self.originalPath = originalPath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

// MARK: - Provenance I/O

extension AssemblyProvenance {

    /// Standard filename for provenance records.
    public static let filename = "provenance.json"

    /// Saves the provenance record to a directory.
    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = directory.appendingPathComponent(Self.filename)
        try data.write(to: url)
    }

    /// Loads a provenance record from a directory.
    public static func load(from directory: URL) throws -> AssemblyProvenance {
        let url = directory.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AssemblyProvenance.self, from: data)
    }
}

// MARK: - ProvenanceBuilder

/// Helper to construct provenance records from pipeline results.
public enum ProvenanceBuilder {

    /// Creates a provenance record from an SPAdes assembly config and result.
    public static func build(
        config: SPAdesAssemblyConfig,
        result: SPAdesAssemblyResult,
        inputRecords: [InputFileRecord],
        lungfishVersion: String = "1.0.0"
    ) -> AssemblyProvenance {
        let parameters = AssemblyParameters(
            mode: config.mode.rawValue,
            kmerSizes: config.kmerSizes.map { $0.map(String.init).joined(separator: ",") } ?? "auto",
            memoryGB: config.memoryGB,
            threads: config.threads,
            skipErrorCorrection: config.skipErrorCorrection,
            minContigLength: config.minContigLength
        )

        return AssemblyProvenance(
            assembler: "SPAdes",
            assemblerVersion: result.spadesVersion,
            executionBackend: .appleContainerization,
            managedEnvironment: nil,
            launcherCommand: result.commandLine,
            containerImage: SPAdesAssemblyPipeline.spadesImageReference,
            containerImageDigest: nil,
            containerRuntime: "apple_containerization",
            hostOS: hostOSVersion(),
            hostArchitecture: hostArchitectureString(),
            lungfishVersion: lungfishVersion,
            assemblyDate: Date(),
            wallTimeSeconds: result.wallTimeSeconds,
            commandLine: result.commandLine,
            parameters: parameters,
            inputs: inputRecords,
            statistics: result.statistics
        )
    }

    /// Creates a provenance record from a managed assembly request and result.
    public static func build(
        request: AssemblyRunRequest,
        result: AssemblyResult,
        inputRecords: [InputFileRecord],
        lungfishVersion: String = "1.0.0"
    ) -> AssemblyProvenance {
        let parameters = AssemblyParameters(
            mode: request.selectedProfileID ?? "default",
            kmerSizes: "managed",
            memoryGB: request.memoryGB ?? 0,
            threads: request.threads,
            skipErrorCorrection: request.extraArguments.contains("--only-assembler"),
            minContigLength: request.minContigLength ?? 0
        )

        return AssemblyProvenance(
            assembler: request.tool.displayName,
            assemblerVersion: result.assemblerVersion,
            executionBackend: .micromamba,
            managedEnvironment: request.tool.environmentName,
            launcherCommand: result.commandLine,
            containerImage: nil,
            containerImageDigest: nil,
            containerRuntime: nil,
            hostOS: hostOSVersion(),
            hostArchitecture: hostArchitectureString(),
            lungfishVersion: lungfishVersion,
            assemblyDate: Date(),
            wallTimeSeconds: result.wallTimeSeconds,
            commandLine: result.commandLine,
            parameters: parameters,
            inputs: inputRecords,
            statistics: result.statistics
        )
    }

    /// Computes an InputFileRecord for a file URL.
    ///
    /// SHA-256 computation is skipped for files larger than `maxHashSizeBytes`
    /// to avoid blocking on multi-GB FASTQ files.
    public static func inputRecord(
        for url: URL,
        maxHashSizeBytes: Int64 = 500_000_000  // 500 MB
    ) -> InputFileRecord {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let sha256: String? = size <= maxHashSizeBytes ? computeSHA256(of: url) : nil

        return InputFileRecord(
            filename: url.lastPathComponent,
            originalPath: url.path,
            sha256: sha256,
            sizeBytes: size
        )
    }

    // MARK: - Private

    private static func hostOSVersion() -> String {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func hostArchitectureString() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func computeSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024  // 1 MB chunks
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: bufferSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
