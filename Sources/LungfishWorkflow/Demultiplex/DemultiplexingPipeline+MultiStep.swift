// DemultiplexingPipeline+MultiStep.swift - Multi-step demultiplexing pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "DemultiplexingPipeline")

extension DemultiplexingPipeline {

    // MARK: - Multi-Step Demultiplexing

    /// Runs a multi-step demultiplexing pipeline.
    ///
    /// Step 0 demultiplexes the raw input into outer bins.
    /// Subsequent steps demultiplex each output bin from the previous step.
    ///
    /// - Parameters:
    ///   - plan: The multi-step demultiplexing plan.
    ///   - inputURL: Input FASTQ file or bundle URL.
    ///   - outputDirectory: Root output directory.
    ///   - progress: Progress callback.
    /// - Returns: Combined result with all output bundles.
    /// Maximum number of bins to process concurrently in inner steps.
    private static let maxConcurrentBins = 4

    /// Maximum total bin count across all steps to prevent combinatorial explosion.
    /// 96 outer × 96 inner = 9216 is the largest reasonable scenario.
    private static let maxBinCount = 10_000

    public func runMultiStep(
        plan: DemultiplexPlan,
        inputURL: URL,
        sourceBundleURL: URL? = nil,
        outputDirectory: URL,
        rootBundleURL: URL? = nil,
        rootFASTQFilename: String? = nil,
        inputPairingMode: IngestionMetadata.PairingMode? = nil,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MultiStepDemultiplexResult {
        try plan.validate()
        let startTime = Date()

        let sortedSteps = plan.steps.sorted { $0.ordinal < $1.ordinal }
        var stepResults: [MultiStepDemultiplexResult.StepResult] = []
        var currentInputURLs = [inputURL]
        // Progress tracking: Step 0 gets a fixed share, remaining steps share the rest
        // proportionally. We track cumulative progress explicitly.
        var cumulativeProgress = 0.0

        for (stepIndex, var step) in sortedSteps.enumerated() {
            let stepStartTime = Date()

            guard let kit = BarcodeKitRegistry.kit(byID: step.barcodeKitID) else {
                throw DemultiplexPlanError.missingKit(step: step.label)
            }

            // Auto-scout combinatorial dual kits that have no sample assignments.
            // This discovers which barcode pairs actually exist rather than requiring
            // the user to pre-configure all N×N combinations.
            if kit.pairingMode == .combinatorialDual && step.sampleAssignments.isEmpty {
                logger.info("Step \(stepIndex + 1) uses combinatorial kit '\(kit.displayName)' with no assignments — auto-scouting...")
                let scoutBaseProgress = cumulativeProgress
                progress(scoutBaseProgress, "Step \(stepIndex + 1): Auto-scouting barcode pairs...")
                let scoutInput = currentInputURLs.first ?? inputURL
                let scoutResult = try await scout(
                    inputURL: scoutInput,
                    kit: kit,
                    sourcePlatform: step.sourcePlatform,
                    errorRate: step.errorRate,
                    minimumOverlap: step.minimumOverlap,
                    searchReverseComplement: step.searchReverseComplement,
                    useNoIndels: !step.allowIndels,
                    readLimit: 10_000,
                    acceptThreshold: 3,
                    rejectThreshold: 1,
                    progress: { fraction, message in
                        progress(scoutBaseProgress, "Step \(stepIndex + 1) auto-scout: \(message)")
                    }
                )
                // Convert detected barcode pairs to sample assignments
                let assignments: [FASTQSampleBarcodeAssignment] = scoutResult.detections
                    .filter { $0.hitCount > 0 }
                    .map { detection in
                        let parts = detection.barcodeID.components(separatedBy: "--")
                        if parts.count == 2 {
                            let fwdID = parts[0]
                            let revID = parts[1]
                            let fwdBarcode = kit.barcodes.first { $0.id == fwdID }
                            let revBarcode = kit.barcodes.first { $0.id == revID }
                            return FASTQSampleBarcodeAssignment(
                                sampleID: detection.barcodeID,
                                forwardBarcodeID: fwdID,
                                forwardSequence: fwdBarcode?.i7Sequence,
                                reverseBarcodeID: revID,
                                reverseSequence: revBarcode?.i7Sequence
                            )
                        }
                        let barcode = kit.barcodes.first { $0.id == detection.barcodeID }
                        return FASTQSampleBarcodeAssignment(
                            sampleID: detection.barcodeID,
                            forwardBarcodeID: detection.barcodeID,
                            forwardSequence: barcode?.i7Sequence,
                            reverseBarcodeID: detection.barcodeID,
                            reverseSequence: barcode?.i5Sequence ?? barcode?.i7Sequence
                        )
                    }
                if assignments.isEmpty {
                    logger.warning("Step \(stepIndex + 1) auto-scout found no barcode pairs in '\(kit.displayName)'")
                } else {
                    step.sampleAssignments = assignments
                    logger.info("Step \(stepIndex + 1) auto-scout discovered \(assignments.count) barcode pair(s)")
                }
            }

            let binCount = currentInputURLs.count
            // Weight progress by actual bin count: Step 0 = 1 bin, inner steps = N bins.
            // Allocate progress proportionally: step's share = binCount / totalEstimatedBins
            let stepProgressShare: Double = if sortedSteps.count == 1 {
                1.0
            } else if stepIndex == 0 {
                0.3 // Step 0 (1 bin) gets 30%
            } else {
                0.7 / Double(max(1, sortedSteps.count - 1)) // Remaining steps share 70% equally
            }
            let stepBaseProgress = cumulativeProgress
            let progressPerBin = stepProgressShare / Double(max(1, binCount))

            let isFinalStep = stepIndex == sortedSteps.count - 1
            let stepRootBundleURL = isFinalStep ? rootBundleURL : nil
            let stepRootFASTQFilename = isFinalStep ? rootFASTQFilename : nil

            // Step 0 (single input) runs sequentially; inner steps run bins concurrently.
            // Inner steps use partial-success: per-bin errors are collected, not thrown.
            let perBinResults: [DemultiplexResult]
            var binFailures: [MultiStepDemultiplexResult.BinFailure] = []
            if stepIndex == 0 || binCount <= 1 {
                var results: [DemultiplexResult] = []
                for (binIndex, binInputURL) in currentInputURLs.enumerated() {
                    let binBaseProgress = stepBaseProgress + Double(binIndex) * progressPerBin
                    let config = buildStepConfig(
                        step: step, kit: kit, binInputURL: binInputURL,
                        outputDirectory: outputDirectory,
                        isInnerStep: stepIndex > 0,
                        rootBundleURL: stepRootBundleURL,
                        rootFASTQFilename: stepRootFASTQFilename,
                        inputPairingMode: inputPairingMode,
                        captureTrimsForChaining: !isFinalStep,
                        overrideSourceBundleURL: stepIndex == 0 ? sourceBundleURL : nil
                    )
                    if stepIndex == 0 {
                        // Step 0 failure is fatal — no inputs to fall back on
                        let result = try await run(config: config) { fraction, message in
                            progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1): \(message)")
                        }
                        results.append(result)
                    } else {
                        do {
                            let result = try await run(config: config) { fraction, message in
                                progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1): \(message)")
                            }
                            results.append(result)
                        } catch {
                            let binName = binInputURL.deletingPathExtension().lastPathComponent
                            binFailures.append(.init(binName: binName, errorDescription: error.localizedDescription))
                            logger.warning("Step \(stepIndex + 1) bin '\(binName)' failed: \(error)")
                        }
                    }
                }
                perBinResults = results
            } else {
                // Process inner bins concurrently with bounded parallelism and partial-success
                let binResults: ([DemultiplexResult], [MultiStepDemultiplexResult.BinFailure]) = await {
                    var results = [DemultiplexResult?](repeating: nil, count: binCount)
                    var failures: [MultiStepDemultiplexResult.BinFailure] = []
                    var nextBinIndex = 0

                    await withTaskGroup(of: (Int, Result<DemultiplexResult, Error>).self) { group in
                        // Launch initial batch
                        for _ in 0..<min(Self.maxConcurrentBins, binCount) {
                            let idx = nextBinIndex
                            let binInputURL = currentInputURLs[idx]
                            let binBaseProgress = stepBaseProgress + Double(idx) * progressPerBin
                            let config = buildStepConfig(
                                step: step, kit: kit, binInputURL: binInputURL,
                                outputDirectory: outputDirectory,
                                isInnerStep: stepIndex > 0,
                                rootBundleURL: stepRootBundleURL,
                                rootFASTQFilename: stepRootFASTQFilename,
                                inputPairingMode: inputPairingMode,
                                captureTrimsForChaining: !isFinalStep,
                                overrideSourceBundleURL: stepIndex == 0 ? sourceBundleURL : nil
                            )
                            nextBinIndex += 1
                            group.addTask { [self] in
                                do {
                                    let result = try await self.run(config: config) { fraction, message in
                                        progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1) [\(idx + 1)/\(binCount)]: \(message)")
                                    }
                                    return (idx, .success(result))
                                } catch {
                                    return (idx, .failure(error))
                                }
                            }
                        }

                        // As each completes, launch the next
                        for await (idx, outcome) in group {
                            switch outcome {
                            case .success(let result):
                                results[idx] = result
                            case .failure(let error):
                                let binName = currentInputURLs[idx].deletingPathExtension().lastPathComponent
                                failures.append(.init(binName: binName, errorDescription: error.localizedDescription))
                                logger.warning("Step \(stepIndex + 1) bin '\(binName)' failed: \(error)")
                            }
                            if nextBinIndex < binCount {
                                let nextIdx = nextBinIndex
                                let binInputURL = currentInputURLs[nextIdx]
                                let binBaseProgress = stepBaseProgress + Double(nextIdx) * progressPerBin
                                let config = buildStepConfig(
                                    step: step, kit: kit, binInputURL: binInputURL,
                                    outputDirectory: outputDirectory,
                                    isInnerStep: stepIndex > 0,
                                    rootBundleURL: stepRootBundleURL,
                                    rootFASTQFilename: stepRootFASTQFilename,
                                    inputPairingMode: inputPairingMode,
                                    captureTrimsForChaining: !isFinalStep,
                                    overrideSourceBundleURL: stepIndex == 0 ? sourceBundleURL : nil
                                )
                                nextBinIndex += 1
                                group.addTask { [self] in
                                    do {
                                        let result = try await self.run(config: config) { fraction, message in
                                            progress(binBaseProgress + fraction * progressPerBin, "Step \(stepIndex + 1) [\(nextIdx + 1)/\(binCount)]: \(message)")
                                        }
                                        return (nextIdx, .success(result))
                                    } catch {
                                        return (nextIdx, .failure(error))
                                    }
                                }
                            }
                        }
                    }
                    return (results.compactMap { $0 }, failures)
                }()
                perBinResults = binResults.0
                binFailures = binResults.1
            }

