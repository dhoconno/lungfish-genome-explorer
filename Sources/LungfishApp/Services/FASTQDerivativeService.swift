// FASTQDerivativeService.swift - Pointer-based FASTQ derivative creation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import os.log

private let derivativeLogger = Logger(subsystem: "com.lungfish.browser", category: "FASTQDerivativeService")

public enum FASTQDerivativeRequest: Sendable {
    // Subset operations (produce read ID lists)
    case subsampleProportion(Double)
    case subsampleCount(Int)
    case lengthFilter(min: Int?, max: Int?)
    case searchText(query: String, field: FASTQSearchField, regex: Bool)
    case searchMotif(pattern: String, regex: Bool)
    case deduplicate(mode: FASTQDeduplicateMode, pairedAware: Bool)

    // Trim operations (produce trim position records)
    case qualityTrim(threshold: Int, windowSize: Int, mode: FASTQQualityTrimMode)
    case adapterTrim(mode: FASTQAdapterMode, sequence: String?, sequenceR2: String?, fastaFilename: String?)
    case fixedTrim(from5Prime: Int, from3Prime: Int)

    // BBTools operations
    case contaminantFilter(mode: FASTQContaminantFilterMode, referenceFasta: String?, kmerSize: Int, hammingDistance: Int)
    case pairedEndMerge(strictness: FASTQMergeStrictness, minOverlap: Int)
    case pairedEndRepair
    case primerRemoval(source: FASTQPrimerSource, literalSequence: String?, referenceFasta: String?, kmerSize: Int, minKmer: Int, hammingDistance: Int)
    case errorCorrection(kmerSize: Int)
    case interleaveReformat(direction: FASTQInterleaveDirection)

    // Demultiplexing (produces per-barcode bundles)
    case demultiplex(
        kitID: String,
        customCSVPath: String?,
        location: String,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        errorRate: Double,
        trimBarcodes: Bool,
        sampleAssignments: [FASTQSampleBarcodeAssignment]?,
        kitOverride: BarcodeKitDefinition?
    )

    // Multi-step demultiplexing (produces per-barcode bundles via DemultiplexPlan)
    case multiStepDemultiplex(plan: DemultiplexPlan, sourcePlatform: SequencingPlatform?)

    // Orient sequences against a reference
    case orient(
        referenceURL: URL,
        wordLength: Int,
        dbMask: String,
        saveUnoriented: Bool
    )

    /// Human-readable label for this operation, used in the Operations panel.
    var operationLabel: String {
        switch self {
        case .subsampleProportion(let p): return "Subsample \(Int(p * 100))%"
        case .subsampleCount(let n): return "Subsample \(n) reads"
        case .lengthFilter: return "Length Filter"
        case .searchText: return "Search"
        case .searchMotif: return "Motif Search"
        case .deduplicate: return "Deduplicate"
        case .qualityTrim: return "Quality Trim"
        case .adapterTrim: return "Adapter Trim"
        case .fixedTrim: return "Fixed Trim"
        case .contaminantFilter: return "Contaminant Filter"
        case .pairedEndMerge: return "Paired-End Merge"
        case .pairedEndRepair: return "Paired-End Repair"
        case .primerRemoval: return "Primer Removal"
        case .errorCorrection: return "Error Correction"
        case .interleaveReformat: return "Interleave Reformat"
        case .demultiplex: return "Demultiplex"
        case .multiStepDemultiplex: return "Multi-Step Demultiplex"
        case .orient: return "Orient Sequences"
        }
    }

    /// Whether this request produces a trim derivative (vs subset).
    var isTrimOperation: Bool {
        switch self {
        case .qualityTrim, .adapterTrim, .fixedTrim:
            return true
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .contaminantFilter:
            return false
        case .pairedEndMerge, .pairedEndRepair, .primerRemoval,
             .errorCorrection, .interleaveReformat, .demultiplex,
             .multiStepDemultiplex, .orient:
            return false
        }
    }

    /// Whether this request produces a full materialized FASTQ (content-transforming).
    var isFullOperation: Bool {
        switch self {
        case .pairedEndMerge, .pairedEndRepair, .primerRemoval,
             .errorCorrection, .interleaveReformat, .demultiplex,
             .multiStepDemultiplex:
            return true
        default:
            return false
        }
    }

    /// Whether this request produces an orient-map derivative.
    var isOrientOperation: Bool {
        if case .orient = self { return true }
        return false
    }

    /// Whether this request produces paired R1/R2 output files.
    var isFullPairedOperation: Bool {
        if case .interleaveReformat(let dir) = self, dir == .deinterleave {
            return true
        }
        return false
    }

    /// Whether this operation produces multiple classified output files (mixed read types).
    var isMixedOutputOperation: Bool {
        switch self {
        case .pairedEndMerge, .pairedEndRepair:
            return true
        default:
            return false
        }
    }
}

public enum FASTQDerivativeError: Error, LocalizedError {
    case sourceMustBeBundle
    case sourceFASTQMissing
    case derivedManifestMissing
    case parentBundleMissing(String)
    case rootBundleMissing(String)
    case rootFASTQMissing
    case invalidOperation(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .sourceMustBeBundle:
            return "FASTQ operations require a .lungfishfastq bundle."
        case .sourceFASTQMissing:
            return "The source FASTQ file is missing from the bundle."
        case .derivedManifestMissing:
            return "Derived FASTQ manifest is missing."
        case .parentBundleMissing(let path):
            return "Parent FASTQ bundle not found: \(path)"
        case .rootBundleMissing(let path):
            return "Root FASTQ bundle not found: \(path)"
        case .rootFASTQMissing:
            return "Root FASTQ payload is missing."
        case .invalidOperation(let reason):
            return "Invalid FASTQ operation: \(reason)"
        case .emptyResult:
            return "Operation produced no reads."
        }
    }
}

