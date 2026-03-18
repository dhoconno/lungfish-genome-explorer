// BatchProcessingEngine.swift - Batch processing across demultiplexed barcodes
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.browser", category: "BatchProcessingEngine")

// MARK: - Batch Processing Error

public enum BatchProcessingError: Error, LocalizedError {
    case noBarcodes
    case recipeEmpty
    case cancelled
    case barcodeNotFound(String)
    case stepFailed(barcode: String, stepIndex: Int, underlying: Error)
    case unsupportedStepInRecipe(String)

    public var errorDescription: String? {
        switch self {
        case .noBarcodes:
            return "No barcode bundles found in the demux group."
        case .recipeEmpty:
            return "The processing recipe contains no steps."
        case .cancelled:
            return "Batch processing was cancelled."
        case .barcodeNotFound(let label):
            return "Barcode bundle not found: \(label)"
        case .stepFailed(let barcode, let stepIndex, let underlying):
            return "Step \(stepIndex) failed for barcode \(barcode): \(underlying)"
        case .unsupportedStepInRecipe(let kind):
            return "Operation '\(kind)' is not supported as a batch recipe step."
        }
    }
}

// MARK: - Batch Source

/// A generalized input source for batch processing.
///
/// Wraps any `.lungfishfastq` bundle (demux barcode, selected bundle, etc.)
/// with display metadata for progress reporting and manifest generation.
public struct BatchSource: Sendable {
    /// URL to the `.lungfishfastq` bundle.
    public let bundleURL: URL

    /// Human-readable label (e.g. "BC01", "sample-A").
    public let displayName: String

    /// Approximate read count (for progress estimates).
    public let readCount: Int

    public init(bundleURL: URL, displayName: String, readCount: Int = 0) {
        self.bundleURL = bundleURL
        self.displayName = displayName
        self.readCount = readCount
    }
}

// MARK: - Batch Progress

/// Progress tracking for a batch processing run.
public struct BatchProgress: Sendable {
    public let totalBarcodes: Int
    public let completedBarcodes: Int
    public let currentBarcode: String?
    public let currentStep: Int?
    public let totalSteps: Int
    public let message: String

    public var overallFraction: Double {
        guard totalBarcodes > 0, totalSteps > 0 else { return 0 }
        let stepsPerBarcode = totalSteps
        let totalWork = totalBarcodes * stepsPerBarcode
        let completedWork = completedBarcodes * stepsPerBarcode + (currentStep ?? 0)
        return Double(completedWork) / Double(totalWork)
    }
}

// MARK: - Batch Processing Engine

