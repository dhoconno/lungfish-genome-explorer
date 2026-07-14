// ReferenceBundleBuilder.swift - Bundle creation pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - BuildStep

/// Represents a step in the bundle build process.
public enum BuildStep: String, Sendable, CaseIterable {
    case validating = "Validating input files"
    case creatingStructure = "Creating bundle structure"
    case compressingFASTA = "Compressing FASTA with bgzip"
    case indexingFASTA = "Creating FASTA index"
    case convertingAnnotations = "Indexing annotations"
    case convertingVariants = "Converting variants to BCF"
    case generatingManifest = "Generating manifest"
    case validatingBundle = "Validating bundle integrity"
    case complete = "Complete"

    /// The relative progress weight of this step (0.0 to 1.0).
    public var progressWeight: Double {
        switch self {
        case .validating: return 0.05
        case .creatingStructure: return 0.05
        case .compressingFASTA: return 0.25
        case .indexingFASTA: return 0.15
        case .convertingAnnotations: return 0.20
        case .convertingVariants: return 0.15
        case .generatingManifest: return 0.05
        case .validatingBundle: return 0.05
        // The other eight weights sum to 0.95; `.complete` carries the final
        // 0.05 so all weights sum to 1.0 (asserted by testBuildStepProgressWeights).
        // `.complete` progress is also set explicitly to 1.0 at the end of build.
        case .complete: return 0.05
        }
    }
}

// MARK: - BuildConfiguration

/// Configuration for building a reference genome bundle.
public struct BuildConfiguration: Sendable {

    /// Name of the bundle (displayed in UI).
    public let name: String

    /// Unique identifier for the bundle (reverse-DNS style).
    public let identifier: String

    /// URL to the input FASTA file.
    public let fastaURL: URL

    /// Optional staged indexed metadata for records parsed from a GenBank source.
    public let referenceRecordStoreURL: URL?

    /// Annotation files to include (GFF3, GTF, GenBank, BED).
    public let annotationFiles: [AnnotationInput]

    /// Variant files to include (VCF).
    public let variantFiles: [VariantInput]

    /// Signal track files to include (BigWig, bedGraph).
    public let signalFiles: [SignalInput]

    /// Output directory for the bundle.
    public let outputDirectory: URL

    /// Source metadata.
    public let source: SourceInfo

    /// Whether to compress the FASTA file with bgzip (default: true).
    ///
    /// `ReferenceBundleBuilder` is the Core fallback builder and cannot perform
    /// bgzip, BCF/CSI, or BigWig conversions itself. Use `NativeBundleBuilder`
    /// for compressed or converted scientific outputs.
    public let compressFASTA: Bool

    /// Optional categorized metadata groups for flexible, source-specific metadata storage.
    ///
    /// When provided, these groups are written to the bundle manifest and displayed in the Inspector.
    /// This allows callers (e.g., NCBI download pipelines) to pass through rich metadata
    /// without requiring schema changes to `BuildConfiguration`.
    public let metadata: [MetadataGroup]?

    /// Human-readable workflow/tool name for bundle-level provenance.
    ///
    /// Consumed by `NativeBundleBuilder`. The Core fallback `ReferenceBundleBuilder`
    /// cannot write provenance because canonical provenance lives in LungfishWorkflow,
    /// so it rejects configurations that set any provenance field.
    public let provenanceWorkflowName: String?

    /// Exact argv to store in bundle-level provenance when the builder is called from a CLI workflow.
    ///
    /// Consumed by `NativeBundleBuilder`; Core fallback callers must write provenance
    /// in their owning CLI/workflow layer.
    public let provenanceCommand: [String]?

    /// User-visible input files to record in provenance, replacing temporary staged inputs when needed.
    ///
    /// Consumed by `NativeBundleBuilder`; Core fallback callers must write provenance
    /// in their owning CLI/workflow layer.
    public let provenanceInputFiles: [URL]?

    /// Creates a new build configuration.
    public init(
        name: String,
        identifier: String,
        fastaURL: URL,
        annotationFiles: [AnnotationInput] = [],
        variantFiles: [VariantInput] = [],
        signalFiles: [SignalInput] = [],
        outputDirectory: URL,
        source: SourceInfo,
        compressFASTA: Bool = true,
        metadata: [MetadataGroup]? = nil,
        provenanceWorkflowName: String? = nil,
        provenanceCommand: [String]? = nil,
        provenanceInputFiles: [URL]? = nil,
        referenceRecordStoreURL: URL? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.fastaURL = fastaURL
        self.annotationFiles = annotationFiles
        self.variantFiles = variantFiles
        self.signalFiles = signalFiles
        self.outputDirectory = outputDirectory
        self.source = source
        self.compressFASTA = compressFASTA
        self.metadata = metadata
        self.provenanceWorkflowName = provenanceWorkflowName
        self.provenanceCommand = provenanceCommand
        self.provenanceInputFiles = provenanceInputFiles
        self.referenceRecordStoreURL = referenceRecordStoreURL
    }
}