            let stepElapsed = Date().timeIntervalSince(stepStartTime)
            cumulativeProgress += stepProgressShare
            stepResults.append(.init(step: step, perBinResults: perBinResults, binFailures: binFailures, wallClockSeconds: stepElapsed))

            // Next step's inputs are the output bundles from this step
            let previousInputURLs = currentInputURLs
            currentInputURLs = perBinResults.flatMap(\.outputBundleURLs)

            // Convert intermediate full-mode bins to virtual bundles and clean up full FASTQ files.
            // Step 0's inputs are the original user file — never modify those.
            // For subsequent steps, the inputs are full-mode intermediate bundles that should be
            // converted to virtual bundles (read-ids + preview) and have their full FASTQ deleted.
            if stepIndex > 0 {
                for binURL in previousInputURLs {
                    await convertToVirtualBundle(
                        binURL: binURL,
                        rootBundleURL: rootBundleURL,
                        rootFASTQFilename: rootFASTQFilename,
                        pairingMode: inputPairingMode
                    )
                }
                logger.info("Converted \(previousInputURLs.count) intermediate bin(s) to virtual bundles")

                // Clean up empty materialized/ directory if all bins were moved out
                if let firstBin = previousInputURLs.first {
                    let parentDir = firstBin.deletingLastPathComponent()
                    if parentDir.lastPathComponent == "materialized" {
                        let remaining = (try? FileManager.default.contentsOfDirectory(
                            at: parentDir, includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )) ?? []
                        if remaining.isEmpty {
                            try? FileManager.default.removeItem(at: parentDir)
                            logger.info("Removed empty materialized/ directory")
                        }
                    }
                }
            }

