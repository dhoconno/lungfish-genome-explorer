// AssemblyConfigurationViewModel.swift - View model for SPAdes assembly configuration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import Combine
import os.log
import UserNotifications
import LungfishWorkflow
import LungfishIO

/// Logger for assembly configuration operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "AssemblyConfiguration")

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

/// View model for the SPAdes assembly configuration sheet.
///
/// Input files and output directory are set externally by the caller
/// (typically the AppDelegate, which passes selected sidebar files and
/// the project's `Assemblies/` directory). The dialog only exposes
/// SPAdes-specific knobs: mode, resources, k-mer sizes, error correction.
@MainActor
public class AssemblyConfigurationViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Input file URLs (set by caller, read-only in the UI)
    @Published public var inputFileURLs: [URL] = []

    /// Output directory (set by caller, not user-editable)
    @Published public var outputDirectory: URL?

    /// Output project name (auto-generated from input files)
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

    /// Whether to perform error correction (SPAdes only)
    @Published public var performErrorCorrection: Bool = true

    /// SPAdes assembly mode (isolate, meta, plasmid, rna, bio)
    @Published public var spadesMode: SPAdesMode = .isolate

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

    /// Whether paired-end reads were auto-detected
    public var hasPairedEndReads: Bool {
        !detectedForwardReads.isEmpty && !detectedReverseReads.isEmpty
    }

    /// Summary of input files for display
    public var inputSummary: String {
        if inputFileURLs.isEmpty { return "No files selected" }
        let totalSize = inputFileURLs.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        if hasPairedEndReads {
            let unpairedCount = detectedUnpairedReads.count
            var parts = ["\(detectedForwardReads.count) paired-end pair\(detectedForwardReads.count == 1 ? "" : "s")"]
            if unpairedCount > 0 {
                parts.append("\(unpairedCount) unpaired")
            }
            return parts.joined(separator: ", ") + " (\(sizeStr))"
        }
        return "\(inputFileURLs.count) file\(inputFileURLs.count == 1 ? "" : "s") (\(sizeStr))"
    }

    /// Called when user cancels the configuration
    public var onCancel: (() -> Void)?

    /// Called to dismiss the hosting sheet (set by the controller)
    public var onDismiss: (() -> Void)?

    // MARK: - Private Properties

    private var assemblyTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var cancellables = Set<AnyCancellable>()

    /// Auto-detected forward reads (R1)
    private var detectedForwardReads: [URL] = []
    /// Auto-detected reverse reads (R2)
    private var detectedReverseReads: [URL] = []
    /// Unpaired reads (no R1/R2 match)
    private var detectedUnpairedReads: [URL] = []

    // MARK: - Lifecycle

    /// Creates a new view model with pre-set input files and output directory.
    ///
    /// - Parameters:
    ///   - inputFiles: FASTQ file URLs selected in the sidebar
    ///   - outputDirectory: Project's Assemblies/ directory
    public init(inputFiles: [URL] = [], outputDirectory: URL? = nil) {
        self.inputFileURLs = inputFiles
        self.outputDirectory = outputDirectory

        // Set reasonable defaults based on system resources
        maxMemoryGB = min(Double(availableMemoryGB) * 0.75, 32)
        maxThreads = min(Double(availableCores), 8)

        // Auto-generate project name from first input file
        if let first = inputFiles.first {
            let stem = first.deletingPathExtension().lastPathComponent
            // Strip _R1/_R2/_1/_2 suffixes for a clean name
            let cleaned = stem
                .replacingOccurrences(of: "_R1", with: "")
                .replacingOccurrences(of: "_R2", with: "")
                .replacingOccurrences(of: "_1", with: "")
                .replacingOccurrences(of: "_2", with: "")
            projectName = cleaned + "_assembly"
        }

        // Auto-detect paired-end files
        detectPairedEndFiles()

        setupKmerStringBinding()
        requestNotificationPermission()

        logger.info("AssemblyConfigurationViewModel initialized: \(inputFiles.count) files, memory=\(self.availableMemoryGB)GB, cores=\(self.availableCores)")
    }

    /// Sets up two-way binding for custom k-mer string
    private func setupKmerStringBinding() {
        $kmerConfig
            .map { config -> String in
                if config.autoSelect { return "" }
                return config.customKmers.map(String.init).joined(separator: ",")
            }
            .assign(to: &$customKmerString)
    }

    // MARK: - Paired-End Detection

    /// Auto-detects paired-end files from the input URLs based on naming conventions.
    private func detectPairedEndFiles() {
        let patterns: [(String, String)] = [
            ("_R1", "_R2"),
            ("_1.", "_2."),
            ("_r1", "_r2"),
            ("_forward", "_reverse"),
        ]

        var forward: [URL] = []
        var reverse: [URL] = []
        var matched = Set<URL>()

        for url in inputFileURLs {
            guard !matched.contains(url) else { continue }
            let name = url.lastPathComponent

            var foundPair = false
            for (p1, p2) in patterns {
                if name.contains(p1) {
                    let pairName = name.replacingOccurrences(of: p1, with: p2)
                    if let pair = inputFileURLs.first(where: { $0.lastPathComponent == pairName }) {
                        forward.append(url)
                        reverse.append(pair)
                        matched.insert(url)
                        matched.insert(pair)
                        foundPair = true
                        break
                    }
                } else if name.contains(p2) {
                    let pairName = name.replacingOccurrences(of: p2, with: p1)
                    if let pair = inputFileURLs.first(where: { $0.lastPathComponent == pairName }) {
                        forward.append(pair)
                        reverse.append(url)
                        matched.insert(url)
                        matched.insert(pair)
                        foundPair = true
                        break
                    }
                }
            }

            if !foundPair {
                // Will be added to unpaired below
            }
        }

        detectedForwardReads = forward
        detectedReverseReads = reverse
        detectedUnpairedReads = inputFileURLs.filter { !matched.contains($0) }

        if !forward.isEmpty {
            logger.info("Auto-detected \(forward.count) paired-end pair(s), \(self.detectedUnpairedReads.count) unpaired")
        }
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                logger.warning("Notification authorization error: \(error)")
            }
        }
    }

    // MARK: - Disk Space Check

    public func checkDiskSpace() -> (sufficient: Bool, requiredBytes: Int64, availableBytes: Int64) {
        guard let outputDir = outputDirectory else {
            return (true, 0, 0)
        }

        let totalInputBytes: Int64 = inputFileURLs.reduce(0) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        let requiredBytes: Int64 = totalInputBytes * 2 + 1_073_741_824

        do {
            let resourceValues = try outputDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let availableBytes = Int64(resourceValues.volumeAvailableCapacityForImportantUsage ?? 0)
            return (availableBytes >= requiredBytes, requiredBytes, availableBytes)
        } catch {
            logger.warning("Failed to check disk space: \(error)")
            return (true, requiredBytes, 0)
        }
    }

    // MARK: - Validation

    public func validateConfiguration() -> AssemblyValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        if inputFileURLs.isEmpty {
            errors.append("No input files selected")
        }

        if outputDirectory == nil {
            errors.append("No output directory")
        }

        if projectName.isEmpty {
            errors.append("Project name is required")
        }

        if Int(maxMemoryGB) > availableMemoryGB {
            warnings.append("Allocated memory exceeds available system memory")
        }

        if maxMemoryGB < 8 {
            warnings.append("SPAdes recommends at least 8 GB of memory")
        }

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

        if errors.isEmpty {
            return .valid
        }
        return .invalid(errors: errors, warnings: warnings)
    }

    private func parseKmerString(_ string: String) -> [Int] {
        return string
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .sorted()
    }

    // MARK: - Assembly Execution

    public func startAssembly() {
        guard canStartAssembly else {
            logger.warning("Cannot start assembly: validation failed or already in progress")
            return
        }

        if runtimeStatus == .unavailable {
            showNoRuntimeAlert()
            return
        }

        let diskCheck = checkDiskSpace()
        if !diskCheck.sufficient {
            let requiredFormatted = ByteCountFormatter.string(fromByteCount: diskCheck.requiredBytes, countStyle: .file)
            let availableFormatted = ByteCountFormatter.string(fromByteCount: diskCheck.availableBytes, countStyle: .file)
            showDiskSpaceAlert(required: requiredFormatted, available: availableFormatted)
            return
        }

        let validation = validateConfiguration()
        if !validation.isValid {
            assemblyState = .failed(error: validation.errors.joined(separator: "; "))
            return
        }

        logger.info("Starting SPAdes assembly: mode=\(self.spadesMode.displayName, privacy: .public)")

        assemblyState = .preparing

        let forwardReads = detectedForwardReads
        let reverseReads = detectedReverseReads
        let unpairedReads = detectedUnpairedReads
        let kmerSizes: [Int]? = kmerConfig.autoSelect ? nil : parseKmerString(customKmerString)

        guard let outputDir = outputDirectory else {
            assemblyState = .failed(error: "No output directory")
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

        let projectNameCapture = projectName

        // Register with OperationCenter so the task survives sheet dismissal
        let task = Task.detached {
            await AssemblyConfigurationViewModel.runAssemblyOperation(
                config: spadesConfig,
                outputDir: outputDir,
                projectName: projectNameCapture
            )
        }

        let operationID = OperationCenter.shared.start(
            title: "SPAdes Assembly: \(projectNameCapture)",
            detail: "Initializing...",
            operationType: .assembly,
            onCancel: { task.cancel() }
        )
        assemblyTask = task

        // Store the operation ID so notification callbacks can update it
        self.activeOperationID = operationID
    }

    /// Runs the assembly pipeline and reports progress to OperationCenter.
    /// This is a static method so it captures no `self` reference — the sheet
    /// can safely dismiss while this continues in the background.
    private static func runAssemblyOperation(
        config: SPAdesAssemblyConfig,
        outputDir: URL,
        projectName: String
    ) async {
        // Find our operation ID from OperationCenter
        let operationID: UUID? = await MainActor.run {
            OperationCenter.shared.items.first(where: {
                $0.title == "SPAdes Assembly: \(projectName)" && $0.state == .running
            })?.id
        }

        guard let opID = operationID else {
            logger.error("Assembly operation not found in OperationCenter")
            return
        }

        do {
            let runtime = try await AppleContainerRuntime()

            await MainActor.run {
                OperationCenter.shared.update(id: opID, progress: 0.02, detail: "Container runtime initialized")
            }

            let pipeline = SPAdesAssemblyPipeline()
            let result = try await pipeline.run(
                config: config,
                runtime: runtime
            ) { fraction, message in
                // Scale pipeline progress to 0.02–0.95
                let scaledProgress = 0.02 + fraction * 0.93
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                    }
                }
            }

            let stats = result.statistics
            logger.info("Assembly stats: contigs=\(stats.contigCount), N50=\(stats.n50), total=\(stats.totalLengthBP)bp")

            await MainActor.run {
                OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Creating reference bundle...")
            }

            let inputRecords = config.allInputFiles.map { url in
                ProvenanceBuilder.inputRecord(for: url)
            }
            let provenance = ProvenanceBuilder.build(
                config: config,
                result: result,
                inputRecords: inputRecords
            )

            let bundleBuilder = AssemblyBundleBuilder()
            let bundleURL = try await bundleBuilder.build(
                result: result,
                config: config,
                provenance: provenance,
                outputDirectory: outputDir,
                bundleName: projectName
            ) { fraction, message in
                let overallFraction = 0.95 + fraction * 0.05
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: overallFraction, detail: message)
                    }
                }
            }

            await MainActor.run {
                OperationCenter.shared.complete(id: opID, detail: "Assembly complete", bundleURLs: [bundleURL])
            }

            postAssemblyNotificationStatic(
                title: "Assembly Complete",
                body: "Project \"\(projectName)\" assembled successfully.",
                isSuccess: true
            )

        } catch is CancellationError {
            await MainActor.run {
                OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
            }
        } catch {
            let errorMessage = "\(error)"
            logger.error("Assembly failed: \(error)")
            await MainActor.run {
                OperationCenter.shared.fail(id: opID, detail: errorMessage)
            }

            postAssemblyNotificationStatic(
                title: "Assembly Failed",
                body: "Project \"\(projectName)\" failed: \(errorMessage)",
                isSuccess: false
            )
        }
    }

    private static func postAssemblyNotificationStatic(title: String, body: String, isSuccess: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isSuccess ? .default : UNNotificationSound.defaultCritical

        let request = UNNotificationRequest(
            identifier: "assembly-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                logger.warning("Failed to post notification: \(error)")
            }
        }
    }

    public func cancelAssembly() {
        assemblyTask?.cancel()
        assemblyTask = nil
        if let opID = activeOperationID {
            OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
            activeOperationID = nil
        }
        assemblyState = .cancelled
        logger.info("Assembly cancelled by user")
    }

    // MARK: - Alert Helpers

    private func showNoRuntimeAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Container Runtime Unavailable"
        alert.informativeText = """
            No container runtime is available on this system. \
            SPAdes assembly requires Apple Containers to run.

            Requirements:
            - macOS 26 (Tahoe) or later
            - Apple Silicon Mac

            Please ensure your system meets these requirements and try again.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        logger.warning("Assembly blocked: no container runtime available")
    }

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

    // MARK: - Preset Configurations

    public func applyBacterialIsolatePreset() {
        spadesMode = .isolate
        maxMemoryGB = min(16, Double(availableMemoryGB))
        maxThreads = min(8, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        minContigLength = 500
    }

    public func applyMetagenomePreset() {
        spadesMode = .meta
        maxMemoryGB = min(Double(availableMemoryGB) * 0.8, 64)
        maxThreads = Double(availableCores)
        kmerConfig.autoSelect = false
        customKmerString = "21,33,55,77"
        kmerConfig.customKmers = parseKmerString(customKmerString)
        performErrorCorrection = false
        minContigLength = 200
    }

    public func applyViralPreset() {
        spadesMode = .isolate
        maxMemoryGB = min(8, Double(availableMemoryGB))
        maxThreads = min(4, Double(availableCores))
        kmerConfig.autoSelect = true
        performErrorCorrection = true
        minContigLength = 100
    }
}