// MARK: - Input Types

/// Annotation file input for bundle building.
public struct AnnotationInput: Sendable {
    /// URL to the annotation file.
    public let url: URL

    /// Display name for the track.
    public let name: String

    /// Optional description.
    public let description: String?

    /// Track ID (auto-generated from filename if not provided).
    public let id: String

    /// The type of annotation.
    public let annotationType: AnnotationTrackType

    /// Creates a new annotation input.
    public init(
        url: URL,
        name: String,
        description: String? = nil,
        id: String? = nil,
        annotationType: AnnotationTrackType = .custom
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.id = id ?? url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        self.annotationType = annotationType
    }
}

/// Variant file input for bundle building.
public struct VariantInput: Sendable {
    /// URL to the VCF file.
    public let url: URL

    /// Display name for the track.
    public let name: String

    /// Optional description.
    public let description: String?

    /// Track ID (auto-generated from filename if not provided).
    public let id: String

    /// The type of variants.
    public let variantType: VariantTrackType

    /// Creates a new variant input.
    public init(
        url: URL,
        name: String,
        description: String? = nil,
        id: String? = nil,
        variantType: VariantTrackType = .mixed
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.id = id ?? url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        self.variantType = variantType
    }
}

/// Signal track input for bundle building.
public struct SignalInput: Sendable {
    /// URL to the signal file (BigWig or bedGraph).
    public let url: URL

    /// Display name for the track.
    public let name: String

    /// Optional description.
    public let description: String?

    /// Track ID (auto-generated from filename if not provided).
    public let id: String

    /// The type of signal data.
    public let signalType: SignalTrackType

    /// Creates a new signal input.
    public init(
        url: URL,
        name: String,
        description: String? = nil,
        id: String? = nil,
        signalType: SignalTrackType = .custom
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.id = id ?? url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        self.signalType = signalType
    }
}

// MARK: - BuildError

/// Errors that can occur during bundle building.
public enum BundleBuildError: Error, LocalizedError, Sendable {
    /// Input file not found.
    case inputFileNotFound(URL)

    /// Input file is not readable.
    case inputFileNotReadable(URL)

    /// Invalid FASTA file format.
    case invalidFASTAFormat(String)

    /// Failed to create bundle directory structure.
    case directoryCreationFailed(URL, String)

    /// Output bundle already exists.
    case outputBundleAlreadyExists(URL)

    /// FASTA compression failed.
    case compressionFailed(String)

    /// FASTA indexing failed.
    case indexingFailed(String)

    /// Annotation conversion failed.
    case annotationConversionFailed(String, String)

    /// Variant conversion failed.
    case variantConversionFailed(String, String)

    /// Signal track conversion failed.
    case signalConversionFailed(String, String)

    /// Manifest generation failed.
    case manifestGenerationFailed(String)

    /// Bundle validation failed.
    case validationFailed([String])

    /// Provenance configuration was supplied to a builder that cannot write provenance.
    case unsupportedProvenanceConfiguration(String)

    /// Container runtime not available.
    case containerRuntimeNotAvailable

    /// Required tools are missing.
    case missingTools([String])

    /// Build was cancelled.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .inputFileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .inputFileNotReadable(let url):
            return "Cannot read input file: \(url.lastPathComponent)"
        case .invalidFASTAFormat(let reason):
            return "Invalid FASTA format: \(reason)"
        case .directoryCreationFailed(let url, let reason):
            return "Failed to create directory at \(url.path): \(reason)"
        case .outputBundleAlreadyExists(let url):
            return "Output bundle already exists: \(url.path)"
        case .compressionFailed(let reason):
            return "FASTA compression failed: \(reason)"
        case .indexingFailed(let reason):
            return "FASTA indexing failed: \(reason)"
        case .annotationConversionFailed(let file, let reason):
            return "Annotation conversion failed for '\(file)': \(reason)"
        case .variantConversionFailed(let file, let reason):
            return "Variant conversion failed for '\(file)': \(reason)"
        case .signalConversionFailed(let file, let reason):
            return "Signal conversion failed for '\(file)': \(reason)"
        case .manifestGenerationFailed(let reason):
            return "Manifest generation failed: \(reason)"
        case .validationFailed(let errors):
            return "Bundle validation failed:\n" + errors.joined(separator: "\n")
        case .unsupportedProvenanceConfiguration(let reason):
            return "Unsupported provenance configuration: \(reason)"
        case .containerRuntimeNotAvailable:
            return "Container runtime is not available. Requires macOS 26+ on Apple Silicon."
        case .missingTools(let tools):
            return "Required tools are missing: \(tools.joined(separator: ", "))"
        case .cancelled:
            return "Build was cancelled"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .inputFileNotFound:
            return "Verify the file exists and the path is correct."
        case .inputFileNotReadable:
            return "Check file permissions and ensure the file is not locked."
        case .invalidFASTAFormat:
            return "Ensure the file is a valid FASTA format with proper headers."
        case .directoryCreationFailed:
            return "Check disk space and write permissions for the output directory."
        case .outputBundleAlreadyExists:
            return "Choose a different bundle name or remove the existing output bundle before building."
        case .compressionFailed, .indexingFailed:
            return "Ensure the container runtime is working and try again."
        case .annotationConversionFailed:
            return "Verify the annotation file format is correct (GFF3, GTF, or BED)."
        case .variantConversionFailed:
            return "Provide an indexed BCF or use NativeBundleBuilder/CLI bundle creation with bcftools available."
        case .signalConversionFailed:
            return "Provide a BigWig file or use NativeBundleBuilder/CLI bundle creation with bedGraph conversion tools available."
        case .manifestGenerationFailed:
            return "This is an internal error. Please report it."
        case .validationFailed:
            return "Review the validation errors and fix any issues."
        case .unsupportedProvenanceConfiguration:
            return "Use NativeBundleBuilder or write CLI/workflow provenance around the Core fallback build."
        case .containerRuntimeNotAvailable:
            return "Update to macOS 26 or later on an Apple Silicon Mac."
        case .missingTools:
            return "The app bundle is missing required bioinformatics tools. Please reinstall the application or verify the bundle contents."
        case .cancelled:
            return "Restart the build process if needed."
        }
    }
}