            // Guard against combinatorial bin explosion
            if currentInputURLs.count > Self.maxBinCount {
                logger.error("Bin count \(currentInputURLs.count) exceeds maximum \(Self.maxBinCount) after step \(stepIndex + 1)")
                throw DemultiplexError.binCountExceeded(count: currentInputURLs.count, limit: Self.maxBinCount)
            }

            // Log partial failures for this step
            if !binFailures.isEmpty {
                let succeeded = perBinResults.count
                let failed = binFailures.count
                progress(stepBaseProgress + stepProgressShare, "Step \(stepIndex + 1): \(succeeded)/\(succeeded + failed) bins succeeded")
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let finalBundles = stepResults.last?.perBinResults.flatMap(\.outputBundleURLs) ?? []

        guard !stepResults.isEmpty,
              stepResults[0].perBinResults.first?.manifest != nil else {
            throw DemultiplexError.noOutputResults
        }

        // Build composite manifest with multi-step provenance
        let provenance = buildProvenance(
            plan: plan, sortedSteps: sortedSteps,
            stepResults: stepResults, elapsed: elapsed
        )

        // Use last step's kit/parameters for the composite (barcodes array comes from last step)
        let finalManifests = stepResults.last?.perBinResults.map(\.manifest) ?? []
        guard let lastStepManifest = finalManifests.first else {
            throw DemultiplexError.noOutputResults
        }

        let allBarcodes = finalManifests.flatMap(\.barcodes)
        let totalUnassignedReads = finalManifests.reduce(0) { $0 + $1.unassigned.readCount }
        let totalUnassignedBases = finalManifests.reduce(0) { $0 + $1.unassigned.baseCount }

        let compositeManifest = DemultiplexManifest(
            version: 2,
            barcodeKit: lastStepManifest.barcodeKit,
            parameters: lastStepManifest.parameters,
            barcodes: allBarcodes,
            unassigned: UnassignedReadsSummary(
                readCount: totalUnassignedReads,
                baseCount: totalUnassignedBases,
                disposition: lastStepManifest.unassigned.disposition
            ),
            outputDirectoryRelativePath: lastStepManifest.outputDirectoryRelativePath,
            inputReadCount: stepResults[0].perBinResults.reduce(0) { $0 + $1.manifest.inputReadCount },
            multiStepProvenance: provenance
        )

        progress(1.0, "Multi-step demultiplexing complete")

        return MultiStepDemultiplexResult(
            stepResults: stepResults,
            outputBundleURLs: finalBundles,
            manifest: compositeManifest,
            wallClockSeconds: elapsed
        )
    }