/// Creates pointer-based FASTQ derivative bundles using bundled tools.
public actor FASTQDerivativeService {
    public static let shared = FASTQDerivativeService()

    private let runner = NativeToolRunner.shared

    /// Cached BBTools environment dictionary — stable across the actor's lifetime.
    private var cachedBBToolsEnv: [String: String]?

    public init() {}

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

        let tempDir = try makeTemporaryDirectory(prefix: "fastq-export-")
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
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard FASTQBundle.isBundleURL(sourceBundleURL) else {
            throw FASTQDerivativeError.sourceMustBeBundle
        }

        let tempDir = try makeTemporaryDirectory(prefix: "fastq-derive-")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        progress?("Resolving source dataset...")
        let materializedSourceFASTQ = try await materializeDatasetFASTQ(
            fromBundle: sourceBundleURL,
            tempDirectory: tempDir,
            progress: progress
        )

        // Resolve lineage and root bundle info (needed for all operation types)
        let sourceManifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL)
        let parentRelativePath = "../\(sourceBundleURL.lastPathComponent)"
        let rootRelativePath: String
        let rootFASTQFilename: String
        let pairingMode: IngestionMetadata.PairingMode?
        let baseLineage: [FASTQDerivativeOperation]

        if let sourceManifest {
            rootRelativePath = sourceManifest.rootBundleRelativePath
            rootFASTQFilename = sourceManifest.rootFASTQFilename
            pairingMode = sourceManifest.pairingMode
            baseLineage = sourceManifest.lineage
        } else {
            guard let rootFASTQURL = FASTQBundle.resolvePrimaryFASTQURL(for: sourceBundleURL) else {
                throw FASTQDerivativeError.sourceFASTQMissing
            }
            rootRelativePath = "../\(sourceBundleURL.lastPathComponent)"
            rootFASTQFilename = rootFASTQURL.lastPathComponent
            pairingMode = FASTQMetadataStore.load(for: rootFASTQURL)?.ingestion?.pairingMode
            baseLineage = []
        }

        // Multi-step demultiplexing has its own execution path
        if case .multiStepDemultiplex(let plan, _) = request {
            return try await createMultiStepDemultiplexDerivative(
                plan: plan,
                sourceFASTQ: materializedSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                progress: progress
            )
        }

        // Orient has its own execution path — produces an orient-map derivative
        if case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented) = request {
            return try await createOrientDerivative(
                sourceFASTQ: materializedSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                parentRelativePath: parentRelativePath,
                rootRelativePath: rootRelativePath,
                rootFASTQFilename: rootFASTQFilename,
                pairingMode: pairingMode,
                baseLineage: baseLineage,
                referenceURL: referenceURL,
                wordLength: wordLength,
                dbMask: dbMask,
                saveUnoriented: saveUnoriented,
                progress: progress
            )
        }

        // Mixed-output operations (merge/repair) write multiple files directly
        // to the output bundle, bypassing the single-file temp flow.
        if case .demultiplex(
            let kitID,
            let customCSVPath,
            let location,
            let maxDistanceFrom5Prime,
            let maxDistanceFrom3Prime,
            let errorRate,
            let trimBarcodes,
            let sampleAssignments,
            let kitOverride
        ) = request {
            return try await createDemultiplexDerivative(
                sourceFASTQ: materializedSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                kitID: kitID,
                customCSVPath: customCSVPath,
                location: location,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                errorRate: errorRate,
                trimBarcodes: trimBarcodes,
                sampleAssignments: sampleAssignments ?? [],
                kitOverride: kitOverride,
                progress: progress
            )
        }

        if request.isMixedOutputOperation {
            return try await createMixedOutputDerivative(
                request: request,
                sourceFASTQ: materializedSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                parentRelativePath: parentRelativePath,
                rootRelativePath: rootRelativePath,
                rootFASTQFilename: rootFASTQFilename,
                pairingMode: pairingMode,
                baseLineage: baseLineage,
                progress: progress
            )
        }

        progress?("Applying transformation...")
        let transformedFASTQ = tempDir.appendingPathComponent("transformed.fastq")
        let operation = try await runTransformation(
            request: request,
            sourceFASTQ: materializedSourceFASTQ,
            outputFASTQ: transformedFASTQ,
            sourceBundleURL: sourceBundleURL,
            progress: progress
        )

        // Statistics are computed on the transformed output. For deinterleave, this is the
        // interleaved source (same reads, just reorganized into R1/R2), so stats represent
        // the combined R1+R2 dataset — which is correct for display purposes.
        progress?("Computing output statistics...")
        let reader = FASTQReader(validateSequence: false)
        let (stats, _) = try await reader.computeStatistics(from: transformedFASTQ, sampleLimit: 0)
        guard stats.readCount > 0 else {
            throw FASTQDerivativeError.emptyResult
        }

        let lineage = baseLineage + [operation]

        let outputBundle = try createOutputBundleURL(
            sourceBundleURL: sourceBundleURL,
            operation: operation
        )
        try FileManager.default.createDirectory(at: outputBundle, withIntermediateDirectories: true)

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
            let splitResult = try await runner.run(
                .reformat,
                arguments: [
                    "in=\(transformedFASTQ.path)",
                    "out1=\(r1URL.path)",
                    "out2=\(r2URL.path)",
                    "interleaved=t",
                ],
                environment: env,
                timeout: 1800
            )
            guard splitResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("reformat.sh deinterleave failed: \(splitResult.stderr)")
            }
            payload = .fullPaired(r1Filename: r1Filename, r2Filename: r2Filename)
        } else if request.isFullOperation {
            // Full materialization — copy the transformed FASTQ into the output bundle
            progress?("Storing materialized FASTQ...")
            let fastqFilename = "reads.fastq"
            let destinationFASTQ = outputBundle.appendingPathComponent(fastqFilename)
            try FileManager.default.copyItem(at: transformedFASTQ, to: destinationFASTQ)
            payload = .full(fastqFilename: fastqFilename)
        } else if request.isTrimOperation {
            // Extract trim positions by diffing original vs trimmed FASTQ
            progress?("Extracting trim positions...")
            let trimRecords = try await extractTrimPositions(
                originalFASTQ: materializedSourceFASTQ,
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
            payload = .subset(readIDListFilename: destinationReadIDURL.lastPathComponent)
        }

        let manifest = FASTQDerivedBundleManifest(
            name: outputBundle.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: rootRelativePath,
            rootFASTQFilename: rootFASTQFilename,
            payload: payload,
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats,
            pairingMode: pairingMode
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundle)

        progress?("Created derived dataset: \(outputBundle.lastPathComponent)")
        derivativeLogger.info("Created FASTQ derivative bundle at \(outputBundle.path, privacy: .public)")
        return outputBundle
    }

    // MARK: - Mixed Output Derivatives

    /// Runs vsearch orient and creates an orient-map derivative bundle.
    ///
    /// The orient-map derivative stores a TSV mapping read IDs to orientation (+/-)
    /// and a preview FASTQ of the first 1000 oriented reads. The full oriented FASTQ
    /// is materialized on demand using seqkit.
    private func createOrientDerivative(
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        parentRelativePath: String,
        rootRelativePath: String,
        rootFASTQFilename: String,
        pairingMode: IngestionMetadata.PairingMode?,
        baseLineage: [FASTQDerivativeOperation],
        referenceURL: URL,
        wordLength: Int,
        dbMask: String,
        saveUnoriented: Bool,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        progress?("Running vsearch orient...")

        let pipeline = OrientPipeline(runner: runner)
        let config = OrientConfig(
            inputURL: sourceFASTQ,
            referenceURL: referenceURL,
            wordLength: wordLength,
            dbMask: dbMask,
            qMask: dbMask,
            saveUnoriented: saveUnoriented
        )

        let result = try await pipeline.run(config: config) { fraction, msg in
            progress?(msg)
        }

        progress?("Creating orient derivative bundle...")

        // Create the derivative bundle in the Derivatives folder
        let derivativesDir = sourceBundleURL.appendingPathComponent("Derivatives", isDirectory: true)
        try FileManager.default.createDirectory(at: derivativesDir, withIntermediateDirectories: true)

        let bundleName = "oriented.lungfishfastq"
        let bundleURL = derivativesDir.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Create the orient-map TSV from vsearch tabbed output
        let orientMapFilename = "orient-map.tsv"
        let orientMapURL = bundleURL.appendingPathComponent(orientMapFilename)
        let (fwdCount, rcCount) = try pipeline.createOrientMap(
            from: result.tabbedOutput,
            to: orientMapURL
        )

        // Create a preview FASTQ (first 1000 oriented reads)
        let previewFilename = "preview.fastq"
        let previewURL = bundleURL.appendingPathComponent(previewFilename)
        let previewResult = try await runner.run(
            .seqkit,
            arguments: [
                "head", "-n", "1000",
                result.orientedFASTQ.path,
                "-o", previewURL.path,
            ],
            timeout: 60
        )
        if !previewResult.isSuccess {
            derivativeLogger.warning("Failed to create orient preview: \(previewResult.stderr)")
        }

        // Compute statistics on the oriented output
        let statsResult = try await runner.run(
            .seqkit,
            arguments: ["stats", "--tabular", result.orientedFASTQ.path],
            timeout: 120
        )
        let stats = parseFASTQStats(statsResult.stdout)

        var orientCommandParts: [String] = [
            "vsearch",
            "--orient", sourceFASTQ.path,
            "--db", referenceURL.path,
            "--fastqout", result.orientedFASTQ.path,
            "--tabbedout", result.tabbedOutput.path,
            "--wordlength", String(wordLength),
            "--dbmask", dbMask,
            "--qmask", dbMask,
            "--threads", "0",
        ]
        if saveUnoriented, let unorientedFASTQ = result.unorientedFASTQ {
            orientCommandParts += ["--notmatched", unorientedFASTQ.path]
        }
        let orientCommand = orientCommandParts.joined(separator: " ")

        // Build the operation record
        let operation = FASTQDerivativeOperation(
            kind: .orient,
            orientReferencePath: referenceURL.lastPathComponent,
            orientWordLength: wordLength,
            orientDbMask: dbMask,
            orientSaveUnoriented: saveUnoriented,
            orientRCCount: rcCount,
            orientUnmatchedCount: result.unmatchedCount,
            toolUsed: "vsearch",
            toolCommand: orientCommand
        )

        var lineage = baseLineage
        lineage.append(operation)

        let manifest = FASTQDerivedBundleManifest(
            name: "Oriented",
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: rootRelativePath,
            rootFASTQFilename: rootFASTQFilename,
            payload: .orientMap(orientMapFilename: orientMapFilename, previewFilename: previewFilename),
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats ?? .placeholder(readCount: fwdCount + rcCount, baseCount: 0),
            pairingMode: pairingMode
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent("manifest.json"))

        // Optionally create unoriented reads derivative
        if saveUnoriented, let unorientedFASTQ = result.unorientedFASTQ,
           FileManager.default.fileExists(atPath: unorientedFASTQ.path) {
            let unorientedBundleName = "unoriented.lungfishfastq"
            let unorientedBundleURL = derivativesDir.appendingPathComponent(unorientedBundleName, isDirectory: true)
            try FileManager.default.createDirectory(at: unorientedBundleURL, withIntermediateDirectories: true)

            // Copy the unoriented FASTQ
            let unorientedDest = unorientedBundleURL.appendingPathComponent("unoriented.fastq")
            try FileManager.default.copyItem(at: unorientedFASTQ, to: unorientedDest)

            let unorientedStats = parseFASTQStats(
                (try? await runner.run(.seqkit, arguments: ["stats", "--tabular", unorientedDest.path], timeout: 120))?.stdout ?? ""
            )

            let unorientedOp = FASTQDerivativeOperation(
                kind: .orient,
                orientReferencePath: referenceURL.lastPathComponent,
                orientSaveUnoriented: true,
                orientUnmatchedCount: result.unmatchedCount,
                toolUsed: "vsearch",
                toolCommand: orientCommand
            )

            var unorientedLineage = baseLineage
            unorientedLineage.append(unorientedOp)

            let unorientedManifest = FASTQDerivedBundleManifest(
                name: "Unoriented",
                parentBundleRelativePath: parentRelativePath,
                rootBundleRelativePath: rootRelativePath,
                rootFASTQFilename: rootFASTQFilename,
                payload: .full(fastqFilename: "unoriented.fastq"),
                lineage: unorientedLineage,
                operation: unorientedOp,
                cachedStatistics: unorientedStats ?? .placeholder(readCount: result.unmatchedCount, baseCount: 0),
                pairingMode: pairingMode
            )

            let unorientedManifestData = try encoder.encode(unorientedManifest)
            try unorientedManifestData.write(to: unorientedBundleURL.appendingPathComponent("manifest.json"))
        }

        // Clean up vsearch work directory
        let workDir = result.orientedFASTQ.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: workDir)

        progress?("Orient complete: \(fwdCount) forward, \(rcCount) reverse-complemented, \(result.unmatchedCount) unmatched")
        return bundleURL
    }

    /// Parses seqkit stats tabular output into FASTQDatasetStatistics.
    private func parseFASTQStats(_ output: String) -> FASTQDatasetStatistics? {
        let lines = output.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let values = lines[1].split(separator: "\t")
        // seqkit stats --tabular: file, format, type, num_seqs, sum_len, min_len, avg_len, max_len
        guard values.count >= 8,
              let readCount = Int(values[3].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")),
              let totalBases = Int(values[4].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")),
              let minLength = Int(values[5].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")),
              let avgLength = Double(values[6].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")),
              let maxLength = Int(values[7].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
        else { return nil }

        return FASTQDatasetStatistics(
            readCount: readCount, baseCount: Int64(totalBases),
            meanReadLength: avgLength, minReadLength: minLength, maxReadLength: maxLength,
            medianReadLength: Int(avgLength), n50ReadLength: 0,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }

    /// Runs cutadapt-based demultiplexing and returns the most representative output bundle.
    ///
    /// The demultiplex output directory is created next to the source bundle and contains one
    /// `.lungfishfastq` bundle per barcode (plus optional `unassigned.lungfishfastq`).
    /// Returns the largest assigned barcode bundle for immediate selection in the UI.
    private func createDemultiplexDerivative(
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        rootFASTQFilename: String,
        kitID: String,
        customCSVPath: String?,
        location: String,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        errorRate: Double,
        minimumOverlap: Int? = nil,
        symmetryMode: BarcodeSymmetryMode? = nil,
        searchReverseComplement: Bool? = nil,
        unassignedDisposition: UnassignedDisposition = .keep,
        allowIndels: Bool = true,
        trimBarcodes: Bool,
        sampleAssignments: [FASTQSampleBarcodeAssignment],
        kitOverride: BarcodeKitDefinition?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let barcodeKit: BarcodeKitDefinition
        if let kitOverride {
            // Use the caller-provided kit directly (e.g. pruned by scout)
            barcodeKit = kitOverride
        } else if let customCSVPath, !customCSVPath.isEmpty {
            let csvURL: URL
            if customCSVPath.hasPrefix("/") {
                csvURL = URL(fileURLWithPath: customCSVPath)
            } else {
                csvURL = sourceBundleURL.appendingPathComponent(customCSVPath)
            }
            guard FileManager.default.fileExists(atPath: csvURL.path) else {
                throw FASTQDerivativeError.invalidOperation("Custom barcode CSV not found: \(csvURL.path)")
            }
            barcodeKit = try BarcodeKitRegistry.loadCustomKit(from: csvURL, name: "Custom")
        } else if let builtin = BarcodeKitRegistry.kit(byID: kitID) {
            barcodeKit = builtin
        } else {
            throw FASTQDerivativeError.invalidOperation("Unknown barcode kit: \(kitID)")
        }

        let barcodeLocation: BarcodeLocation
        switch location.lowercased() {
        case "fiveprime", "5prime", "five_prime":
            barcodeLocation = .fivePrime
        case "threeprime", "3prime", "three_prime":
            barcodeLocation = .threePrime
        case "bothends", "both_ends", "both-ends", "both":
            barcodeLocation = .bothEnds
        default:
            throw FASTQDerivativeError.invalidOperation("Unsupported barcode location: \(location)")
        }

        let sourceBaseName = FASTQBundle.deriveBaseName(from: sourceBundleURL)
        let parentDir = sourceBundleURL.deletingLastPathComponent()
        let outputDirBase = parentDir.appendingPathComponent("\(sourceBaseName)-demux", isDirectory: true)
        let outputDirectory = uniqueDirectoryURL(startingAt: outputDirBase)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        progress?("Demultiplexing reads...")
        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: sourceFASTQ,
                barcodeKit: barcodeKit,
                outputDirectory: outputDirectory,
                barcodeLocation: barcodeLocation,
                symmetryMode: symmetryMode,
                errorRate: errorRate,
                minimumOverlap: minimumOverlap,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                trimBarcodes: trimBarcodes,
                searchReverseComplement: searchReverseComplement,
                unassignedDisposition: unassignedDisposition,
                sampleAssignments: sampleAssignments,
                rootBundleURL: sourceBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                useNoIndels: !allowIndels
            ),
            progress: { fraction, message in
                let percent = Int((fraction * 100.0).rounded())
                progress?("Demultiplexing (\(percent)%): \(message)")
            }
        )

        // Persist manifest in source bundle so downstream batch workflows can discover demux runs.
        if FASTQBundle.isBundleURL(sourceBundleURL) {
            let sourceScopedManifest = DemultiplexManifest(
                version: result.manifest.version,
                runID: result.manifest.runID,
                demultiplexedAt: result.manifest.demultiplexedAt,
                barcodeKit: result.manifest.barcodeKit,
                parameters: result.manifest.parameters,
                barcodes: result.manifest.barcodes,
                unassigned: result.manifest.unassigned,
                outputDirectoryRelativePath: relativePath(from: sourceBundleURL, to: outputDirectory),
                inputReadCount: result.manifest.inputReadCount
            )
            try? sourceScopedManifest.save(to: sourceBundleURL)
        }

        if !sampleAssignments.isEmpty {
            persistDemultiplexedSampleMetadata(
                for: result,
                outputDirectory: outputDirectory,
                sourceBundleURL: sourceBundleURL,
                assignments: sampleAssignments
            )
        }

        // Prefer selecting the largest assigned barcode bundle; fall back to unassigned.
        let selectedBundle: URL
        if let topBarcode = result.manifest.barcodes.max(by: { $0.readCount < $1.readCount }) {
            selectedBundle = outputDirectory.appendingPathComponent(topBarcode.bundleRelativePath, isDirectory: true)
        } else if let unassigned = result.unassignedBundleURL {
            selectedBundle = unassigned
        } else {
            throw FASTQDerivativeError.emptyResult
        }

        progress?("Demultiplex complete: \(result.manifest.barcodes.count) barcode bundle(s)")
        derivativeLogger.info("Created demultiplex output at \(outputDirectory.path, privacy: .public)")
        return selectedBundle
    }

    /// Runs a multi-step demultiplexing pipeline and returns the most representative output bundle.
    ///
    /// - Parameters:
    ///   - plan: The multi-step demultiplexing plan.
    ///   - sourceFASTQ: Materialized source FASTQ file.
    ///   - sourceBundleURL: Source bundle URL.
    ///   - progress: Progress callback.
    /// - Returns: URL of the largest output bundle for immediate selection.
    private func createMultiStepDemultiplexDerivative(
        plan: DemultiplexPlan,
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        rootFASTQFilename: String,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        try plan.validate()

        // For single-step plans, delegate to existing single-step implementation
        if plan.steps.count == 1, let step = plan.steps.first {
            let location: String
            switch step.barcodeLocation {
            case .fivePrime: location = "fivePrime"
            case .threePrime: location = "threePrime"
            case .bothEnds: location = "bothEnds"
            }
            let resolvedKit = BarcodeKitRegistry.kit(byID: step.barcodeKitID)
            return try await createDemultiplexDerivative(
                sourceFASTQ: sourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                kitID: step.barcodeKitID,
                customCSVPath: nil,
                location: location,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: step.errorRate,
                minimumOverlap: step.minimumOverlap,
                symmetryMode: step.symmetryMode,
                searchReverseComplement: step.searchReverseComplement,
                unassignedDisposition: step.unassignedDisposition,
                allowIndels: step.allowIndels,
                trimBarcodes: step.trimBarcodes,
                sampleAssignments: step.sampleAssignments,
                kitOverride: resolvedKit,
                progress: progress
            )
        }

        // Multi-step: use DemultiplexingPipeline.runMultiStep
        let sourceBaseName = FASTQBundle.deriveBaseName(from: sourceBundleURL)
        let parentDir = sourceBundleURL.deletingLastPathComponent()
        let outputDirBase = parentDir.appendingPathComponent("\(sourceBaseName)-demux-multi", isDirectory: true)
        let outputDirectory = uniqueDirectoryURL(startingAt: outputDirBase)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        progress?("Running multi-step demultiplexing (\(plan.steps.count) steps)...")
        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.runMultiStep(
            plan: plan,
            inputURL: sourceFASTQ,
            outputDirectory: outputDirectory,
            rootBundleURL: sourceBundleURL,
            rootFASTQFilename: rootFASTQFilename,
            progress: { fraction, message in
                let percent = Int((fraction * 100.0).rounded())
                progress?("Multi-step demux (\(percent)%): \(message)")
            }
        )

        // Select the largest final output bundle
        guard let topBundle = result.outputBundleURLs.max(by: {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? 0 <
            (try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0
        }) else {
            throw FASTQDerivativeError.emptyResult
        }

        progress?("Multi-step demux complete: \(result.outputBundleURLs.count) output bundle(s)")
        derivativeLogger.info("Created multi-step demux output at \(outputDirectory.path, privacy: .public)")
        return topBundle
    }

    private func persistDemultiplexedSampleMetadata(
        for result: DemultiplexResult,
        outputDirectory: URL,
        sourceBundleURL: URL,
        assignments: [FASTQSampleBarcodeAssignment]
    ) {
        var assignmentLookup: [String: FASTQSampleBarcodeAssignment] = [:]
        for assignment in assignments {
            assignmentLookup[normalizeSampleKey(assignment.sampleID)] = assignment
        }
        guard !assignmentLookup.isEmpty else { return }

        for barcode in result.manifest.barcodes {
            let key = normalizeSampleKey(barcode.barcodeID)
            guard let assignment = assignmentLookup[key] else { continue }

            let bundleURL = outputDirectory.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            guard let payloadFASTQ = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
                  FileManager.default.fileExists(atPath: payloadFASTQ.path) else {
                continue
            }

            var metadata = FASTQMetadataStore.load(for: payloadFASTQ) ?? PersistedFASTQMetadata()
            var demux = metadata.demultiplexMetadata ?? FASTQDemultiplexMetadata()

            // Child bundles only need the single resolved sample assignment.
            let resolvedAssignment = FASTQSampleBarcodeAssignment(
                sampleID: assignment.sampleID,
                sampleName: assignment.sampleName,
                forwardBarcodeID: assignment.forwardBarcodeID ?? barcode.barcodeID,
                forwardSequence: barcode.forwardSequence ?? assignment.forwardSequence,
                reverseBarcodeID: assignment.reverseBarcodeID,
                reverseSequence: barcode.reverseSequence ?? assignment.reverseSequence,
                metadata: assignment.metadata
            )
            demux.sampleAssignments = [resolvedAssignment]
            metadata.demultiplexMetadata = demux
            FASTQMetadataStore.save(metadata, for: payloadFASTQ)
        }

        // Preserve full sample-assignment metadata on the demultiplexed source as well.
        if let sourceFASTQ = FASTQBundle.resolvePrimaryFASTQURL(for: sourceBundleURL) {
            var sourceMetadata = FASTQMetadataStore.load(for: sourceFASTQ) ?? PersistedFASTQMetadata()
            var sourceDemux = sourceMetadata.demultiplexMetadata ?? FASTQDemultiplexMetadata()
            sourceDemux.sampleAssignments = assignments
            sourceMetadata.demultiplexMetadata = sourceDemux
            FASTQMetadataStore.save(sourceMetadata, for: sourceFASTQ)
        }
    }

    private func normalizeSampleKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
            .lowercased()
    }

    /// Creates a derivative bundle for operations that produce multiple classified files
    /// (e.g. paired-end merge produces R1, R2, and merged files).
    private func createMixedOutputDerivative(
        request: FASTQDerivativeRequest,
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        parentRelativePath: String,
        rootRelativePath: String,
        rootFASTQFilename: String,
        pairingMode: IngestionMetadata.PairingMode?,
        baseLineage: [FASTQDerivativeOperation],
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        // Build the operation metadata first (for bundle naming)
        let operation: FASTQDerivativeOperation
        let classification: ReadClassification

        let outputBundle = try createOutputBundleURL(
            sourceBundleURL: sourceBundleURL,
            request: request
        )
        try FileManager.default.createDirectory(at: outputBundle, withIntermediateDirectories: true)

        switch request {
        case .pairedEndMerge(let strictness, let minOverlap):
            guard isInterleavedBundle(sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "PE merge requires interleaved paired-end input."
                )
            }
            progress?("Merging overlapping pairs...")
            let (result, cls) = try await runBBMerge(
                sourceFASTQ: sourceFASTQ,
                outputBundleURL: outputBundle,
                strictness: strictness,
                minOverlap: minOverlap
            )
            classification = cls
            operation = FASTQDerivativeOperation(
                kind: .pairedEndMerge,
                mergeStrictness: strictness,
                mergeMinOverlap: minOverlap,
                toolUsed: "bbmerge",
                toolCommand: result.toolCommand
            )

        case .pairedEndRepair:
            guard isInterleavedBundle(sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "PE repair requires interleaved paired-end input."
                )
            }
            progress?("Repairing paired-end reads...")
            let (result, cls) = try await runBBRepair(
                sourceFASTQ: sourceFASTQ,
                outputBundleURL: outputBundle
            )
            classification = cls
            operation = FASTQDerivativeOperation(
                kind: .pairedEndRepair,
                toolUsed: "repair",
                toolCommand: result.toolCommand
            )

        default:
            throw FASTQDerivativeError.invalidOperation(
                "Mixed-output execution requested for unsupported operation: \(request)"
            )
        }

        guard classification.totalReadCount > 0 else {
            // Clean up the empty bundle
            try? FileManager.default.removeItem(at: outputBundle)
            throw FASTQDerivativeError.emptyResult
        }

        // Compute statistics from the largest output file for dashboard display
        progress?("Computing output statistics...")
        let largestFile = classification.files.max(by: { $0.readCount < $1.readCount })
        let statsURL: URL
        if let largestFile {
            statsURL = outputBundle.appendingPathComponent(largestFile.filename)
        } else {
            throw FASTQDerivativeError.emptyResult
        }
        let reader = FASTQReader(validateSequence: false)
        let (stats, _) = try await reader.computeStatistics(from: statsURL, sampleLimit: 0)

        let lineage = baseLineage + [operation]

        // Save the read manifest alongside the derived manifest
        let readManifest = ReadManifest(
            classification: classification,
            sourceOperation: operation.kind.rawValue
        )
        try readManifest.save(to: outputBundle)

        let manifest = FASTQDerivedBundleManifest(
            name: outputBundle.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: rootRelativePath,
            rootFASTQFilename: rootFASTQFilename,
            payload: .fullMixed(classification),
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats,
            pairingMode: pairingMode,
            readClassification: classification
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundle)

        progress?("Created derived dataset: \(outputBundle.lastPathComponent) (\(classification.compositionLabel))")
        derivativeLogger.info("Created mixed-output derivative bundle at \(outputBundle.path, privacy: .public)")
        return outputBundle
    }

    /// Creates output bundle URL for a request (used by mixed-output path which doesn't have an operation yet).
    private func createOutputBundleURL(
        sourceBundleURL: URL,
        request: FASTQDerivativeRequest
    ) throws -> URL {
        let baseName = FASTQBundle.deriveBaseName(from: sourceBundleURL)
        let suffix: String
        switch request {
        case .pairedEndMerge: suffix = "merge-normal"
        case .pairedEndRepair: suffix = "repair"
        default: suffix = "derived"
        }
        let bundleName = "\(baseName)-\(suffix).\(FASTQBundle.directoryExtension)"
        let parentDir = sourceBundleURL.deletingLastPathComponent()
        return parentDir.appendingPathComponent(bundleName)
    }

    // MARK: - Transformations

    private func runTransformation(
        request: FASTQDerivativeRequest,
        sourceFASTQ: URL,
        outputFASTQ: URL,
        sourceBundleURL: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> FASTQDerivativeOperation {
        let isInterleaved = isInterleavedBundle(sourceBundleURL)

        switch request {
        case .subsampleProportion(let proportion):
            guard proportion > 0.0, proportion <= 1.0 else {
                throw FASTQDerivativeError.invalidOperation("proportion must be in (0, 1]")
            }
            if isInterleaved {
                // Use reformat.sh with samplerate for pair-aware subsampling
                let env = await bbToolsEnvironment()
                let result = try await runner.run(
                    .reformat,
                    arguments: [
                        "in=\(sourceFASTQ.path)",
                        "out=\(outputFASTQ.path)",
                        "samplerate=\(proportion)",
                        "interleaved=t",
                    ],
                    environment: env,
                    timeout: 1800
                )
                guard result.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("reformat.sh subsample failed: \(result.stderr)")
                }
            } else {
                _ = try await runner.run(
                    .seqkit,
                    arguments: ["sample", "-p", String(proportion), sourceFASTQ.path, "-o", outputFASTQ.path]
                )
            }
            return FASTQDerivativeOperation(
                kind: .subsampleProportion,
                proportion: proportion
            )

        case .subsampleCount(let count):
            guard count > 0 else {
                throw FASTQDerivativeError.invalidOperation("count must be > 0")
            }
            if isInterleaved {
                // For PE data, sample count/2 pairs to get ~count total reads
                let pairCount = max(1, count / 2)
                let env = await bbToolsEnvironment()
                let result = try await runner.run(
                    .reformat,
                    arguments: [
                        "in=\(sourceFASTQ.path)",
                        "out=\(outputFASTQ.path)",
                        "samplereadstarget=\(pairCount)",
                        "interleaved=t",
                    ],
                    environment: env,
                    timeout: 1800
                )
                guard result.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("reformat.sh subsample failed: \(result.stderr)")
                }
            } else {
                _ = try await runner.run(
                    .seqkit,
                    arguments: ["sample", "-n", String(count), sourceFASTQ.path, "-o", outputFASTQ.path]
                )
            }
            return FASTQDerivativeOperation(
                kind: .subsampleCount,
                count: count
            )

        case .lengthFilter(let minLength, let maxLength):
            if isInterleaved {
                // Use bbduk for pair-aware length filtering
                try await runPairedAwareFilter(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    minLength: minLength,
                    maxLength: maxLength
                )
            } else {
                var args = ["seq"]
                if let minLength {
                    args += ["-m", String(minLength)]
                }
                if let maxLength {
                    args += ["-M", String(maxLength)]
                }
                args += [sourceFASTQ.path, "-o", outputFASTQ.path]
                _ = try await runner.run(.seqkit, arguments: args)
            }
            return FASTQDerivativeOperation(
                kind: .lengthFilter,
                minLength: minLength,
                maxLength: maxLength
            )

        case .searchText(let query, let field, let regex):
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FASTQDerivativeError.invalidOperation("query cannot be empty")
            }
            if isInterleaved {
                // For PE data: search, extract matching base IDs, re-extract both mates
                try await runPairedAwareSearch(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    searchArgs: buildSearchArgs(field: field, regex: regex, query: query)
                )
            } else {
                var args = ["grep"]
                if field == .description {
                    args.append("-n")
                }
                if regex {
                    args.append("-r")
                }
                args += ["-p", query, sourceFASTQ.path, "-o", outputFASTQ.path]
                _ = try await runner.run(.seqkit, arguments: args)
            }
            return FASTQDerivativeOperation(
                kind: .searchText,
                query: query,
                searchField: field,
                useRegex: regex
            )

        case .searchMotif(let pattern, let regex):
            guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FASTQDerivativeError.invalidOperation("motif cannot be empty")
            }
            if isInterleaved {
                // For PE data: search by motif, then re-extract both mates of matching pairs
                try await runPairedAwareSearch(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    searchArgs: buildMotifSearchArgs(pattern: pattern, regex: regex)
                )
            } else {
                var args = ["grep", "-s"]
                if regex {
                    args.append("-r")
                }
                args += ["-p", pattern, sourceFASTQ.path, "-o", outputFASTQ.path]
                _ = try await runner.run(.seqkit, arguments: args)
            }
            return FASTQDerivativeOperation(
                kind: .searchMotif,
                query: pattern,
                useRegex: regex
            )

        case .deduplicate(let mode, let pairedAware):
            if pairedAware, isInterleavedBundle(sourceBundleURL) {
                try await deduplicateInterleavedPairs(
                    mode: mode,
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ
                )
            } else {
                var args = ["rmdup"]
                switch mode {
                case .identifier, .description:
                    args.append("-n")
                case .sequence:
                    args.append("-s")
                }
                args += [sourceFASTQ.path, "-o", outputFASTQ.path]
                _ = try await runner.run(.seqkit, arguments: args)
            }
            return FASTQDerivativeOperation(
                kind: .deduplicate,
                deduplicateMode: mode,
                pairedAware: pairedAware
            )

        case .qualityTrim(let threshold, let windowSize, let mode):
            let result = try await runFastpQualityTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                threshold: threshold,
                windowSize: windowSize,
                mode: mode,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .qualityTrim,
                qualityThreshold: threshold,
                windowSize: windowSize,
                qualityTrimMode: mode,
                toolUsed: "fastp",
                toolCommand: result.toolCommand
            )

        case .adapterTrim(let adapterMode, let sequence, let sequenceR2, let fastaFilename):
            let result = try await runFastpAdapterTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                mode: adapterMode,
                sequence: sequence,
                sequenceR2: sequenceR2,
                fastaFilename: fastaFilename,
                sourceBundleURL: sourceBundleURL,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .adapterTrim,
                adapterMode: adapterMode,
                adapterSequence: sequence,
                adapterSequenceR2: sequenceR2,
                adapterFastaFilename: fastaFilename,
                toolUsed: "fastp",
                toolCommand: result.toolCommand
            )

        case .fixedTrim(let from5Prime, let from3Prime):
            let result = try await runFastpFixedTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                from5Prime: from5Prime,
                from3Prime: from3Prime,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .fixedTrim,
                trimFrom5Prime: from5Prime,
                trimFrom3Prime: from3Prime,
                toolUsed: "fastp",
                toolCommand: result.toolCommand
            )

        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            let result = try await runBBDukContaminantFilter(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                mode: mode,
                referenceFasta: referenceFasta,
                kmerSize: kmerSize,
                hammingDistance: hammingDistance,
                sourceBundleURL: sourceBundleURL,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .contaminantFilter,
                contaminantFilterMode: mode,
                contaminantReferenceFasta: referenceFasta,
                contaminantKmerSize: kmerSize,
                contaminantHammingDistance: hammingDistance,
                toolUsed: "bbduk",
                toolCommand: result.toolCommand
            )

        case .pairedEndMerge, .pairedEndRepair:
            throw FASTQDerivativeError.invalidOperation(
                "Mixed-output operations must be handled via createMixedOutputDerivative"
            )

        case .primerRemoval(let source, let literalSequence, let referenceFasta, let kmerSize, let minKmer, let hammingDistance):
            let result = try await runBBDukPrimerRemoval(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                source: source,
                literalSequence: literalSequence,
                referenceFasta: referenceFasta,
                kmerSize: kmerSize,
                minKmer: minKmer,
                hammingDistance: hammingDistance,
                sourceBundleURL: sourceBundleURL,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .primerRemoval,
                primerSource: source,
                primerLiteralSequence: literalSequence,
                primerReferenceFasta: referenceFasta,
                primerKmerSize: kmerSize,
                primerMinKmer: minKmer,
                primerHammingDistance: hammingDistance,
                toolUsed: "bbduk",
                toolCommand: result.toolCommand
            )

        case .errorCorrection(let kmerSize):
            let result = try await runTadpole(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                kmerSize: kmerSize,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .errorCorrection,
                errorCorrectionKmerSize: kmerSize,
                toolUsed: "tadpole",
                toolCommand: result.toolCommand
            )

        case .interleaveReformat(let direction):
            let result = try await runReformat(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                direction: direction,
                sourceBundleURL: sourceBundleURL
            )
            return FASTQDerivativeOperation(
                kind: .interleaveReformat,
                interleaveDirection: direction,
                toolUsed: "reformat",
                toolCommand: result.toolCommand
            )

        case .demultiplex:
            throw FASTQDerivativeError.invalidOperation(
                "Demultiplexing is not implemented in FASTQDerivativeService. Use the demultiplexing pipeline."
            )

        case .multiStepDemultiplex:
            throw FASTQDerivativeError.invalidOperation(
                "Multi-step demultiplexing is handled via createMultiStepDemultiplexDerivative."
            )
        case .orient:
            throw FASTQDerivativeError.invalidOperation(
                "Orient is handled via createOrientDerivative."
            )
        }
    }

    // MARK: - Materialization

    private func materializeDatasetFASTQ(
        fromBundle bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        // For root (non-derived) bundles, return the physical FASTQ directly.
        // Derived bundles must go through manifest-based materialization to handle
        // subset/trim/full/fullPaired payloads correctly.
        if !FASTQBundle.isDerivedBundle(bundleURL),
           let payload = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return payload
        }

        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            // Root bundle without a manifest — try resolving primary FASTQ
            if let payload = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
                return payload
            }
            throw FASTQDerivativeError.derivedManifestMissing
        }

        let rootBundleURL = FASTQBundle.resolveBundle(
            relativePath: manifest.rootBundleRelativePath,
            from: bundleURL
        )
        guard FASTQBundle.isBundleURL(rootBundleURL) else {
            throw FASTQDerivativeError.rootBundleMissing(manifest.rootBundleRelativePath)
        }

        let rootFASTQURL = rootBundleURL.appendingPathComponent(manifest.rootFASTQFilename)
        guard FileManager.default.fileExists(atPath: rootFASTQURL.path) else {
            throw FASTQDerivativeError.rootFASTQMissing
        }

        let outputURL = tempDirectory.appendingPathComponent("materialized.fastq")
        progress?("Materializing pointer dataset...")

        switch manifest.payload {
        case .subset(let readIDFilename):
            let readIDListURL = bundleURL.appendingPathComponent(readIDFilename)
            try await extractReads(
                fromRootFASTQ: rootFASTQURL,
                readIDsFile: readIDListURL,
                outputFASTQ: outputURL
            )

        case .trim(let trimFilename):
            let trimURL = bundleURL.appendingPathComponent(trimFilename)
            let positions = try FASTQTrimPositionFile.load(from: trimURL)
            try await extractTrimmedReads(
                fromRootFASTQ: rootFASTQURL,
                positions: positions,
                outputFASTQ: outputURL
            )

        case .full(let fastqFilename):
            // Full payload bundles contain the physical FASTQ directly
            let fullFASTQURL = bundleURL.appendingPathComponent(fastqFilename)
            guard FileManager.default.fileExists(atPath: fullFASTQURL.path) else {
                throw FASTQDerivativeError.sourceFASTQMissing
            }
            try FileManager.default.copyItem(at: fullFASTQURL, to: outputURL)

        case .fullPaired(let r1Filename, let r2Filename):
            // Paired payload — interleave R1/R2 into a single file for downstream ops
            let r1URL = bundleURL.appendingPathComponent(r1Filename)
            let r2URL = bundleURL.appendingPathComponent(r2Filename)
            guard FileManager.default.fileExists(atPath: r1URL.path),
                  FileManager.default.fileExists(atPath: r2URL.path) else {
                throw FASTQDerivativeError.sourceFASTQMissing
            }
            // Interleave using reformat.sh
            let env = await bbToolsEnvironment()
            let reformatResult = try await runner.run(
                .reformat,
                arguments: [
                    "in1=\(r1URL.path)",
                    "in2=\(r2URL.path)",
                    "out=\(outputURL.path)",
                    "interleaved=t",
                ],
                environment: env,
                timeout: 1800
            )
            guard reformatResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("reformat.sh interleave failed: \(reformatResult.stderr)")
            }

        case .fullMixed(let classification):
            // Mixed payload — concatenate all classified files into a single FASTQ
            // (paired R1/R2 interleaved first, then merged, then unpaired)
            let roleOrder: [ReadClassification.FileRole] = [.pairedR1, .pairedR2, .merged, .unpaired]
            let pairedR1 = classification.files.first(where: { $0.role == .pairedR1 })
            let pairedR2 = classification.files.first(where: { $0.role == .pairedR2 })

            // If we have paired reads, interleave R1/R2 first
            if let r1 = pairedR1, let r2 = pairedR2 {
                let r1URL = bundleURL.appendingPathComponent(r1.filename)
                let r2URL = bundleURL.appendingPathComponent(r2.filename)
                let interleavedURL = tempDirectory.appendingPathComponent("interleaved-temp.fastq")
                let env = await bbToolsEnvironment()
                let reformatResult = try await runner.run(
                    .reformat,
                    arguments: [
                        "in1=\(r1URL.path)",
                        "in2=\(r2URL.path)",
                        "out=\(interleavedURL.path)",
                        "interleaved=t",
                    ],
                    environment: env,
                    timeout: 1800
                )
                guard reformatResult.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("reformat.sh interleave failed: \(reformatResult.stderr)")
                }

                // Concatenate interleaved pairs + remaining single-read files
                var filesToConcat = [interleavedURL]
                for role in [ReadClassification.FileRole.merged, .unpaired] {
                    if let entry = classification.files.first(where: { $0.role == role }) {
                        let url = bundleURL.appendingPathComponent(entry.filename)
                        if FileManager.default.fileExists(atPath: url.path) {
                            filesToConcat.append(url)
                        }
                    }
                }
                try concatenateFASTQFiles(filesToConcat, to: outputURL)
            } else {
                // No paired reads — just concatenate all files in role order
                var filesToConcat: [URL] = []
                for role in roleOrder {
                    if let entry = classification.files.first(where: { $0.role == role }) {
                        let url = bundleURL.appendingPathComponent(entry.filename)
                        if FileManager.default.fileExists(atPath: url.path) {
                            filesToConcat.append(url)
                        }
                    }
                }
                try concatenateFASTQFiles(filesToConcat, to: outputURL)
            }

        case .demuxedVirtual(_, let readIDFilename, _, let trimPositionsFilename):
            // Virtual demuxed barcode bundle — extract reads from root FASTQ using read ID list
            let readIDListURL = bundleURL.appendingPathComponent(readIDFilename)
            if let trimFilename = trimPositionsFilename {
                let trimURL = bundleURL.appendingPathComponent(trimFilename)
                try await extractAndTrimReads(
                    fromRootFASTQ: rootFASTQURL,
                    readIDsFile: readIDListURL,
                    trimPositionsFile: trimURL,
                    outputFASTQ: outputURL
                )
            } else {
                try await extractReads(
                    fromRootFASTQ: rootFASTQURL,
                    readIDsFile: readIDListURL,
                    outputFASTQ: outputURL
                )
            }

        case .demuxGroup:
            // Demux group is a directory, not a materializable payload
            throw FASTQDerivativeError.invalidOperation("Cannot materialize a demux group directory")

        case .orientMap(let orientMapFilename, _):
            // Orient map: extract forward reads + RC reads from orient map, excluding unmatched.
            let mapURL = bundleURL.appendingPathComponent(orientMapFilename)
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: mapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: mapURL)
            try await materializeOrientedReads(
                fromRootFASTQ: rootFASTQURL,
                forwardReadIDs: fwdReadIDs,
                rcReadIDs: rcReadIDs,
                outputFASTQ: outputURL
            )
        }

        return outputURL
    }

    /// Extracts reads from root FASTQ by ID list using `seqkit grep`.
    private func extractReads(
        fromRootFASTQ rootFASTQ: URL,
        readIDsFile: URL,
        outputFASTQ: URL
    ) async throws {
        let result = try await runner.run(
            .seqkit,
            arguments: [
                "grep", "-f", readIDsFile.path,
                rootFASTQ.path,
                "-o", outputFASTQ.path,
            ],
            timeout: 600
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep failed: \(result.stderr)")
        }
    }

    /// Materializes an oriented FASTQ by streaming through the root FASTQ and
    /// reverse-complementing reads marked in the RC set using seqkit.
    ///
    /// Strategy: Extract RC reads → reverse complement them → concatenate with forward reads.
    private func materializeOrientedReads(
        fromRootFASTQ rootFASTQ: URL,
        forwardReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTQ: URL
    ) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "lungfish-orient-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Write forward read ID list
        let fwdIDFile = tempDir.appendingPathComponent("fwd-read-ids.txt")
        try forwardReadIDs.joined(separator: "\n").write(to: fwdIDFile, atomically: true, encoding: .utf8)

        // Extract forward reads explicitly (excludes unmatched reads)
        let fwdExtracted = tempDir.appendingPathComponent("fwd-extracted.fastq.gz")
        let fwdResult = try await runner.run(
            .seqkit,
            arguments: [
                "grep", "-f", fwdIDFile.path,
                rootFASTQ.path,
                "-o", fwdExtracted.path,
            ],
            timeout: 600
        )
        guard fwdResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep (fwd reads) failed: \(fwdResult.stderr)")
        }

        guard !rcReadIDs.isEmpty else {
            // No reads need RC — forward-only output (unmatched reads excluded)
            try fm.moveItem(at: fwdExtracted, to: outputFASTQ)
            return
        }

        // Write RC read ID list
        let rcIDFile = tempDir.appendingPathComponent("rc-read-ids.txt")
        try rcReadIDs.joined(separator: "\n").write(to: rcIDFile, atomically: true, encoding: .utf8)

        // Extract and RC the reads that need reverse complementing
        let rcExtracted = tempDir.appendingPathComponent("rc-extracted.fastq.gz")
        let rcResult = try await runner.run(
            .seqkit,
            arguments: [
                "grep", "-f", rcIDFile.path,
                rootFASTQ.path,
                "-o", rcExtracted.path,
            ],
            timeout: 600
        )
        guard rcResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep (RC reads) failed: \(rcResult.stderr)")
        }

        let rcOriented = tempDir.appendingPathComponent("rc-oriented.fastq.gz")
        let rcSeqResult = try await runner.run(
            .seqkit,
            arguments: [
                "seq", "--reverse", "--complement",
                rcExtracted.path,
                "-o", rcOriented.path,
            ],
            timeout: 600
        )
        guard rcSeqResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit seq -rp failed: \(rcSeqResult.stderr)")
        }

        // Concatenate forward + RC'd reads.
        // Multi-member gzip concatenation is valid per RFC 1952;
        // downstream tools (seqkit, samtools, cutadapt) handle it correctly.
        try concatenateFASTQFiles([fwdExtracted, rcOriented], to: outputFASTQ)
    }

    /// Extracts reads from root FASTQ by ID list, then applies stored trim positions
    /// to remove adapter/barcode/primer sequences from each read.
    ///
    /// Uses a two-step approach: seqkit grep (extract by ID) → seqkit subseq (apply trims).
    /// The trim positions file is a TSV with columns: read_id, trim_5p, trim_3p
    /// where trim_5p is bases to remove from 5' end and trim_3p is bases to remove from 3' end.
    private func extractAndTrimReads(
        fromRootFASTQ rootFASTQ: URL,
        readIDsFile: URL,
        trimPositionsFile: URL,
        outputFASTQ: URL
    ) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-trim-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Step 1: Extract reads by ID into temp file
        let extractedURL = tempDir.appendingPathComponent("extracted.fastq.gz")
        try await extractReads(fromRootFASTQ: rootFASTQ, readIDsFile: readIDsFile, outputFASTQ: extractedURL)

        // Step 2: Parse trim positions
        guard let trimContent = try? String(contentsOf: trimPositionsFile, encoding: .utf8) else {
            // No trim positions — just move extracted reads to output
            try fm.moveItem(at: extractedURL, to: outputFASTQ)
            return
        }

        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in trimContent.split(separator: "\n").dropFirst() {  // skip header
            let cols = line.split(separator: "\t")
            guard cols.count >= 3,
                  let t5 = Int(cols[1]),
                  let t3 = Int(cols[2]) else { continue }
            trimMap[String(cols[0])] = (t5, t3)
        }

        guard !trimMap.isEmpty else {
            try fm.moveItem(at: extractedURL, to: outputFASTQ)
            return
        }

        // Step 3: Apply trims using native Swift FASTQ reader/writer
        let reader = FASTQReader(validateSequence: false)
        var outputContent = ""

        for try await record in reader.records(from: extractedURL) {
            let readID = record.identifier
            let seq = record.sequence
            let qual = record.quality.toAscii()
            let header = record.description != nil
                ? "\(record.identifier) \(record.description!)"
                : record.identifier

            if let trim = trimMap[readID] {
                let startIndex = min(trim.trim5p, seq.count)
                let endIndex = max(startIndex, seq.count - trim.trim3p)
                let trimmedSeq = String(seq[seq.index(seq.startIndex, offsetBy: startIndex)..<seq.index(seq.startIndex, offsetBy: endIndex)])
                let trimmedQual = String(qual[qual.index(qual.startIndex, offsetBy: startIndex)..<qual.index(qual.startIndex, offsetBy: endIndex)])
                outputContent += "@\(header)\n\(trimmedSeq)\n+\n\(trimmedQual)\n"
            } else {
                outputContent += "@\(header)\n\(seq)\n+\n\(qual)\n"
            }
        }

        // Write trimmed FASTQ, then use seqkit to convert to gzipped output if needed
        let plainURL = tempDir.appendingPathComponent("trimmed.fastq")
        try outputContent.write(to: plainURL, atomically: true, encoding: .utf8)

        if outputFASTQ.pathExtension == "gz" {
            // Use seqkit seq to copy and gzip the output
            let gzipResult = try await runner.run(
                .seqkit,
                arguments: ["seq", plainURL.path, "-o", outputFASTQ.path],
                timeout: 300
            )
            if !gzipResult.isSuccess {
                // Fallback: copy uncompressed
                try fm.moveItem(at: plainURL, to: outputFASTQ)
            }
        } else {
            try fm.moveItem(at: plainURL, to: outputFASTQ)
        }
    }

    // MARK: - Fastp Trim Operations

    private struct FastpResult {
        let toolCommand: String
    }

    private func runFastpQualityTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        threshold: Int,
        windowSize: Int,
        mode: FASTQQualityTrimMode,
        isInterleaved: Bool = false
    ) async throws -> FastpResult {
        // For interleaved PE data, fastp needs separate R1/R2 outputs
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "-W", String(windowSize),
            "-M", String(threshold),
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        switch mode {
        case .cutRight: args.append("--cut_right")
        case .cutFront: args.append("--cut_front")
        case .cutTail: args.append("--cut_tail")
        case .cutBoth:
            args.append("--cut_front")
            args.append("--cut_right")
        }

        let result = try await runner.run(.fastp, arguments: args)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp quality trim failed: \(result.stderr)")
        }

        // Re-interleave R1+R2 into the final output
        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(r1: r1Output, r2: r2, output: outputFASTQ)
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    private func runFastpAdapterTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        mode: FASTQAdapterMode,
        sequence: String?,
        sequenceR2: String?,
        fastaFilename: String?,
        sourceBundleURL: URL,
        isInterleaved: Bool = false
    ) async throws -> FastpResult {
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        switch mode {
        case .autoDetect:
            break // fastp auto-detects by default
        case .specified:
            if let sequence {
                args += ["--adapter_sequence", sequence]
            }
            if let sequenceR2 {
                args += ["--adapter_sequence_r2", sequenceR2]
            }
        case .fastaFile:
            if let fastaFilename {
                let fastaURL = sourceBundleURL.appendingPathComponent(fastaFilename)
                args += ["--adapter_fasta", fastaURL.path]
            }
        }

        let result = try await runner.run(.fastp, arguments: args)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp adapter trim failed: \(result.stderr)")
        }

        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(r1: r1Output, r2: r2, output: outputFASTQ)
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    private func runFastpFixedTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        from5Prime: Int,
        from3Prime: Int,
        isInterleaved: Bool = false
    ) async throws -> FastpResult {
        let r1Output: URL
        let r2Output: URL?
        if isInterleaved {
            r1Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R1.fastq")
            r2Output = outputFASTQ.deletingLastPathComponent().appendingPathComponent("fastp_R2.fastq")
        } else {
            r1Output = outputFASTQ
            r2Output = nil
        }

        var args = [
            "-i", sourceFASTQ.path,
            "-o", r1Output.path,
            "--disable_adapter_trimming",
            "--disable_quality_filtering",
            "--disable_length_filtering",
            "--json", "/dev/null",
            "--html", "/dev/null",
        ]
        if isInterleaved, let r2 = r2Output {
            args.append("--interleaved_in")
            args += ["--out2", r2.path]
        }

        if from5Prime > 0 {
            args += ["--trim_front1", String(from5Prime)]
        }
        if from3Prime > 0 {
            args += ["--trim_tail1", String(from3Prime)]
        }

        let result = try await runner.run(.fastp, arguments: args)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("fastp fixed trim failed: \(result.stderr)")
        }

        if isInterleaved, let r2 = r2Output {
            try await reinterleaveFastpOutput(r1: r1Output, r2: r2, output: outputFASTQ)
        }

        return FastpResult(toolCommand: "fastp \(args.joined(separator: " "))")
    }

    /// Re-interleaves split R1/R2 fastp output back into a single interleaved file
    /// using reformat.sh, then cleans up the temp files.
    private func reinterleaveFastpOutput(r1: URL, r2: URL, output: URL) async throws {
        let env = await bbToolsEnvironment()
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(output.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh re-interleave failed: \(result.stderr)")
        }
        try? FileManager.default.removeItem(at: r1)
        try? FileManager.default.removeItem(at: r2)
    }

    // MARK: - BBTools Operations

    private struct BBToolResult {
        let toolCommand: String
    }

    /// Builds environment variables required by BBTools shell scripts.
    ///
    /// BBTools scripts are Java wrappers — they need the bundled JRE on PATH
    /// and JAVA_HOME/BBMAP_JAVA set to avoid depending on system Java.
    /// Result is cached after first call since the tools directory is stable.
    private func bbToolsEnvironment() async -> [String: String] {
        if let cached = cachedBBToolsEnv {
            return cached
        }
        var env: [String: String] = [:]
        // Add tools directory to PATH so bbtools scripts can find the bundled JRE
        if let toolsDir = await runner.getToolsDirectory() {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
            env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
            // Set JAVA_HOME and BBMAP_JAVA for bbtools' internal Java detection
            let javaURL = jreBinDir.appendingPathComponent("java")
            let javaHome = toolsDir.appendingPathComponent("jre")
            if FileManager.default.fileExists(atPath: javaURL.path) {
                env["JAVA_HOME"] = javaHome.path
                env["BBMAP_JAVA"] = javaURL.path
            }
        }
        cachedBBToolsEnv = env
        return env
    }

    /// Runs bbduk.sh for contaminant/reference-based filtering.
    ///
    /// PhiX mode uses the reference bundled within bbtools. Custom mode requires
    /// a user-provided FASTA file path.
    private func runBBDukContaminantFilter(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        mode: FASTQContaminantFilterMode,
        referenceFasta: String?,
        kmerSize: Int,
        hammingDistance: Int,
        sourceBundleURL: URL,
        isInterleaved: Bool = false
    ) async throws -> BBToolResult {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "k=\(kmerSize)",
            "hdist=\(hammingDistance)",
        ]
        if isInterleaved {
            args.append("interleaved=t")
        }

        switch mode {
        case .phix:
            // bbduk.sh resolves the "phix" alias via Data.findPath() to its bundled PhiX reference
            args.append("ref=phix")
        case .custom:
            guard let refPath = referenceFasta else {
                throw FASTQDerivativeError.invalidOperation("Custom contaminant filter requires a reference FASTA path")
            }
            // Resolve relative to bundle or treat as absolute
            let refURL: URL
            if refPath.hasPrefix("/") {
                refURL = URL(fileURLWithPath: refPath)
            } else {
                refURL = sourceBundleURL.appendingPathComponent(refPath)
            }
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw FASTQDerivativeError.invalidOperation("Reference FASTA not found: \(refURL.path)")
            }
            args.append("ref=\(refURL.path)")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk contaminant filter failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "bbduk.sh \(args.joined(separator: " "))")
    }

    /// Runs bbmerge.sh to merge overlapping paired-end reads.
    ///
    /// Requires interleaved input. Produces separate FASTQ files for merged reads
    /// and unmerged R1/R2 pairs directly into the output bundle directory.
    private func runBBMerge(
        sourceFASTQ: URL,
        outputBundleURL: URL,
        strictness: FASTQMergeStrictness,
        minOverlap: Int
    ) async throws -> (BBToolResult, ReadClassification) {
        // bbmerge writes merged reads to `out`, unmerged R1/R2 to `outu1`/`outu2`.
        let mergedURL = outputBundleURL.appendingPathComponent("merged.fastq")
        let unmergedR1URL = outputBundleURL.appendingPathComponent("unmerged_R1.fastq")
        let unmergedR2URL = outputBundleURL.appendingPathComponent("unmerged_R2.fastq")

        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(mergedURL.path)",
            "outu1=\(unmergedR1URL.path)",
            "outu2=\(unmergedR2URL.path)",
            "minoverlap=\(minOverlap)",
        ]

        if strictness == .strict {
            args.append("strict=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.bbmerge, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbmerge failed: \(result.stderr)")
        }

        // Count reads in each output file to build classification
        let mergedCount = try countFASTQReads(at: mergedURL)
        let r1Count = try countFASTQReads(at: unmergedR1URL)
        let r2Count = try countFASTQReads(at: unmergedR2URL)

        // Remove empty output files
        var files: [ReadClassification.FileEntry] = []
        if r1Count > 0 {
            files.append(.init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: r1Count))
        } else {
            try? FileManager.default.removeItem(at: unmergedR1URL)
        }
        if r2Count > 0 {
            files.append(.init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: r2Count))
        } else {
            try? FileManager.default.removeItem(at: unmergedR2URL)
        }
        if mergedCount > 0 {
            files.append(.init(filename: "merged.fastq", role: .merged, readCount: mergedCount))
        } else {
            try? FileManager.default.removeItem(at: mergedURL)
        }

        let classification = ReadClassification(files: files)
        return (BBToolResult(toolCommand: "bbmerge.sh \(args.joined(separator: " "))"), classification)
    }

    /// Runs repair.sh to fix desynchronized paired-end FASTQ files.
    ///
    /// Reads an interleaved FASTQ and outputs repaired R1/R2 pairs
    /// plus singletons (reads with no mate) as separate files.
    private func runBBRepair(
        sourceFASTQ: URL,
        outputBundleURL: URL
    ) async throws -> (BBToolResult, ReadClassification) {
        // repair.sh writes repaired pairs to out1/out2, singletons to outs
        let repairedR1URL = outputBundleURL.appendingPathComponent("repaired_R1.fastq")
        let repairedR2URL = outputBundleURL.appendingPathComponent("repaired_R2.fastq")
        let singletonsURL = outputBundleURL.appendingPathComponent("singletons.fastq")

        let args = [
            "in=\(sourceFASTQ.path)",
            "out1=\(repairedR1URL.path)",
            "out2=\(repairedR2URL.path)",
            "outs=\(singletonsURL.path)",
        ]

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.repair, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("repair.sh failed: \(result.stderr)")
        }

        // Count reads in each output
        let r1Count = try countFASTQReads(at: repairedR1URL)
        let r2Count = try countFASTQReads(at: repairedR2URL)
        let singletonsCount = try countFASTQReads(at: singletonsURL)

        var files: [ReadClassification.FileEntry] = []
        if r1Count > 0 {
            files.append(.init(filename: "repaired_R1.fastq", role: .pairedR1, readCount: r1Count))
        } else {
            try? FileManager.default.removeItem(at: repairedR1URL)
        }
        if r2Count > 0 {
            files.append(.init(filename: "repaired_R2.fastq", role: .pairedR2, readCount: r2Count))
        } else {
            try? FileManager.default.removeItem(at: repairedR2URL)
        }
        if singletonsCount > 0 {
            files.append(.init(filename: "singletons.fastq", role: .unpaired, readCount: singletonsCount))
        } else {
            try? FileManager.default.removeItem(at: singletonsURL)
        }

        let classification = ReadClassification(files: files)
        return (BBToolResult(toolCommand: "repair.sh \(args.joined(separator: " "))"), classification)
    }

    /// Runs bbduk.sh for custom primer/adapter removal via literal sequence or reference FASTA.
    private func runBBDukPrimerRemoval(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        source: FASTQPrimerSource,
        literalSequence: String?,
        referenceFasta: String?,
        kmerSize: Int,
        minKmer: Int,
        hammingDistance: Int,
        sourceBundleURL: URL,
        isInterleaved: Bool = false
    ) async throws -> BBToolResult {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "ktrim=r",
            "k=\(kmerSize)",
            "mink=\(minKmer)",
            "hdist=\(hammingDistance)",
        ]
        if isInterleaved {
            args.append("interleaved=t")
        }

        switch source {
        case .literal:
            guard let seq = literalSequence, !seq.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("Primer removal requires a non-empty literal sequence")
            }
            args.append("literal=\(seq)")
        case .reference:
            guard let refPath = referenceFasta, !refPath.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("Primer removal requires a reference FASTA path")
            }
            let refURL: URL
            if refPath.hasPrefix("/") {
                refURL = URL(fileURLWithPath: refPath)
            } else {
                refURL = sourceBundleURL.appendingPathComponent(refPath)
            }
            guard FileManager.default.fileExists(atPath: refURL.path) else {
                throw FASTQDerivativeError.invalidOperation("Primer reference FASTA not found: \(refURL.path)")
            }
            args.append("ref=\(refURL.path)")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk primer removal failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "bbduk.sh \(args.joined(separator: " "))")
    }

    /// Runs tadpole.sh for k-mer-based error correction.
    private func runTadpole(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        kmerSize: Int,
        isInterleaved: Bool = false
    ) async throws -> BBToolResult {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "mode=correct",
            "ecc=t",
            "k=\(kmerSize)",
        ]
        if isInterleaved {
            args.append("interleaved=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.tadpole, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("tadpole error correction failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "tadpole.sh \(args.joined(separator: " "))")
    }

    /// Runs reformat.sh for interleaving or deinterleaving paired-end reads.
    private func runReformat(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        direction: FASTQInterleaveDirection,
        sourceBundleURL: URL
    ) async throws -> BBToolResult {
        var args: [String]

        switch direction {
        case .interleave:
            // Interleave requires a fullPaired source bundle — source has already been
            // materialized as interleaved by materializeDatasetFASTQ, so this is a no-op copy.
            // However, if the user wants to interleave from a fullPaired bundle, the
            // materialization already interleaves via reformat.sh. We just pass through.
            guard let pairedURLs = FASTQBundle.pairedFASTQURLs(forDerivedBundle: sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "Interleave requires a deinterleaved (paired R1/R2) input bundle."
                )
            }
            args = [
                "in1=\(pairedURLs.r1.path)",
                "in2=\(pairedURLs.r2.path)",
                "out=\(outputFASTQ.path)",
            ]

        case .deinterleave:
            guard isInterleavedBundle(sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "Deinterleave requires interleaved paired-end input. This dataset is not interleaved."
                )
            }
            // Deinterleave into the output file (will be split into R1/R2 in createDerivative)
            // For the transformation step, we just copy through; the actual split happens
            // when creating the bundle payload.
            try FileManager.default.copyItem(at: sourceFASTQ, to: outputFASTQ)
            return BBToolResult(toolCommand: "reformat.sh in=\(sourceFASTQ.path) out1=R1.fastq out2=R2.fastq")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.reformat, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("reformat.sh failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "reformat.sh \(args.joined(separator: " "))")
    }

    /// Concatenates multiple FASTQ files into one output file.
    private func concatenateFASTQFiles(_ inputFiles: [URL], to outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputFiles {
            guard FileManager.default.fileExists(atPath: inputURL.path) else { continue }
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            defer { try? inputHandle.close() }

            // Stream in chunks to avoid loading entire files into memory
            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576) // 1 MB chunks
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }
    }

    /// Counts FASTQ reads in a file by counting lines and dividing by 4.
    private func countFASTQReads(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineCount = 0
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            lineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        }
        return lineCount / 4
    }

    // MARK: - PE-Aware Subset Helpers

    /// Builds seqkit grep args for text search (ID or description).
    private func buildSearchArgs(field: FASTQSearchField, regex: Bool, query: String) -> [String] {
        var args = ["grep"]
        if field == .description {
            args.append("-n")
        }
        if regex {
            args.append("-r")
        }
        args += ["-p", query]
        return args
    }

    /// Builds seqkit grep args for motif (sequence) search.
    private func buildMotifSearchArgs(pattern: String, regex: Bool) -> [String] {
        var args = ["grep", "-s"]
        if regex {
            args.append("-r")
        }
        args += ["-p", pattern]
        return args
    }

    /// Pair-aware search for interleaved PE data.
    ///
    /// Strategy: run seqkit grep to find matching reads, extract their base IDs
    /// (deduplicated), then re-extract both mates from the original source FASTQ
    /// using the base ID list. This ensures both R1 and R2 are included and
    /// interleaving order is preserved.
    private func runPairedAwareSearch(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        searchArgs: [String]
    ) async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "pe-search-")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Step 1: Run the search to find matching reads
        let matchesURL = tempDir.appendingPathComponent("matches.fastq")
        let matchArgs = searchArgs + [sourceFASTQ.path, "-o", matchesURL.path]
        let searchResult = try await runner.run(.seqkit, arguments: matchArgs)
        guard searchResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep failed: \(searchResult.stderr)")
        }

        // Step 2: Extract base IDs from matches (deduplicated)
        let matchedIDsURL = tempDir.appendingPathComponent("matched-ids.txt")
        let idResult = try await runner.runWithFileOutput(
            .seqkit,
            arguments: ["seq", "--name", "--only-id", matchesURL.path],
            outputFile: matchedIDsURL,
            timeout: 600
        )
        guard idResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit seq --name failed: \(idResult.stderr)")
        }

        // Deduplicate IDs (for PE, R1 and R2 may both match and share the same base ID)
        let dedupedIDsURL = tempDir.appendingPathComponent("deduped-ids.txt")
        try deduplicateIDFile(from: matchedIDsURL, to: dedupedIDsURL)

        // Step 3: Re-extract both mates from the original source using base IDs
        let reExtractResult = try await runner.run(
            .seqkit,
            arguments: [
                "grep", "-f", dedupedIDsURL.path,
                sourceFASTQ.path,
                "-o", outputFASTQ.path,
            ],
            timeout: 600
        )
        guard reExtractResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep (pair re-extraction) failed: \(reExtractResult.stderr)")
        }
    }

    /// Pair-aware length filtering for interleaved PE data using bbduk.
    ///
    /// bbduk with `interleaved=t` removes/keeps both mates as a pair.
    private func runPairedAwareFilter(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        minLength: Int?,
        maxLength: Int?
    ) async throws {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "interleaved=t",
        ]
        if let minLength {
            args.append("minlen=\(minLength)")
        }
        if let maxLength {
            args.append("maxlen=\(maxLength)")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk length filter failed: \(result.stderr)")
        }
    }

    /// Deduplicates lines in a text file (preserving first occurrence order).
    private func deduplicateIDFile(from inputURL: URL, to outputURL: URL) throws {
        let content = try String(contentsOf: inputURL, encoding: .utf8)
        var seen = Set<String>()
        var unique: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let id = String(line)
            if !seen.contains(id) {
                seen.insert(id)
                unique.append(id)
            }
        }
        try unique.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Trim Position Extraction

    /// Extracts trim positions by diffing original vs trimmed FASTQ records.
    ///
    /// For each read that appears in both files (matched by identifier), computes
    /// the trim boundaries by finding where the trimmed sequence aligns within
    /// the original sequence.
    ///
    /// For interleaved PE data where R1/R2 share the same base ID, uses a
    /// positional index to disambiguate (e.g., "SRR123.456#0" for R1,
    /// "SRR123.456#1" for R2). Since fastp with `--interleaved_in` preserves
    /// read order and drops both mates together, the positional correspondence
    /// between original and trimmed files is maintained.
    private func extractTrimPositions(
        originalFASTQ: URL,
        trimmedFASTQ: URL
    ) async throws -> [FASTQTrimRecord] {
        // Build a dictionary of trimmed records keyed by positional ID.
        // Using read index ensures uniqueness even when base IDs are shared.
        let trimmedReader = FASTQReader(validateSequence: false)
        var trimmedByKey: [String: FASTQRecord] = [:]
        var trimmedIndex = 0
        for try await record in trimmedReader.records(from: trimmedFASTQ) {
            let baseID = normalizedIdentifier(record.identifier)
            let key = "\(baseID)#\(trimmedIndex)"
            trimmedByKey[key] = record
            trimmedIndex += 1
        }

        // For order-preserving matching, also build a lookup by base ID to
        // handle the common case where fastp drops some reads entirely.
        // We use a dictionary of arrays to handle PE reads with same base ID.
        var trimmedByBaseID: [String: [(index: Int, record: FASTQRecord)]] = [:]
        var idx = 0
        let trimmedReader2 = FASTQReader(validateSequence: false)
        for try await record in trimmedReader2.records(from: trimmedFASTQ) {
            let baseID = normalizedIdentifier(record.identifier)
            trimmedByBaseID[baseID, default: []].append((index: idx, record: record))
            idx += 1
        }

        // Stream through original and compute positions.
        // Track consumption index per base ID so we match R1→R1, R2→R2 in order.
        var consumedPerBaseID: [String: Int] = [:]
        let originalReader = FASTQReader(validateSequence: false)
        var records: [FASTQTrimRecord] = []
        var originalIndex = 0
        for try await original in originalReader.records(from: originalFASTQ) {
            let baseID = normalizedIdentifier(original.identifier)
            defer { originalIndex += 1 }

            // Find the next unconsumed trimmed record with this base ID
            let consumed = consumedPerBaseID[baseID] ?? 0
            guard let entries = trimmedByBaseID[baseID],
                  consumed < entries.count else { continue }
            let trimmed = entries[consumed].record
            consumedPerBaseID[baseID] = consumed + 1

            // Use positional key for the trim record to ensure uniqueness
            let pairOrdinal = consumed  // 0 = first occurrence (R1), 1 = second (R2), etc.
            let trimKey = "\(baseID)#\(pairOrdinal)"

            let trimStart: Int
            let trimEnd: Int

            if trimmed.sequence.isEmpty {
                continue
            } else if trimmed.sequence.count == original.sequence.count {
                trimStart = 0
                trimEnd = original.length
            } else {
                let origLen = original.sequence.count
                let trimLen = trimmed.sequence.count

                if original.sequence.hasSuffix(trimmed.sequence) {
                    trimStart = origLen - trimLen
                    trimEnd = origLen
                } else if original.sequence.hasPrefix(trimmed.sequence) {
                    trimStart = 0
                    trimEnd = trimLen
                } else {
                    var fivePrimeTrim = 0
                    let origChars = Array(original.sequence.utf8)
                    let trimChars = Array(trimmed.sequence.utf8)
                    let maxOffset = origLen - trimLen
                    for offset in 1...maxOffset {
                        if origChars[offset] == trimChars[0] &&
                           origChars[offset + trimLen - 1] == trimChars[trimLen - 1] {
                            var match = true
                            for i in 0..<trimLen {
                                if origChars[offset + i] != trimChars[i] {
                                    match = false
                                    break
                                }
                            }
                            if match {
                                fivePrimeTrim = offset
                                break
                            }
                        }
                    }
                    trimStart = fivePrimeTrim
                    trimEnd = fivePrimeTrim + trimLen
                }
            }

            records.append(FASTQTrimRecord(readID: trimKey, trimStart: trimStart, trimEnd: trimEnd))
        }
        return records
    }

    // MARK: - Trim Materialization

    /// Materializes a trim derivative by applying trim positions to root FASTQ records.
    ///
    /// Handles both plain keys (`readID`) and positional keys (`readID#ordinal`)
    /// for PE interleaved data where R1/R2 share the same base ID.
    private func extractTrimmedReads(
        fromRootFASTQ rootFASTQ: URL,
        positions: [String: (start: Int, end: Int)],
        outputFASTQ: URL
    ) async throws {
        if positions.isEmpty {
            throw FASTQDerivativeError.emptyResult
        }

        // Detect whether positions use positional keys (contain '#')
        let usesPositionalKeys = positions.keys.contains(where: { $0.contains("#") })

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        if usesPositionalKeys {
            // Track occurrence count per base ID to reconstruct positional keys
            var occurrencePerBaseID: [String: Int] = [:]
            for try await record in reader.records(from: rootFASTQ) {
                let baseID = normalizedIdentifier(record.identifier)
                let ordinal = occurrencePerBaseID[baseID] ?? 0
                occurrencePerBaseID[baseID] = ordinal + 1

                let key = "\(baseID)#\(ordinal)"
                guard let pos = positions[key] else { continue }
                let trimmed = record.trimmed(from: pos.start, to: pos.end)
                if trimmed.length > 0 {
                    try writer.write(trimmed)
                }
            }
        } else {
            // Legacy plain key mode (SE data or pre-PE-fix bundles)
            for try await record in reader.records(from: rootFASTQ) {
                let key = normalizedIdentifier(record.identifier)
                guard let pos = positions[key] else { continue }
                let trimmed = record.trimmed(from: pos.start, to: pos.end)
                if trimmed.length > 0 {
                    try writer.write(trimmed)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Extracts read IDs from a FASTQ file using `seqkit seq --name --only-id`.
    ///
    /// For PE interleaved data, deduplicates the ID list so that re-extraction
    /// with `seqkit grep -f` naturally includes both mates (R1 and R2) for each
    /// base ID. Returns the number of unique IDs written.
    private func writeReadIDs(fromFASTQ fastqURL: URL, to outputURL: URL, deduplicate: Bool = false) async throws -> Int {
        let rawOutputURL: URL
        if deduplicate {
            rawOutputURL = outputURL.deletingLastPathComponent().appendingPathComponent("raw-ids.txt")
        } else {
            rawOutputURL = outputURL
        }

        let result = try await runner.runWithFileOutput(
            .seqkit,
            arguments: [
                "seq", "--name", "--only-id",
                fastqURL.path,
            ],
            outputFile: rawOutputURL,
            timeout: 600
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit seq --name failed: \(result.stderr)")
        }

        if deduplicate {
            try deduplicateIDFile(from: rawOutputURL, to: outputURL)
            try? FileManager.default.removeItem(at: rawOutputURL)
        }

        // Count lines in the output to get read count
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func createOutputBundleURL(
        sourceBundleURL: URL,
        operation: FASTQDerivativeOperation
    ) throws -> URL {
        let parent = sourceBundleURL.deletingLastPathComponent()
        let sourceName = sourceBundleURL.deletingPathExtension().lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let base = "\(sourceName)-\(operation.shortLabel)-\(timestamp)"

        var candidate = parent.appendingPathComponent("\(base).\(FASTQBundle.directoryExtension)", isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(suffix).\(FASTQBundle.directoryExtension)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func uniqueDirectoryURL(startingAt initialURL: URL) -> URL {
        var candidate = initialURL
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = initialURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(initialURL.lastPathComponent)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
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

    private func isInterleavedBundle(_ bundleURL: URL) -> Bool {
        if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            return manifest.pairingMode == .interleaved
        }
        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return FASTQMetadataStore.load(for: fastqURL)?.ingestion?.pairingMode == .interleaved
        }
        return false
    }

    private func normalizedIdentifier(_ identifier: String) -> String {
        var value = identifier
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        return value
    }

    private func deduplicateInterleavedPairs(
        mode: FASTQDeduplicateMode,
        sourceFASTQ: URL,
        outputFASTQ: URL
    ) async throws {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        var buffer: FASTQRecord?
        var seen: Set<String> = []

        for try await record in reader.records(from: sourceFASTQ) {
            if let first = buffer {
                let second = record
                let key = pairedKey(first: first, second: second, mode: mode)
                if !seen.contains(key) {
                    seen.insert(key)
                    try writer.write(first)
                    try writer.write(second)
                }
                buffer = nil
            } else {
                buffer = record
            }
        }

        // If an odd trailing record exists, preserve first appearance.
        if let trailing = buffer {
            let key = singleKey(record: trailing, mode: mode)
            if !seen.contains(key) {
                try writer.write(trailing)
            }
        }
    }

    private func pairedKey(first: FASTQRecord, second: FASTQRecord, mode: FASTQDeduplicateMode) -> String {
        switch mode {
        case .identifier:
            let left = stripPairSuffix(from: normalizedIdentifier(first.identifier))
            let right = stripPairSuffix(from: normalizedIdentifier(second.identifier))
            return "id:\(left)|\(right)"
        case .description:
            let left = (first.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let right = (second.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "desc:\(left)|\(right)"
        case .sequence:
            return "seq:\(first.sequence)|\(second.sequence)"
        }
    }

    private func singleKey(record: FASTQRecord, mode: FASTQDeduplicateMode) -> String {
        switch mode {
        case .identifier:
            return "id:\(normalizedIdentifier(record.identifier))"
        case .description:
            return "desc:\((record.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
        case .sequence:
            return "seq:\(record.sequence)"
        }
    }

    private func stripPairSuffix(from identifier: String) -> String {
        if identifier.hasSuffix("/1") || identifier.hasSuffix("/2") {
            return String(identifier.dropLast(2))
        }
        return identifier
    }
}