// MARK: - ReferenceBundleBuilder

/// Builds `.lungfishref` reference genome bundles from source files.
@MainActor
public final class ReferenceBundleBuilder: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var currentStep: BuildStep = .validating
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var isBuilding: Bool = false
    @Published public private(set) var errors: [String] = []

    // MARK: - Private Properties

    private let logger = Logger(
        subsystem: LogSubsystem.core,
        category: "ReferenceBundleBuilder"
    )

    private var currentBuildTask: Task<URL, Error>?

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    public func build(
        configuration: BuildConfiguration,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)? = nil
    ) async throws -> URL {
        guard !Task.isCancelled else {
            throw BundleBuildError.cancelled
        }

        isBuilding = true
        progress = 0.0
        errors = []

        defer {
            isBuilding = false
            currentBuildTask = nil
        }

        logger.info("Starting bundle build: \(configuration.name)")

        let bundleName = configuration.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let bundleURL = configuration.outputDirectory
            .appendingPathComponent("\(bundleName).lungfishref")
        let executor = ReferenceBundleBuildExecutor(
            configuration: configuration,
            bundleURL: bundleURL
        )
        let task = Task.detached(priority: .userInitiated) { [weak self, progressHandler] in
            try await executor.build { step, progress, message in
                await MainActor.run {
                    self?.updateProgress(step, progress, message, progressHandler)
                }
            }
        }
        currentBuildTask = task

        do {
            let builtBundleURL = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            logger.info("Bundle build complete: \(builtBundleURL.path)")
            return builtBundleURL
        } catch {
            logger.error("Bundle build failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func cancel() {
        currentBuildTask?.cancel()
        logger.info("Build cancellation requested")
    }

    // MARK: - Private Methods

    private func updateProgress(
        _ step: BuildStep,
        _ progress: Double,
        _ message: String,
        _ handler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) {
        self.currentStep = step
        self.progress = progress
        self.statusMessage = message
        handler?(step, progress, message)
    }
}

private struct ReferenceBundleBuildExecutor: Sendable {
    typealias ProgressReporter = @Sendable (BuildStep, Double, String) async -> Void

    let configuration: BuildConfiguration
    let bundleURL: URL

    private let logger = Logger(
        subsystem: LogSubsystem.core,
        category: "ReferenceBundleBuildExecutor"
    )

    func build(progressHandler: @escaping ProgressReporter) async throws -> URL {
        var didCreateBundle = false

        do {
            try checkCancellation()

            try await executeStep(.validating, progressHandler: progressHandler) {
                try validateInputs(configuration)
            }

            try checkCancellation()

            try await executeStep(.creatingStructure, progressHandler: progressHandler) {
                try createBundleStructure(at: bundleURL)
            }
            didCreateBundle = true

            try checkCancellation()

            let genomeInfo = try await processFASTA(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            let annotationInfos = try await processAnnotations(
                configuration: configuration,
                bundleURL: bundleURL,
                chromosomeSizes: genomeInfo.chromosomes.map { ($0.name, $0.length) },
                progressHandler: progressHandler
            )

            try checkCancellation()

            let variantInfos = try await processVariants(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            let signalInfos = try await processSignalTracks(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            try await executeStep(.generatingManifest, progressHandler: progressHandler) {
                let manifest = BundleManifest(
                    name: configuration.name,
                    identifier: configuration.identifier,
                    source: configuration.source,
                    genome: genomeInfo,
                    annotations: annotationInfos,
                    variants: variantInfos,
                    tracks: signalInfos,
                    metadata: configuration.metadata
                )

                try manifest.save(to: bundleURL)
            }

            try checkCancellation()

            try await executeStep(.validatingBundle, progressHandler: progressHandler) {
                try validateBundle(at: bundleURL)
            }

            await updateProgress(.complete, 1.0, "Bundle created successfully", progressHandler)

            return bundleURL

        } catch {
            if didCreateBundle, FileManager.default.fileExists(atPath: bundleURL.path) {
                try? FileManager.default.removeItem(at: bundleURL)
            }

            throw error
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled {
            throw BundleBuildError.cancelled
        }
    }

    private func executeStep(
        _ step: BuildStep,
        progressHandler: ProgressReporter,
        operation: () throws -> Void
    ) async throws {
        await updateProgress(step, calculateProgress(for: step, subProgress: 0.0), step.rawValue, progressHandler)
        try operation()
        await updateProgress(step, calculateProgress(for: step, subProgress: 1.0), step.rawValue, progressHandler)
    }

    private func updateProgress(
        _ step: BuildStep,
        _ progress: Double,
        _ message: String,
        _ handler: ProgressReporter
    ) async {
        await handler(step, progress, message)
    }

    private func calculateProgress(for step: BuildStep, subProgress: Double) -> Double {
        var baseProgress: Double = 0.0

        for s in BuildStep.allCases {
            if s == step {
                return baseProgress + (s.progressWeight * subProgress)
            }
            baseProgress += s.progressWeight
        }

        return baseProgress
    }

    private func validateInputs(_ configuration: BuildConfiguration) throws {
        logger.info("Validating input files")

        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: configuration.fastaURL.path) else {
            throw BundleBuildError.inputFileNotFound(configuration.fastaURL)
        }

        guard fileManager.isReadableFile(atPath: configuration.fastaURL.path) else {
            throw BundleBuildError.inputFileNotReadable(configuration.fastaURL)
        }

        if configuration.provenanceWorkflowName != nil ||
            configuration.provenanceCommand != nil ||
            configuration.provenanceInputFiles != nil {
            throw BundleBuildError.unsupportedProvenanceConfiguration(
                "ReferenceBundleBuilder cannot write provenance; use NativeBundleBuilder or wrap the Core build in CLI/workflow provenance."
            )
        }

        if configuration.compressFASTA {
            throw BundleBuildError.compressionFailed(
                "ReferenceBundleBuilder cannot bgzip-compress FASTA. Use NativeBundleBuilder or CLI bundle creation with bgzip available."
            )
        }

        for annotation in configuration.annotationFiles {
            guard fileManager.fileExists(atPath: annotation.url.path) else {
                throw BundleBuildError.inputFileNotFound(annotation.url)
            }
            guard fileManager.isReadableFile(atPath: annotation.url.path) else {
                throw BundleBuildError.inputFileNotReadable(annotation.url)
            }
        }

        for variant in configuration.variantFiles {
            guard fileManager.fileExists(atPath: variant.url.path) else {
                throw BundleBuildError.inputFileNotFound(variant.url)
            }
            guard fileManager.isReadableFile(atPath: variant.url.path) else {
                throw BundleBuildError.inputFileNotReadable(variant.url)
            }
            guard VariantConverter.InputFormat.detect(from: variant.url) == .bcf else {
                throw BundleBuildError.variantConversionFailed(
                    variant.name,
                    "ReferenceBundleBuilder cannot convert VCF to BCF. Use NativeBundleBuilder or CLI bundle creation with bcftools available."
                )
            }
            let indexURL = bcfIndexURL(for: variant.url)
            guard fileManager.fileExists(atPath: indexURL.path) else {
                throw BundleBuildError.variantConversionFailed(
                    variant.name,
                    "Missing CSI index next to BCF input: \(indexURL.lastPathComponent)"
                )
            }
        }

        for signal in configuration.signalFiles {
            guard fileManager.fileExists(atPath: signal.url.path) else {
                throw BundleBuildError.inputFileNotFound(signal.url)
            }
            guard fileManager.isReadableFile(atPath: signal.url.path) else {
                throw BundleBuildError.inputFileNotReadable(signal.url)
            }
            guard isBigWig(signal.url) else {
                throw BundleBuildError.signalConversionFailed(
                    signal.name,
                    "ReferenceBundleBuilder cannot convert \(signal.url.pathExtension) to BigWig. Use NativeBundleBuilder or CLI bundle creation with bedGraph conversion tools available."
                )
            }
        }

        logger.info("Input validation complete")
    }

    private func createBundleStructure(at bundleURL: URL) throws {
        logger.info("Creating bundle structure at \(bundleURL.path)")

        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: bundleURL.path) {
            throw BundleBuildError.outputBundleAlreadyExists(bundleURL)
        }

        let directories = [
            bundleURL,
            bundleURL.appendingPathComponent("genome"),
            bundleURL.appendingPathComponent("annotations"),
            bundleURL.appendingPathComponent("variants"),
            bundleURL.appendingPathComponent("tracks")
        ]

        for dir in directories {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw BundleBuildError.directoryCreationFailed(dir, error.localizedDescription)
            }
        }

        logger.info("Bundle structure created")
    }

    private func processFASTA(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: ProgressReporter
    ) async throws -> GenomeInfo {
        logger.info("Processing FASTA file")

        let genomeDir = bundleURL.appendingPathComponent("genome")
        let fastaFilename = "sequence.fa"
        let destinationFASTA: URL

        if configuration.compressFASTA {
            await updateProgress(
                .compressingFASTA,
                calculateProgress(for: .compressingFASTA, subProgress: 0.0),
                "Compressing FASTA with bgzip...",
                progressHandler
            )

            throw BundleBuildError.compressionFailed(
                "ReferenceBundleBuilder cannot bgzip-compress FASTA. Use NativeBundleBuilder or CLI bundle creation with bgzip available."
            )
        } else {
            destinationFASTA = genomeDir.appendingPathComponent(fastaFilename)
            try FileManager.default.copyItem(at: configuration.fastaURL, to: destinationFASTA)
        }

        await updateProgress(
            .indexingFASTA,
            calculateProgress(for: .indexingFASTA, subProgress: 0.0),
            "Creating FASTA index...",
            progressHandler
        )

        let chromosomes = try parseFASTAForChromosomes(configuration.fastaURL)

        let indexURL = URL(fileURLWithPath: destinationFASTA.path + ".fai")
        try createFASTAIndex(chromosomes: chromosomes, indexURL: indexURL)

        await updateProgress(
            .indexingFASTA,
            calculateProgress(for: .indexingFASTA, subProgress: 1.0),
            "FASTA indexing complete",
            progressHandler
        )

        let totalLength = chromosomes.reduce(0) { $0 + $1.length }

        let relativePath = configuration.compressFASTA ? "genome/\(fastaFilename).gz" : "genome/\(fastaFilename)"
        let indexPath = "\(relativePath).fai"
        let gzipIndexPath = configuration.compressFASTA ? "\(relativePath).gzi" : nil

        return GenomeInfo(
            path: relativePath,
            indexPath: indexPath,
            gzipIndexPath: gzipIndexPath,
            totalLength: totalLength,
            chromosomes: chromosomes
        )
    }

    private func parseFASTAForChromosomes(_ fastaURL: URL) throws -> [ChromosomeInfo] {
        logger.info("Parsing FASTA for chromosome information")

        let ext = fastaURL.pathExtension.lowercased()

        if ext == "gz" {
            logger.warning("Gzipped FASTA support requires decompression")
        }

        guard let fileHandle = FileHandle(forReadingAtPath: fastaURL.path) else {
            throw BundleBuildError.inputFileNotReadable(fastaURL)
        }
        defer { try? fileHandle.close() }

        var chromosomes: [ChromosomeInfo] = []
        var currentChromName: String?
        var currentLength: Int64 = 0
        var expectedLineBases: Int?
        var expectedLineWidth: Int?
        var sequenceStartOffset: Int64 = 0
        var pendingSequenceLine: FASTASequenceLineMetrics?
        var sawBlankLineInCurrentRecord = false

        var lineKind: FASTALineKind = .undecided
        var headerBytes: [UInt8] = []
        var sequenceLineBases = 0
        var lineByteCount = 0
        var lineStartOffset: Int64 = 0
        var byteOffset: Int64 = 0
        var pendingCarriageReturn = false

        func resetLine() {
            lineKind = .undecided
            headerBytes.removeAll(keepingCapacity: true)
            sequenceLineBases = 0
            lineByteCount = 0
        }

        func validateNonTerminalSequenceLine(
            _ metrics: FASTASequenceLineMetrics,
            contigName: String
        ) throws {
            guard let expectedLineBases, let expectedLineWidth else {
                return
            }

            if metrics.bases != expectedLineBases || metrics.width != expectedLineWidth {
                throw BundleBuildError.invalidFASTAFormat(
                    "Inconsistent sequence line in \(contigName): expected \(expectedLineBases) bases and \(expectedLineWidth) bytes for non-final lines, found \(metrics.bases) bases and \(metrics.width) bytes"
                )
            }
        }

        func validateFinalSequenceLine(
            _ metrics: FASTASequenceLineMetrics,
            contigName: String
        ) throws {
            guard let expectedLineBases, let expectedLineWidth else {
                return
            }

            if metrics.bases > expectedLineBases {
                throw BundleBuildError.invalidFASTAFormat(
                    "Final sequence line in \(contigName) has \(metrics.bases) bases, exceeding the expected \(expectedLineBases)"
                )
            }

            if metrics.width > expectedLineWidth {
                throw BundleBuildError.invalidFASTAFormat(
                    "Final sequence line in \(contigName) has \(metrics.width) bytes, exceeding the expected \(expectedLineWidth)"
                )
            }
        }

        func appendCurrentChromosome() throws {
            guard let chromName = currentChromName else {
                return
            }

            guard let lineBases = expectedLineBases,
                  let lineWidth = expectedLineWidth,
                  currentLength > 0,
                  let pendingSequenceLine else {
                throw BundleBuildError.invalidFASTAFormat("FASTA record \(chromName) contains no sequence")
            }

            try validateFinalSequenceLine(pendingSequenceLine, contigName: chromName)

            let chromInfo = ChromosomeInfo(
                name: chromName,
                length: currentLength,
                offset: sequenceStartOffset,
                lineBases: lineBases,
                lineWidth: lineWidth
            )
            chromosomes.append(chromInfo)
        }

        func processLine(newlineByteCount: Int) throws {
            defer {
                resetLine()
            }

            switch lineKind {
            case .undecided:
                if currentChromName != nil {
                    sawBlankLineInCurrentRecord = true
                }
                return

            case .header:
                try appendCurrentChromosome()

                let headerData = Data(headerBytes)
                guard let headerLine = String(data: headerData, encoding: .utf8) else {
                    throw BundleBuildError.invalidFASTAFormat("Cannot read header as UTF-8")
                }

                let identifier = headerLine
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first
                    .map(String.init)
                guard let identifier, !identifier.isEmpty else {
                    throw BundleBuildError.invalidFASTAFormat("FASTA header is missing a sequence name")
                }

                currentChromName = identifier
                currentLength = 0
                expectedLineBases = nil
                expectedLineWidth = nil
                pendingSequenceLine = nil
                sawBlankLineInCurrentRecord = false
                sequenceStartOffset = lineStartOffset + Int64(lineByteCount + newlineByteCount)

            case .sequence:
                guard sequenceLineBases > 0 else {
                    if currentChromName != nil {
                        sawBlankLineInCurrentRecord = true
                    }
                    return
                }

                guard let chromName = currentChromName else {
                    throw BundleBuildError.invalidFASTAFormat("Sequence data found before the first FASTA header")
                }

                guard !sawBlankLineInCurrentRecord else {
                    throw BundleBuildError.invalidFASTAFormat(
                        "Blank FASTA line in \(chromName) appears before more sequence data"
                    )
                }

                let lineWidthForIndex = lineByteCount + max(newlineByteCount, 1)
                let lineWidthOnDisk = lineByteCount + newlineByteCount

                if let expectedLineBases {
                    if let pendingSequenceLine {
                        try validateNonTerminalSequenceLine(
                            pendingSequenceLine,
                            contigName: chromName
                        )
                    }

                    if sequenceLineBases > expectedLineBases {
                        throw BundleBuildError.invalidFASTAFormat(
                            "Sequence line in \(chromName) has \(sequenceLineBases) bases, exceeding the expected \(expectedLineBases)"
                        )
                    }
                } else {
                    expectedLineBases = sequenceLineBases
                    expectedLineWidth = lineWidthForIndex
                }

                currentLength += Int64(sequenceLineBases)
                pendingSequenceLine = FASTASequenceLineMetrics(
                    bases: sequenceLineBases,
                    width: lineWidthOnDisk
                )
            }
        }

        func appendLineByte(_ byte: UInt8) {
            switch lineKind {
            case .undecided:
                lineKind = byte == UInt8(ascii: ">") ? .header : .sequence
                if lineKind == .sequence && !Self.isFASTASequenceWhitespace(byte) {
                    sequenceLineBases += 1
                }

            case .header:
                headerBytes.append(byte)

            case .sequence:
                if !Self.isFASTASequenceWhitespace(byte) {
                    sequenceLineBases += 1
                }
            }

            lineByteCount += 1
        }

        while true {
            try checkCancellation()

            let data = fileHandle.readData(ofLength: 64 * 1024)
            if data.isEmpty {
                break
            }

            for byte in data {
                byteOffset += 1

                if pendingCarriageReturn {
                    if byte == UInt8(ascii: "\n") {
                        try processLine(newlineByteCount: 2)
                        lineStartOffset = byteOffset
                        pendingCarriageReturn = false
                        continue
                    }

                    throw BundleBuildError.invalidFASTAFormat(
                        "CR-only FASTA line endings are not supported; use LF or CRLF"
                    )
                }

                if byte == UInt8(ascii: "\r") {
                    pendingCarriageReturn = true
                } else if byte == UInt8(ascii: "\n") {
                    try processLine(newlineByteCount: 1)
                    lineStartOffset = byteOffset
                } else {
                    appendLineByte(byte)
                }
            }
        }

        if pendingCarriageReturn {
            throw BundleBuildError.invalidFASTAFormat(
                "CR-only FASTA line endings are not supported; use LF or CRLF"
            )
        }

        if lineKind != .undecided {
            try processLine(newlineByteCount: 0)
        }

        try appendCurrentChromosome()

        if chromosomes.isEmpty {
            throw BundleBuildError.invalidFASTAFormat("No sequences found in FASTA file")
        }

        logger.info("Found \(chromosomes.count) sequences in FASTA")

        return chromosomes
    }

    private enum FASTALineKind {
        case undecided
        case header
        case sequence
    }

    private struct FASTASequenceLineMetrics {
        let bases: Int
        let width: Int
    }

    private static func isFASTASequenceWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), 0x0B, 0x0C:
            return true
        default:
            return false
        }
    }

    private func createFASTAIndex(chromosomes: [ChromosomeInfo], indexURL: URL) throws {
        var indexLines: [String] = []

        for chrom in chromosomes {
            let line = "\(chrom.name)\t\(chrom.length)\t\(chrom.offset)\t\(chrom.lineBases)\t\(chrom.lineWidth)"
            indexLines.append(line)
        }

        let indexContent = indexLines.joined(separator: "\n") + "\n"
        try indexContent.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private func processAnnotations(
        configuration: BuildConfiguration,
        bundleURL: URL,
        chromosomeSizes: [(String, Int64)],
        progressHandler: ProgressReporter
    ) async throws -> [AnnotationTrackInfo] {
        guard !configuration.annotationFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.annotationFiles.count) annotation files")

        await updateProgress(
            .convertingAnnotations,
            calculateProgress(for: .convertingAnnotations, subProgress: 0.0),
            "Converting annotations...",
            progressHandler
        )

        var annotationInfos: [AnnotationTrackInfo] = []
        let annotationsDir = bundleURL.appendingPathComponent("annotations")

        for (index, input) in configuration.annotationFiles.enumerated() {
            let subProgress = Double(index) / Double(configuration.annotationFiles.count)
            await updateProgress(
                .convertingAnnotations,
                calculateProgress(for: .convertingAnnotations, subProgress: subProgress),
                "Converting \(input.name)...",
                progressHandler
            )

            let filename = annotationOutputFilename(for: input)
            let outputPath = "annotations/\(filename)"
            let outputURL = annotationsDir.appendingPathComponent(filename)

            try FileManager.default.copyItem(at: input.url, to: outputURL)

            let featureCount = countFeaturesInFile(input.url)

            let trackInfo = AnnotationTrackInfo(
                id: input.id,
                name: input.name,
                description: annotationDescription(for: input, featureCount: featureCount),
                path: outputPath,
                annotationType: input.annotationType,
                featureCount: featureCount
            )
            annotationInfos.append(trackInfo)
        }

        await updateProgress(
            .convertingAnnotations,
            calculateProgress(for: .convertingAnnotations, subProgress: 1.0),
            "Annotation conversion complete",
            progressHandler
        )

        return annotationInfos
    }

    private func countFeaturesInFile(_ url: URL) -> Int? {
        countNonCommentLines(in: url)
    }

    /// Counts non-empty, non-comment (`#`-prefixed) lines in a text file.
    /// Returns nil if the file cannot be read as UTF-8, such as a gzipped annotation file.
    private func countNonCommentLines(in url: URL) -> Int? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    private func annotationDescription(for input: AnnotationInput, featureCount: Int?) -> String? {
        if let description = input.description {
            return description
        }

        guard let featureCount else {
            return nil
        }

        var detectionURL = input.url
        if detectionURL.pathExtension.lowercased() == "gz" {
            detectionURL = detectionURL.deletingPathExtension()
        }
        let ext = detectionURL.pathExtension.lowercased()
        guard featureCount == 0, ["gff", "gff3", "gtf"].contains(ext) else {
            return nil
        }
        return "No annotations found in source GFF3"
    }

    private func processVariants(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: ProgressReporter
    ) async throws -> [VariantTrackInfo] {
        guard !configuration.variantFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.variantFiles.count) variant files")

        await updateProgress(
            .convertingVariants,
            calculateProgress(for: .convertingVariants, subProgress: 0.0),
            "Converting variants...",
            progressHandler
        )

        var variantInfos: [VariantTrackInfo] = []
        let variantsDir = bundleURL.appendingPathComponent("variants")

        for (index, input) in configuration.variantFiles.enumerated() {
            let subProgress = Double(index) / Double(configuration.variantFiles.count)
            await updateProgress(
                .convertingVariants,
                calculateProgress(for: .convertingVariants, subProgress: subProgress),
                "Converting \(input.name)...",
                progressHandler
            )

            guard VariantConverter.InputFormat.detect(from: input.url) == .bcf else {
                throw BundleBuildError.variantConversionFailed(
                    input.name,
                    "ReferenceBundleBuilder cannot convert VCF to BCF. Use NativeBundleBuilder or CLI bundle creation with bcftools available."
                )
            }

            let sourceIndexURL = bcfIndexURL(for: input.url)
            guard FileManager.default.fileExists(atPath: sourceIndexURL.path) else {
                throw BundleBuildError.variantConversionFailed(
                    input.name,
                    "Missing CSI index next to BCF input: \(sourceIndexURL.lastPathComponent)"
                )
            }

            let filename = "\(input.id).bcf"
            let indexFilename = "\(input.id).bcf.csi"
            let outputPath = "variants/\(filename)"
            let indexPath = "variants/\(indexFilename)"
            let outputURL = variantsDir.appendingPathComponent(filename)
            let indexURL = variantsDir.appendingPathComponent(indexFilename)

            try FileManager.default.copyItem(at: input.url, to: outputURL)
            try FileManager.default.copyItem(at: sourceIndexURL, to: indexURL)

            let trackInfo = VariantTrackInfo(
                id: input.id,
                name: input.name,
                description: input.description,
                path: outputPath,
                indexPath: indexPath,
                variantType: input.variantType,
                variantCount: nil
            )
            variantInfos.append(trackInfo)
        }

        await updateProgress(
            .convertingVariants,
            calculateProgress(for: .convertingVariants, subProgress: 1.0),
            "Variant conversion complete",
            progressHandler
        )

        return variantInfos
    }

    private func processSignalTracks(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: ProgressReporter
    ) async throws -> [SignalTrackInfo] {
        guard !configuration.signalFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.signalFiles.count) signal track files")

        var signalInfos: [SignalTrackInfo] = []
        let tracksDir = bundleURL.appendingPathComponent("tracks")

        for input in configuration.signalFiles {
            guard isBigWig(input.url) else {
                throw BundleBuildError.signalConversionFailed(
                    input.name,
                    "ReferenceBundleBuilder cannot convert \(input.url.pathExtension) to BigWig. Use NativeBundleBuilder or CLI bundle creation with bedGraph conversion tools available."
                )
            }

            let filename = "\(input.id).bw"
            let outputPath = "tracks/\(filename)"
            let outputURL = tracksDir.appendingPathComponent(filename)

            try FileManager.default.copyItem(at: input.url, to: outputURL)

            let trackInfo = SignalTrackInfo(
                id: input.id,
                name: input.name,
                description: input.description,
                path: outputPath,
                signalType: input.signalType
            )
            signalInfos.append(trackInfo)
        }

        return signalInfos
    }

    private func annotationOutputFilename(for input: AnnotationInput) -> String {
        let lowercasedName = input.url.lastPathComponent.lowercased()
        let knownSuffixes = [
            "gff3.gz", "gff.gz", "gtf.gz", "bed.gz",
            "gff3", "gff", "gtf", "bed", "gbff", "gbk", "bb"
        ]

        if let suffix = knownSuffixes.first(where: { lowercasedName.hasSuffix(".\($0)") }) {
            return "\(input.id).\(suffix)"
        }

        let ext = input.url.pathExtension
        return ext.isEmpty ? input.id : "\(input.id).\(ext)"
    }

    private func bcfIndexURL(for bcfURL: URL) -> URL {
        URL(fileURLWithPath: bcfURL.path + ".csi")
    }

    private func isBigWig(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "bw" || ext == "bigwig"
    }

    private func validateBundle(at bundleURL: URL) throws {
        logger.info("Validating bundle at \(bundleURL.path)")

        var validationErrors: [String] = []
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: bundleURL.path) else {
            validationErrors.append("Bundle directory does not exist")
            throw BundleBuildError.validationFailed(validationErrors)
        }

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            validationErrors.append("manifest.json not found")
            throw BundleBuildError.validationFailed(validationErrors)
        }

        do {
            let manifest = try BundleManifest.load(from: bundleURL)
            let manifestErrors = manifest.validate()
            validationErrors.append(contentsOf: manifestErrors.map { $0.localizedDescription })

            if let genome = manifest.genome {
                if let genomePath = try? BundleManifest.validatedBundleMemberURL(
                    for: genome.path,
                    in: bundleURL,
                    field: "genome.path"
                ) {
                    if !fileManager.fileExists(atPath: genomePath.path) {
                        validationErrors.append("Genome file not found: \(genome.path)")
                    }
                }

                if let indexPath = try? BundleManifest.validatedBundleMemberURL(
                    for: genome.indexPath,
                    in: bundleURL,
                    field: "genome.indexPath"
                ) {
                    if !fileManager.fileExists(atPath: indexPath.path) {
                        validationErrors.append("Genome index not found: \(genome.indexPath)")
                    }
                }
            }

        } catch {
            validationErrors.append("Failed to load manifest: \(error.localizedDescription)")
        }

        if !validationErrors.isEmpty {
            throw BundleBuildError.validationFailed(validationErrors)
        }

        logger.info("Bundle validation passed")
    }
}