    /// Builds a `DemultiplexConfig` from a step definition and a specific input bin.
    ///
    /// For inner steps (non-zero), output goes INSIDE the bin's `.lungfishfastq` bundle
    /// as a `demux/` subdirectory, creating a proper parent-child hierarchy.
    private func buildStepConfig(
        step: DemultiplexStep,
        kit: BarcodeKitDefinition,
        binInputURL: URL,
        outputDirectory: URL,
        isInnerStep: Bool = false,
        rootBundleURL: URL? = nil,
        rootFASTQFilename: String? = nil,
        inputPairingMode: IngestionMetadata.PairingMode? = nil,
        captureTrimsForChaining: Bool = false,
        overrideSourceBundleURL: URL? = nil
    ) -> DemultiplexConfig {
        let stepOutputDir: URL
        if isInnerStep && FASTQBundle.isBundleURL(binInputURL) {
            // Inner step: nest output inside the bin's bundle as demux/ subdirectory
            stepOutputDir = binInputURL.appendingPathComponent("demux", isDirectory: true)
        } else {
            let binName = binInputURL.deletingPathExtension().lastPathComponent
            stepOutputDir = outputDirectory
                .appendingPathComponent(binName, isDirectory: true)
        }

        return DemultiplexConfig(
            inputURL: binInputURL,
            sourceBundleURL: overrideSourceBundleURL ?? (FASTQBundle.isBundleURL(binInputURL) ? binInputURL : nil),
            barcodeKit: kit,
            outputDirectory: stepOutputDir,
            barcodeLocation: step.barcodeLocation,
            symmetryMode: step.symmetryMode,
            errorRate: step.errorRate,
            minimumOverlap: step.minimumOverlap,
            maxDistanceFrom5Prime: step.maxSearchDistance5Prime,
            maxDistanceFrom3Prime: step.maxSearchDistance3Prime,
            trimBarcodes: step.trimBarcodes,
            searchReverseComplement: step.searchReverseComplement,
            unassignedDisposition: step.unassignedDisposition,
            sampleAssignments: step.sampleAssignments,
            sourcePlatform: step.sourcePlatform,
            rootBundleURL: rootBundleURL,
            rootFASTQFilename: rootFASTQFilename,
            inputPairingMode: inputPairingMode,
            minimumInsert: step.minimumInsert,
            useNoIndels: !step.allowIndels,
            captureTrimsForChaining: captureTrimsForChaining
        )
    }

