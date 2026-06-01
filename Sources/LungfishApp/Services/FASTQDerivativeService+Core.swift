// FASTQDerivativeService+Core.swift - Export + createDerivative core
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    /// Materializes a derived FASTQ bundle to a standalone FASTQ file.
    ///
    /// Reads from the root FASTQ, applies the derivative's filter or trim positions,
    /// and writes the result to the specified output URL.
    public func exportMaterializedFASTQ(
        fromDerivedBundle bundleURL: URL,
        to outputURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        guard FASTQBundle.isDerivedBundle(bundleURL) else {
            throw FASTQDerivativeError.derivedManifestMissing
        }

        let tempDir = try makeTemporaryDirectory(prefix: "fastq-export-", contextURL: bundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        progress?("Materializing dataset...")
        let materializedURL = try await materializeDatasetFASTQ(
            fromBundle: bundleURL,
            tempDirectory: tempDir,
            progress: progress
        )

        progress?("Writing to output file...")
        try FileManager.default.copyItem(at: materializedURL, to: outputURL)
        progress?("Export complete: \(outputURL.lastPathComponent)")
    }

    public func createDerivative(
        from sourceBundleURL: URL,
        request: FASTQDerivativeRequest,
        batchOperationID: UUID? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let provenanceStartedAt = Date()
        guard FASTQBundle.isBundleURL(sourceBundleURL) else {
            throw FASTQDerivativeError.sourceMustBeBundle
        }

        let tempDir = try makeTemporaryDirectory(prefix: "fastq-derive-", contextURL: sourceBundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        progress?("Resolving source dataset...")
        let materializedSourceFASTQ = try await materializeDatasetFASTQ(
            fromBundle: sourceBundleURL,
            tempDirectory: tempDir,
            progress: progress
        )
        let sourceSequenceFormat = SequenceFormat.from(url: materializedSourceFASTQ)
            ?? FASTQBundle.loadDerivedManifest(in: sourceBundleURL)?.sequenceFormat
            ?? .fastq
        let executionSourceFASTQ: URL
        let sourceBridgeFASTQ: URL?
        if sourceSequenceFormat == .fasta {
            let bridgedFASTQ = tempDir.appendingPathComponent("bridged-source.fastq")
            try await SyntheticFASTQBridge.convertFASTAToFASTQ(
                inputURL: materializedSourceFASTQ,
                outputURL: bridgedFASTQ
            )
            executionSourceFASTQ = bridgedFASTQ
            sourceBridgeFASTQ = bridgedFASTQ
        } else {
            executionSourceFASTQ = materializedSourceFASTQ
            sourceBridgeFASTQ = nil
        }

        // Resolve lineage and root bundle info (needed for all operation types)
        let sourceManifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL)
        let rootFASTQFilename: String
        let resolvedRootBundleURL: URL  // Actual root bundle containing the physical FASTQ
        let pairingMode: IngestionMetadata.PairingMode?
        let baseLineage: [FASTQDerivativeOperation]

        if let sourceManifest {
            resolvedRootBundleURL = FASTQBundle.resolveBundle(
                relativePath: sourceManifest.rootBundleRelativePath,
                from: sourceBundleURL
            )
            rootFASTQFilename = sourceManifest.rootFASTQFilename
            pairingMode = sourceManifest.pairingMode
            baseLineage = sourceManifest.lineage
        } else {
            guard let rootFASTQURL = FASTQBundle.resolvePrimarySequenceURL(for: sourceBundleURL) else {
                throw FASTQDerivativeError.sourceFASTQMissing
            }
            rootFASTQFilename = rootFASTQURL.lastPathComponent
            resolvedRootBundleURL = sourceBundleURL
            pairingMode = SequenceFormat.from(url: rootFASTQURL) == .fastq
                ? FASTQMetadataStore.load(for: rootFASTQURL)?.ingestion?.pairingMode
                : nil
            baseLineage = []
        }

        // Orient has its own execution path — produces an orient-map derivative
        if case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented, let extraArguments) = request {
            let provenanceInputRecord = try durableSourceInputRecord(
                for: sourceBundleURL,
                sequenceFormat: sourceSequenceFormat
            )
            return try await createOrientDerivative(
                sourceFASTQ: executionSourceFASTQ,
                sourceProvenanceInputRecord: provenanceInputRecord,
                sourceBridgeFASTQ: sourceBridgeFASTQ,
                sourceBundleURL: sourceBundleURL,
                resolvedRootBundleURL: resolvedRootBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                sourceSequenceFormat: sourceSequenceFormat,
                pairingMode: pairingMode,
                baseLineage: baseLineage,
                referenceURL: referenceURL,
                wordLength: wordLength,
                dbMask: dbMask,
                saveUnoriented: saveUnoriented,
                extraArguments: extraArguments,
                batchOperationID: batchOperationID,
                progress: progress
            )
        }

        // Mixed-output operations (merge/repair) write multiple files directly
        // to the output bundle, bypassing the single-file temp flow.
        if case .demultiplex(
            let kitID,
            let customCSVPath,
            let location,
            let symmetryMode,
            let maxDistanceFrom5Prime,
            let maxDistanceFrom3Prime,
            let errorRate,
            let engine,
            let trimBarcodes,
            let sampleAssignments,
            let kitOverride
        ) = request {
            return try await createDemultiplexDerivative(
                sourceFASTQ: executionSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                rootBundleURL: resolvedRootBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                inputSequenceFormat: sourceSequenceFormat,
                pairingMode: pairingMode,
                kitID: kitID,
                customCSVPath: customCSVPath,
                location: location,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                errorRate: errorRate,
                engine: engine,
                symmetryMode: symmetryMode,
                trimBarcodes: trimBarcodes,
                sampleAssignments: sampleAssignments ?? [],
                kitOverride: kitOverride,
                batchOperationID: batchOperationID,
                progress: progress
            )
        }

        if request.isMixedOutputOperation {
            return try await createMixedOutputDerivative(
                request: request,
                sourceFASTQ: executionSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                sourceSequenceFormat: sourceSequenceFormat,
                resolvedRootBundleURL: resolvedRootBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                pairingMode: pairingMode,
                baseLineage: baseLineage,
                nativeTemporaryPathRoots: [tempDir.path],
                batchOperationID: batchOperationID,
                progress: progress
            )
        }

        progress?("Applying transformation...")
        let transformedFASTQ = tempDir.appendingPathComponent("transformed.fastq")
        let nativeProvenanceCollector = FASTQDerivativeNativeProvenanceCollector()
        let operation = try await runTransformation(
            request: request,
            sourceFASTQ: executionSourceFASTQ,
            outputFASTQ: transformedFASTQ,
            sourceBundleURL: sourceBundleURL,
            provenanceCollector: nativeProvenanceCollector,
            progress: progress
        )

        let outputSequenceFormat = request.outputSequenceFormat(sourceSequenceFormat: sourceSequenceFormat)

        // Statistics are computed on the transformed output. For deinterleave, this is the
        // interleaved source (same reads, just reorganized into R1/R2), so stats represent
        // the combined R1+R2 dataset — which is correct for display purposes.
        progress?("Computing output statistics...")
        let stats: FASTQDatasetStatistics
        if outputSequenceFormat == .fasta {
            stats = try await SyntheticFASTQBridge.placeholderStatistics(fromFASTQ: transformedFASTQ)
        } else {
            let reader = FASTQReader(validateSequence: false)
            let computed = try await reader.computeStatistics(from: transformedFASTQ, sampleLimit: 0)
            stats = computed.0
        }
        guard stats.readCount > 0 else {
            throw FASTQDerivativeError.emptyResult
        }

        let lineage = baseLineage + [operation]

        let outputBundle = try createOutputBundleURL(
            sourceBundleURL: sourceBundleURL,
            operation: operation
        )
        try FileManager.default.createDirectory(at: outputBundle, withIntermediateDirectories: true)
        var shouldCleanOutputBundleOnFailure = true
        defer {
            if shouldCleanOutputBundleOnFailure {
                try? FileManager.default.removeItem(at: outputBundle)
            }
        }
        OperationMarker.markInProgress(outputBundle, detail: "Creating derivative FASTQ\u{2026}")
        defer { OperationMarker.clearInProgress(outputBundle) }

        // Build payload depending on operation type
        let payload: FASTQDerivativePayload
        if request.isFullPairedOperation {
            // Deinterleave — the transformed output contains interleaved R1/R2
            // but we need to split into separate files using reformat.sh
            progress?("Splitting into R1/R2...")
            let r1Filename = "R1.fastq"
            let r2Filename = "R2.fastq"
            let r1URL = outputBundle.appendingPathComponent(r1Filename)
            let r2URL = outputBundle.appendingPathComponent(r2Filename)

            let env = await bbToolsEnvironment()
            let splitResult = try await runNativeTool(
                .reformat,
                arguments: [
                    "in=\(transformedFASTQ.path)",
                    "out1=\(r1URL.path)",
                    "out2=\(r2URL.path)",
                    "interleaved=t",
                ],
                environment: env,
                timeout: 1800,
                provenanceCollector: nativeProvenanceCollector
            )
            guard splitResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("reformat.sh deinterleave failed: \(splitResult.stderr)")
            }
            payload = .fullPaired(r1Filename: r1Filename, r2Filename: r2Filename)
        } else if request.isFullOperation {
            if outputSequenceFormat == .fasta {
                progress?("Storing materialized FASTA...")
                let fastaFilename = "reads.fasta"
                let destinationFASTA = outputBundle.appendingPathComponent(fastaFilename)
                try await convertFASTQSequencesToFASTA(
                    inputURL: transformedFASTQ,
                    outputURL: destinationFASTA
                )
                payload = .fullFASTA(fastaFilename: fastaFilename)
            } else {
                // Full materialization — copy the transformed FASTQ into the output bundle
                progress?("Storing materialized FASTQ...")
                let fastqFilename = "reads.fastq"
                let destinationFASTQ = outputBundle.appendingPathComponent(fastqFilename)
                try FileManager.default.copyItem(at: transformedFASTQ, to: destinationFASTQ)
                payload = .full(fastqFilename: fastqFilename)
            }
        } else if request.isTrimOperation {
            // Extract trim positions by diffing original vs trimmed FASTQ
            progress?("Extracting trim positions...")
            let trimRecords = try await extractTrimPositions(
                originalFASTQ: executionSourceFASTQ,
                trimmedFASTQ: transformedFASTQ
            )
            guard !trimRecords.isEmpty else {
                throw FASTQDerivativeError.emptyResult
            }

            // If the source was already a trim derivative, compose positions
            // to get absolute positions relative to root.
            let finalRecords: [FASTQTrimRecord]
            if let sourceManifest, case .trim = sourceManifest.payload {
                let sourceBundleTrimURL = FASTQBundle.trimPositionsURL(forDerivedBundle: sourceBundleURL)
                if let trimURL = sourceBundleTrimURL {
                    let parentPositions = try FASTQTrimPositionFile.load(from: trimURL)
                    // Use last-wins to handle PE reads with same base ID safely
                    var childPositions: [String: (start: Int, end: Int)] = [:]
                    for record in trimRecords {
                        childPositions[record.readID] = (start: record.trimStart, end: record.trimEnd)
                    }
                    let composed = FASTQTrimPositionFile.compose(parent: parentPositions, child: childPositions)
                    finalRecords = composed.map { FASTQTrimRecord(readID: $0.key, trimStart: $0.value.start, trimEnd: $0.value.end) }
                } else {
                    finalRecords = trimRecords
                }
            } else {
                finalRecords = trimRecords
            }

            let trimFilename = FASTQBundle.trimPositionFilename
            let trimURL = outputBundle.appendingPathComponent(trimFilename)
            try FASTQTrimPositionFile.write(finalRecords, to: trimURL)
            // Write preview.fastq from the trimmed output so the viewport can display it
            let previewURL = outputBundle.appendingPathComponent("preview.fastq")
            try await writePreviewFASTQ(from: transformedFASTQ, to: previewURL)
            payload = .trim(trimPositionFilename: trimFilename)
        } else {
            // Subset: extract read IDs (deduplicate for PE data to avoid doubled reads)
            progress?("Extracting read pointers...")
            let readIDListURL = tempDir.appendingPathComponent("read-ids.txt")
            let isInterleaved = isInterleavedBundle(sourceBundleURL)
            let readCount = try await writeReadIDs(fromFASTQ: transformedFASTQ, to: readIDListURL, deduplicate: isInterleaved)
            guard readCount > 0 else {
                throw FASTQDerivativeError.emptyResult
            }

            let destinationReadIDURL = outputBundle.appendingPathComponent("read-ids.txt")
            try FileManager.default.copyItem(at: readIDListURL, to: destinationReadIDURL)
            let previewURL = outputBundle.appendingPathComponent("preview.fastq")
            try await writePreviewFASTQ(from: transformedFASTQ, to: previewURL)
            try propagateVirtualSubsetSidecars(
                from: sourceBundleURL,
                selectedReadIDsFile: destinationReadIDURL,
                to: outputBundle
            )
            payload = .subset(readIDListFilename: destinationReadIDURL.lastPathComponent)
        }

        // Compute relative paths from the output bundle to parent and root bundles.
        // Prefer project-relative paths (@/...); fall back to filesystem-relative.
        let parentRelativePath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: outputBundle)
            ?? relativePathFromBundle(outputBundle, to: sourceBundleURL)
        let rootRelativePath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: outputBundle)
            ?? relativePathFromBundle(outputBundle, to: resolvedRootBundleURL)

        let manifest = FASTQDerivedBundleManifest(
            name: outputBundle.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: rootRelativePath,
            rootFASTQFilename: rootFASTQFilename,
            payload: payload,
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats,
            pairingMode: pairingMode,
            batchOperationID: batchOperationID,
            sequenceFormat: outputSequenceFormat
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundle)
        let nativeReplayContext = derivativeNativeReplayContext(
            sourceFASTQ: executionSourceFASTQ,
            sourceBundleURL: sourceBundleURL,
            sourceSequenceFormat: sourceSequenceFormat,
            transformedFASTQ: transformedFASTQ,
            outputBundleURL: outputBundle,
            payload: payload,
            temporaryPathRoots: [tempDir.path]
        )
        try await writeDerivativeProvenance(
            workflowName: "lungfish fastq \(request.operationKindString) derivative",
            request: request,
            operation: operation,
            sourceBundleURL: sourceBundleURL,
            sourceSequenceFormat: sourceSequenceFormat,
            outputBundleURL: outputBundle,
            nativeExecutions: nativeProvenanceCollector.snapshot(),
            nativeReplayContext: nativeReplayContext,
            startedAt: provenanceStartedAt,
            completedAt: Date()
        )

        progress?("Created derived dataset: \(outputBundle.lastPathComponent)")
        derivativeLogger.info("Created FASTQ derivative bundle at \(outputBundle.path, privacy: .public)")
        shouldCleanOutputBundleOnFailure = false
        return outputBundle
    }

}
