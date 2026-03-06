// AssemblyConfigurationViewModel.swift - View model for assembly configuration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import Foundation
import SwiftUI
import Combine
import os.log
import UserNotifications
import LungfishWorkflow
import LungfishIO

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

    /// Container image reference for the algorithm (arm64-native).
    var containerImage: String {
        switch self {
        case .auto, .spades:
            return SPAdesAssemblyPipeline.spadesImageReference
        case .megahit:
            return "docker.io/lungfish/megahit:1.2.9-arm64"
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

// MARK: - Runtime Status

/// Represents the container runtime availability status.
public enum RuntimeStatus {
    case checking
    case available
    case unavailable
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

    /// Returns the file size in bytes, or 0 if unavailable.
    public var fileSizeBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
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

    /// SPAdes assembly mode (isolate, meta, plasmid, rna, bio)
    @Published public var spadesMode: SPAdesMode = .isolate

    /// Elapsed time since assembly started
    @Published public var elapsedTime: TimeInterval = 0

    /// Minimum contig length to report
    @Published public var minContigLength: Int = 200

    /// Container runtime availability status.
    @Published public var runtimeStatus: RuntimeStatus = .checking

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
    private var elapsedTimer: Timer?
    private var assemblyStartTime: Date?

    // MARK: - Lifecycle

    deinit {
        MainActor.assumeIsolated {
            elapsedTimer?.invalidate()
        }
    }

    public init() {
        // Set default output directory to user's Documents folder
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        outputDirectory = documentsURL?.appendingPathComponent("Lungfish-Assemblies")

        // Set reasonable defaults based on system resources
        maxMemoryGB = min(Double(availableMemoryGB) * 0.75, 32)
        maxThreads = min(Double(availableCores), 8)

        setupKmerStringBinding()
        requestNotificationPermission()

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

    // MARK: - Runtime Availability

    /// Checks whether a container runtime is available and updates `runtimeStatus`.
    public func checkRuntimeAvailability() {
        runtimeStatus = .checking
        Task {
            let available = await NewContainerRuntimeFactory.createRuntime() != nil
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.runtimeStatus = available ? .available : .unavailable
                    logger.info("Runtime availability check: \(available ? "available" : "unavailable")")
                }
            }
        }
    }

    // MARK: - Notifications

    /// Requests permission to deliver user notifications on assembly completion.
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                logger.warning("Notification authorization error: \(error)")
            } else {
                logger.debug("Notification authorization granted: \(granted)")
            }
        }
    }

    /// Posts a user notification for assembly completion or failure.
    ///
    /// - Parameters:
    ///   - title: Notification title
    ///   - body: Notification body text
    ///   - isSuccess: Whether the assembly succeeded (determines notification category)
    private func postAssemblyNotification(title: String, body: String, isSuccess: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isSuccess ? .default : UNNotificationSound.defaultCritical

        let request = UNNotificationRequest(
            identifier: "assembly-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                logger.warning("Failed to post notification: \(error)")
            }
        }
    }

    // MARK: - Disk Space Check

    /// Checks whether there is sufficient disk space at the output directory for assembly.
    ///
    /// SPAdes requires at least 2x the total input file size plus 1 GB overhead.
    ///
    /// - Returns: A tuple of (sufficient, requiredBytes, availableBytes).
    ///   Returns `(true, 0, 0)` if the output directory is not set.
    public func checkDiskSpace() -> (sufficient: Bool, requiredBytes: Int64, availableBytes: Int64) {
        guard let outputDir = outputDirectory else {
            return (true, 0, 0)
        }

        let totalInputBytes: Int64 = inputFiles.reduce(0) { $0 + $1.fileSizeBytes }
        let requiredBytes: Int64 = totalInputBytes * 2 + 1_073_741_824 // 2x input + 1 GB

        do {
            let resourceValues = try outputDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let availableBytes = Int64(resourceValues.volumeAvailableCapacityForImportantUsage ?? 0)
            return (availableBytes >= requiredBytes, requiredBytes, availableBytes)
        } catch {
            logger.warning("Failed to check disk space: \(error)")
            // If we cannot determine available space, proceed anyway
            return (true, requiredBytes, 0)
        }
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
    /// Validates configuration, checks runtime availability and disk space,
    /// creates an `SPAdesAssemblyConfig`, runs the pipeline via Apple Containers,
    /// then builds a `.lungfishref` bundle.
    public func startAssembly() {
        guard canStartAssembly else {
            logger.warning("Cannot start assembly: validation failed or already in progress")
            return
        }

        // Pre-flight: check runtime availability
        if runtimeStatus == .unavailable {
            showNoRuntimeAlert()
            return
        }

        // Pre-flight: check disk space
        let diskCheck = checkDiskSpace()
        if !diskCheck.sufficient {
            let requiredFormatted = ByteCountFormatter.string(fromByteCount: diskCheck.requiredBytes, countStyle: .file)
            let availableFormatted = ByteCountFormatter.string(fromByteCount: diskCheck.availableBytes, countStyle: .file)
            showDiskSpaceAlert(required: requiredFormatted, available: availableFormatted)
            return
        }

        logger.info("Starting assembly with mode: \(self.spadesMode.displayName, privacy: .public)")

        assemblyState = .validating
        logOutput.removeAll()
        elapsedTime = 0
        appendLog("Starting assembly...", level: .info)
        appendLog("Mode: \(spadesMode.displayName)", level: .info)
        appendLog("Input files: \(inputFiles.count)", level: .info)

        // Validate
        let validation = validateConfiguration()
        if !validation.isValid {
            assemblyState = .failed(error: validation.errors.joined(separator: "; "))
            appendLog("Validation failed: \(validation.errors.joined(separator: ", "))", level: .error)
            return
        }

        for warning in validation.warnings {
            appendLog("Warning: \(warning)", level: .warning)
        }

        assemblyState = .preparing
        appendLog("Preparing assembly environment...", level: .info)
        startElapsedTimer()

        // Build SPAdes config from ViewModel state
        // Use pairedWith UUIDs to correctly identify R1/R2 pairs.
        // For each pair, the file whose ID is less than its partner's is forward (R1).
        var forwardReads: [URL] = []
        var reverseReads: [URL] = []
        var unpairedReads: [URL] = []

        if pairedEndMode {
            var seen = Set<UUID>()
            for file in inputFiles {
                guard let partnerID = file.pairedWith, !seen.contains(file.id) else {
                    if file.pairedWith == nil {
                        unpairedReads.append(file.url)
                    }
                    continue
                }
                seen.insert(file.id)
                seen.insert(partnerID)

                if let partner = inputFiles.first(where: { $0.id == partnerID }) {
                    // Use naming convention: file containing _R1/_1/_forward is forward
                    let name = file.url.lastPathComponent.lowercased()
                    let isForward = name.contains("_r1") || name.contains("_1.") || name.contains("_forward")
                    if isForward {
                        forwardReads.append(file.url)
                        reverseReads.append(partner.url)
                    } else {
                        forwardReads.append(partner.url)
                        reverseReads.append(file.url)
                    }
                }
            }
        } else {
            unpairedReads = inputFiles.map(\.url)
        }

        let kmerSizes: [Int]? = kmerConfig.autoSelect ? nil : parseKmerString(customKmerString)

        guard let outputDir = outputDirectory else {
            stopElapsedTimer()
            assemblyState = .failed(error: "No output directory selected")
            return
        }

        let spadesConfig = SPAdesAssemblyConfig(
            mode: spadesMode,
            forwardReads: forwardReads,
            reverseReads: reverseReads,
            unpairedReads: unpairedReads,
            kmerSizes: kmerSizes,
            memoryGB: Int(maxMemoryGB),
            threads: Int(maxThreads),
            minContigLength: minContigLength,
            skipErrorCorrection: !performErrorCorrection,
            outputDirectory: outputDir,
            projectName: projectName
        )

        // Capture values for the detached task
        let projectNameCapture = projectName

        assemblyTask = Task.detached { [weak self] in
            do {
                // 1. Initialize Apple Container runtime
                let runtime = try await AppleContainerRuntime()

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.appendLog("Apple Container runtime initialized", level: .info)
                    }
                }

                // 2. Run SPAdes pipeline
                let pipeline = SPAdesAssemblyPipeline()
                let result = try await pipeline.run(
                    config: spadesConfig,
                    runtime: runtime
                ) { [weak self] fraction, message in
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.assemblyState = .running(progress: fraction, stage: message)
                            self?.appendLog(message, level: .info)
                        }
                    }
                }

                // 3. Log assembly statistics
                let stats = result.statistics
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.appendLog("Assembly statistics:", level: .info)
                        self?.appendLog("  Contigs: \(stats.contigCount)", level: .info)
                        self?.appendLog("  Total length: \(stats.totalLengthBP.formatted()) bp", level: .info)
                        self?.appendLog("  N50: \(stats.n50.formatted()) bp", level: .info)
                        self?.appendLog("  GC: \(String(format: "%.1f", stats.gcPercent))%", level: .info)
                    }
                }

                // 4. Build provenance
                let inputRecords = spadesConfig.allInputFiles.map { url in
                    ProvenanceBuilder.inputRecord(for: url)
                }
                let provenance = ProvenanceBuilder.build(
                    config: spadesConfig,
                    result: result,
                    inputRecords: inputRecords
                )

                // 5. Create .lungfishref bundle
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.assemblyState = .running(progress: 0.97, stage: "Creating reference bundle...")
                        self?.appendLog("Creating .lungfishref bundle...", level: .info)
                    }
                }

                let bundleBuilder = AssemblyBundleBuilder()
                let bundleURL = try await bundleBuilder.build(
                    result: result,
                    config: spadesConfig,
                    provenance: provenance,
                    outputDirectory: outputDir,
                    bundleName: projectNameCapture
                ) { [weak self] fraction, message in
                    let overallFraction = 0.95 + fraction * 0.05
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.assemblyState = .running(progress: overallFraction, stage: message)
                        }
                    }
                }

                // 6. Complete
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.stopElapsedTimer()
                        self?.assemblyState = .completed(outputPath: bundleURL.path)
                        self?.appendLog("Bundle created: \(bundleURL.lastPathComponent)", level: .info)
                        self?.appendLog("Assembly completed successfully!", level: .info)
                        self?.onAssemblyComplete?(bundleURL)
                        self?.postAssemblyNotification(
                            title: "Assembly Complete",
                            body: "Project \"\(projectNameCapture)\" assembled successfully.",
                            isSuccess: true
                        )
                    }
                }

            } catch is CancellationError {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.stopElapsedTimer()
                        self?.assemblyState = .cancelled
                        self?.appendLog("Assembly cancelled by user", level: .warning)
                    }
                }
            } catch {
                let errorMessage = "\(error)"
                logger.error("Assembly failed: \(error)")
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.stopElapsedTimer()
                        self?.assemblyState = .failed(error: errorMessage)
                        self?.appendLog("Error: \(errorMessage)", level: .error)
                        self?.onAssemblyFailed?(errorMessage)
                        self?.postAssemblyNotification(
                            title: "Assembly Failed",
                            body: "Project \"\(projectNameCapture)\" failed: \(errorMessage)",
                            isSuccess: false
                        )
                    }
                }
            }
        }
    }

    /// Cancels the current assembly.
    public func cancelAssembly() {
        assemblyTask?.cancel()
        assemblyTask = nil
        stopElapsedTimer()
        assemblyState = .cancelled
        appendLog("Assembly cancelled", level: .warning)
        logger.info("Assembly cancelled by user")
    }

    // MARK: - Alert Helpers

    /// Shows an alert explaining that no container runtime is available.
    private func showNoRuntimeAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Container Runtime Unavailable"
        alert.informativeText = """
            No container runtime is available on this system. \
            Sequence assembly requires a container runtime to execute \
            bioinformatics tools.

            Requirements:
            - macOS 26 (Tahoe) or later on Apple Silicon for native containers
            - Or Docker Desktop installed and running as a fallback

            Please ensure your system meets these requirements and try again.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        logger.warning("Assembly blocked: no container runtime available")
    }

    /// Shows an alert warning that disk space is insufficient.
    ///
    /// - Parameters:
    ///   - required: Formatted string of required disk space
    ///   - available: Formatted string of available disk space
    private func showDiskSpaceAlert(required: String, available: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insufficient Disk Space"
        alert.informativeText = """
            The output directory does not have enough free space for this assembly.

            Required: \(required)
            Available: \(available)

            SPAdes needs at least 2x the total input file size plus 1 GB of overhead. \
            Please free up disk space or choose a different output directory.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        logger.warning("Assembly blocked: insufficient disk space (required=\(required), available=\(available))")
    }

    // MARK: - Elapsed Timer

    private func startElapsedTimer() {
        assemblyStartTime = Date()
        elapsedTime = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let start = self.assemblyStartTime else { return }
                    self.elapsedTime = Date().timeIntervalSince(start)
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Formatted elapsed time string (e.g., "14m 32s").
    public var formattedElapsedTime: String {
        let total = Int(elapsedTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
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
        spadesMode = .isolate
        maxMemoryGB = min(16, Double(availableMemoryGB))
        maxThreads = min(8, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        minContigLength = 500
        logger.info("Applied bacterial isolate preset")
    }

    /// Applies a preset configuration for metagenome assembly.
    public func applyMetagenomePreset() {
        algorithm = .spades
        spadesMode = .meta
        maxMemoryGB = min(Double(availableMemoryGB) * 0.8, 64)
        maxThreads = Double(availableCores)
        kmerConfig.autoSelect = false
        customKmerString = "21,33,55,77"
        kmerConfig.customKmers = parseKmerString(customKmerString)
        performErrorCorrection = false
        minContigLength = 200
        logger.info("Applied metagenome preset")
    }

    /// Applies a preset configuration for viral assembly.
    public func applyViralPreset() {
        algorithm = .spades
        spadesMode = .isolate
        maxMemoryGB = min(8, Double(availableMemoryGB))
        maxThreads = min(4, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        minContigLength = 100
        logger.info("Applied viral preset")
    }

    /// Applies a preset configuration for plasmid assembly.
    public func applyPlasmidPreset() {
        algorithm = .spades
        spadesMode = .plasmid
        maxMemoryGB = min(8, Double(availableMemoryGB))
        maxThreads = min(4, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        minContigLength = 200
        logger.info("Applied plasmid preset")
    }

    /// Applies a preset configuration for RNA assembly.
    public func applyRNAPreset() {
        algorithm = .spades
        spadesMode = .rna
        maxMemoryGB = min(16, Double(availableMemoryGB))
        maxThreads = min(8, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        minContigLength = 200
        logger.info("Applied RNA preset")
    }
}
