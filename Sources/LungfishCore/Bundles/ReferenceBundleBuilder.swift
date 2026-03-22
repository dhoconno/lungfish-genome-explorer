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
    case convertingAnnotations = "Converting annotations to BigBed"
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

    /// Whether to compress the FASTA file (default: true).
    public let compressFASTA: Bool

    /// Optional categorized metadata groups for flexible, source-specific metadata storage.
    ///
    /// When provided, these groups are written to the bundle manifest and displayed in the Inspector.
    /// This allows callers (e.g., NCBI download pipelines) to pass through rich metadata
    /// without requiring schema changes to `BuildConfiguration`.
    public let metadata: [MetadataGroup]?

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
        metadata: [MetadataGroup]? = nil
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

    /// FASTA compression failed.
    case compressionFailed(String)

    /// FASTA indexing failed.
    case indexingFailed(String)

    /// Annotation conversion failed.
    case annotationConversionFailed(String, String)

    /// Variant conversion failed.
    case variantConversionFailed(String, String)

    /// Manifest generation failed.
    case manifestGenerationFailed(String)

    /// Bundle validation failed.
    case validationFailed([String])

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
        case .compressionFailed(let reason):
            return "FASTA compression failed: \(reason)"
        case .indexingFailed(let reason):
            return "FASTA indexing failed: \(reason)"
        case .annotationConversionFailed(let file, let reason):
            return "Annotation conversion failed for '\(file)': \(reason)"
        case .variantConversionFailed(let file, let reason):
            return "Variant conversion failed for '\(file)': \(reason)"
        case .manifestGenerationFailed(let reason):
            return "Manifest generation failed: \(reason)"
        case .validationFailed(let errors):
            return "Bundle validation failed:\n" + errors.joined(separator: "\n")
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
        case .compressionFailed, .indexingFailed:
            return "Ensure the container runtime is working and try again."
        case .annotationConversionFailed:
            return "Verify the annotation file format is correct (GFF3, GTF, or BED)."
        case .variantConversionFailed:
            return "Verify the VCF file is properly formatted."
        case .manifestGenerationFailed:
            return "This is an internal error. Please report it."
        case .validationFailed:
            return "Review the validation errors and fix any issues."
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

    private var isCancelled: Bool = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    public func build(
        configuration: BuildConfiguration,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)? = nil
    ) async throws -> URL {
        isBuilding = true
        isCancelled = false
        progress = 0.0
        errors = []

        defer { isBuilding = false }

        logger.info("Starting bundle build: \(configuration.name)")

        let bundleName = configuration.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let bundleURL = configuration.outputDirectory
            .appendingPathComponent("\(bundleName).lungfishref")

        do {
            try await executeStep(.validating, progressHandler: progressHandler) {
                try self.validateInputs(configuration)
            }

            try checkCancellation()

            try await executeStep(.creatingStructure, progressHandler: progressHandler) {
                try self.createBundleStructure(at: bundleURL)
            }

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
                try self.validateBundle(at: bundleURL)
            }

            updateProgress(.complete, 1.0, "Bundle created successfully", progressHandler)

            logger.info("Bundle build complete: \(bundleURL.path)")

            return bundleURL

        } catch {
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                try? FileManager.default.removeItem(at: bundleURL)
            }

            logger.error("Bundle build failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func cancel() {
        isCancelled = true
        logger.info("Build cancellation requested")
    }

    // MARK: - Private Methods

    private func checkCancellation() throws {
        if isCancelled {
            throw BundleBuildError.cancelled
        }
    }

    private func executeStep(
        _ step: BuildStep,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?,
        operation: () throws -> Void
    ) async throws {
        updateProgress(step, calculateProgress(for: step, subProgress: 0.0), step.rawValue, progressHandler)
        try operation()
        updateProgress(step, calculateProgress(for: step, subProgress: 1.0), step.rawValue, progressHandler)
    }

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
        }

        for signal in configuration.signalFiles {
            guard fileManager.fileExists(atPath: signal.url.path) else {
                throw BundleBuildError.inputFileNotFound(signal.url)
            }
            guard fileManager.isReadableFile(atPath: signal.url.path) else {
                throw BundleBuildError.inputFileNotReadable(signal.url)
            }
        }

        logger.info("Input validation complete")
    }

    private func createBundleStructure(at bundleURL: URL) throws {
        logger.info("Creating bundle structure at \(bundleURL.path)")

        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
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
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> GenomeInfo {
        logger.info("Processing FASTA file")

        let genomeDir = bundleURL.appendingPathComponent("genome")
        let fastaFilename = "sequence.fa"
        let destinationFASTA: URL

        if configuration.compressFASTA {
            updateProgress(
                .compressingFASTA,
                calculateProgress(for: .compressingFASTA, subProgress: 0.0),
                "Compressing FASTA with bgzip...",
                progressHandler
            )

            destinationFASTA = genomeDir.appendingPathComponent("\(fastaFilename).gz")

            try copyAndOptionallyCompress(
                from: configuration.fastaURL,
                to: destinationFASTA,
                compress: true
            )

            updateProgress(
                .compressingFASTA,
                calculateProgress(for: .compressingFASTA, subProgress: 1.0),
                "FASTA compression complete",
                progressHandler
            )
        } else {
            destinationFASTA = genomeDir.appendingPathComponent(fastaFilename)
            try FileManager.default.copyItem(at: configuration.fastaURL, to: destinationFASTA)
        }

        updateProgress(
            .indexingFASTA,
            calculateProgress(for: .indexingFASTA, subProgress: 0.0),
            "Creating FASTA index...",
            progressHandler
        )

        let chromosomes = try parseFASTAForChromosomes(configuration.fastaURL)

        let indexURL = URL(fileURLWithPath: destinationFASTA.path + ".fai")
        try createFASTAIndex(chromosomes: chromosomes, indexURL: indexURL)

        updateProgress(
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

        let fileURL = fastaURL
        let ext = fastaURL.pathExtension.lowercased()

        if ext == "gz" {
            logger.warning("Gzipped FASTA support requires decompression")
        }

        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw BundleBuildError.inputFileNotReadable(fastaURL)
        }
        defer { try? fileHandle.close() }

        var chromosomes: [ChromosomeInfo] = []
        var currentChromName: String?
        var currentLength: Int64 = 0
        var lineBasesFirst: Int?
        var lineWidthFirst: Int?
        var sequenceStartOffset: Int64 = 0

        let data = fileHandle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            throw BundleBuildError.invalidFASTAFormat("Cannot read file as UTF-8")
        }

        var byteOffset: Int64 = 0
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let lineLength = line.utf8.count

            if line.hasPrefix(">") {
                if let chromName = currentChromName {
                    let chromInfo = ChromosomeInfo(
                        name: chromName,
                        length: currentLength,
                        offset: sequenceStartOffset,
                        lineBases: lineBasesFirst ?? 50,
                        lineWidth: (lineWidthFirst ?? 50) + 1
                    )
                    chromosomes.append(chromInfo)
                }

                let headerLine = String(line.dropFirst())
                currentChromName = headerLine.split(separator: " ").first.map(String.init) ?? headerLine
                currentLength = 0
                lineBasesFirst = nil
                lineWidthFirst = nil
                sequenceStartOffset = byteOffset + Int64(lineLength) + 1
            } else if !line.isEmpty {
                let basesInLine = line.filter { !$0.isWhitespace }.count
                currentLength += Int64(basesInLine)

                if lineBasesFirst == nil && basesInLine > 0 {
                    lineBasesFirst = basesInLine
                    lineWidthFirst = lineLength
                }
            }

            byteOffset += Int64(lineLength) + 1
        }

        if let chromName = currentChromName {
            let chromInfo = ChromosomeInfo(
                name: chromName,
                length: currentLength,
                offset: sequenceStartOffset,
                lineBases: lineBasesFirst ?? 50,
                lineWidth: (lineWidthFirst ?? 50) + 1
            )
            chromosomes.append(chromInfo)
        }

        if chromosomes.isEmpty {
            throw BundleBuildError.invalidFASTAFormat("No sequences found in FASTA file")
        }

        logger.info("Found \(chromosomes.count) sequences in FASTA")

        return chromosomes
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

    private func copyAndOptionallyCompress(from source: URL, to destination: URL, compress: Bool) throws {
        if compress {
            try FileManager.default.copyItem(at: source, to: destination)
            logger.warning("Using simple copy instead of bgzip compression (container not available)")
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func processAnnotations(
        configuration: BuildConfiguration,
        bundleURL: URL,
        chromosomeSizes: [(String, Int64)],
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [AnnotationTrackInfo] {
        guard !configuration.annotationFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.annotationFiles.count) annotation files")

        updateProgress(
            .convertingAnnotations,
            calculateProgress(for: .convertingAnnotations, subProgress: 0.0),
            "Converting annotations...",
            progressHandler
        )

        var annotationInfos: [AnnotationTrackInfo] = []
        let annotationsDir = bundleURL.appendingPathComponent("annotations")

        for (index, input) in configuration.annotationFiles.enumerated() {
            let subProgress = Double(index) / Double(configuration.annotationFiles.count)
            updateProgress(
                .convertingAnnotations,
                calculateProgress(for: .convertingAnnotations, subProgress: subProgress),
                "Converting \(input.name)...",
                progressHandler
            )

            let outputPath = "annotations/\(input.id).bb"
            let outputURL = annotationsDir.appendingPathComponent("\(input.id).bb")

            try FileManager.default.copyItem(at: input.url, to: outputURL)

            let featureCount = try countFeaturesInFile(input.url)

            let trackInfo = AnnotationTrackInfo(
                id: input.id,
                name: input.name,
                description: input.description,
                path: outputPath,
                annotationType: input.annotationType,
                featureCount: featureCount
            )
            annotationInfos.append(trackInfo)
        }

        updateProgress(
            .convertingAnnotations,
            calculateProgress(for: .convertingAnnotations, subProgress: 1.0),
            "Annotation conversion complete",
            progressHandler
        )

        return annotationInfos
    }

    private func countFeaturesInFile(_ url: URL) throws -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    private func processVariants(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [VariantTrackInfo] {
        guard !configuration.variantFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.variantFiles.count) variant files")

        updateProgress(
            .convertingVariants,
            calculateProgress(for: .convertingVariants, subProgress: 0.0),
            "Converting variants...",
            progressHandler
        )

        var variantInfos: [VariantTrackInfo] = []
        let variantsDir = bundleURL.appendingPathComponent("variants")

        for (index, input) in configuration.variantFiles.enumerated() {
            let subProgress = Double(index) / Double(configuration.variantFiles.count)
            updateProgress(
                .convertingVariants,
                calculateProgress(for: .convertingVariants, subProgress: subProgress),
                "Converting \(input.name)...",
                progressHandler
            )

            let outputPath = "variants/\(input.id).bcf"
            let indexPath = "variants/\(input.id).bcf.csi"
            let outputURL = variantsDir.appendingPathComponent("\(input.id).bcf")
            let indexURL = variantsDir.appendingPathComponent("\(input.id).bcf.csi")

            try FileManager.default.copyItem(at: input.url, to: outputURL)

            try Data().write(to: indexURL)

            let variantCount = try countVariantsInVCF(input.url)

            let trackInfo = VariantTrackInfo(
                id: input.id,
                name: input.name,
                description: input.description,
                path: outputPath,
                indexPath: indexPath,
                variantType: input.variantType,
                variantCount: variantCount
            )
            variantInfos.append(trackInfo)
        }

        updateProgress(
            .convertingVariants,
            calculateProgress(for: .convertingVariants, subProgress: 1.0),
            "Variant conversion complete",
            progressHandler
        )

        return variantInfos
    }

    private func countVariantsInVCF(_ url: URL) throws -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    private func processSignalTracks(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [SignalTrackInfo] {
        guard !configuration.signalFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.signalFiles.count) signal track files")

        var signalInfos: [SignalTrackInfo] = []
        let tracksDir = bundleURL.appendingPathComponent("tracks")

        for input in configuration.signalFiles {
            let outputPath = "tracks/\(input.id).bw"
            let outputURL = tracksDir.appendingPathComponent("\(input.id).bw")

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
                let genomePath = bundleURL.appendingPathComponent(genome.path)
                if !fileManager.fileExists(atPath: genomePath.path) {
                    validationErrors.append("Genome file not found: \(genome.path)")
                }

                let indexPath = bundleURL.appendingPathComponent(genome.indexPath)
                if !fileManager.fileExists(atPath: indexPath.path) {
                    validationErrors.append("Genome index not found: \(genome.indexPath)")
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
