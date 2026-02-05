// ContainerBundleBuilder.swift - Bundle builder with container tool support
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

// MARK: - ContainerBundleBuilder

/// Builds `.lungfishref` reference genome bundles using containerized bioinformatics tools.
///
/// This builder extends the basic `ReferenceBundleBuilder` with proper file format
/// conversions using container tools:
/// - FASTA files are bgzip-compressed with samtools
/// - FASTA indices are created with samtools faidx
/// - Annotations are converted to BigBed format with bedToBigBed
/// - Variants are converted to indexed BCF with bcftools
///
/// ## Requirements
///
/// - macOS 26.0+ (Tahoe) for Apple Containerization
/// - Apple Silicon (M1/M2/M3/M4)
@available(macOS 26.0, *)
@MainActor
public final class ContainerBundleBuilder: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var currentStep: BuildStep = .validating
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var isBuilding: Bool = false
    @Published public private(set) var errors: [String] = []
    @Published public private(set) var containerStatus: ContainerStatus = .notInitialized

    // MARK: - Types

    /// Status of the container runtime.
    public enum ContainerStatus: String, Sendable {
        case notInitialized = "Not Initialized"
        case initializing = "Initializing"
        case ready = "Ready"
        case unavailable = "Unavailable"
        case error = "Error"
    }

    // MARK: - Private Properties

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ContainerBundleBuilder"
    )

    private var isCancelled: Bool = false
    private var pluginManager: ContainerPluginManager?

    // MARK: - Initialization

    public init() {}

    // MARK: - Static Methods

    /// Checks if container support is likely available.
    /// 
    /// Container support requires:
    /// 1. macOS 26+ (Tahoe)
    /// 2. Apple Silicon (arm64)
    /// 3. The `com.apple.security.virtualization` entitlement
    /// 4. Bundled kernel and initfs files
    /// 
    /// Note: While NAT networking doesn't require `com.apple.vm.networking`,
    /// VM creation still requires the virtualization entitlement.
    public nonisolated static func isContainerSupportAvailable() -> Bool {
        // Check if we're on Apple Silicon
        #if !arch(arm64)
        return false
        #endif

        // Check if the bundled kernel and initfs exist
        let bundlePath = Bundle.module.bundlePath
        let kernelPath = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Containerization")
            .appendingPathComponent("vmlinux")
        let initfsPath = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Containerization")
            .appendingPathComponent("init.rootfs.tar.gz")
        
        let hasKernel = FileManager.default.fileExists(atPath: kernelPath.path)
        let hasInitfs = FileManager.default.fileExists(atPath: initfsPath.path)
        
        guard hasKernel && hasInitfs else {
            return false
        }
        
        // Check if we have a provisioning profile (indicates proper signing)
        let hasProvisioningProfile = FileManager.default.fileExists(
            atPath: Bundle.main.bundlePath + "/embedded.mobileprovision"
        ) || FileManager.default.fileExists(
            atPath: Bundle.main.bundlePath + "/Contents/embedded.provisionprofile"
        )

        // Also check if running in Xcode development environment with entitlements
        let isXcodeDevelopment = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil

        // For command-line tools built with swift run, check code signing
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let signingInfo = checkCodeSigningStatus(at: executablePath)

        // Container support requires proper signing with virtualization entitlement
        return signingInfo.hasVirtualizationEntitlement || hasProvisioningProfile || isXcodeDevelopment
    }
    
    /// Checks the code signing status of the executable.
    private nonisolated static func checkCodeSigningStatus(at path: String) -> (isAdHoc: Bool, hasVirtualizationEntitlement: Bool) {
        // Run codesign -d --entitlements - to check entitlements
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // Check for virtualization entitlement
            let hasVirtualization = output.contains("com.apple.security.virtualization")
            
            // Check for ad-hoc signature using codesign -dvv
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process2.arguments = ["-dvv", path]
            let pipe2 = Pipe()
            process2.standardOutput = pipe2
            process2.standardError = pipe2
            try process2.run()
            process2.waitUntilExit()
            let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
            let output2 = String(data: data2, encoding: .utf8) ?? ""
            let isAdHoc = output2.contains("Signature=adhoc")

            return (isAdHoc: isAdHoc, hasVirtualizationEntitlement: hasVirtualization)
        } catch {
            return (isAdHoc: true, hasVirtualizationEntitlement: false)
        }
    }

    // MARK: - Public API

    /// Builds a reference genome bundle with container-based conversions.
    public func build(
        configuration: BuildConfiguration,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)? = nil
    ) async throws -> URL {
        isBuilding = true
        isCancelled = false
        progress = 0.0
        errors = []

        defer { isBuilding = false }

        logger.info("Starting container-aware bundle build: \(configuration.name)")

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

            // Step 2: Initialize container runtime
            updateProgress(.creatingStructure, 0.05, "Initializing container runtime...", progressHandler)
            containerStatus = .initializing

            pluginManager = ContainerPluginManager.shared

            // Prepare required plugins
            try await preparePlugins(progressHandler: progressHandler)
            containerStatus = .ready

            try checkCancellation()

            // Step 3: Create bundle structure
            try await executeStep(.creatingStructure, progressHandler: progressHandler) {
                try self.createBundleStructure(at: bundleURL)
            }

            try checkCancellation()

            // Step 4: Process FASTA with containers
            let genomeInfo = try await processFASTAWithContainers(
                configuration: configuration,
                bundleURL: bundleURL,
                progressHandler: progressHandler
            )

            try checkCancellation()

            // Step 5: Convert annotations with containers
            let annotationInfos = try await processAnnotationsWithContainers(
                configuration: configuration,
                bundleURL: bundleURL,
                chromosomeSizes: genomeInfo.chromosomes.map { ($0.name, $0.length) },
                progressHandler: progressHandler
            )

            try checkCancellation()

            // Step 6: Convert variants with containers
            let variantInfos = try await processVariantsWithContainers(
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

            logger.info("Container bundle build complete: \(bundleURL.path)")

            return bundleURL

        } catch {
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                try? FileManager.default.removeItem(at: bundleURL)
            }

            logger.error("Container bundle build failed: \(error.localizedDescription)")
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

    private func preparePlugins(
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws {
        guard let manager = pluginManager else {
            throw BundleBuildError.containerRuntimeNotAvailable
        }

        // Only prepare samtools for now (essential for FASTA indexing)
        // Other plugins will be prepared on-demand when needed
        let requiredPlugins = ["samtools"]
        let total = Double(requiredPlugins.count)

        for (index, pluginId) in requiredPlugins.enumerated() {
            let subProgress = Double(index) / total
            updateProgress(
                .creatingStructure,
                0.05 + (subProgress * 0.05),
                "Preparing \(pluginId)...",
                progressHandler
            )

            try await manager.preparePlugin(pluginId) { progress, message in
                self.logger.debug("\(pluginId): \(Int(progress * 100))% - \(message)")
            }
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

    // MARK: - FASTA Processing with Containers

    private func processFASTAWithContainers(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> GenomeInfo {
        guard let manager = pluginManager else {
            throw BundleBuildError.containerRuntimeNotAvailable
        }

        logger.info("Processing FASTA with containers")

        let genomeDir = bundleURL.appendingPathComponent("genome")
        let fastaFilename = "sequence.fa"

        // Copy FASTA to bundle first
        let destinationFASTA = genomeDir.appendingPathComponent(fastaFilename)
        try FileManager.default.copyItem(at: configuration.fastaURL, to: destinationFASTA)

        // Parse chromosomes from FASTA
        let chromosomes = try parseFASTAForChromosomes(configuration.fastaURL)

        if configuration.compressFASTA {
            updateProgress(
                .compressingFASTA,
                calculateProgress(for: .compressingFASTA, subProgress: 0.0),
                "Compressing FASTA with bgzip...",
                progressHandler
            )

            // Use bgzip to compress
            let result = try await manager.bgzipCompress(
                inputPath: destinationFASTA,
                workspacePath: genomeDir
            )

            if !result.isSuccess {
                logger.warning("bgzip compression failed: \(result.stderr)")
            } else {
                let compressedPath = URL(fileURLWithPath: destinationFASTA.path + ".gz")
                if FileManager.default.fileExists(atPath: compressedPath.path) {
                    try? FileManager.default.removeItem(at: destinationFASTA)
                }
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

        let fastaToIndex = configuration.compressFASTA
            ? genomeDir.appendingPathComponent("\(fastaFilename).gz")
            : destinationFASTA

        let actualFastaPath = FileManager.default.fileExists(atPath: fastaToIndex.path)
            ? fastaToIndex
            : destinationFASTA

        let indexResult = try await manager.indexFASTA(
            fastaPath: actualFastaPath,
            workspacePath: genomeDir
        )

        if !indexResult.isSuccess {
            logger.warning("samtools faidx failed: \(indexResult.stderr)")
            let indexURL = URL(fileURLWithPath: actualFastaPath.path + ".fai")
            try createFASTAIndex(chromosomes: chromosomes, indexURL: indexURL)
        }

        updateProgress(
            .indexingFASTA,
            calculateProgress(for: .indexingFASTA, subProgress: 1.0),
            "FASTA indexing complete",
            progressHandler
        )

        let totalLength = chromosomes.reduce(0) { $0 + $1.length }
        let isCompressed = FileManager.default.fileExists(
            atPath: genomeDir.appendingPathComponent("\(fastaFilename).gz").path
        )

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

    // MARK: - Annotation Processing with Containers

    private func processAnnotationsWithContainers(
        configuration: BuildConfiguration,
        bundleURL: URL,
        chromosomeSizes: [(String, Int64)],
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [AnnotationTrackInfo] {
        guard !configuration.annotationFiles.isEmpty else {
            return []
        }

        guard let manager = pluginManager else {
            throw BundleBuildError.containerRuntimeNotAvailable
        }

        logger.info("Processing \(configuration.annotationFiles.count) annotation files with containers")

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

            // Convert BED to BigBed using container
            let result = try await manager.convertBEDtoBigBed(
                bedPath: bedURL,
                chromSizesPath: chromSizesURL,
                outputPath: outputURL,
                workspacePath: annotationsDir
            )

            if !result.isSuccess {
                logger.warning("bedToBigBed failed for \(input.name): \(result.stderr)")
                try FileManager.default.copyItem(at: bedURL, to: outputURL)
            }

            try? FileManager.default.removeItem(at: bedURL)

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

    // MARK: - Variant Processing with Containers

    private func processVariantsWithContainers(
        configuration: BuildConfiguration,
        bundleURL: URL,
        progressHandler: (@Sendable (BuildStep, Double, String) -> Void)?
    ) async throws -> [VariantTrackInfo] {
        guard !configuration.variantFiles.isEmpty else {
            return []
        }

        guard let manager = pluginManager else {
            throw BundleBuildError.containerRuntimeNotAvailable
        }

        logger.info("Processing \(configuration.variantFiles.count) variant files with containers")

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

            let vcfCopy = variantsDir.appendingPathComponent(input.url.lastPathComponent)
            try FileManager.default.copyItem(at: input.url, to: vcfCopy)

            let result = try await manager.convertVCFtoBCF(
                vcfPath: vcfCopy,
                outputPath: outputURL,
                workspacePath: variantsDir
            )

            try? FileManager.default.removeItem(at: vcfCopy)

            if !result.isSuccess {
                logger.warning("bcftools conversion failed for \(input.name): \(result.stderr)")
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
