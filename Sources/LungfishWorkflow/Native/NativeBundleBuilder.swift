// NativeBundleBuilder.swift - Bundle builder using native tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

// MARK: - NativeBundleBuilder

/// Builds `.lungfishref` reference genome bundles using native bioinformatics tools.
///
/// This builder uses locally installed tools (via Homebrew or bundled with the app)
/// instead of containers. Tools used:
/// - `bgzip` - FASTA compression (from htslib)
/// - `samtools faidx` - FASTA indexing
/// - `bcftools` - VCF to BCF conversion
/// - `bedToBigBed` - BED to BigBed conversion (UCSC)
/// - `bedGraphToBigWig` - bedGraph to BigWig conversion (UCSC)
///
/// ## Installation
///
/// Install required tools via Homebrew:
/// ```
/// brew install samtools bcftools htslib
/// brew install kent-tools  # For bedToBigBed and bedGraphToBigWig
/// ```
@MainActor
public final class NativeBundleBuilder: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var currentStep: BuildStep = .validating
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var isBuilding: Bool = false
    @Published public private(set) var errors: [String] = []
    @Published public private(set) var toolStatus: ToolStatus = .notChecked

    // MARK: - Types

    /// Status of native tool availability.
    public enum ToolStatus: String, Sendable {
        case notChecked = "Not Checked"
        case checking = "Checking"
        case ready = "Ready"
        case missingTools = "Missing Tools"
    }

    /// Information about missing tools.
    public struct MissingToolsInfo: Sendable {
        public let missingTools: [NativeTool]

        public var description: String {
            let toolNames = missingTools.map { $0.rawValue }.joined(separator: ", ")
            return "Missing bundled tools: \(toolNames). The app bundle may be incomplete or corrupted."
        }
    }

    // MARK: - Private Properties

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "NativeBundleBuilder"
    )

    private var isCancelled: Bool = false
    private let toolRunner = NativeToolRunner.shared

    // MARK: - Initialization

    public init() {}

    // MARK: - Tool Checking

    /// Checks if all required native tools are available.
    ///
    /// - Parameter requiredTools: The tools needed for the build.
    /// - Returns: Information about missing tools, or nil if all are available.
    public func checkRequiredTools(
        requiredTools: Set<NativeTool> = [.samtools, .bgzip]
    ) async -> MissingToolsInfo? {
        toolStatus = .checking

        var missingTools: [NativeTool] = []

        for tool in requiredTools {
            let available = await toolRunner.isToolAvailable(tool)
            if !available {
                missingTools.append(tool)
            }
        }

        if missingTools.isEmpty {
            toolStatus = .ready
            return nil
        }

        toolStatus = .missingTools

        return MissingToolsInfo(missingTools: missingTools)
    }

    /// Checks all tools and returns their availability status.
    public func checkAllToolStatus() async -> [NativeTool: Bool] {
        return await toolRunner.checkAllTools()
    }

    // MARK: - Public API

    /// Builds a reference genome bundle using native tools.
    public func build(
        configuration: BuildConfiguration,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)? = nil
    ) async throws -> URL {
        isBuilding = true
        isCancelled = false
        progress = 0.0
        errors = []

        defer { isBuilding = false }

        logger.info("Starting native bundle build: \(configuration.name)")

        let bundleName = configuration.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let bundleURL = configuration.outputDirectory
            .appendingPathComponent("\(bundleName).lungfishref")

        do {
            // Step 1: Validate inputs
            try await executeStep(.validating, progressHandler: progressHandler) {
                try self.validateInputs(configuration)
            }

            try checkCancellation()

            // Step 2: Check tool availability
            updateProgress(.creatingStructure, 0.05, "Checking native tools...", progressHandler)

            let requiredTools = determineRequiredTools(for: configuration)
            if let missingInfo = await checkRequiredTools(requiredTools: requiredTools) {
                throw NativeBundleBuildError.missingTools(missingInfo)
            }

            try checkCancellation()

            // Step 3: Create bundle structure
            try await executeStep(.creatingStructure, progressHandler: progressHandler) {
                try self.createBundleStructure(at: bundleURL)
            }

            try checkCancellation()

            // Step 4: Process FASTA with native tools
            let genomeInfo = try await processFASTAWithNativeTools(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            // Step 5: Convert annotations
            let annotationInfos = try await processAnnotationsWithNativeTools(
                configuration: configuration,
                bundleURL: bundleURL,
                chromosomeSizes: genomeInfo.chromosomes.map { ($0.name, $0.length) },
                progressHandler: progressHandler
            )

            try checkCancellation()

            // Step 6: Convert variants
            let variantInfos = try await processVariantsWithNativeTools(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            // Step 7: Process signal tracks
            let signalInfos = try await processSignalTracks(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            // Step 8: Generate manifest
            try await executeStep(.generatingManifest, progressHandler: progressHandler) {
                let manifest = BundleManifest(
                    name: configuration.name,
                    identifier: configuration.identifier,
                    source: configuration.source,
                    genome: genomeInfo,
                    annotations: annotationInfos,
                    variants: variantInfos,
                    tracks: signalInfos
                )

                try manifest.save(to: bundleURL)
            }

            try checkCancellation()

            // Step 9: Validate bundle
            try await executeStep(.validatingBundle, progressHandler: progressHandler) {
                try self.validateBundle(at: bundleURL)
            }

            updateProgress(.complete, 1.0, "Bundle created successfully", progressHandler)

            logger.info("Native bundle build complete: \(bundleURL.path)")

            return bundleURL

        } catch {
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                try? FileManager.default.removeItem(at: bundleURL)
            }

            logger.error("Native bundle build failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Cancels the current build.
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

    private func determineRequiredTools(for configuration: BuildConfiguration) -> Set<NativeTool> {
        var tools: Set<NativeTool> = [.samtools]

        if configuration.compressFASTA {
            tools.insert(.bgzip)
        }

        if !configuration.variantFiles.isEmpty {
            tools.insert(.bcftools)
        }

        if !configuration.annotationFiles.isEmpty {
            tools.insert(.bedToBigBed)
        }

        if !configuration.signalFiles.isEmpty {
            // Check if any need conversion
            for signal in configuration.signalFiles {
                let ext = signal.url.pathExtension.lowercased()
                if ext == "bedgraph" || ext == "bg" {
                    tools.insert(.bedGraphToBigWig)
                    break
                }
            }
        }

        return tools
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
        }

        for variant in configuration.variantFiles {
            guard fileManager.fileExists(atPath: variant.url.path) else {
                throw BundleBuildError.inputFileNotFound(variant.url)
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
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        logger.info("Bundle structure created")
    }

    // MARK: - FASTA Processing with Native Tools

    private func processFASTAWithNativeTools(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> GenomeInfo {
        logger.info("Processing FASTA with native tools")

        let genomeDir = bundleURL.appendingPathComponent("genome")
        let fastaFilename = "sequence.fa"

        // Copy FASTA to bundle first
        let destinationFASTA = genomeDir.appendingPathComponent(fastaFilename)
        try FileManager.default.copyItem(at: configuration.fastaURL, to: destinationFASTA)

        // Parse chromosomes from FASTA
        let chromosomes = try parseFASTAForChromosomes(configuration.fastaURL)

        var finalFASTAPath = destinationFASTA

        if configuration.compressFASTA {
            updateProgress(
                .compressingFASTA,
                calculateProgress(for: .compressingFASTA, subProgress: 0.0),
                "Compressing FASTA with bgzip...",
                progressHandler
            )

            // Use bgzip to compress
            let result = try await toolRunner.bgzipCompress(
                inputPath: destinationFASTA,
                keepOriginal: false
            )

            if result.isSuccess {
                finalFASTAPath = URL(fileURLWithPath: destinationFASTA.path + ".gz")
                logger.info("FASTA compressed successfully")
            } else {
                logger.warning("bgzip compression failed: \(result.stderr)")
                // Fall back to uncompressed
            }

            updateProgress(
                .compressingFASTA,
                calculateProgress(for: .compressingFASTA, subProgress: 1.0),
                "FASTA compression complete",
                progressHandler
            )
        }

        // Create FASTA index using samtools
        updateProgress(
            .indexingFASTA,
            calculateProgress(for: .indexingFASTA, subProgress: 0.0),
            "Creating FASTA index with samtools...",
            progressHandler
        )

        let indexResult = try await toolRunner.indexFASTA(fastaPath: finalFASTAPath)

        if !indexResult.isSuccess {
            logger.warning("samtools faidx failed: \(indexResult.stderr)")
            // Fall back to manual index creation
            let indexURL = URL(fileURLWithPath: finalFASTAPath.path + ".fai")
            try createFASTAIndex(chromosomes: chromosomes, indexURL: indexURL)
        }

        updateProgress(
            .indexingFASTA,
            calculateProgress(for: .indexingFASTA, subProgress: 1.0),
            "FASTA indexing complete",
            progressHandler
        )

        let totalLength = chromosomes.reduce(0) { $0 + $1.length }
        let isCompressed = finalFASTAPath.pathExtension == "gz"

        let relativePath = isCompressed ? "genome/\(fastaFilename).gz" : "genome/\(fastaFilename)"
        let indexPath = "\(relativePath).fai"
        let gzipIndexPath = isCompressed ? "\(relativePath).gzi" : nil

        return GenomeInfo(
            path: relativePath,
            indexPath: indexPath,
            gzipIndexPath: gzipIndexPath,
            totalLength: totalLength,
            chromosomes: chromosomes
        )
    }

    // MARK: - Annotation Processing with Native Tools

    private func processAnnotationsWithNativeTools(
        configuration: BuildConfiguration,
        bundleURL: URL,
        chromosomeSizes: [(String, Int64)],
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [AnnotationTrackInfo] {
        guard !configuration.annotationFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.annotationFiles.count) annotation files with native tools")

        updateProgress(
            .convertingAnnotations,
            calculateProgress(for: .convertingAnnotations, subProgress: 0.0),
            "Converting annotations...",
            progressHandler
        )

        var annotationInfos: [AnnotationTrackInfo] = []
        let annotationsDir = bundleURL.appendingPathComponent("annotations")

        // Create chrom.sizes file for bedToBigBed
        let chromSizesURL = annotationsDir.appendingPathComponent("chrom.sizes")
        let chromSizesContent = chromosomeSizes
            .map { "\($0.0)\t\($0.1)" }
            .joined(separator: "\n")
        try chromSizesContent.write(to: chromSizesURL, atomically: true, encoding: .utf8)

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

            // Convert annotation to BED format first
            let bedURL = annotationsDir.appendingPathComponent("\(input.id).bed")
            let featureCount = try await convertAnnotationToBED(
                from: input.url,
                to: bedURL
            )

            // Try to convert BED to BigBed using native tool
            let hasBedToBigBed = await toolRunner.isToolAvailable(.bedToBigBed)

            if hasBedToBigBed {
                let result = try await toolRunner.convertBEDtoBigBed(
                    bedPath: bedURL,
                    chromSizesPath: chromSizesURL,
                    outputPath: outputURL
                )

                if !result.isSuccess {
                    logger.warning("bedToBigBed failed for \(input.name): \(result.stderr)")
                    // Keep BED file as fallback
                    let bedOutputURL = annotationsDir.appendingPathComponent("\(input.id).bed")
                    if bedURL != bedOutputURL {
                        try? FileManager.default.moveItem(at: bedURL, to: bedOutputURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: bedURL)
                }
            } else {
                // No bedToBigBed available, keep as BED
                logger.info("bedToBigBed not available, keeping BED format for \(input.name)")
            }

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

        try? FileManager.default.removeItem(at: chromSizesURL)

        updateProgress(
            .convertingAnnotations,
            calculateProgress(for: .convertingAnnotations, subProgress: 1.0),
            "Annotation conversion complete",
            progressHandler
        )

        return annotationInfos
    }

    // MARK: - Variant Processing with Native Tools

    private func processVariantsWithNativeTools(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [VariantTrackInfo] {
        guard !configuration.variantFiles.isEmpty else {
            return []
        }

        logger.info("Processing \(configuration.variantFiles.count) variant files with native tools")

        updateProgress(
            .convertingVariants,
            calculateProgress(for: .convertingVariants, subProgress: 0.0),
            "Converting variants...",
            progressHandler
        )

        var variantInfos: [VariantTrackInfo] = []
        let variantsDir = bundleURL.appendingPathComponent("variants")

        let hasBcftools = await toolRunner.isToolAvailable(.bcftools)

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

            if hasBcftools {
                let result = try await toolRunner.convertVCFtoBCF(
                    vcfPath: input.url,
                    outputPath: outputURL
                )

                if !result.isSuccess {
                    logger.warning("bcftools conversion failed for \(input.name): \(result.stderr)")
                    // Copy VCF as fallback
                    try FileManager.default.copyItem(at: input.url, to: outputURL)
                    try Data().write(to: variantsDir.appendingPathComponent("\(input.id).bcf.csi"))
                }
            } else {
                // No bcftools available, copy VCF
                logger.info("bcftools not available, copying VCF for \(input.name)")
                try FileManager.default.copyItem(at: input.url, to: outputURL)
                try Data().write(to: variantsDir.appendingPathComponent("\(input.id).bcf.csi"))
            }

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

    // MARK: - Signal Track Processing

    private func processSignalTracks(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [SignalTrackInfo] {
        guard !configuration.signalFiles.isEmpty else {
            return []
        }

        var signalInfos: [SignalTrackInfo] = []
        let tracksDir = bundleURL.appendingPathComponent("tracks")

        for input in configuration.signalFiles {
            let outputPath = "tracks/\(input.id).bw"
            let outputURL = tracksDir.appendingPathComponent("\(input.id).bw")

            // Check if input is already BigWig
            let ext = input.url.pathExtension.lowercased()
            if ext == "bw" || ext == "bigwig" {
                try FileManager.default.copyItem(at: input.url, to: outputURL)
            } else if ext == "bedgraph" || ext == "bg" {
                // Try to convert using native tool
                // Note: Would need chrom.sizes file, skip for now
                try FileManager.default.copyItem(at: input.url, to: outputURL)
            } else {
                try FileManager.default.copyItem(at: input.url, to: outputURL)
            }

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

    // MARK: - Helper Methods

    private func parseFASTAForChromosomes(_ fastaURL: URL) throws -> [ChromosomeInfo] {
        guard let fileHandle = FileHandle(forReadingAtPath: fastaURL.path) else {
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

    private func convertAnnotationToBED(from sourceURL: URL, to outputURL: URL) async throws -> Int {
        let converter = AnnotationConverter()

        _ = try await converter.convertToBED(
            from: sourceURL,
            output: outputURL
        )

        guard let content = try? String(contentsOf: outputURL, encoding: .utf8) else {
            return 0
        }

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
    }

    private func countVariantsInVCF(_ url: URL) throws -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
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

            let genomePath = bundleURL.appendingPathComponent(manifest.genome.path)
            if !fileManager.fileExists(atPath: genomePath.path) {
                validationErrors.append("Genome file not found: \(manifest.genome.path)")
            }

            let indexPath = bundleURL.appendingPathComponent(manifest.genome.indexPath)
            if !fileManager.fileExists(atPath: indexPath.path) {
                validationErrors.append("Genome index not found: \(manifest.genome.indexPath)")
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

// MARK: - NativeBundleBuildError

/// Errors specific to native bundle building.
public enum NativeBundleBuildError: Error, LocalizedError, Sendable {
    /// Required tools are missing.
    case missingTools(NativeBundleBuilder.MissingToolsInfo)

    /// Tool execution failed.
    case toolFailed(NativeTool, String)

    public var errorDescription: String? {
        switch self {
        case .missingTools(let info):
            return info.description
        case .toolFailed(let tool, let reason):
            return "Tool '\(tool.rawValue)' failed: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missingTools:
            return "The app bundle is missing required bioinformatics tools. Please reinstall the application."
        case .toolFailed:
            return "Check the tool output for more details."
        }
    }
}