    /// Converts a full-mode intermediate `.lungfishfastq` bundle into a virtual bundle.
    ///
    /// Extracts read IDs and a preview from the full FASTQ, writes a derived manifest,
    /// then deletes the full FASTQ to reclaim disk space. The bundle remains as a
    /// navigable node in the sidebar with its inner demux output nested inside.
    private func convertToVirtualBundle(
        binURL: URL,
        rootBundleURL: URL?,
        rootFASTQFilename: String?,
        pairingMode: IngestionMetadata.PairingMode?
    ) async {
        guard FASTQBundle.isBundleURL(binURL) else { return }
        guard let fullFASTQ = FASTQBundle.resolvePrimaryFASTQURL(for: binURL) else { return }
        guard FileManager.default.fileExists(atPath: fullFASTQ.path) else { return }

        let binName = binURL.deletingPathExtension().lastPathComponent
        do {
            // Extract read IDs
            let readIDsURL = binURL.appendingPathComponent("read-ids.txt")
            if !FileManager.default.fileExists(atPath: readIDsURL.path) {
                let readIDResult = try await runner.run(
                    .seqkit,
                    arguments: ["seq", "--name", "--only-id", fullFASTQ.path, "-o", readIDsURL.path],
                    timeout: 300
                )
                guard readIDResult.isSuccess else {
                    logger.warning("Failed to extract read IDs for \(binName): \(readIDResult.stderr)")
                    return
                }
            }

            // Create preview
            let previewURL = binURL.appendingPathComponent("preview.fastq")
            if !FileManager.default.fileExists(atPath: previewURL.path) {
                let previewResult = try await runner.run(
                    .seqkit,
                    arguments: ["head", "-n", "1000", fullFASTQ.path, "-o", previewURL.path],
                    timeout: 120
                )
                guard previewResult.isSuccess else {
                    logger.warning("Failed to create preview for \(binName): \(previewResult.stderr)")
                    return
                }
            }

            // Compute statistics before deleting the full FASTQ
            let reader = FASTQReader(validateSequence: false)
            let (statistics, _) = try await reader.computeStatistics(from: fullFASTQ, sampleLimit: 0)

            // Write derived manifest
            if let rootBundleURL, let rootFASTQFilename {
                let rootRelativePath = FASTQBundle.projectRelativePath(for: rootBundleURL, from: binURL)
                    ?? relativePath(from: binURL, to: rootBundleURL)
                let demuxOp = FASTQDerivativeOperation(
                    kind: .demultiplex,
                    toolUsed: "cutadapt",
                    toolVersion: await runner.getToolVersion(.cutadapt)
                )
                let manifest = FASTQDerivedBundleManifest(
                    name: binName,
                    parentBundleRelativePath: rootRelativePath,
                    rootBundleRelativePath: rootRelativePath,
                    rootFASTQFilename: rootFASTQFilename,
                    payload: .demuxedVirtual(
                        barcodeID: binName,
                        readIDListFilename: "read-ids.txt",
                        previewFilename: "preview.fastq",
                        trimPositionsFilename: hasTrimPositionsFile(in: binURL) ? "trim-positions.tsv" : nil,
                        orientMapFilename: hasOrientMapFile(in: binURL) ? "orient-map.tsv" : nil
                    ),
                    lineage: [demuxOp],
                    operation: demuxOp,
                    cachedStatistics: statistics,
                    pairingMode: pairingMode
                )
                try FASTQBundle.saveDerivedManifest(manifest, in: binURL)
            }

            // Delete the full FASTQ to reclaim disk space
            try FileManager.default.removeItem(at: fullFASTQ)
            logger.info("Converted \(binName) to virtual bundle (\(statistics.readCount) reads)")

            // If the bundle is inside materialized/, move it up to the parent demux/ directory
            // so it becomes visible to the sidebar (which skips materialized/)
            let parentDir = binURL.deletingLastPathComponent()
            if parentDir.lastPathComponent == "materialized" {
                let demuxDir = parentDir.deletingLastPathComponent()
                let destinationURL = demuxDir.appendingPathComponent(binURL.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.moveItem(at: binURL, to: destinationURL)
                    logger.info("Moved virtual bundle \(binName) from materialized/ to demux/")
                }
            }
        } catch {
            logger.warning("Failed to convert \(binName) to virtual bundle: \(error)")
        }
    }

