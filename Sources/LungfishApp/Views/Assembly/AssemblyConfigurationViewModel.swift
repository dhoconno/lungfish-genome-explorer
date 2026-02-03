// AssemblyConfigurationViewModel.swift - View model for assembly configuration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import Foundation
import SwiftUI
import Combine
import os.log

/// Logger for assembly configuration operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "AssemblyConfiguration")

// MARK: - Assembly Algorithm

/// Supported assembly algorithms.
public enum AssemblyAlgorithm: String, CaseIterable, Identifiable {
    case auto = "Auto-select"
    case spades = "SPAdes"
    case megahit = "MEGAHIT"

    public var id: String { rawValue }

    /// SF Symbol for the algorithm
    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .spades: return "cpu"
        case .megahit: return "bolt"
        }
    }

    /// Description of the algorithm
    var description: String {
        switch self {
        case .auto:
            return "Automatically select the best algorithm based on input size and available resources"
        case .spades:
            return "SPAdes: Accurate de novo assembly, optimal for smaller genomes and isolates"
        case .megahit:
            return "MEGAHIT: Fast and memory-efficient, suitable for large metagenomes"
        }
    }

    /// Docker image for the algorithm
    var dockerImage: String {
        switch self {
        case .auto, .spades:
            return "staphb/spades:latest"
        case .megahit:
            return "vout/megahit:latest"
        }
    }

    /// Recommended memory in GB
    var recommendedMemoryGB: Int {
        switch self {
        case .auto, .spades:
            return 16
        case .megahit:
            return 8
        }
    }
}

// MARK: - Assembly State

/// Represents the current state of an assembly job.
public enum AssemblyState: Equatable {
    case idle
    case validating
    case preparing
    case running(progress: Double?, stage: String)
    case completed(outputPath: String)
    case failed(error: String)
    case cancelled

    var isInProgress: Bool {
        switch self {
        case .validating, .preparing, .running:
            return true
        default:
            return false
        }
    }

    var statusMessage: String {
        switch self {
        case .idle:
            return "Ready to start assembly"
        case .validating:
            return "Validating input files..."
        case .preparing:
            return "Preparing assembly environment..."
        case .running(_, let stage):
            return stage.isEmpty ? "Running assembly..." : stage
        case .completed(let path):
            return "Assembly complete: \(path)"
        case .failed(let error):
            return "Failed: \(error)"
        case .cancelled:
            return "Assembly cancelled"
        }
    }
}

// MARK: - Input File

