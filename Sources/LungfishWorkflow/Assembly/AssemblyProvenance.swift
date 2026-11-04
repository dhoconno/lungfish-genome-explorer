// AssemblyProvenance.swift - Reproducibility metadata for assembly runs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
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

    /// The inputs the user chose for the run, as absolute paths in the order
    /// they were given. ``inputs`` also records their lineage (a virtual
    /// bundle comes with the root FASTQ it was cut from and the copy the run
    /// materialized), so Reassemble reads this instead
    /// (``reassemblyInputPaths``). Nil in records written before the field.
    public let requestedInputs: [String]?

    /// Ordered reproducibility steps for app-managed assembly workflows.
    public let steps: [ProvenanceStep]

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
        case requestedInputs = "requested_inputs"
        case steps
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
        requestedInputs: [String]? = nil,
        steps: [ProvenanceStep] = [],
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
        self.requestedInputs = requestedInputs
        self.steps = steps
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
        self.requestedInputs = try container.decodeIfPresent([String].self, forKey: .requestedInputs)
        self.steps = try container.decodeIfPresent([ProvenanceStep].self, forKey: .steps) ?? []
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
    /// Raw extra-args string reconstructed from parsed arguments.
    public let extraArgs: String
    /// Parsed advanced arguments passed to the assembler.
    public let advancedArguments: [String]
    /// Why the profile in `mode` was chosen when the app or CLI picked it
    /// from the reads (Flye's read-quality rule). Nil for user-typed profiles
    /// and for records written before the rule existed.
    public let profileBasis: String?

    public var advancedOptions: String { extraArgs }

    private enum CodingKeys: String, CodingKey {
        case mode
        case kmerSizes = "k_mer_sizes"
        case memoryGB = "memory_gb"
        case threads
        case skipErrorCorrection = "skip_error_correction"
        case minContigLength = "min_contig_length"
        case extraArgs
        case legacyAdvancedOptions = "advanced_options"
        case advancedArguments = "advanced_arguments"
        case profileBasis = "profile_basis"
    }

    public init(
        mode: String,
        kmerSizes: String,
        memoryGB: Int,
        threads: Int,
        skipErrorCorrection: Bool,
        minContigLength: Int,
        extraArgs: String = "",
        advancedArguments: [String] = [],
        profileBasis: String? = nil
    ) {
        self.mode = mode
        self.kmerSizes = kmerSizes
        self.memoryGB = memoryGB
        self.threads = threads
        self.skipErrorCorrection = skipErrorCorrection
        self.minContigLength = minContigLength
        self.extraArgs = extraArgs
        self.advancedArguments = advancedArguments
        self.profileBasis = profileBasis
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decode(String.self, forKey: .mode)
        self.kmerSizes = try container.decode(String.self, forKey: .kmerSizes)
        self.memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        self.threads = try container.decode(Int.self, forKey: .threads)
        self.skipErrorCorrection = try container.decode(Bool.self, forKey: .skipErrorCorrection)
        self.minContigLength = try container.decode(Int.self, forKey: .minContigLength)
        self.extraArgs = try container.decodeIfPresent(String.self, forKey: .extraArgs)
            ?? (try container.decodeIfPresent(String.self, forKey: .legacyAdvancedOptions) ?? "")
        self.advancedArguments = try container.decodeIfPresent([String].self, forKey: .advancedArguments) ?? []
        self.profileBasis = try container.decodeIfPresent(String.self, forKey: .profileBasis)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(kmerSizes, forKey: .kmerSizes)
        try container.encode(memoryGB, forKey: .memoryGB)
        try container.encode(threads, forKey: .threads)
        try container.encode(skipErrorCorrection, forKey: .skipErrorCorrection)
        try container.encode(minContigLength, forKey: .minContigLength)
        try container.encode(extraArgs, forKey: .extraArgs)
        try container.encode(advancedArguments, forKey: .advancedArguments)
        try container.encodeIfPresent(profileBasis, forKey: .profileBasis)
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

// MARK: - Reassembly Inputs

extension AssemblyProvenance {

    /// The inputs the user chose for this run, and nothing else, in the order
    /// they were given: what Reassemble hands the assembly wizard again (R3).
    ///
    /// ``requestedInputs`` names them when the record has it. An older record
    /// lists them in ``inputs`` among their lineage, so they are read from
    /// what it records. A path one of this run's own ``steps`` wrote (a
    /// materialized or joined copy) is not an input. Nor is a path a step read
    /// only to write the copy of another input, which the step names as its
    /// origin (the root FASTQ of a virtual bundle), unless the assembler's
    /// ``commandLine`` names it too, so the run also assembled it directly. A
    /// record without a path gives its file name.
    public var reassemblyInputPaths: [String] {
        if let requestedInputs { return requestedInputs }
        let written = Set(steps.flatMap(\.outputs).map { Self.standardizedPath($0.path) })
        let lineage = Set(
            steps.flatMap(\.inputs)
                .filter { $0.originPath != nil }
                .map { Self.standardizedPath($0.path) }
        )
        let assembled = Self.pathsNamed(by: commandLine)
        var seen = Set<String>()
        var paths: [String] = []
        for record in inputs {
            guard let recordedPath = record.originalPath else {
                if seen.insert(record.filename).inserted { paths.append(record.filename) }
                continue
            }
            let path = Self.standardizedPath(recordedPath)
            guard !written.contains(path) else { continue }
            guard !lineage.contains(path) || assembled.contains(path) else { continue }
            if seen.insert(path).inserted { paths.append(recordedPath) }
        }
        return paths
    }

    /// ``reassemblyInputPaths`` found on disk, each checked against the record this run kept of its reads
    /// (REASSEMBLE-COPY-INPUT). Each input is looked for in this order, and the first place that holds the
    /// recorded bytes is the one used.
    ///
    /// 1. The same path inside the open project, which is where a copied, renamed or moved project holds its own
    ///    reads (``ProjectTempDirectory/pathInsideRecordedProject(_:)``).
    /// 2. Its file name in the project folder and in its FASTQ, Reads and Imports folders.
    /// 3. The recorded path.
    ///
    /// A place is checked against the records whose path is the input or lies inside it, since a bundle is asked
    /// for and the record names its primary file. The size comes first and the SHA-256 after it. Reads that exist
    /// only with other bytes are `changed` and never `found`. Reads that cannot be checked, since the record holds
    /// no checksum or no record, are `unverified`, and `found` holds them too so that the person can go on once
    /// asked. `missing` holds the recorded paths found nowhere. The checks read the files, so this runs off the
    /// main actor.
    @concurrent
    public func reassemblyInputFiles(projectURL: URL?) async -> (
        found: [URL], missing: [String], changed: [String], unverified: [String]
    ) {
        var found: [URL] = []
        var missing: [String] = []
        var changed: [String] = []
        var unverified: [String] = []
        for path in reassemblyInputPaths {
            switch resolvedReassemblyInput(path, projectURL: projectURL) {
            case .verified(let url):
                found.append(url)
            case .unverified(let url):
                found.append(url)
                unverified.append(path)
            case .changed:
                changed.append(path)
            case .missing:
                missing.append(path)
            }
        }
        return (found, missing, changed, unverified)
    }

    private enum ReassemblyInput {
        case verified(URL), unverified(URL), changed, missing
    }

    private enum ReadsComparison {
        case same, differs, unchecked
    }

    private func resolvedReassemblyInput(_ path: String, projectURL: URL?) -> ReassemblyInput {
        let records = inputs.filter { Self.record($0, isAtOrInside: path) }
        var unchecked: URL?
        var differs = false
        for candidate in Self.reassemblyCandidates(for: path, projectURL: projectURL)
        where FileManager.default.fileExists(atPath: candidate.path) {
            switch Self.comparison(of: candidate, standingFor: path, with: records) {
            case .same: return .verified(candidate)
            case .unchecked: unchecked = unchecked ?? candidate
            case .differs: differs = true
            }
        }
        if let unchecked { return .unverified(unchecked) }
        return differs ? .changed : .missing
    }

    /// The places an input may be, best first and none twice.
    private static func reassemblyCandidates(for path: String, projectURL: URL?) -> [URL] {
        var candidates: [URL] = []
        if let projectURL {
            if let inside = ProjectTempDirectory.pathInsideRecordedProject(path) {
                candidates.append(projectURL.appendingPathComponent(inside))
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let folders = [projectURL] + ["FASTQ", "Reads", "Imports"].map { projectURL.appendingPathComponent($0) }
            candidates += folders.map { $0.appendingPathComponent(name) }
        }
        if path.hasPrefix("/") { candidates.append(URL(fileURLWithPath: path)) }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Whether `record` is of the input `path` or of a file inside it.
    private static func record(_ record: InputFileRecord, isAtOrInside path: String) -> Bool {
        guard let recorded = record.originalPath else { return !path.hasPrefix("/") && record.filename == path }
        guard path.hasPrefix("/") else { return false }
        let input = standardizedPath(path)
        let at = standardizedPath(recorded)
        return at == input || at.hasPrefix(input + "/")
    }

    /// The file of `record` as it stands in `candidate`, the place that stands for the input `path`.
    private static func file(of record: InputFileRecord, in candidate: URL, standingFor path: String) -> URL {
        guard let recorded = record.originalPath, path.hasPrefix("/") else { return candidate }
        let input = standardizedPath(path)
        let at = standardizedPath(recorded)
        guard at.hasPrefix(input + "/") else { return candidate }
        return candidate.appendingPathComponent(String(at.dropFirst(input.count + 1)))
    }

    private static func comparison(
        of candidate: URL, standingFor path: String, with records: [InputFileRecord]
    ) -> ReadsComparison {
        guard !records.isEmpty else { return .unchecked }
        var result = ReadsComparison.same
        for record in records {
            switch comparison(of: file(of: record, in: candidate, standingFor: path), with: record) {
            case .differs: return .differs
            case .unchecked: result = .unchecked
            case .same: break
            }
        }
        return result
    }

    /// The size first, since another size settles it without reading the file, and the SHA-256 after it.
    private static func comparison(of file: URL, with record: InputFileRecord) -> ReadsComparison {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else { return .differs }
        let sizeIsRecorded = record.sha256 != nil || record.sizeBytes > 0
        if isDirectory.boolValue {
            // A bundle recorded as a whole, as AssemblyInputMaterialization records it.
            guard let manifest = try? ProvenanceFileHasher.directoryManifest(for: file, role: .input) else { return .unchecked }
            let size = Int64(clamping: manifest.files.reduce(UInt64(0)) { $0 + ($1.fileSize ?? 0) })
            if sizeIsRecorded, size != record.sizeBytes { return .differs }
            guard let recorded = record.sha256 else { return .unchecked }
            return bundleChecksum(of: manifest) == recorded ? .same : .differs
        }
        guard let size = try? ProvenanceFileHasher.fileSize(of: file) else { return .unchecked }
        if sizeIsRecorded, Int64(clamping: size) != record.sizeBytes { return .differs }
        guard let recorded = record.sha256 else { return .unchecked }
        guard let actual = try? ProvenanceFileHasher.sha256(of: file) else { return .unchecked }
        return actual == recorded ? .same : .differs
    }

    /// One checksum over the relative path, checksum and size of every file a bundle holds, in the form
    /// AssemblyInputMaterialization writes for a bundle input.
    private static func bundleChecksum(of manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { [$0.path, $0.checksumSHA256 ?? "", $0.fileSize.map(String.init) ?? "0"].joined(separator: "\t") }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The absolute paths `commandLine` hands the assembler: each argument,
    /// and each comma-separated part of one, since SKESA and MEGAHIT can name
    /// several files in one argument.
    private static func pathsNamed(by commandLine: String) -> Set<String> {
        guard let arguments = try? AdvancedCommandLineOptions.parse(commandLine) else { return [] }
        var paths = Set<String>()
        for argument in arguments {
            for part in [argument] + argument.split(separator: ",").map(String.init) where part.hasPrefix("/") {
                paths.insert(standardizedPath(part))
            }
        }
        return paths
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
        steps: [ProvenanceStep] = [],
        lungfishVersion: String = "1.0.0"
    ) -> AssemblyProvenance {
        let parameters = AssemblyParameters(
            mode: config.mode.rawValue,
            kmerSizes: config.kmerSizes.map { $0.map(String.init).joined(separator: ",") } ?? "auto",
            memoryGB: config.memoryGB,
            threads: config.threads,
            skipErrorCorrection: config.skipErrorCorrection,
            minContigLength: config.minContigLength,
            extraArgs: AdvancedCommandLineOptions.join(config.customArgs),
            advancedArguments: config.customArgs
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
            steps: steps,
            statistics: result.statistics
        )
    }

    /// Creates a provenance record from a managed assembly request and result.
    ///
    /// `request` is the request the assembler ran, whose inputs are the
    /// execution files. `requestedInputURLs` are the inputs the user chose,
    /// recorded as ``AssemblyProvenance/requestedInputs``.
    public static func build(
        request: AssemblyRunRequest,
        result: AssemblyResult,
        inputRecords: [InputFileRecord],
        requestedInputURLs: [URL]? = nil,
        steps: [ProvenanceStep] = [],
        lungfishVersion: String = "1.0.0"
    ) -> AssemblyProvenance {
        let parameters = AssemblyParameters(
            mode: request.selectedProfileID ?? "default",
            kmerSizes: "managed",
            memoryGB: request.memoryGB ?? 0,
            threads: request.threads,
            skipErrorCorrection: request.extraArguments.contains("--only-assembler"),
            minContigLength: request.effectiveMinContigLength ?? 0,
            extraArgs: AdvancedCommandLineOptions.join(request.extraArguments),
            advancedArguments: request.extraArguments,
            profileBasis: request.profileSelectionBasis
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
            requestedInputs: requestedInputURLs?.map(\.standardizedFileURL.path),
            steps: steps,
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
        let sha256: String? = size <= maxHashSizeBytes ? (try? FileDigest.sha256(of: url)) : nil

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

}