    /// Builds multi-step provenance from completed step results.
    private func buildProvenance(
        plan: DemultiplexPlan,
        sortedSteps: [DemultiplexStep],
        stepResults: [MultiStepDemultiplexResult.StepResult],
        elapsed: Double
    ) -> MultiStepProvenance {
        let summaries = zip(sortedSteps, stepResults).map { step, result in
            MultiStepProvenance.StepSummary(
                label: step.label,
                barcodeKitID: step.barcodeKitID,
                symmetryMode: step.symmetryMode,
                errorRate: step.errorRate,
                inputBinCount: result.perBinResults.count,
                outputBundleCount: result.perBinResults.reduce(0) { $0 + $1.outputBundleURLs.count },
                totalReadsProcessed: result.perBinResults.reduce(0) { $0 + $1.manifest.inputReadCount },
                wallClockSeconds: result.wallClockSeconds
            )
        }

        return MultiStepProvenance(
            totalSteps: sortedSteps.count,
            stepSummaries: summaries,
            compositeSampleNames: plan.compositeSampleNames,
            totalWallClockSeconds: elapsed
        )
    }

    // MARK: - Helpers

    /// Compute a relative path from one URL to another (e.g. "../../parent-bundle.fastqbundle").
    func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents

        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let down = Array(targetComponents.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}