/// Represents a FASTQ input file for assembly.
public struct AssemblyInputFile: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let isPaired: Bool
    public var pairedWith: UUID?

    public var filename: String {
        url.lastPathComponent
    }

    public var fileSize: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int64 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return "Unknown size"
    }

    public init(url: URL, isPaired: Bool = false) {
        self.id = UUID()
        self.url = url
        self.isPaired = isPaired
        self.pairedWith = nil
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: AssemblyInputFile, rhs: AssemblyInputFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - K-mer Configuration

/// K-mer size configuration for assembly.
public struct KmerConfiguration: Equatable {
    /// Whether to use automatic k-mer selection
    var autoSelect: Bool = true

    /// Custom k-mer sizes (odd numbers only, typically 21-127)
    var customKmers: [Int] = [21, 33, 55, 77, 99, 127]

    /// Validates the k-mer configuration
    var isValid: Bool {
        if autoSelect { return true }
        return !customKmers.isEmpty && customKmers.allSatisfy { $0 % 2 == 1 && $0 >= 11 && $0 <= 127 }
    }

    /// K-mer sizes as a comma-separated string for display
    var displayString: String {
        if autoSelect { return "Auto" }
        return customKmers.map(String.init).joined(separator: ", ")
    }
}

// MARK: - Validation Result

/// Result of configuration validation.
public struct AssemblyValidationResult {
    let isValid: Bool
    let errors: [String]
    let warnings: [String]

    static var valid: AssemblyValidationResult {
        AssemblyValidationResult(isValid: true, errors: [], warnings: [])
    }

    static func invalid(errors: [String], warnings: [String] = []) -> AssemblyValidationResult {
        AssemblyValidationResult(isValid: false, errors: errors, warnings: warnings)
    }
}

// MARK: - AssemblyConfigurationViewModel

/// View model for the assembly configuration sheet.
///
/// Manages all configuration options for sequence assembly, including:
/// - Algorithm selection (SPAdes, MEGAHIT, auto)
/// - Input file management
/// - Output location
/// - Resource allocation (memory, threads)
/// - K-mer size configuration
/// - Progress tracking during assembly
@MainActor
public class AssemblyConfigurationViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Selected assembly algorithm
    @Published public var algorithm: AssemblyAlgorithm = .auto

    /// Input FASTQ files
    @Published public var inputFiles: [AssemblyInputFile] = []

    /// Output directory URL
    @Published public var outputDirectory: URL?

    /// Output project name (used for output folder naming)
    @Published public var projectName: String = "assembly_output"

    /// Maximum memory to use in GB
    @Published public var maxMemoryGB: Double = 8

    /// Maximum number of threads to use
    @Published public var maxThreads: Double = 4

    /// K-mer configuration
    @Published public var kmerConfig: KmerConfiguration = KmerConfiguration()

    /// Custom k-mer string input (for advanced users)
    @Published public var customKmerString: String = "21,33,55,77"

    /// Whether advanced options section is expanded
    @Published public var isAdvancedExpanded: Bool = false

    /// Current assembly state
    @Published public var assemblyState: AssemblyState = .idle

    /// Log output from assembly process
    @Published public var logOutput: [LogEntry] = []

    /// Whether to use paired-end mode
    @Published public var pairedEndMode: Bool = false

    /// Whether to perform error correction (SPAdes only)
    @Published public var performErrorCorrection: Bool = true

    /// Whether to use careful mode for mismatch correction (SPAdes only)
    @Published public var carefulMode: Bool = false

    /// Minimum contig length to report
    @Published public var minContigLength: Int = 200

    // MARK: - Computed Properties

    /// Available system memory in GB
    public var availableMemoryGB: Int {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return Int(totalMemory / (1024 * 1024 * 1024))
    }

    /// Available CPU cores
    public var availableCores: Int {
        ProcessInfo.processInfo.processorCount
    }

    /// Whether the current configuration is valid for running
    public var canStartAssembly: Bool {
        let validation = validateConfiguration()
        return validation.isValid && !assemblyState.isInProgress
    }

    /// Estimated memory requirement based on input file sizes
    public var estimatedMemoryRequirement: String {
        let totalSize: Int64 = inputFiles.reduce(0) { total, file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
            return total + (attributes?[.size] as? Int64 ?? 0)
        }
        // Rough estimate: assembly typically needs 2-10x input size in memory
        let estimatedBytes = totalSize * 5
        return ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .memory)
    }

    /// Formatted output path
    public var fullOutputPath: String {
        guard let outputDir = outputDirectory else { return "Not selected" }
        return outputDir.appendingPathComponent(projectName).path
    }

    // MARK: - Callbacks

    /// Called when assembly completes successfully
    public var onAssemblyComplete: ((URL) -> Void)?

    /// Called when assembly fails
    public var onAssemblyFailed: ((String) -> Void)?

    /// Called when user cancels the configuration
    public var onCancel: (() -> Void)?

    // MARK: - Private Properties

    private var assemblyTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init() {
        // Set default output directory to user's Documents folder
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        outputDirectory = documentsURL?.appendingPathComponent("Lungfish-Assemblies")

        // Set reasonable defaults based on system resources
        maxMemoryGB = min(Double(availableMemoryGB) * 0.75, 32)
        maxThreads = min(Double(availableCores), 8)

        setupKmerStringBinding()

        logger.info("AssemblyConfigurationViewModel initialized: memory=\(self.availableMemoryGB)GB, cores=\(self.availableCores)")
    }

    /// Sets up two-way binding for custom k-mer string
    private func setupKmerStringBinding() {
        // Update customKmerString when kmerConfig changes
        $kmerConfig
            .map { config -> String in
                if config.autoSelect { return "" }
                return config.customKmers.map(String.init).joined(separator: ",")
            }
            .assign(to: &$customKmerString)
    }

    // MARK: - Input File Management

    /// Adds input files from URLs.
    ///
    /// - Parameter urls: File URLs to add
    public func addInputFiles(_ urls: [URL]) {
        for url in urls {
            // Check if file is already added
            guard !inputFiles.contains(where: { $0.url == url }) else {
                logger.debug("File already added: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            let file = AssemblyInputFile(url: url)
            inputFiles.append(file)
            logger.info("Added input file: \(url.lastPathComponent, privacy: .public)")
        }

        // Auto-detect paired-end files
        detectPairedEndFiles()
    }

    /// Removes an input file.
    ///
    /// - Parameter file: The file to remove
    public func removeInputFile(_ file: AssemblyInputFile) {
        inputFiles.removeAll { $0.id == file.id }

        // Also remove any paired relationship
        if let pairedId = file.pairedWith {
            if let index = inputFiles.firstIndex(where: { $0.id == pairedId }) {
                inputFiles[index].pairedWith = nil
            }
        }

        logger.info("Removed input file: \(file.filename, privacy: .public)")
    }

    /// Clears all input files.
    public func clearInputFiles() {
        inputFiles.removeAll()
        logger.info("Cleared all input files")
    }

    /// Attempts to auto-detect paired-end files based on naming conventions.
    private func detectPairedEndFiles() {
        // Common paired-end naming patterns: _R1/_R2, _1/_2, .1/.2
        let patterns = [
            ("_R1", "_R2"),
            ("_1", "_2"),
            (".1", ".2"),
            ("_r1", "_r2"),
            ("_forward", "_reverse"),
        ]

        for i in 0..<inputFiles.count {
            guard inputFiles[i].pairedWith == nil else { continue }

            let baseName = inputFiles[i].url.deletingPathExtension().lastPathComponent

            for (pattern1, pattern2) in patterns {
                if baseName.contains(pattern1) {
                    let expectedPairName = baseName.replacingOccurrences(of: pattern1, with: pattern2)

                    if let pairIndex = inputFiles.firstIndex(where: {
                        $0.url.deletingPathExtension().lastPathComponent == expectedPairName
                    }) {
                        inputFiles[i].pairedWith = inputFiles[pairIndex].id
                        inputFiles[pairIndex].pairedWith = inputFiles[i].id
                        pairedEndMode = true
                        logger.info("Detected paired-end: \(self.inputFiles[i].filename, privacy: .public) <-> \(self.inputFiles[pairIndex].filename, privacy: .public)")
                        break
                    }
                }
            }
        }
    }

    // MARK: - Validation

    /// Validates the current configuration.
    ///
    /// - Returns: Validation result with any errors or warnings
    public func validateConfiguration() -> AssemblyValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Check input files
        if inputFiles.isEmpty {
            errors.append("No input files selected")
        }

        // Check output directory
        if outputDirectory == nil {
            errors.append("No output directory selected")
        }

        // Check project name
        if projectName.isEmpty {
            errors.append("Project name is required")
        } else if projectName.contains("/") || projectName.contains("\\") {
            errors.append("Project name cannot contain path separators")
        }

        // Check memory allocation
        if Int(maxMemoryGB) > availableMemoryGB {
            warnings.append("Allocated memory exceeds available system memory")
        }

        if maxMemoryGB < Double(algorithm.recommendedMemoryGB) {
            warnings.append("Allocated memory is below recommended (\(algorithm.recommendedMemoryGB)GB) for \(algorithm.rawValue)")
        }

        // Check k-mer configuration
        if !kmerConfig.autoSelect {
            let kmers = parseKmerString(customKmerString)
            if kmers.isEmpty {
                errors.append("Invalid k-mer configuration")
            } else {
                for k in kmers {
                    if k % 2 == 0 {
                        errors.append("K-mer sizes must be odd numbers (found \(k))")
                        break
                    }
                    if k < 11 || k > 127 {
                        errors.append("K-mer sizes must be between 11 and 127 (found \(k))")
                        break
                    }
                }
            }
        }

        // Check paired-end consistency
        if pairedEndMode {
            let pairedCount = inputFiles.filter { $0.pairedWith != nil }.count
            if pairedCount % 2 != 0 {
                warnings.append("Odd number of paired files detected")
            }
        }

        if errors.isEmpty {
            return .valid
        }
        return .invalid(errors: errors, warnings: warnings)
    }

    /// Parses a comma-separated k-mer string into integers.
    private func parseKmerString(_ string: String) -> [Int] {
        return string
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .sorted()
    }

    // MARK: - Assembly Execution

    /// Starts the assembly process.
    ///
    /// This method validates the configuration, prepares the environment,
    /// and launches the assembly in a container.
    public func startAssembly() {
        guard canStartAssembly else {
            logger.warning("Cannot start assembly: validation failed or already in progress")
            return
        }

        logger.info("Starting assembly with algorithm: \(self.algorithm.rawValue, privacy: .public)")

        assemblyState = .validating
        logOutput.removeAll()
        appendLog("Starting assembly...", level: .info)
        appendLog("Algorithm: \(algorithm.rawValue)", level: .info)
        appendLog("Input files: \(inputFiles.count)", level: .info)

        assemblyTask = Task { [weak self] in
            guard let self = self else { return }

            // Validate
            let validation = self.validateConfiguration()
            if !validation.isValid {
                await MainActor.run {
                    self.assemblyState = .failed(error: validation.errors.joined(separator: "; "))
                    self.appendLog("Validation failed: \(validation.errors.joined(separator: ", "))", level: .error)
                }
                return
            }

            for warning in validation.warnings {
                await MainActor.run {
                    self.appendLog("Warning: \(warning)", level: .warning)
                }
            }

            // Prepare
            await MainActor.run {
                self.assemblyState = .preparing
                self.appendLog("Preparing assembly environment...", level: .info)
            }

            // Create output directory
            do {
                let outputPath = self.outputDirectory!.appendingPathComponent(self.projectName)
                try FileManager.default.createDirectory(at: outputPath, withIntermediateDirectories: true)
                await MainActor.run {
                    self.appendLog("Created output directory: \(outputPath.path)", level: .info)
                }
            } catch {
                await MainActor.run {
                    self.assemblyState = .failed(error: "Failed to create output directory: \(error.localizedDescription)")
                    self.appendLog("Error: \(error.localizedDescription)", level: .error)
                }
                return
            }

            // Simulate assembly stages (placeholder for actual container execution)
            await self.simulateAssembly()
        }
    }

    /// Simulates assembly execution for UI development.
    ///
    /// In production, this would be replaced with actual container execution.
    private func simulateAssembly() async {
        let stages = [
            (0.1, "Reading input files..."),
            (0.2, "Building k-mer graph..."),
            (0.4, "Performing error correction..."),
            (0.6, "Assembling contigs..."),
            (0.8, "Scaffolding..."),
            (0.9, "Writing output..."),
        ]

        for (progress, stage) in stages {
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.assemblyState = .cancelled
                    self.appendLog("Assembly cancelled by user", level: .warning)
                }
                return
            }

            await MainActor.run {
                self.assemblyState = .running(progress: progress, stage: stage)
                self.appendLog(stage, level: .info)
            }

            // Simulate work
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Complete
        let outputPath = outputDirectory!.appendingPathComponent(projectName)
        await MainActor.run {
            self.assemblyState = .completed(outputPath: outputPath.path)
            self.appendLog("Assembly completed successfully!", level: .info)
            self.appendLog("Output: \(outputPath.path)", level: .info)
            self.onAssemblyComplete?(outputPath)
        }
    }

    /// Cancels the current assembly.
    public func cancelAssembly() {
        assemblyTask?.cancel()
        assemblyTask = nil
        assemblyState = .cancelled
        appendLog("Assembly cancelled", level: .warning)
        logger.info("Assembly cancelled by user")
    }

    // MARK: - Logging

    /// Appends a log entry.
    public func appendLog(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        logOutput.append(entry)
    }

    /// Log entry for assembly output.
    public struct LogEntry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
        public let level: LogLevel

        public var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: timestamp)
        }
    }

    /// Log level for assembly messages.
    public enum LogLevel: String {
        case debug
        case info
        case warning
        case error

        public var color: Color {
            switch self {
            case .debug: return .gray
            case .info: return .primary
            case .warning: return .orange
            case .error: return .red
            }
        }

        public var icon: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.circle"
            }
        }
    }

    // MARK: - Preset Configurations

    /// Applies a preset configuration for bacterial isolate assembly.
    public func applyBacterialIsolatePreset() {
        algorithm = .spades
        maxMemoryGB = min(16, Double(availableMemoryGB))
        maxThreads = min(8, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        carefulMode = true
        minContigLength = 500
        logger.info("Applied bacterial isolate preset")
    }

    /// Applies a preset configuration for metagenome assembly.
    public func applyMetagenomePreset() {
        algorithm = .megahit
        maxMemoryGB = min(Double(availableMemoryGB) * 0.8, 64)
        maxThreads = Double(availableCores)
        kmerConfig.autoSelect = false
        customKmerString = "21,29,39,59,79,99,119"
        kmerConfig.customKmers = parseKmerString(customKmerString)
        performErrorCorrection = false
        carefulMode = false
        minContigLength = 200
        logger.info("Applied metagenome preset")
    }

    /// Applies a preset configuration for viral assembly.
    public func applyViralPreset() {
        algorithm = .spades
        maxMemoryGB = min(8, Double(availableMemoryGB))
        maxThreads = min(4, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        carefulMode = true
        minContigLength = 100
        logger.info("Applied viral preset")
    }
}