/// Processes all barcodes in a demux group through a recipe pipeline.
///
/// Executes steps sequentially per barcode, with bounded concurrency across
/// barcodes. Each barcode's output feeds into the next step as input.
///
/// ```
/// multiplexed-demux/
/// ├── batch-runs/
/// │   └── {batch-name}/
/// │       ├── batch.manifest.json
/// │       ├── recipe.json
/// │       ├── comparison.json
/// │       └── bc01/
/// │           ├── step-1-qtrim-Q20/
/// │           │   └── bc01-trimmed.lungfishfastq/
/// │           └── step-2-adapter-trim/
/// ```
public actor BatchProcessingEngine {

    private let derivativeService: FASTQDerivativeService
    private let maxConcurrency: Int

    /// Active cancellation flag.
    private var isCancelled = false

    public init(
        derivativeService: FASTQDerivativeService,
        maxConcurrency: Int = 4
    ) {
        self.derivativeService = derivativeService
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Cancels the current batch processing run.
    public func cancel() {
        isCancelled = true
    }

    // MARK: - Generalized Batch Execution

    /// Executes a recipe across an array of batch sources with bounded concurrency.
    ///
    /// This is the primary batch execution method. Each source is processed through
    /// all recipe steps sequentially. Sources are processed concurrently up to
    /// `maxConcurrency`.
    ///
    /// - Parameters:
    ///   - sources: The input bundles to process.
    ///   - recipe: The processing recipe to apply.
    ///   - batchName: Human-readable name for this batch run.
    ///   - outputDirectory: Directory to write batch results into.
    ///   - progress: Callback for progress updates.
    /// - Returns: The completed `BatchManifest` with timing info.
    public func executeBatch(
        sources: [BatchSource],
        recipe: ProcessingRecipe,
        batchName: String,
        outputDirectory: URL,
        progress: (@Sendable (BatchProgress) -> Void)? = nil
    ) async throws -> BatchManifest {
        guard !sources.isEmpty else { throw BatchProcessingError.noBarcodes }
        guard !recipe.steps.isEmpty else { throw BatchProcessingError.recipeEmpty }

        isCancelled = false

        // Create batch run directory
        let batchRunsDir = outputDirectory.appendingPathComponent("batch-runs", isDirectory: true)
        let batchDir = batchRunsDir.appendingPathComponent(batchName, isDirectory: true)
        try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)

        // Save recipe snapshot
        try recipe.save(to: batchDir.appendingPathComponent("recipe.json"))

        let sourceLabels = sources.map(\.displayName)

        var batchManifest = BatchManifest(
            recipeName: recipe.name,
            recipeID: recipe.id,
            batchName: batchName,
            barcodeCount: sources.count,
            stepCount: recipe.steps.count,
            barcodeLabels: sourceLabels
        )

        // Process sources with bounded concurrency
        let results = try await withThrowingTaskGroup(of: (Int, BarcodeSummary).self) { group in
            var activeTasks = 0
            var sourceIndex = 0
            var collectedResults: [(Int, BarcodeSummary)] = []

            while sourceIndex < sources.count || activeTasks > 0 {
                while activeTasks < maxConcurrency && sourceIndex < sources.count {
                    guard !isCancelled else { throw BatchProcessingError.cancelled }

                    let source = sources[sourceIndex]
                    let idx = sourceIndex
                    sourceIndex += 1
                    activeTasks += 1

                    group.addTask { [self] in
                        let summary = try await self.processSource(
                            source: source,
                            sourceIndex: idx,
                            batchDir: batchDir,
                            recipe: recipe,
                            totalSources: sources.count,
                            progress: progress
                        )
                        return (idx, summary)
                    }
                }

                if let result = try await group.next() {
                    collectedResults.append(result)
                    activeTasks -= 1

                    progress?(BatchProgress(
                        totalBarcodes: sources.count,
                        completedBarcodes: collectedResults.count,
                        currentBarcode: nil,
                        currentStep: nil,
                        totalSteps: recipe.steps.count,
                        message: "Completed \(collectedResults.count)/\(sources.count) sources"
                    ))
                }
            }

            return collectedResults
        }

        let sortedSummaries = results.sorted(by: { $0.0 < $1.0 }).map(\.1)

        let stepDefs = recipe.steps.enumerated().map { index, step in
            StepDefinition(
                index: index,
                operationKind: step.kind.rawValue,
                shortLabel: step.shortLabel,
                displaySummary: step.displaySummary
            )
        }

        let comparison = BatchComparisonManifest(
            batchID: batchManifest.batchID,
            recipeName: recipe.name,
            steps: stepDefs,
            barcodes: sortedSummaries
        )
        try comparison.save(to: batchDir)

        batchManifest.completedAt = Date()
        try batchManifest.save(to: batchDir)

        logger.info("Batch '\(batchName)' completed: \(sources.count) sources × \(recipe.steps.count) steps")

        return batchManifest
    }

    // MARK: - Demux Convenience Wrapper

    /// Executes a recipe across all barcode bundles in a demux group.
    ///
    /// Convenience wrapper around `executeBatch(sources:...)` that converts
    /// `DemultiplexManifest` barcodes into `BatchSource` objects.
    public func executeBatch(
        demuxGroupURL: URL,
        manifest: DemultiplexManifest,
        recipe: ProcessingRecipe,
        batchName: String,
        progress: (@Sendable (BatchProgress) -> Void)? = nil
    ) async throws -> BatchManifest {
        let sources = manifest.barcodes.map { barcode in
            BatchSource(
                bundleURL: demuxGroupURL.appendingPathComponent(barcode.bundleRelativePath),
                displayName: barcode.displayName,
                readCount: barcode.readCount
            )
        }
        return try await executeBatch(
            sources: sources,
            recipe: recipe,
            batchName: batchName,
            outputDirectory: demuxGroupURL,
            progress: progress
        )
    }

    // MARK: - Per-Barcode Processing

    /// Processes a single barcode through all recipe steps sequentially.
    private func processBarcode(
        barcode: BarcodeResult,
        barcodeIndex: Int,
        demuxGroupURL: URL,
        batchDir: URL,
        recipe: ProcessingRecipe,
        totalBarcodes: Int,
        progress: (@Sendable (BatchProgress) -> Void)?
    ) async throws -> BarcodeSummary {
        let barcodeDir = batchDir.appendingPathComponent(barcode.displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)

        // Resolve the barcode's source bundle
        let sourceBundleURL = demuxGroupURL.appendingPathComponent(barcode.bundleRelativePath)
        guard FileManager.default.fileExists(atPath: sourceBundleURL.path) else {
            throw BatchProcessingError.barcodeNotFound(barcode.displayName)
        }

        // Load input statistics for retention calculations
        let inputStats = loadBundleStatistics(from: sourceBundleURL)
        let inputMetrics = StepMetrics(
            readCount: inputStats?.readCount ?? barcode.readCount,
            baseCount: inputStats?.baseCount ?? barcode.baseCount,
            meanReadLength: inputStats?.meanReadLength ?? (barcode.meanReadLength ?? 0),
            medianReadLength: inputStats?.medianReadLength ?? 0,
            n50ReadLength: inputStats?.n50ReadLength ?? 0,
            meanQuality: inputStats?.meanQuality ?? (barcode.meanQuality ?? 0),
            q20Percentage: inputStats?.q20Percentage ?? 0,
            q30Percentage: inputStats?.q30Percentage ?? 0,
            gcContent: inputStats?.gcContent ?? 0
        )

        var currentInputURL = sourceBundleURL
        var stepResults: [StepResult] = []
        let rawReadCount = inputMetrics.readCount

        for (stepIndex, step) in recipe.steps.enumerated() {
            guard !isCancelled else { throw BatchProcessingError.cancelled }

            progress?(BatchProgress(
                totalBarcodes: totalBarcodes,
                completedBarcodes: barcodeIndex,
                currentBarcode: barcode.displayName,
                currentStep: stepIndex,
                totalSteps: recipe.steps.count,
                message: "\(barcode.displayName): \(step.shortLabel) (\(stepIndex + 1)/\(recipe.steps.count))"
            ))

            let stepDir = barcodeDir.appendingPathComponent(
                "step-\(stepIndex + 1)-\(step.shortLabel)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)

            do {
                let request = try convertStepToRequest(step)
                let outputURL = try await derivativeService.createDerivative(
                    from: currentInputURL,
                    request: request,
                    progress: { message in
                        progress?(BatchProgress(
                            totalBarcodes: totalBarcodes,
                            completedBarcodes: barcodeIndex,
                            currentBarcode: barcode.displayName,
                            currentStep: stepIndex,
                            totalSteps: recipe.steps.count,
                            message: "\(barcode.displayName): \(message)"
                        ))
                    }
                )

                // Move output bundle into step directory (atomic replace)
                let destURL = stepDir.appendingPathComponent(outputURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    _ = try FileManager.default.replaceItemAt(destURL, withItemAt: outputURL)
                } else {
                    try FileManager.default.moveItem(at: outputURL, to: destURL)
                }

                // Load output statistics
                let outputStats = loadBundleStatistics(from: destURL)
                let previousReadCount = stepResults.last?.metrics.readCount ?? rawReadCount
                let outputMetrics: StepMetrics
                if let stats = outputStats {
                    outputMetrics = StepMetrics(
                        from: stats,
                        inputReadCount: previousReadCount,
                        rawInputReadCount: rawReadCount
                    )
                } else {
                    outputMetrics = .empty
                }

                stepResults.append(StepResult(
                    stepIndex: stepIndex,
                    status: .completed,
                    metrics: outputMetrics,
                    bundleRelativePath: destURL.lastPathComponent
                ))

                currentInputURL = destURL

            } catch {
                logger.warning("Step \(stepIndex) failed for \(barcode.displayName): \(error)")

                stepResults.append(StepResult(
                    stepIndex: stepIndex,
                    status: .failed,
                    metrics: .empty,
                    errorMessage: error.localizedDescription
                ))

                // Skip remaining steps for this barcode on failure
                for remainingIndex in (stepIndex + 1)..<recipe.steps.count {
                    stepResults.append(StepResult(
                        stepIndex: remainingIndex,
                        status: .skipped,
                        metrics: .empty
                    ))
                }
                break
            }
        }

        return BarcodeSummary(
            label: barcode.displayName,
            inputMetrics: inputMetrics,
            stepResults: stepResults
        )
    }

    /// Processes a single `BatchSource` through all recipe steps sequentially.
    private func processSource(
        source: BatchSource,
        sourceIndex: Int,
        batchDir: URL,
        recipe: ProcessingRecipe,
        totalSources: Int,
        progress: (@Sendable (BatchProgress) -> Void)?
    ) async throws -> BarcodeSummary {
        let sourceDir = batchDir.appendingPathComponent(source.displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: source.bundleURL.path) else {
            throw BatchProcessingError.barcodeNotFound(source.displayName)
        }

        let inputStats = loadBundleStatistics(from: source.bundleURL)
        let inputMetrics = StepMetrics(
            readCount: inputStats?.readCount ?? source.readCount,
            baseCount: inputStats?.baseCount ?? 0,
            meanReadLength: inputStats?.meanReadLength ?? 0,
            medianReadLength: inputStats?.medianReadLength ?? 0,
            n50ReadLength: inputStats?.n50ReadLength ?? 0,
            meanQuality: inputStats?.meanQuality ?? 0,
            q20Percentage: inputStats?.q20Percentage ?? 0,
            q30Percentage: inputStats?.q30Percentage ?? 0,
            gcContent: inputStats?.gcContent ?? 0
        )

        var currentInputURL = source.bundleURL
        var stepResults: [StepResult] = []
        let rawReadCount = inputMetrics.readCount

        for (stepIndex, step) in recipe.steps.enumerated() {
            guard !isCancelled else { throw BatchProcessingError.cancelled }

            progress?(BatchProgress(
                totalBarcodes: totalSources,
                completedBarcodes: sourceIndex,
                currentBarcode: source.displayName,
                currentStep: stepIndex,
                totalSteps: recipe.steps.count,
                message: "\(source.displayName): \(step.shortLabel) (\(stepIndex + 1)/\(recipe.steps.count))"
            ))

            let stepDir = sourceDir.appendingPathComponent(
                "step-\(stepIndex + 1)-\(step.shortLabel)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)

            do {
                let request = try convertStepToRequest(step)
                let outputURL = try await derivativeService.createDerivative(
                    from: currentInputURL,
                    request: request,
                    progress: { message in
                        progress?(BatchProgress(
                            totalBarcodes: totalSources,
                            completedBarcodes: sourceIndex,
                            currentBarcode: source.displayName,
                            currentStep: stepIndex,
                            totalSteps: recipe.steps.count,
                            message: "\(source.displayName): \(message)"
                        ))
                    }
                )

                let destURL = stepDir.appendingPathComponent(outputURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    _ = try FileManager.default.replaceItemAt(destURL, withItemAt: outputURL)
                } else {
                    try FileManager.default.moveItem(at: outputURL, to: destURL)
                }

                let outputStats = loadBundleStatistics(from: destURL)
                let previousReadCount = stepResults.last?.metrics.readCount ?? rawReadCount
                let outputMetrics: StepMetrics
                if let stats = outputStats {
                    outputMetrics = StepMetrics(
                        from: stats,
                        inputReadCount: previousReadCount,
                        rawInputReadCount: rawReadCount
                    )
                } else {
                    outputMetrics = .empty
                }

                stepResults.append(StepResult(
                    stepIndex: stepIndex,
                    status: .completed,
                    metrics: outputMetrics,
                    bundleRelativePath: destURL.lastPathComponent
                ))

                currentInputURL = destURL

            } catch {
                logger.warning("Step \(stepIndex) failed for \(source.displayName): \(error)")

                stepResults.append(StepResult(
                    stepIndex: stepIndex,
                    status: .failed,
                    metrics: .empty,
                    errorMessage: error.localizedDescription
                ))

                for remainingIndex in (stepIndex + 1)..<recipe.steps.count {
                    stepResults.append(StepResult(
                        stepIndex: remainingIndex,
                        status: .skipped,
                        metrics: .empty
                    ))
                }
                break
            }
        }

        return BarcodeSummary(
            label: source.displayName,
            inputMetrics: inputMetrics,
            stepResults: stepResults
        )
    }

    // MARK: - Helpers

    /// Converts a recipe step (FASTQDerivativeOperation) into a service request.
    public nonisolated func convertStepToRequest(_ step: FASTQDerivativeOperation) throws -> FASTQDerivativeRequest {
        switch step.kind {
        case .subsampleProportion:
            return .subsampleProportion(step.proportion ?? 0.1)
        case .subsampleCount:
            return .subsampleCount(step.count ?? 1000)
        case .lengthFilter:
            return .lengthFilter(min: step.minLength, max: step.maxLength)
        case .searchText:
            return .searchText(
                query: step.query ?? "",
                field: step.searchField ?? .id,
                regex: step.useRegex ?? false
            )
        case .searchMotif:
            return .searchMotif(pattern: step.query ?? "", regex: step.useRegex ?? false)
        case .deduplicate:
            let preset = step.deduplicatePreset ?? .exactPCR
            return .deduplicate(
                preset: preset,
                substitutions: step.deduplicateSubstitutions ?? 0,
                optical: step.deduplicateOptical ?? false,
                opticalDistance: step.deduplicateOpticalDistance ?? 40
            )
        case .qualityTrim:
            return .qualityTrim(
                threshold: step.qualityThreshold ?? 20,
                windowSize: step.windowSize ?? 4,
                mode: step.qualityTrimMode ?? .cutRight
            )
        case .adapterTrim:
            return .adapterTrim(
                mode: step.adapterMode ?? .autoDetect,
                sequence: step.adapterSequence,
                sequenceR2: step.adapterSequenceR2,
                fastaFilename: step.adapterFastaFilename
            )
        case .fixedTrim:
            return .fixedTrim(
                from5Prime: step.trimFrom5Prime ?? 0,
                from3Prime: step.trimFrom3Prime ?? 0
            )
        case .contaminantFilter:
            return .contaminantFilter(
                mode: step.contaminantFilterMode ?? .phix,
                referenceFasta: step.contaminantReferenceFasta,
                kmerSize: step.contaminantKmerSize ?? 31,
                hammingDistance: step.contaminantHammingDistance ?? 1
            )
        case .pairedEndMerge:
            return .pairedEndMerge(
                strictness: step.mergeStrictness ?? .normal,
                minOverlap: step.mergeMinOverlap ?? 12
            )
        case .pairedEndRepair:
            return .pairedEndRepair
        case .primerRemoval:
            return .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                source: step.primerSource ?? .literal,
                readMode: step.primerReadMode ?? .single,
                mode: step.primerTrimMode ?? .fivePrime,
                forwardSequence: step.primerForwardSequence ?? step.primerLiteralSequence,
                reverseSequence: step.primerReverseSequence,
                referenceFasta: step.primerReferenceFasta,
                anchored5Prime: step.primerAnchored5Prime ?? true,
                anchored3Prime: step.primerAnchored3Prime ?? true,
                errorRate: step.primerErrorRate ?? 0.15,
                minimumOverlap: step.primerMinimumOverlap ?? 12,
                allowIndels: step.primerAllowIndels ?? true,
                keepUntrimmed: step.primerKeepUntrimmed ?? false,
                searchReverseComplement: step.primerSearchReverseComplement ?? false,
                pairFilter: step.primerPairFilter ?? .any,
                tool: step.primerTool ?? .cutadapt,
                ktrimDirection: step.primerKtrimDirection ?? .left,
                kmerSize: step.primerKmerSize ?? 15,
                minKmer: step.primerMinKmer ?? 11,
                hammingDistance: step.primerHammingDistance ?? 1
            ))
        case .errorCorrection:
            return .errorCorrection(kmerSize: step.errorCorrectionKmerSize ?? 50)
        case .interleaveReformat:
            return .interleaveReformat(direction: step.interleaveDirection ?? .interleave)
        case .demultiplex:
            // Demultiplexing is not a derivative request — it's handled separately.
            // This case should never be in a recipe's steps array.
            throw BatchProcessingError.unsupportedStepInRecipe(step.kind.rawValue)
        case .sequencePresenceFilter:
            return .sequencePresenceFilter(
                sequence: step.adapterFilterSequence,
                fastaPath: step.adapterFilterFastaPath,
                searchEnd: step.adapterFilterSearchEnd ?? .fivePrime,
                minOverlap: step.adapterFilterMinOverlap ?? 16,
                errorRate: step.adapterFilterErrorRate ?? 0.15,
                keepMatched: step.adapterFilterKeepMatched ?? true,
                searchReverseComplement: step.adapterFilterSearchReverseComplement ?? false
            )
        case .orient:
            // Orientation is not yet supported in batch recipes.
            throw BatchProcessingError.unsupportedStepInRecipe(step.kind.rawValue)
        case .humanReadScrub:
            return .humanReadScrub(
                databaseID: step.humanScrubDatabaseID ?? "human-scrubber",
                removeReads: step.humanScrubRemoveReads ?? false
            )
        }
    }

    /// Loads cached statistics from a bundle's metadata.
    private func loadBundleStatistics(from bundleURL: URL) -> FASTQDatasetStatistics? {
        // Try derived manifest first
        if let derived = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            return derived.cachedStatistics
        }
        // Try persisted metadata from the primary FASTQ in the bundle
        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
           let metadata = FASTQMetadataStore.load(for: fastqURL) {
            return metadata.computedStatistics
        }
        return nil
    }
}
