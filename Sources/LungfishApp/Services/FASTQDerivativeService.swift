// FASTQDerivativeService.swift - Pointer-based FASTQ derivative creation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import os.log

private let derivativeLogger = Logger(subsystem: LogSubsystem.app, category: "FASTQDerivativeService")

public enum FASTQDerivativeRequest: Sendable {
    // Subset operations (produce read ID lists)
    case subsampleProportion(Double)
    case subsampleCount(Int)
    case lengthFilter(min: Int?, max: Int?)
    case searchText(query: String, field: FASTQSearchField, regex: Bool)
    case searchMotif(pattern: String, regex: Bool)
    case deduplicate(preset: FASTQDeduplicatePreset, substitutions: Int, optical: Bool, opticalDistance: Int)

    // Trim operations (produce trim position records)
    case qualityTrim(threshold: Int, windowSize: Int, mode: FASTQQualityTrimMode)
    case adapterTrim(mode: FASTQAdapterMode, sequence: String?, sequenceR2: String?, fastaFilename: String?)
    case fixedTrim(from5Prime: Int, from3Prime: Int)

    // BBTools operations
    case contaminantFilter(mode: FASTQContaminantFilterMode, referenceFasta: String?, kmerSize: Int, hammingDistance: Int)
    case pairedEndMerge(strictness: FASTQMergeStrictness, minOverlap: Int)
    case pairedEndRepair
    case primerRemoval(configuration: FASTQPrimerTrimConfiguration)
    case sequencePresenceFilter(
        sequence: String?,
        fastaPath: String?,
        searchEnd: FASTQAdapterSearchEnd,
        minOverlap: Int,
        errorRate: Double,
        keepMatched: Bool,
        searchReverseComplement: Bool
    )
    case errorCorrection(kmerSize: Int)
    case interleaveReformat(direction: FASTQInterleaveDirection)

    // Demultiplexing (produces per-barcode bundles)
    case demultiplex(
        kitID: String,
        customCSVPath: String?,
        location: String,
        symmetryMode: BarcodeSymmetryMode?,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        errorRate: Double,
        trimBarcodes: Bool,
        sampleAssignments: [FASTQSampleBarcodeAssignment]?,
        kitOverride: BarcodeKitDefinition?
    )

    // Orient sequences against a reference
    case orient(
        referenceURL: URL,
        wordLength: Int,
        dbMask: String,
        saveUnoriented: Bool
    )

    // Human read removal
    case humanReadScrub(databaseID: String, removeReads: Bool)

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
        case .primerRemoval: return "PCR Primer Trimming"
        case .sequencePresenceFilter: return "Sequence Presence Filter"
        case .errorCorrection: return "Error Correction"
        case .interleaveReformat: return "Interleave Reformat"
        case .demultiplex: return "Demultiplex"
        case .orient: return "Orient Sequences"
        case .humanReadScrub: return "Human Read Scrub"
        }
    }

    /// Whether this request produces a trim derivative (vs subset).
    var isTrimOperation: Bool {
        switch self {
        case .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval:
            return true
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .contaminantFilter,
             .sequencePresenceFilter:
            return false
        case .pairedEndMerge, .pairedEndRepair,
             .errorCorrection, .interleaveReformat, .demultiplex,
             .orient, .humanReadScrub:
            return false
        }
    }

    /// Whether this request produces a full materialized FASTQ (content-transforming).
    var isFullOperation: Bool {
        switch self {
        case .pairedEndMerge, .pairedEndRepair,
             .errorCorrection, .interleaveReformat, .demultiplex, .humanReadScrub:
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

    /// Human-readable label for batch operation records.
    var batchLabel: String {
        switch self {
        case .lengthFilter(let min, let max):
            let parts = [min.map { "\($0)" } ?? "", max.map { "\($0)" } ?? ""]
                .filter { !$0.isEmpty }
            if parts.isEmpty { return "Filter by Length" }
            return "Filter by Length (\(parts.joined(separator: "-")) bp)"
        case .subsampleProportion(let p):
            return "Subsample \(Int(p * 100))%"
        case .subsampleCount(let n):
            return "Subsample \(n) reads"
        default:
            return operationLabel
        }
    }

    /// Machine-readable operation kind string for batch manifests.
    var operationKindString: String {
        switch self {
        case .subsampleProportion: return "subsampleProportion"
        case .subsampleCount: return "subsampleCount"
        case .lengthFilter: return "lengthFilter"
        case .searchText: return "searchText"
        case .searchMotif: return "searchMotif"
        case .deduplicate: return "deduplicate"
        case .qualityTrim: return "qualityTrim"
        case .adapterTrim: return "adapterTrim"
        case .fixedTrim: return "fixedTrim"
        case .contaminantFilter: return "contaminantFilter"
        case .pairedEndMerge: return "pairedEndMerge"
        case .pairedEndRepair: return "pairedEndRepair"
        case .primerRemoval: return "primerRemoval"
        case .sequencePresenceFilter: return "sequencePresenceFilter"
        case .errorCorrection: return "errorCorrection"
        case .interleaveReformat: return "interleaveReformat"
        case .demultiplex: return "demultiplex"
        case .orient: return "orient"
        case .humanReadScrub: return "humanReadScrub"
        }
    }

    /// Key-value parameters for batch manifest display.
    var batchParameters: [String: String] {
        switch self {
        case .subsampleProportion(let p):
            return ["proportion": String(format: "%.2f", p)]
        case .subsampleCount(let n):
            return ["count": "\(n)"]
        case .lengthFilter(let min, let max):
            var params: [String: String] = [:]
            if let min { params["minLength"] = "\(min)" }
            if let max { params["maxLength"] = "\(max)" }
            return params
        case .searchText(let query, let field, let regex):
            return ["query": query, "field": "\(field)", "regex": "\(regex)"]
        case .searchMotif(let pattern, let regex):
            return ["pattern": pattern, "regex": "\(regex)"]
        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            var params: [String: String] = ["preset": preset.rawValue, "substitutions": "\(substitutions)"]
            if optical { params["optical"] = "true"; params["opticalDistance"] = "\(opticalDistance)" }
            return params
        case .qualityTrim(let threshold, let windowSize, let mode):
            return ["threshold": "\(threshold)", "windowSize": "\(windowSize)", "mode": "\(mode)"]
        case .adapterTrim(let mode, let sequence, _, _):
            var params: [String: String] = ["mode": "\(mode)"]
            if let seq = sequence { params["sequence"] = seq }
            return params
        case .fixedTrim(let from5, let from3):
            return ["from5Prime": "\(from5)", "from3Prime": "\(from3)"]
        case .contaminantFilter(let mode, _, let kmerSize, let hammingDistance):
            return ["mode": "\(mode)", "kmerSize": "\(kmerSize)", "hammingDistance": "\(hammingDistance)"]
        case .pairedEndMerge(let strictness, let minOverlap):
            return ["strictness": "\(strictness)", "minOverlap": "\(minOverlap)"]
        case .pairedEndRepair:
            return [:]
        case .primerRemoval(let configuration):
            var params: [String: String] = [
                "source": configuration.source.rawValue,
                "readMode": configuration.readMode.rawValue,
                "mode": configuration.mode.rawValue,
                "minimumOverlap": "\(configuration.minimumOverlap)",
                "errorRate": String(format: "%.2f", configuration.errorRate),
                "keepUntrimmed": "\(configuration.keepUntrimmed)",
                "tool": configuration.tool.rawValue,
            ]
            if configuration.tool == .bbduk {
                params["ktrimDirection"] = configuration.ktrimDirection.rawValue
                params["kmerSize"] = "\(configuration.kmerSize)"
                params["minKmer"] = "\(configuration.minKmer)"
                params["hammingDistance"] = "\(configuration.hammingDistance)"
            }
            return params
        case .sequencePresenceFilter(_, _, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchRC):
            return [
                "searchEnd": searchEnd.rawValue,
                "minOverlap": "\(minOverlap)",
                "errorRate": String(format: "%.2f", errorRate),
                "keepMatched": "\(keepMatched)",
                "searchReverseComplement": "\(searchRC)",
            ]
        case .errorCorrection(let kmerSize):
            return ["kmerSize": "\(kmerSize)"]
        case .interleaveReformat(let direction):
            return ["direction": "\(direction)"]
        case .demultiplex(let kitID, _, let location, _, _, _, let errorRate, let trimBarcodes, _, _):
            return ["kitID": kitID, "location": location, "errorRate": "\(errorRate)", "trimBarcodes": "\(trimBarcodes)"]
        case .orient(_, let wordLength, _, _):
            return ["wordLength": "\(wordLength)"]
        case .humanReadScrub(let databaseID, let removeReads):
            return ["databaseID": databaseID, "removeReads": "\(removeReads)"]
        }
    }
}

// MARK: - CLI Command Construction

/// Shell-quotes a single argument for display in the CLI command string.
///
/// Uses the same quoting rules as ``OperationCenter/shellQuote(_:)`` but
/// is a module-level free function to avoid requiring visibility changes
/// to the private OperationCenter helper.
private func shellQuoteForCLI(_ argument: String) -> String {
    let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./=:@%+,"))
    if !argument.isEmpty && argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return argument
    }
    let escaped = argument.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

/// Builds a shell-quoted command string from an array of parts.
private func buildToolCommand(parts: [String]) -> String {
    parts.map { shellQuoteForCLI($0) }.joined(separator: " ")
}

/// Builds a shell-quoted `lungfish <subcommand> <args>` command string.
private func buildLungfishCommand(subcommand: String, args: [String]) -> String {
    buildToolCommand(parts: ["lungfish", subcommand] + args)
}

extension FASTQDerivativeRequest {
    /// Constructs the equivalent `lungfish fastq` CLI command for this operation.
    ///
    /// The returned string is a copy-pasteable shell command that reproduces
    /// the same transformation on the command line. Displayed in the Operations
    /// Panel for transparency and reproducibility.
    ///
    /// For operations without a direct `lungfish fastq` subcommand (e.g. search,
    /// orient), the string shows the underlying tool invocation instead.
    ///
    /// - Parameters:
    ///   - inputPath: Path to the input FASTQ file.
    ///   - outputPath: Path to the output FASTQ file.
    /// - Returns: A shell-quoted CLI command string.
    func cliCommand(inputPath: String, outputPath: String) -> String {
        switch self {
        case .subsampleProportion(let proportion):
            return buildLungfishCommand(subcommand: "fastq subsample", args: [
                "--proportion", String(proportion), inputPath, "-o", outputPath,
            ])

        case .subsampleCount(let count):
            return buildLungfishCommand(subcommand: "fastq subsample", args: [
                "--count", String(count), inputPath, "-o", outputPath,
            ])

        case .lengthFilter(let min, let max):
            var args: [String] = []
            if let min { args += ["--min", String(min)] }
            if let max { args += ["--max", String(max)] }
            args += [inputPath, "-o", outputPath]
            return buildLungfishCommand(subcommand: "fastq length-filter", args: args)

        case .searchText(let query, let field, let regex):
            // No direct lungfish CLI subcommand — show the seqkit grep invocation.
            var parts = ["seqkit", "grep"]
            if field == .description { parts.append("-n") }
            if regex { parts.append("-r") }
            parts += ["-p", query, inputPath, "-o", outputPath]
            return buildToolCommand(parts: parts)

        case .searchMotif(let pattern, let regex):
            // No direct lungfish CLI subcommand — show the seqkit grep invocation.
            var parts = ["seqkit", "grep", "-s"]
            if regex { parts.append("-r") }
            parts += ["-p", pattern, inputPath, "-o", outputPath]
            return buildToolCommand(parts: parts)

        case .deduplicate(_, let substitutions, let optical, let opticalDistance):
            var args = [inputPath, "--subs", String(substitutions), "-o", outputPath]
            if optical {
                args += ["--optical", "--dupedist", String(opticalDistance)]
            }
            return buildLungfishCommand(subcommand: "fastq deduplicate", args: args)

        case .qualityTrim(let threshold, let windowSize, let mode):
            let modeString: String
            switch mode {
            case .cutRight: modeString = "cut-right"
            case .cutFront: modeString = "cut-front"
            case .cutTail: modeString = "cut-tail"
            case .cutBoth: modeString = "cut-both"
            }
            return buildLungfishCommand(subcommand: "fastq quality-trim", args: [
                "--threshold", String(threshold),
                "--window", String(windowSize),
                "--mode", modeString,
                inputPath, "-o", outputPath,
            ])

        case .adapterTrim(_, let sequence, _, _):
            var args = [inputPath, "-o", outputPath]
            if let sequence {
                args += ["--adapter", sequence]
            }
            return buildLungfishCommand(subcommand: "fastq adapter-trim", args: args)

        case .fixedTrim(let from5Prime, let from3Prime):
            var args = [inputPath, "-o", outputPath]
            if from5Prime > 0 { args += ["--front", String(from5Prime)] }
            if from3Prime > 0 { args += ["--tail", String(from3Prime)] }
            return buildLungfishCommand(subcommand: "fastq fixed-trim", args: args)

        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            var args = [inputPath, "-o", outputPath, "--kmer", String(kmerSize), "--hdist", String(hammingDistance)]
            switch mode {
            case .phix:
                args += ["--mode", "phix"]
            case .custom:
                args += ["--mode", "custom"]
                if let ref = referenceFasta { args += ["--ref", ref] }
            }
            return buildLungfishCommand(subcommand: "fastq contaminant-filter", args: args)

        case .pairedEndMerge(let strictness, let minOverlap):
            var args = [inputPath, "-o", outputPath, "--min-overlap", String(minOverlap)]
            if strictness == .strict { args.append("--strict") }
            return buildLungfishCommand(subcommand: "fastq merge", args: args)

        case .pairedEndRepair:
            return buildLungfishCommand(subcommand: "fastq repair", args: [
                inputPath, "-o", outputPath,
            ])

        case .primerRemoval(let configuration):
            var args = [inputPath, "-o", outputPath]
            if let seq = configuration.forwardSequence {
                args += ["--literal", seq]
            } else if let ref = configuration.referenceFasta {
                args += ["--ref", ref]
            }
            if configuration.tool == .bbduk {
                args += [
                    "--kmer", String(configuration.kmerSize),
                    "--mink", String(configuration.minKmer),
                    "--hdist", String(configuration.hammingDistance),
                ]
            }
            return buildLungfishCommand(subcommand: "fastq primer-remove", args: args)

        case .sequencePresenceFilter(let sequence, let fastaPath, _, let minOverlap, let errorRate, let keepMatched, _):
            // No direct lungfish CLI subcommand — show cutadapt invocation.
            var parts = ["cutadapt", "--discard-untrimmed", "-O", String(minOverlap), "-e", String(format: "%.2f", errorRate)]
            if let seq = sequence { parts += ["-a", seq] }
            else if let path = fastaPath { parts += ["-a", "file:\(path)"] }
            parts += ["-o", outputPath, inputPath]
            let note = keepMatched ? " # keep matched" : " # keep unmatched"
            return buildToolCommand(parts: parts) + note

        case .errorCorrection(let kmerSize):
            return buildLungfishCommand(subcommand: "fastq error-correct", args: [
                inputPath, "-o", outputPath, "--kmer", String(kmerSize),
            ])

        case .interleaveReformat(let direction):
            switch direction {
            case .deinterleave:
                return buildLungfishCommand(subcommand: "fastq deinterleave", args: [
                    inputPath, "--out1", outputPath + ".R1.fastq", "--out2", outputPath + ".R2.fastq",
                ])
            case .interleave:
                return buildLungfishCommand(subcommand: "fastq interleave", args: [
                    "--in1", inputPath, "--in2", "<R2>", "-o", outputPath,
                ])
            }

        case .demultiplex(let kitID, let customCSVPath, let location, _, _, _, let errorRate, let trimBarcodes, _, _):
            var args = [inputPath, "--kit", customCSVPath ?? kitID, "-o", outputPath]
            args += ["--location", location, "--error-rate", String(format: "%.2f", errorRate)]
            if !trimBarcodes { args.append("--no-trim") }
            return buildLungfishCommand(subcommand: "fastq demultiplex", args: args)

        case .orient(let referenceURL, let wordLength, _, _):
            // No direct lungfish CLI subcommand — show vsearch invocation.
            return buildToolCommand(parts: [
                "vsearch", "--orient", inputPath,
                "--db", referenceURL.path,
                "--fastaout", outputPath,
                "--wordlength", String(wordLength),
            ])

        case .humanReadScrub(let databaseID, let removeReads):
            // No direct lungfish CLI subcommand — show sra-human-scrubber invocation.
            let action = removeReads ? "--remove" : "--flag"
            return buildToolCommand(parts: [
                "sra-human-scrubber", "--db", databaseID, action, inputPath, "-o", outputPath,
            ])
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

    /// Number of threads to pass to multithreaded tools (fastp, seqkit, etc.).
    /// Uses all available cores for maximum throughput.
    private let toolThreadCount = ProcessInfo.processInfo.activeProcessorCount

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
            guard let rootFASTQURL = FASTQBundle.resolvePrimaryFASTQURL(for: sourceBundleURL) else {
                throw FASTQDerivativeError.sourceFASTQMissing
            }
            rootFASTQFilename = rootFASTQURL.lastPathComponent
            resolvedRootBundleURL = sourceBundleURL
            pairingMode = FASTQMetadataStore.load(for: rootFASTQURL)?.ingestion?.pairingMode
            baseLineage = []
        }

        // Orient has its own execution path — produces an orient-map derivative
        if case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented) = request {
            return try await createOrientDerivative(
                sourceFASTQ: materializedSourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                resolvedRootBundleURL: resolvedRootBundleURL,
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
            let symmetryMode,
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
                rootBundleURL: resolvedRootBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                pairingMode: pairingMode,
                kitID: kitID,
                customCSVPath: customCSVPath,
                location: location,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                errorRate: errorRate,
                symmetryMode: symmetryMode,
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
                resolvedRootBundleURL: resolvedRootBundleURL,
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
            pairingMode: pairingMode
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundle)

        progress?("Created derived dataset: \(outputBundle.lastPathComponent)")
        derivativeLogger.info("Created FASTQ derivative bundle at \(outputBundle.path, privacy: .public)")
        return outputBundle
    }

    // MARK: - Batch Operations

    /// Result of a batch operation on multiple FASTQ bundles.
    public struct BatchResult: Sendable {
        /// Bundles that were successfully processed.
        public let outputBundleURLs: [URL]

        /// Input bundles that failed, with error descriptions.
        public let failures: [(inputURL: URL, error: String)]

        /// The batch operation record for manifest persistence.
        public let record: BatchOperationRecord

        /// Total wall clock time in seconds.
        public let wallClockSeconds: Double
    }

    /// Applies a derivative operation to multiple FASTQ bundles in sequence.
    ///
    /// Each input bundle is processed individually via `createDerivative`. Results are
    /// stored as children of each input bundle. A `BatchOperationRecord` is written to
    /// the common parent directory for sidebar virtual group creation.
    ///
    /// - Parameters:
    ///   - inputBundleURLs: The FASTQ bundles to process.
    ///   - request: The operation to apply to each bundle.
    ///   - commonParentDirectory: Directory where batch-operations.json is stored.
    ///   - progress: Callback reporting (fraction, message) across all bundles.
    /// - Returns: A `BatchResult` with output URLs, failures, and the batch record.
    public func createBatchDerivative(
        from inputBundleURLs: [URL],
        request: FASTQDerivativeRequest,
        commonParentDirectory: URL?,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> BatchResult {
        let startTime = Date()
        let totalCount = inputBundleURLs.count
        var outputURLs: [URL] = []
        var failures: [(URL, String)] = []

        for (index, inputURL) in inputBundleURLs.enumerated() {
            let bundleName = inputURL.deletingPathExtension().lastPathComponent
            let fraction = Double(index) / Double(max(1, totalCount))
            progress?(fraction, "Processing \(bundleName) (\(index + 1)/\(totalCount))...")

            do {
                let outputURL = try await createDerivative(
                    from: inputURL,
                    request: request,
                    progress: { message in
                        let subFraction = fraction + (1.0 / Double(max(1, totalCount))) * 0.9
                        progress?(subFraction, "[\(bundleName)] \(message)")
                    }
                )
                outputURLs.append(outputURL)
            } catch {
                failures.append((inputURL, error.localizedDescription))
                derivativeLogger.warning("Batch operation failed for \(bundleName): \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        progress?(1.0, "Batch complete: \(outputURLs.count)/\(totalCount) succeeded")

        // Build the batch record
        let record = BatchOperationRecord(
            label: request.batchLabel,
            operationKind: request.operationKindString,
            parameters: request.batchParameters,
            outputBundlePaths: outputURLs.compactMap { url in
                commonParentDirectory.flatMap { parent in
                    relativePath(from: parent, to: url)
                } ?? url.lastPathComponent
            },
            inputBundlePaths: inputBundleURLs.compactMap { url in
                commonParentDirectory.flatMap { parent in
                    relativePath(from: parent, to: url)
                } ?? url.lastPathComponent
            },
            failureCount: failures.count,
            wallClockSeconds: elapsed
        )

        for outputURL in outputURLs {
            attachBatchOperationID(record.id, to: outputURL)
        }

        // Persist the batch record to the common parent directory
        if let parentDir = commonParentDirectory {
            do {
                try FASTQBatchManifest.appendOperation(record, to: parentDir)
                derivativeLogger.info("Saved batch operation record to \(parentDir.path, privacy: .public)")
            } catch {
                derivativeLogger.warning("Failed to save batch manifest: \(error)")
            }
        }

        return BatchResult(
            outputBundleURLs: outputURLs,
            failures: failures,
            record: record,
            wallClockSeconds: elapsed
        )
    }

    private func attachBatchOperationID(_ batchOperationID: UUID, to bundleURL: URL) {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else { return }
        let updatedManifest = FASTQDerivedBundleManifest(
            id: manifest.id,
            name: manifest.name,
            createdAt: manifest.createdAt,
            parentBundleRelativePath: manifest.parentBundleRelativePath,
            rootBundleRelativePath: manifest.rootBundleRelativePath,
            rootFASTQFilename: manifest.rootFASTQFilename,
            payload: manifest.payload,
            lineage: manifest.lineage,
            operation: manifest.operation,
            cachedStatistics: manifest.cachedStatistics,
            pairingMode: manifest.pairingMode,
            readClassification: manifest.readClassification,
            batchOperationID: batchOperationID,
            sequenceFormat: manifest.sequenceFormat,
            provenance: manifest.provenance,
            payloadChecksums: manifest.payloadChecksums
        )
        try? FASTQBundle.saveDerivedManifest(updatedManifest, in: bundleURL)
    }

    /// Computes a relative path from one URL to another.
    private func relativePath(from base: URL, to target: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedBase) else { return nil }
        return String(targetPath.dropFirst(normalizedBase.count))
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
        resolvedRootBundleURL: URL,
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

        // Create the derivative bundle inside the source bundle's derivatives/ directory.
        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: sourceBundleURL)
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let initialBundleURL = derivDir.appendingPathComponent(
            "orient-\(shortID).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let bundleURL = uniqueDirectoryURL(startingAt: initialBundleURL)
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
        do {
            try await writeOrientedPreviewFASTQ(
                fromSourceFASTQ: sourceFASTQ,
                orientMapURL: orientMapURL,
                outputFASTQ: previewURL
            )
        } catch {
            derivativeLogger.warning("Failed to create orient preview: \(error.localizedDescription)")
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

        let orientParentPath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: bundleURL)
            ?? relativePathFromBundle(bundleURL, to: sourceBundleURL)
        let orientRootPath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: bundleURL)
            ?? relativePathFromBundle(bundleURL, to: resolvedRootBundleURL)

        let manifest = FASTQDerivedBundleManifest(
            name: "Oriented",
            parentBundleRelativePath: orientParentPath,
            rootBundleRelativePath: orientRootPath,
            rootFASTQFilename: rootFASTQFilename,
            payload: .orientMap(orientMapFilename: orientMapFilename, previewFilename: previewFilename),
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats ?? .placeholder(readCount: fwdCount + rcCount, baseCount: 0),
            pairingMode: pairingMode
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        // Optionally create unoriented reads derivative
        if saveUnoriented, let unorientedFASTQ = result.unorientedFASTQ,
           FileManager.default.fileExists(atPath: unorientedFASTQ.path) {
            let unorientedShortID = UUID().uuidString.prefix(8).lowercased()
            let unorientedBaseName = "unoriented-\(unorientedShortID).\(FASTQBundle.directoryExtension)"
            let initialUnorientedBundleURL = derivDir.appendingPathComponent(unorientedBaseName, isDirectory: true)
            let unorientedBundleURL = uniqueDirectoryURL(startingAt: initialUnorientedBundleURL)
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

            let unorientedParentPath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: unorientedBundleURL)
                ?? relativePathFromBundle(unorientedBundleURL, to: sourceBundleURL)
            let unorientedRootPath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: unorientedBundleURL)
                ?? relativePathFromBundle(unorientedBundleURL, to: resolvedRootBundleURL)

            let unorientedManifest = FASTQDerivedBundleManifest(
                name: "Unoriented",
                parentBundleRelativePath: unorientedParentPath,
                rootBundleRelativePath: unorientedRootPath,
                rootFASTQFilename: rootFASTQFilename,
                payload: .full(fastqFilename: "unoriented.fastq"),
                lineage: unorientedLineage,
                operation: unorientedOp,
                cachedStatistics: unorientedStats ?? .placeholder(readCount: result.unmatchedCount, baseCount: 0),
                pairingMode: pairingMode
            )

            try FASTQBundle.saveDerivedManifest(unorientedManifest, in: unorientedBundleURL)
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
        rootBundleURL: URL,
        rootFASTQFilename: String,
        pairingMode: IngestionMetadata.PairingMode?,
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

        // Create demux output as a child directory inside the source bundle
        // This produces a parent-child hierarchy: parent.lungfishfastq/demux/barcode01/...
        let outputDirectory = sourceBundleURL.appendingPathComponent("demux", isDirectory: true)
        // Remove prior demux results if re-running
        if FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        progress?("Demultiplexing reads...")
        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: sourceFASTQ,
                sourceBundleURL: sourceBundleURL,
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
                rootBundleURL: rootBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                inputPairingMode: pairingMode,
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
        resolvedRootBundleURL: URL,
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

        let mixedParentPath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: outputBundle)
            ?? relativePathFromBundle(outputBundle, to: sourceBundleURL)
        let mixedRootPath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: outputBundle)
            ?? relativePathFromBundle(outputBundle, to: resolvedRootBundleURL)

        let manifest = FASTQDerivedBundleManifest(
            name: outputBundle.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: mixedParentPath,
            rootBundleRelativePath: mixedRootPath,
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
        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: sourceBundleURL)
        let suffix: String
        switch request {
        case .pairedEndMerge: suffix = "merge"
        case .pairedEndRepair: suffix = "repair"
        default: suffix = "derived"
        }
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let bundleName = "\(suffix)-\(shortID).\(FASTQBundle.directoryExtension)"
        return derivDir.appendingPathComponent(bundleName)
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
            let seed = UInt64.random(in: 0...UInt64.max)
            if isInterleaved {
                // Use reformat.sh with samplerate for pair-aware subsampling
                let env = await bbToolsEnvironment()
                let result = try await runner.run(
                    .reformat,
                    arguments: [
                        "in=\(sourceFASTQ.path)",
                        "out=\(outputFASTQ.path)",
                        "samplerate=\(proportion)",
                        "sampleseed=\(seed)",
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
                    arguments: ["sample", "-p", String(proportion), "-s", String(seed), sourceFASTQ.path, "-o", outputFASTQ.path]
                )
            }
            return FASTQDerivativeOperation(
                kind: .subsampleProportion,
                proportion: proportion,
                randomSeed: seed
            )

        case .subsampleCount(let count):
            guard count > 0 else {
                throw FASTQDerivativeError.invalidOperation("count must be > 0")
            }
            let seed = UInt64.random(in: 0...UInt64.max)
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
                        "sampleseed=\(seed)",
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
                    arguments: ["sample", "-n", String(count), "-s", String(seed), sourceFASTQ.path, "-o", outputFASTQ.path]
                )
            }
            return FASTQDerivativeOperation(
                kind: .subsampleCount,
                count: count,
                randomSeed: seed
            )

        case .lengthFilter(let minLength, let maxLength):
            if minLength == nil, maxLength == nil {
                throw FASTQDerivativeError.invalidOperation("Specify a minimum length, a maximum length, or both.")
            }
            if let minLength, minLength < 0 {
                throw FASTQDerivativeError.invalidOperation("Minimum length must be >= 0.")
            }
            if let maxLength, maxLength < 0 {
                throw FASTQDerivativeError.invalidOperation("Maximum length must be >= 0.")
            }
            if let minLength, let maxLength, minLength > maxLength {
                throw FASTQDerivativeError.invalidOperation("Minimum length cannot exceed maximum length.")
            }
            if isInterleaved {
                // Use bbduk for pair-aware length filtering
                try await runPairedAwareFilter(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    minLength: minLength,
                    maxLength: maxLength
                )
            } else {
                var args = ["seq", "-j", String(toolThreadCount)]
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
                var args = ["grep", "-j", String(toolThreadCount)]
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
                var args = ["grep", "-s", "-j", String(toolThreadCount)]
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

        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            let env = await bbToolsEnvironment()
            // Allocate ~80% of physical memory to Java heap, capped at 31g
            let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
            let heapGB = max(1, min(31, physicalMemoryGB * 80 / 100))
            var args = [
                "in=\(sourceFASTQ.path)",
                "out=\(outputFASTQ.path)",
                "-Xmx\(heapGB)g",
                "dedupe=t",
                "subs=\(substitutions)",
                "ow=t"
            ]
            if optical {
                args.append("optical=t")
                args.append("dupedist=\(opticalDistance)")
            }
            let result = try await runner.run(.clumpify, arguments: args, environment: env, timeout: 3600)
            guard result.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("clumpify deduplication failed: \(result.stderr)")
            }
            return FASTQDerivativeOperation(
                kind: .deduplicate,
                deduplicatePreset: preset,
                deduplicateSubstitutions: substitutions,
                deduplicateOptical: optical,
                deduplicateOpticalDistance: optical ? opticalDistance : nil,
                toolUsed: "clumpify",
                toolCommand: "clumpify.sh dedupe=t subs=\(substitutions)\(optical ? " optical=t dupedist=\(opticalDistance)" : "")"
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

        case .primerRemoval(let configuration):
            let result: BBToolResult
            switch configuration.tool {
            case .cutadapt:
                result = try await runCutadaptPrimerTrim(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    configuration: configuration,
                    sourceBundleURL: sourceBundleURL,
                    isInterleaved: isInterleaved
                )
            case .bbduk:
                result = try await runBBDukPrimerTrim(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    configuration: configuration,
                    sourceBundleURL: sourceBundleURL,
                    isInterleaved: isInterleaved
                )
            }
            return FASTQDerivativeOperation(
                kind: .primerRemoval,
                primerSource: configuration.source,
                primerLiteralSequence: configuration.forwardSequence,
                primerReferenceFasta: configuration.referenceFasta,
                primerKmerSize: configuration.tool == .bbduk ? configuration.kmerSize : nil,
                primerMinKmer: configuration.tool == .bbduk ? configuration.minKmer : nil,
                primerHammingDistance: configuration.tool == .bbduk ? configuration.hammingDistance : nil,
                primerReadMode: configuration.readMode,
                primerTrimMode: configuration.mode,
                primerForwardSequence: configuration.forwardSequence,
                primerReverseSequence: configuration.reverseSequence,
                primerAnchored5Prime: configuration.anchored5Prime,
                primerAnchored3Prime: configuration.anchored3Prime,
                primerErrorRate: configuration.errorRate,
                primerMinimumOverlap: configuration.minimumOverlap,
                primerAllowIndels: configuration.allowIndels,
                primerKeepUntrimmed: configuration.keepUntrimmed,
                primerSearchReverseComplement: configuration.searchReverseComplement,
                primerPairFilter: configuration.pairFilter,
                primerTool: configuration.tool,
                primerKtrimDirection: configuration.tool == .bbduk ? configuration.ktrimDirection : nil,
                toolUsed: configuration.tool == .bbduk ? "bbduk" : "cutadapt",
                toolCommand: result.toolCommand
            )

        case .sequencePresenceFilter(let sequence, let fastaPath, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchRC):
            let result = try await runCutadaptAdapterPresenceFilter(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                sequence: sequence,
                fastaPath: fastaPath,
                searchEnd: searchEnd,
                minOverlap: minOverlap,
                errorRate: errorRate,
                keepMatched: keepMatched,
                searchReverseComplement: searchRC,
                sourceBundleURL: sourceBundleURL,
                isInterleaved: isInterleaved
            )
            return FASTQDerivativeOperation(
                kind: .sequencePresenceFilter,
                adapterFilterSequence: sequence,
                adapterFilterFastaPath: fastaPath,
                adapterFilterSearchEnd: searchEnd,
                adapterFilterMinOverlap: minOverlap,
                adapterFilterErrorRate: errorRate,
                adapterFilterKeepMatched: keepMatched,
                adapterFilterSearchReverseComplement: searchRC,
                toolUsed: "cutadapt",
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

        case .orient:
            throw FASTQDerivativeError.invalidOperation(
                "Orient is handled via createOrientDerivative."
            )

        case .humanReadScrub(let databaseID, let removeReads):
            let outputURL = outputFASTQ
            _ = try await runHumanReadScrub(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputURL,
                databaseID: databaseID,
                isInterleaved: isInterleaved,
                removeReads: removeReads
            )
            return FASTQDerivativeOperation(
                kind: .humanReadScrub,
                humanScrubRemoveReads: removeReads,
                humanScrubDatabaseID: databaseID,
                toolUsed: "sra-human-scrubber"
            )
        }
    }

    // MARK: - Materialization

    func materializeDatasetFASTQ(
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

        var rootBundleURL = FASTQBundle.resolveBundle(
            relativePath: manifest.rootBundleRelativePath,
            from: bundleURL
        )
        // Recovery for legacy broken relative paths: search the project root
        if !FASTQBundle.isBundleURL(rootBundleURL),
           let recovered = FASTQBundle.findBundleContaining(
               fastqFilename: manifest.rootFASTQFilename, from: bundleURL
           ) {
            rootBundleURL = recovered
            // Repair the manifest with a project-relative path for future operations
            if let projectPath = FASTQBundle.projectRelativePath(for: recovered, from: bundleURL) {
                var repairedManifest = manifest
                repairedManifest = FASTQDerivedBundleManifest(
                    id: manifest.id,
                    name: manifest.name,
                    createdAt: manifest.createdAt,
                    parentBundleRelativePath: manifest.parentBundleRelativePath,
                    rootBundleRelativePath: projectPath,
                    rootFASTQFilename: manifest.rootFASTQFilename,
                    payload: manifest.payload,
                    lineage: manifest.lineage,
                    operation: manifest.operation,
                    cachedStatistics: manifest.cachedStatistics,
                    pairingMode: manifest.pairingMode,
                    readClassification: manifest.readClassification,
                    batchOperationID: manifest.batchOperationID,
                    sequenceFormat: manifest.sequenceFormat,
                    provenance: manifest.provenance,
                    payloadChecksums: manifest.payloadChecksums
                )
                try? FASTQBundle.saveDerivedManifest(repairedManifest, in: bundleURL)
            }
        }
        guard FASTQBundle.isBundleURL(rootBundleURL) else {
            throw FASTQDerivativeError.rootBundleMissing(manifest.rootBundleRelativePath)
        }

        let rootFASTQURL = rootBundleURL.appendingPathComponent(manifest.rootFASTQFilename)
        guard FileManager.default.fileExists(atPath: rootFASTQURL.path) else {
            throw FASTQDerivativeError.rootFASTQMissing
        }

        let outputExtension = (manifest.sequenceFormat ?? .fastq).fileExtension
        let outputURL = tempDirectory.appendingPathComponent("materialized.\(outputExtension)")
        progress?("Materializing pointer dataset...")

        switch manifest.payload {
        case .subset(let readIDFilename):
            let readIDListURL = bundleURL.appendingPathComponent(readIDFilename)
            let trimURL = bundleTrimPositionsURL(bundleURL)
            let orientURL = bundleOrientMapURL(bundleURL)
            if manifest.sequenceFormat == .fasta {
                try await materializeVirtualFASTASubset(
                    rootFASTAURL: rootFASTQURL,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            } else {
                try await materializeVirtualFASTQSubset(
                    rootFASTQURL: rootFASTQURL,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            }

        case .trim(let trimFilename):
            let trimURL = bundleURL.appendingPathComponent(trimFilename)
            let positions = try FASTQTrimPositionFile.load(from: trimURL)
            if manifest.sequenceFormat == .fasta {
                try await extractTrimmedFASTAReads(
                    fromRootFASTA: rootFASTQURL,
                    positions: positions,
                    outputFASTA: outputURL
                )
            } else {
                try await extractTrimmedReads(
                    fromRootFASTQ: rootFASTQURL,
                    positions: positions,
                    outputFASTQ: outputURL
                )
            }

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

        case .demuxedVirtual(_, let readIDFilename, _, let trimPositionsFilename, let orientMapFilename):
            // Virtual demuxed barcode bundle — extract reads from root FASTQ using read ID list.
            // When an orient map is present (inherited from parent orient step), trims are already
            // adjusted to root orientation. After extraction+trimming, apply RC to reads marked "-".
            let readIDListURL = bundleURL.appendingPathComponent(readIDFilename)
            let trimURL = trimPositionsFilename.map { bundleURL.appendingPathComponent($0) }
            let orientURL = orientMapFilename.map { bundleURL.appendingPathComponent($0) }
            try await materializeVirtualFASTQSubset(
                rootFASTQURL: rootFASTQURL,
                readIDListURL: readIDListURL,
                trimPositionsURL: trimURL,
                orientMapURL: orientURL,
                outputURL: outputURL
            )

        case .fullFASTA(let fastaFilename):
            // Full FASTA payload — copy directly to output
            let fullFASTAURL = bundleURL.appendingPathComponent(fastaFilename)
            try FileManager.default.copyItem(at: fullFASTAURL, to: outputURL)

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

    /// Extracts reads from root FASTQ(s) by ID list using `seqkit grep`.
    ///
    /// Supports multi-file bundles: when the root bundle has a `source-files.json`,
    /// all constituent files are passed to seqkit grep (which natively accepts multiple inputs).
    private func extractReads(
        fromRootFASTQ rootFASTQ: URL,
        readIDsFile: URL,
        outputFASTQ: URL
    ) async throws {
        // Resolve multi-file bundles: check if the root FASTQ's parent bundle
        // has a source-files.json manifest
        var inputPaths = [rootFASTQ.path]
        let parentBundle = rootFASTQ.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundle),
           let allURLs = FASTQBundle.resolveAllFASTQURLs(for: parentBundle), allURLs.count > 1 {
            inputPaths = allURLs.map(\.path)
        }

        var args = ["grep", "-f", readIDsFile.path]
        args.append(contentsOf: inputPaths)
        args.append(contentsOf: ["-o", outputFASTQ.path])

        let timeout = max(600.0, Double(inputPaths.count) * 120.0)
        let result = try await runner.run(
            .seqkit,
            arguments: args,
            timeout: timeout
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep failed: \(result.stderr)")
        }
    }

    private func materializeVirtualFASTQSubset(
        rootFASTQURL: URL,
        readIDListURL: URL,
        trimPositionsURL: URL?,
        orientMapURL: URL?,
        outputURL: URL
    ) async throws {
        let needsOrientation = orientMapURL != nil
        let fm = FileManager.default

        let extractTarget: URL
        var orientTempDir: URL?
        if needsOrientation {
            let tempDir = fm.temporaryDirectory.appendingPathComponent(
                "lungfish-virtual-orient-\(UUID().uuidString)", isDirectory: true
            )
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            orientTempDir = tempDir
            extractTarget = tempDir.appendingPathComponent("pre-orient.fastq")
        } else {
            extractTarget = outputURL
        }
        defer {
            if let tempDir = orientTempDir {
                try? fm.removeItem(at: tempDir)
            }
        }

        if let trimPositionsURL {
            if isAbsoluteTrimPositionsFile(trimPositionsURL) {
                let positions = try filteredTrimPositions(from: trimPositionsURL, selectedReadIDsFile: readIDListURL)
                try await extractTrimmedReads(
                    fromRootFASTQ: rootFASTQURL,
                    positions: positions,
                    outputFASTQ: extractTarget
                )
            } else if let filteredTrimContent = try filteredRelativeTrimPositionsContent(
                from: trimPositionsURL,
                selectedReadIDsFile: readIDListURL
            ) {
                let filteredTrimURL = fm.temporaryDirectory.appendingPathComponent(
                    "lungfish-demux-trim-\(UUID().uuidString).tsv"
                )
                try filteredTrimContent.write(to: filteredTrimURL, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(at: filteredTrimURL) }
                try await extractAndTrimReads(
                    fromRootFASTQ: rootFASTQURL,
                    readIDsFile: readIDListURL,
                    trimPositionsFile: filteredTrimURL,
                    outputFASTQ: extractTarget
                )
            } else {
                throw FASTQDerivativeError.emptyResult
            }
        } else {
            try await extractReads(
                fromRootFASTQ: rootFASTQURL,
                readIDsFile: readIDListURL,
                outputFASTQ: extractTarget
            )
        }

        if let orientMapURL {
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            try await materializeOrientedReads(
                fromRootFASTQ: extractTarget,
                forwardReadIDs: fwdReadIDs,
                rcReadIDs: rcReadIDs,
                outputFASTQ: outputURL
            )
        }
    }

    private func materializeVirtualFASTASubset(
        rootFASTAURL: URL,
        readIDListURL: URL,
        trimPositionsURL: URL?,
        orientMapURL: URL?,
        outputURL: URL
    ) async throws {
        let needsOrientation = orientMapURL != nil
        let fm = FileManager.default

        let extractTarget: URL
        var orientTempDir: URL?
        if needsOrientation {
            let tempDir = fm.temporaryDirectory.appendingPathComponent(
                "lungfish-fasta-orient-\(UUID().uuidString)", isDirectory: true
            )
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            orientTempDir = tempDir
            extractTarget = tempDir.appendingPathComponent("pre-orient.fasta")
        } else {
            extractTarget = outputURL
        }
        defer {
            if let tempDir = orientTempDir {
                try? fm.removeItem(at: tempDir)
            }
        }

        if let trimPositionsURL {
            if isAbsoluteTrimPositionsFile(trimPositionsURL) {
                let positions = try filteredTrimPositions(from: trimPositionsURL, selectedReadIDsFile: readIDListURL)
                try await extractTrimmedFASTAReads(
                    fromRootFASTA: rootFASTAURL,
                    positions: positions,
                    outputFASTA: extractTarget
                )
            } else if let filteredTrimContent = try filteredRelativeTrimPositionsContent(
                from: trimPositionsURL,
                selectedReadIDsFile: readIDListURL
            ) {
                let filteredTrimURL = fm.temporaryDirectory.appendingPathComponent(
                    "lungfish-fasta-demux-trim-\(UUID().uuidString).tsv"
                )
                try filteredTrimContent.write(to: filteredTrimURL, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(at: filteredTrimURL) }
                try await extractAndTrimFASTAReads(
                    fromRootFASTA: rootFASTAURL,
                    readIDsFile: readIDListURL,
                    trimPositionsFile: filteredTrimURL,
                    outputFASTA: extractTarget
                )
            } else {
                throw FASTQDerivativeError.emptyResult
            }
        } else if let orientMapURL {
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            let selectedReadIDs = try loadSelectedReadIDLookup(from: readIDListURL)
            try await materializeOrientedFASTAReads(
                fromRootFASTA: rootFASTAURL,
                forwardReadIDs: fwdReadIDs.filter { selectedReadIDs.contains($0) },
                rcReadIDs: rcReadIDs.filter { selectedReadIDs.contains($0) },
                outputFASTA: outputURL
            )
            return
        } else {
            try await extractReads(
                fromRootFASTQ: rootFASTAURL,
                readIDsFile: readIDListURL,
                outputFASTQ: outputURL
            )
            return
        }

        if let orientMapURL {
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            try await materializeOrientedFASTAReads(
                fromRootFASTA: extractTarget,
                forwardReadIDs: fwdReadIDs,
                rcReadIDs: rcReadIDs,
                outputFASTA: outputURL
            )
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
        let selectedReadIDs = forwardReadIDs.union(rcReadIDs)
        guard !selectedReadIDs.isEmpty else {
            throw FASTQDerivativeError.emptyResult
        }

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: rootFASTQ) {
            let readID = normalizedIdentifier(record.identifier)
            guard selectedReadIDs.contains(readID) || selectedReadIDs.contains(record.identifier) else { continue }
            if rcReadIDs.contains(readID) || rcReadIDs.contains(record.identifier) {
                try writer.write(record.reverseComplement())
            } else {
                try writer.write(record)
            }
        }
    }

    private func writeOrientedPreviewFASTQ(
        fromSourceFASTQ sourceFASTQ: URL,
        orientMapURL: URL,
        outputFASTQ: URL,
        readLimit: Int = 1_000
    ) async throws {
        let orientContent = try String(contentsOf: orientMapURL, encoding: .utf8)
        var orderedReadIDs: [String] = []
        var rcReadIDs: Set<String> = []

        for line in orientContent.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let readID = String(fields[0])
            orderedReadIDs.append(readID)
            if fields[1] == "-" {
                rcReadIDs.insert(readID)
            }
            if orderedReadIDs.count >= max(1, readLimit) {
                break
            }
        }

        guard !orderedReadIDs.isEmpty else { return }

        let selectedReadIDs = Set(orderedReadIDs)
        var previewRecords: [String: FASTQRecord] = [:]
        let reader = FASTQReader(validateSequence: false)

        for try await record in reader.records(from: sourceFASTQ) {
            let readID = normalizedIdentifier(record.identifier)
            guard selectedReadIDs.contains(readID) else { continue }

            if rcReadIDs.contains(readID) {
                previewRecords[readID] = record.reverseComplement()
            } else {
                previewRecords[readID] = record
            }

            if previewRecords.count == selectedReadIDs.count {
                break
            }
        }

        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for readID in orderedReadIDs {
            if let record = previewRecords[readID] {
                try writer.write(record)
            }
        }
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

        // Step 2: Parse trim positions (supports both 3-column legacy and 4-column mate-aware formats)
        guard let trimContent = try? String(contentsOf: trimPositionsFile, encoding: .utf8) else {
            // No trim positions — just move extracted reads to output
            try fm.moveItem(at: extractedURL, to: outputFASTQ)
            return
        }

        // Key: "readID\tmate" for PE-safe lookup (mate=0 for single-end/legacy)
        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in trimContent.split(separator: "\n") {
            // Skip format headers and column headers
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                // 4-column format: read_id, mate, trim_5p, trim_3p
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t\(mate)"] = (t5, t3)
            } else if cols.count >= 3,
                      let t5 = Int(cols[1]),
                      let t3 = Int(cols[2]) {
                // Legacy 3-column format: read_id, trim_5p, trim_3p
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t0"] = (t5, t3)
            }
        }

        guard !trimMap.isEmpty else {
            try fm.moveItem(at: extractedURL, to: outputFASTQ)
            return
        }

        // Step 3: Apply trims using native Swift FASTQ reader/writer with streaming writes
        let reader = FASTQReader(validateSequence: false)
        let plainURL = tempDir.appendingPathComponent("trimmed.fastq")
        fm.createFile(atPath: plainURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: plainURL)

        do {
            for try await record in reader.records(from: extractedURL) {
                let readID = record.identifier
                let seq = record.sequence
                let qual = record.quality.toAscii()
                let header = record.description != nil
                    ? "\(record.identifier) \(record.description!)"
                    : record.identifier

                // Detect mate for PE-safe trim lookup (also strips /1 /2 from readID)
                let (baseReadID, mate) = detectMateFromHeader(identifier: readID, description: record.description)
                // Try mate-specific key first, then fallback to mate=0 (single-end/legacy)
                let trim = trimMap["\(baseReadID)\t\(mate)"] ?? trimMap["\(baseReadID)\t0"]

                let line: String
                if let trim {
                    let startIndex = min(trim.trim5p, seq.count)
                    let endIndex = max(startIndex, seq.count - trim.trim3p)
                    let trimmedSeq = String(seq[seq.index(seq.startIndex, offsetBy: startIndex)..<seq.index(seq.startIndex, offsetBy: endIndex)])
                    let trimmedQual = String(qual[qual.index(qual.startIndex, offsetBy: startIndex)..<qual.index(qual.startIndex, offsetBy: endIndex)])
                    line = "@\(header)\n\(trimmedSeq)\n+\n\(trimmedQual)\n"
                } else {
                    line = "@\(header)\n\(seq)\n+\n\(qual)\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

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

    /// Extracts and trims reads from a FASTA file.
    /// Analogous to `extractAndTrimReads` but produces FASTA output (no quality scores).
    private func extractAndTrimFASTAReads(
        fromRootFASTA rootFASTA: URL,
        readIDsFile: URL,
        trimPositionsFile: URL,
        outputFASTA: URL
    ) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-fasta-trim-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Step 1: Extract reads by ID using seqkit grep (works on FASTA too)
        let extractedURL = tempDir.appendingPathComponent("extracted.fasta")
        try await extractReads(fromRootFASTQ: rootFASTA, readIDsFile: readIDsFile, outputFASTQ: extractedURL)

        // Step 2: Parse trim positions
        guard let trimContent = try? String(contentsOf: trimPositionsFile, encoding: .utf8) else {
            try fm.moveItem(at: extractedURL, to: outputFASTA)
            return
        }

        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in trimContent.split(separator: "\n") {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t\(mate)"] = (t5, t3)
            } else if cols.count >= 3,
                      let t5 = Int(cols[1]),
                      let t3 = Int(cols[2]) {
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t0"] = (t5, t3)
            }
        }

        guard !trimMap.isEmpty else {
            try fm.moveItem(at: extractedURL, to: outputFASTA)
            return
        }

        // Step 3: Apply trims using FASTAReader streaming
        let reader = try FASTAReader(url: extractedURL)
        let plainURL = tempDir.appendingPathComponent("trimmed.fasta")
        fm.createFile(atPath: plainURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: plainURL)

        do {
            for try await record in reader.sequences() {
                let readID = record.name
                let seq = record.asString()
                let header = record.description != nil
                    ? "\(record.name) \(record.description!)"
                    : record.name

                let trim = trimMap["\(readID)\t0"]

                let outputSeq: String
                if let trim {
                    let startIndex = min(trim.trim5p, seq.count)
                    let endIndex = max(startIndex, seq.count - trim.trim3p)
                    outputSeq = String(seq[seq.index(seq.startIndex, offsetBy: startIndex)..<seq.index(seq.startIndex, offsetBy: endIndex)])
                } else {
                    outputSeq = seq
                }

                // Write FASTA record with 60-char line wrapping
                var line = ">\(header)\n"
                for i in stride(from: 0, to: outputSeq.count, by: 60) {
                    let start = outputSeq.index(outputSeq.startIndex, offsetBy: i)
                    let end = outputSeq.index(start, offsetBy: min(60, outputSeq.count - i))
                    line += String(outputSeq[start..<end]) + "\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

        try fm.moveItem(at: plainURL, to: outputFASTA)
    }

    private func materializeOrientedFASTAReads(
        fromRootFASTA rootFASTA: URL,
        forwardReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTA: URL
    ) async throws {
        let selectedReadIDs = forwardReadIDs.union(rcReadIDs)
        guard !selectedReadIDs.isEmpty else {
            throw FASTQDerivativeError.emptyResult
        }

        let reader = try FASTAReader(url: rootFASTA)
        let fm = FileManager.default
        fm.createFile(atPath: outputFASTA.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: outputFASTA)

        do {
            defer { try? writeHandle.close() }
            for try await record in reader.sequences() {
                let normalizedID = normalizedIdentifier(record.name)
                let baseReadID = detectMateFromHeader(identifier: normalizedID, description: nil).readID
                guard selectedReadIDs.contains(record.name)
                        || selectedReadIDs.contains(normalizedID)
                        || selectedReadIDs.contains(baseReadID) else { continue }

                let outputSequence: String
                if rcReadIDs.contains(record.name)
                    || rcReadIDs.contains(normalizedID)
                    || rcReadIDs.contains(baseReadID) {
                    outputSequence = PlatformAdapters.reverseComplement(record.asString())
                } else {
                    outputSequence = record.asString()
                }

                var line = ">\(record.name)"
                if let description = record.description {
                    line += " \(description)"
                }
                line += "\n"
                for i in stride(from: 0, to: outputSequence.count, by: 60) {
                    let start = outputSequence.index(outputSequence.startIndex, offsetBy: i)
                    let end = outputSequence.index(start, offsetBy: min(60, outputSequence.count - i))
                    line += String(outputSequence[start..<end]) + "\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
        } catch {
            try? writeHandle.close()
            throw error
        }
    }

    /// Extracts and trims FASTA reads using absolute position-based trims.
    /// Analogous to `extractTrimmedReads` but for FASTA format (no quality scores).
    private func extractTrimmedFASTAReads(
        fromRootFASTA rootFASTA: URL,
        positions: [String: (start: Int, end: Int)],
        outputFASTA: URL
    ) async throws {
        if positions.isEmpty {
            throw FASTQDerivativeError.emptyResult
        }

        let reader = try FASTAReader(url: rootFASTA)
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-fasta-postrim-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let plainURL = tempDir.appendingPathComponent("trimmed.fasta")
        fm.createFile(atPath: plainURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: plainURL)

        do {
            for try await record in reader.sequences() {
                let key = record.name
                guard let pos = positions[key] else { continue }
                let seq = record.asString()
                let safeStart = min(pos.start, seq.count)
                let safeEnd = min(max(safeStart, pos.end), seq.count)
                guard safeEnd > safeStart else { continue }

                let trimmedSeq = String(seq[seq.index(seq.startIndex, offsetBy: safeStart)..<seq.index(seq.startIndex, offsetBy: safeEnd)])
                let header = record.description.map { "\(record.name) \($0)" } ?? record.name

                var line = ">\(header)\n"
                for i in stride(from: 0, to: trimmedSeq.count, by: 60) {
                    let start = trimmedSeq.index(trimmedSeq.startIndex, offsetBy: i)
                    let end = trimmedSeq.index(start, offsetBy: min(60, trimmedSeq.count - i))
                    line += String(trimmedSeq[start..<end]) + "\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

        try fm.moveItem(at: plainURL, to: outputFASTA)
    }

    /// Detects mate number from FASTQ record header for PE-safe trim lookup.
    /// Returns (baseReadID, mate) where mate is 0 (single), 1 (R1), or 2 (R2).
    /// Strips `/1` or `/2` suffix from identifier when present so the returned
    /// readID matches the pipeline's trim map keys.
    private func detectMateFromHeader(identifier: String, description: String?) -> (readID: String, mate: Int) {
        // Check /1 or /2 suffix on identifier (legacy FASTQ format)
        if identifier.hasSuffix("/1") {
            return (String(identifier.dropLast(2)), 1)
        }
        if identifier.hasSuffix("/2") {
            return (String(identifier.dropLast(2)), 2)
        }
        // Check Illumina description format: "1:N:0:..." or "2:N:0:..."
        if let desc = description {
            if desc.hasPrefix("1:") { return (identifier, 1) }
            if desc.hasPrefix("2:") { return (identifier, 2) }
        }
        return (identifier, 0)
    }

    // MARK: - Materialized Recipe Pipeline

    /// Runs recipe steps directly on materialized FASTQ files, chaining tool outputs.
    ///
    /// Unlike the virtual derivative chain, this pipeline:
    /// - Writes real FASTQ files at every step
    /// - Correctly handles paired-end merge (outputs can be longer than inputs)
    /// - Passes properly de-interleaved R1/R2 to fastp for adapter/quality trim
    /// - Returns the URL of the final processed FASTQ in `tempDir`
    ///
    /// - Parameters:
    ///   - fastqURL: Uncompressed FASTQ to process (usually decompressed bundle content).
    ///   - steps: Ordered recipe steps to apply.
    ///   - isInterleaved: Whether the input is interleaved paired-end.
    ///   - tempDir: Scratch directory for intermediate files.
    ///   - measureReadCounts: When true, gathers per-step input/output read counts via seqkit stats.
    ///     Disable for ingestion hot paths to avoid extra full-file scans per step.
    ///   - progress: Optional callback (fraction 0–1, message).
    func runMaterializedRecipe(
        fastqURL: URL,
        steps: [FASTQDerivativeOperation],
        isInterleaved: Bool,
        tempDir: URL,
        measureReadCounts: Bool = true,
        progress: ((Double, String) -> Void)?
    ) async throws -> (url: URL, stepResults: [RecipeStepResult]) {
        var currentURL = fastqURL
        var currentIsInterleaved = isInterleaved
        let fm = FileManager.default
        var stepResults: [RecipeStepResult] = []

        for (index, step) in steps.enumerated() {
            let fraction = Double(index) / Double(steps.count)
            let outputURL = tempDir.appendingPathComponent("step_\(index + 1)_\(step.kind.rawValue).fastq")
            let inputCount = measureReadCounts
                ? await countFASTQReads(at: currentURL, isInterleaved: currentIsInterleaved)
                : nil
            let stepStart = Date()
            var commandLine: String?

            switch step.kind {
            case .qualityTrim:
                progress?(fraction, "Quality trimming (\(index + 1)/\(steps.count))…")
                commandLine = "fastp (quality-trim) threshold=\(step.qualityThreshold ?? 20) window=\(step.windowSize ?? 4) mode=\((step.qualityTrimMode ?? .cutRight).rawValue) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpQualityTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    threshold: step.qualityThreshold ?? 20,
                    windowSize: step.windowSize ?? 4,
                    mode: step.qualityTrimMode ?? .cutRight,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .adapterTrim:
                progress?(fraction, "Adapter trimming (\(index + 1)/\(steps.count))…")
                commandLine = "fastp (adapter-trim) mode=\((step.adapterMode ?? .autoDetect).rawValue) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpAdapterTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    mode: step.adapterMode ?? .autoDetect,
                    sequence: step.adapterSequence,
                    sequenceR2: step.adapterSequenceR2,
                    fastaFilename: step.adapterFastaFilename,
                    sourceBundleURL: tempDir,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .fixedTrim:
                progress?(fraction, "Fixed trimming (\(index + 1)/\(steps.count))…")
                commandLine = "fastp (fixed-trim) trim5=\(step.trimFrom5Prime ?? 0) trim3=\(step.trimFrom3Prime ?? 0) interleaved=\(currentIsInterleaved)"
                _ = try await runFastpFixedTrim(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    from5Prime: step.trimFrom5Prime ?? 0,
                    from3Prime: step.trimFrom3Prime ?? 0,
                    isInterleaved: currentIsInterleaved
                )
                currentURL = outputURL

            case .deduplicate:
                progress?(fraction, "Deduplicating (\(index + 1)/\(steps.count))…")
                let subs = step.deduplicateSubstitutions ?? 0
                let optical = step.deduplicateOptical ?? false
                let opticalDist = step.deduplicateOpticalDistance ?? 2500
                commandLine = "clumpify.sh dedupe=t subs=\(subs)\(optical ? " optical=t dupedist=\(opticalDist)" : "") interleaved=\(currentIsInterleaved)"
                let env = await bbToolsEnvironment()
                let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                let heapGB = max(1, min(31, physicalMemoryGB * 80 / 100))
                var args = [
                    "in=\(currentURL.path)",
                    "out=\(outputURL.path)",
                    "-Xmx\(heapGB)g",
                    "dedupe=t",
                    "subs=\(subs)",
                    "ow=t",
                ]
                if currentIsInterleaved { args.append("interleaved=t") }
                if optical {
                    args.append("optical=t")
                    args.append("dupedist=\(opticalDist)")
                }
                let dedupeResult = try await runner.run(.clumpify, arguments: args, environment: env, timeout: 3600)
                guard dedupeResult.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("clumpify deduplication failed: \(dedupeResult.stderr)")
                }
                currentURL = outputURL

            case .pairedEndMerge:
                progress?(fraction, "Merging paired-end reads (\(index + 1)/\(steps.count))…")
                let strictness = step.mergeStrictness ?? .normal
                let minOverlap = step.mergeMinOverlap ?? 12
                commandLine = "bbmerge.sh strictness=\(strictness.rawValue) minoverlap=\(minOverlap); reformat.sh (unmerged interleave)"
                let mergeDir = tempDir.appendingPathComponent("step_\(index + 1)_merge")
                try fm.createDirectory(at: mergeDir, withIntermediateDirectories: true)

                // bbmerge writes: merged.fastq, unmerged_R1.fastq, unmerged_R2.fastq
                let (_, _) = try await runBBMerge(
                    sourceFASTQ: currentURL,
                    outputBundleURL: mergeDir,
                    strictness: strictness,
                    minOverlap: minOverlap
                )

                // Build output: merged reads + re-interleaved unmerged pairs
                let mergedFile = mergeDir.appendingPathComponent("merged.fastq")
                let unmergedR1 = mergeDir.appendingPathComponent("unmerged_R1.fastq")
                let unmergedR2 = mergeDir.appendingPathComponent("unmerged_R2.fastq")

                // Re-interleave unmerged pairs using reformat.sh
                let unmergedInterleaved = mergeDir.appendingPathComponent("unmerged_interleaved.fastq")
                let hasMerged = fm.fileExists(atPath: mergedFile.path)
                let hasUnmerged = fm.fileExists(atPath: unmergedR1.path) && fm.fileExists(atPath: unmergedR2.path)

                if hasUnmerged {
                    try await reinterleaveFastpOutput(r1: unmergedR1, r2: unmergedR2, output: unmergedInterleaved)
                }

                // Concatenate parts: merged (singles) + unmerged (interleaved pairs)
                var parts: [URL] = []
                if hasMerged { parts.append(mergedFile) }
                if hasUnmerged { parts.append(unmergedInterleaved) }
                guard !parts.isEmpty else {
                    throw FASTQDerivativeError.emptyResult
                }
                try concatenateFASTQParts(parts, to: outputURL)

                currentURL = outputURL
                // Post-merge: data is mixed (merged singles + interleaved unmerged pairs).
                // Downstream pair-aware tools (bbduk length filter) handle this mixed format
                // correctly with interleaved=t.
                currentIsInterleaved = true

            case .lengthFilter:
                progress?(fraction, "Length filtering (\(index + 1)/\(steps.count))…")
                if currentIsInterleaved {
                    commandLine = "bbduk.sh interleaved=t minlen=\(step.minLength.map(String.init) ?? "none") maxlen=\(step.maxLength.map(String.init) ?? "none")"
                    try await runPairedAwareFilter(
                        sourceFASTQ: currentURL,
                        outputFASTQ: outputURL,
                        minLength: step.minLength,
                        maxLength: step.maxLength
                    )
                } else {
                    commandLine = "seqkit seq -m \(step.minLength.map(String.init) ?? "none") -M \(step.maxLength.map(String.init) ?? "none")"
                    var seqkitArgs = ["seq", "-j", String(toolThreadCount), currentURL.path, "-o", outputURL.path]
                    if let min = step.minLength { seqkitArgs += ["-m", String(min)] }
                    if let max = step.maxLength { seqkitArgs += ["-M", String(max)] }
                    let seqkitResult = try await runner.run(.seqkit, arguments: seqkitArgs)
                    guard seqkitResult.isSuccess else {
                        throw FASTQDerivativeError.invalidOperation("seqkit length filter failed: \(seqkitResult.stderr)")
                    }
                }
                currentURL = outputURL

            case .humanReadScrub:
                progress?(fraction, "Removing human reads (\(index + 1)/\(steps.count))…")
                let dbID = step.humanScrubDatabaseID ?? "human-scrubber"
                let removeReads = step.humanScrubRemoveReads ?? false
                commandLine = "scrub.sh -d \(dbID) -s\(removeReads ? " -x" : "")"
                let maskedSpots = try await runHumanReadScrub(
                    sourceFASTQ: currentURL,
                    outputFASTQ: outputURL,
                    databaseID: dbID,
                    isInterleaved: currentIsInterleaved,
                    removeReads: removeReads
                )
                currentURL = outputURL

                // For mask mode: reads are still present but as N-strings.
                // Report outputReadCount = input - masked so the Inspector shows
                // how many non-human pairs remain. The length filter later removes the N reads.
                let outputCount: Int?
                if let inputCount, let maskedSpots {
                    outputCount = inputCount - maskedSpots
                } else if measureReadCounts {
                    outputCount = await countFASTQReads(at: currentURL, isInterleaved: currentIsInterleaved)
                } else {
                    outputCount = nil
                }
                let duration = Date().timeIntervalSince(stepStart)
                stepResults.append(RecipeStepResult(
                    stepName: step.displaySummary,
                    tool: step.toolUsed ?? "sra-human-scrubber",
                    toolVersion: step.toolVersion,
                    commandLine: commandLine,
                    inputReadCount: inputCount,
                    outputReadCount: outputCount,
                    durationSeconds: duration
                ))
                continue  // skip the generic result append at the bottom of the loop

            default:
                derivativeLogger.warning("runMaterializedRecipe: Skipping unsupported step '\(step.kind.rawValue)'")
            }

            // Record per-step stats
            let outputCount = measureReadCounts
                ? await countFASTQReads(at: currentURL, isInterleaved: currentIsInterleaved)
                : nil
            let duration = Date().timeIntervalSince(stepStart)
            stepResults.append(RecipeStepResult(
                stepName: step.displaySummary,
                tool: step.toolUsed ?? step.kind.rawValue,
                toolVersion: step.toolVersion,
                commandLine: commandLine,
                inputReadCount: inputCount,
                outputReadCount: outputCount,
                durationSeconds: duration
            ))
        }

        return (currentURL, stepResults)
    }

    /// Concatenates FASTQ parts into one output file without loading full files into memory.
    private func concatenateFASTQParts(_ inputs: [URL], to output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw FASTQDerivativeError.invalidOperation("Failed to create merged FASTQ output at \(output.path)")
        }

        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }

        for input in inputs {
            let inputHandle = try FileHandle(forReadingFrom: input)
            defer { try? inputHandle.close() }
            while true {
                let chunk = try inputHandle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try outputHandle.write(contentsOf: chunk)
            }
        }
    }

    /// Counts reads in a FASTQ file using seqkit stats.
    /// Returns nil if the file doesn't exist or seqkit fails.
    /// For interleaved files, returns the read pair count (total reads / 2).
    private func countFASTQReads(at url: URL, isInterleaved: Bool) async -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try? await runner.run(.seqkit, arguments: ["stats", "-T", url.path])
        guard let result, result.isSuccess else { return nil }
        // seqkit stats -T output: file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: "\t")
        guard fields.count >= 4, let total = Int(fields[3]) else { return nil }
        return isInterleaved ? total / 2 : total
    }

    // MARK: - Human Read Scrub

    /// Runs NCBI sra-human-scrubber on a (possibly interleaved) FASTQ file.
    ///
    /// scrub.sh expects the database via `-d`, uses `-s` for interleaved paired-end
    /// (mask both reads in a pair if either aligns to human), and `-x` to remove
    /// (rather than mask with N) when removeReads is true.
    /// Returns the number of spots (read pairs in interleaved mode) that were masked/removed.
    private func runHumanReadScrub(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        databaseID: String,
        isInterleaved: Bool,
        removeReads: Bool
    ) async throws -> Int? {
        guard let dbPath = await DatabaseRegistry.shared.effectiveDatabasePath(for: databaseID) else {
            throw FASTQDerivativeError.invalidOperation(
                "Human read scrub database '\(databaseID)' not found. " +
                "Place the database file in ~/Library/Application Support/Lungfish/databases/\(databaseID)/")
        }

        let scrubSh = try await runner.findTool(.scrubSh)
        let threads = ProcessInfo.processInfo.activeProcessorCount
        let scriptsDir = scrubSh.deletingLastPathComponent()

        // scrub.sh pipes the input file through fastq_to_fasta.py which reads plain text via
        // stdin. Decompress gzipped inputs to a temp file first so the script can read them.
        let inputFASTQ: URL
        var decompressedTmp: URL? = nil
        if sourceFASTQ.pathExtension.lowercased() == "gz" {
            let tmp = outputFASTQ.deletingLastPathComponent()
                .appendingPathComponent("scrub_input_\(UUID().uuidString).fastq")
            let pigzResult = try await runner.runWithFileOutput(
                .pigz,
                arguments: ["-d", "-c", sourceFASTQ.path],
                outputFile: tmp
            )
            guard pigzResult.isSuccess else {
                throw FASTQDerivativeError.invalidOperation("Failed to decompress input for scrub.sh: \(pigzResult.stderr)")
            }
            inputFASTQ = tmp
            decompressedTmp = tmp
        } else {
            inputFASTQ = sourceFASTQ
        }
        defer { if let tmp = decompressedTmp { try? FileManager.default.removeItem(at: tmp) } }

        // scrub.sh usage: scrub.sh -i <input> -o <output> -d <db> [-s] [-x] [-p threads]
        // Run via bash to ensure the shebang is honoured and PATH is set correctly.
        var scriptArgs: [String] = [scrubSh.path,
            "-i", inputFASTQ.path,
            "-o", outputFASTQ.path,
            "-d", dbPath.path,
            "-p", "\(threads)",
        ]
        if isInterleaved { scriptArgs.append("-s") }   // paired-end mode: mask both if either is human
        if removeReads   { scriptArgs.append("-x") }   // remove instead of mask with N

        let scrubResult = try await runner.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: scriptArgs,
            workingDirectory: scriptsDir,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 7200,
            toolName: "scrub.sh"
        )
        guard scrubResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("sra-human-scrubber failed: \(scrubResult.stderr)")
        }

        // Parse "N  spot(s) masked or removed." from cut_spots_fastq.py stderr
        // (scrubResult.stderr contains combined stderr from both aligns_to and the Python scripts)
        let maskedSpots: Int? = scrubResult.stderr
            .components(separatedBy: .newlines)
            .compactMap { line -> Int? in
                // Pattern: "8381523  spot(s) masked or removed."
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("spot(s) masked or removed"),
                      let first = trimmed.split(separator: " ").first,
                      let count = Int(first) else { return nil }
                return count
            }
            .first
        return maskedSpots
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
            "-w", String(toolThreadCount),
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
            "-w", String(toolThreadCount),
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
            "-w", String(toolThreadCount),
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

    /// Runs cutadapt for PCR primer trimming.
    private func runCutadaptPrimerTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        configuration: FASTQPrimerTrimConfiguration,
        sourceBundleURL: URL,
        isInterleaved: Bool = false
    ) async throws -> BBToolResult {
        try validatePrimerTrimConfiguration(configuration)
        let primerSpec = try await resolvePrimerTrimSpecification(
            configuration: configuration,
            sourceBundleURL: sourceBundleURL
        )

        var args: [String] = [
            "-e", String(configuration.errorRate),
            "--overlap", String(configuration.minimumOverlap),
            "--action", "trim",
            "--cores", "1",
        ]
        if !configuration.allowIndels {
            args.append("--no-indels")
        }
        if !configuration.keepUntrimmed {
            args.append("--discard-untrimmed")
        }

        switch configuration.readMode {
        case .single:
            if configuration.searchReverseComplement {
                args.append("--revcomp")
            }
            switch configuration.mode {
            case .fivePrime:
                guard let forward = primerSpec.forward else {
                    throw FASTQDerivativeError.invalidOperation("Primer trimming requires a 5' primer sequence")
                }
                args += ["-g", cutadaptFivePrimeAdapter(forward, anchored: configuration.anchored5Prime)]
            case .threePrime:
                guard let forward = primerSpec.forward else {
                    throw FASTQDerivativeError.invalidOperation("Primer trimming requires a 3' primer sequence")
                }
                args += ["-a", cutadaptThreePrimeAdapter(forward, anchored: configuration.anchored3Prime)]
            case .linked:
                guard let forward = primerSpec.forward, let reverse = primerSpec.reverse else {
                    throw FASTQDerivativeError.invalidOperation("Linked primer trimming requires both 5' and 3' primers")
                }
                args += ["-g", cutadaptLinkedAdapter(
                    forward: forward,
                    reverse: reverse,
                    anchored5Prime: configuration.anchored5Prime,
                    anchored3Prime: configuration.anchored3Prime
                )]
            case .paired:
                throw FASTQDerivativeError.invalidOperation("Paired primer mode requires paired/interleaved reads")
            }
            args += ["-o", outputFASTQ.path, sourceFASTQ.path]

        case .paired:
            guard isInterleaved else {
                throw FASTQDerivativeError.invalidOperation("Paired primer trimming currently requires interleaved input")
            }
            guard configuration.mode == .paired else {
                throw FASTQDerivativeError.invalidOperation("Paired read mode supports only paired R1/R2 primer trimming")
            }
            guard let forward = primerSpec.forward, let reverse = primerSpec.reverse else {
                throw FASTQDerivativeError.invalidOperation("Paired primer trimming requires both R1 and R2 primer sequences")
            }
            args.append("--interleaved")
            args += ["--pair-filter", configuration.pairFilter.rawValue]
            args += ["-g", cutadaptFivePrimeAdapter(forward, anchored: configuration.anchored5Prime)]
            args += ["-G", cutadaptFivePrimeAdapter(reverse, anchored: configuration.anchored5Prime)]
            args += ["-o", outputFASTQ.path, sourceFASTQ.path]
        }

        let result = try await runner.run(.cutadapt, arguments: args, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("cutadapt primer trimming failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "cutadapt \(args.joined(separator: " "))")
    }

    private func resolvePrimerTrimSpecification(
        configuration: FASTQPrimerTrimConfiguration,
        sourceBundleURL: URL
    ) async throws -> (forward: String?, reverse: String?) {
        switch configuration.source {
        case .literal:
            let forward = configuration.forwardSequence
            let reverse = configuration.reverseSequence
            return (forward, reverse)
        case .reference:
            guard let refPath = configuration.referenceFasta, !refPath.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("Primer trimming requires a reference FASTA path")
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
            let reader = try FASTAReader(url: refURL)
            let sequences = try await reader.readAll()
            guard let first = sequences.first?.asString(), !first.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("Primer reference FASTA did not contain any primer sequences")
            }
            let second = sequences.count > 1 ? sequences[1].asString() : nil
            return (first.uppercased(), second?.uppercased())
        }
    }

    private func validatePrimerTrimConfiguration(_ configuration: FASTQPrimerTrimConfiguration) throws {
        guard configuration.minimumOverlap > 0 else {
            throw FASTQDerivativeError.invalidOperation("Primer minimum overlap must be > 0.")
        }
        guard configuration.errorRate >= 0.0, configuration.errorRate <= 1.0 else {
            throw FASTQDerivativeError.invalidOperation("Primer error rate must be between 0.0 and 1.0.")
        }
    }

    private func cutadaptFivePrimeAdapter(_ sequence: String, anchored: Bool) -> String {
        anchored ? "^\(sequence)" : sequence
    }

    private func cutadaptThreePrimeAdapter(_ sequence: String, anchored: Bool) -> String {
        anchored ? "\(sequence)$" : sequence
    }

    private func cutadaptLinkedAdapter(
        forward: String,
        reverse: String,
        anchored5Prime: Bool,
        anchored3Prime: Bool
    ) -> String {
        let left = cutadaptFivePrimeAdapter(forward, anchored: anchored5Prime)
        let right = cutadaptThreePrimeAdapter(reverse, anchored: anchored3Prime)
        return "\(left)...\(right)"
    }

    /// Runs bbduk.sh for k-mer-based primer trimming.
    ///
    /// BBDuk uses exact k-mer matching (with Hamming distance tolerance) to find
    /// primer sequences and trim everything to the left (ktrim=l) or right (ktrim=r).
    /// This matches the Snakemake workflow's approach:
    ///   bbduk.sh ref=primers k=15 mink=11 hdist=1 ktrim=l rcomp=t  (5' trim)
    ///   bbduk.sh ref=primers k=15 mink=11 hdist=1 ktrim=r rcomp=t  (3' trim)
    private func runBBDukPrimerTrim(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        configuration: FASTQPrimerTrimConfiguration,
        sourceBundleURL: URL,
        isInterleaved: Bool = false
    ) async throws -> BBToolResult {
        // Resolve primer reference
        let refPath: String
        switch configuration.source {
        case .reference:
            guard let rp = configuration.referenceFasta, !rp.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("BBDuk primer trim requires a reference FASTA path")
            }
            if rp.hasPrefix("/") {
                refPath = rp
            } else {
                refPath = sourceBundleURL.appendingPathComponent(rp).path
            }
            guard FileManager.default.fileExists(atPath: refPath) else {
                throw FASTQDerivativeError.invalidOperation("Primer reference FASTA not found: \(refPath)")
            }
        case .literal:
            // Write literal sequences to a temp FASTA for bbduk
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bbduk-primer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let tmpFasta = tmpDir.appendingPathComponent("primers.fasta")
            var fastaContent = ""
            if let fwd = configuration.forwardSequence {
                fastaContent += ">forward_primer\n\(fwd)\n"
            }
            if let rev = configuration.reverseSequence {
                fastaContent += ">reverse_primer\n\(rev)\n"
            }
            guard !fastaContent.isEmpty else {
                throw FASTQDerivativeError.invalidOperation("BBDuk primer trim requires at least one primer sequence")
            }
            try fastaContent.write(to: tmpFasta, atomically: true, encoding: .utf8)
            refPath = tmpFasta.path
        }

        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "ref=\(refPath)",
            "k=\(configuration.kmerSize)",
            "mink=\(configuration.minKmer)",
            "hdist=\(configuration.hammingDistance)",
            "ktrim=\(configuration.ktrimDirection == .left ? "l" : "r")",
            "rcomp=\(configuration.searchReverseComplement ? "t" : "f")",
        ]

        if isInterleaved {
            args.append("interleaved=t")
        }

        let env = await bbToolsEnvironment()
        let result = try await runner.run(.bbduk, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk primer trim failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "bbduk.sh \(args.joined(separator: " "))")
    }

    /// Runs cutadapt for adapter presence filtering (no trimming).
    ///
    /// Uses `--action=none` to pass reads through without modification and
    /// `--discard-untrimmed` (or `--discard-trimmed`) to filter by adapter presence.
    /// This matches the Snakemake workflow's ONT barcode filtering:
    ///   cutadapt -g "BARCODE;min_overlap=16" --action=none --discard-untrimmed -e 0.15
    private func runCutadaptAdapterPresenceFilter(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        sequence: String?,
        fastaPath: String?,
        searchEnd: FASTQAdapterSearchEnd,
        minOverlap: Int,
        errorRate: Double,
        keepMatched: Bool,
        searchReverseComplement: Bool = false,
        sourceBundleURL: URL,
        isInterleaved: Bool = false
    ) async throws -> BBToolResult {
        var args: [String] = [
            "-e", String(errorRate),
            "--overlap", String(minOverlap),
            "--action", "none",
            "--cores", "1",
        ]

        if isInterleaved {
            args.append("--interleaved")
        }

        // Keep matched reads = discard untrimmed; Discard matched = discard trimmed
        if keepMatched {
            args.append("--discard-untrimmed")
        } else {
            args.append("--discard-trimmed")
        }

        // Build adapter specification.
        // When searching reverse complement: if the original adapter is at the 5' end,
        // reads in the opposite orientation will carry its revcomp at the 3' end, and vice versa.
        let adapterFlag = searchEnd == .fivePrime ? "-g" : "-a"
        let oppositeFlag = searchEnd == .fivePrime ? "-a" : "-g"

        if let seq = sequence, !seq.isEmpty {
            args += [adapterFlag, seq]
            if searchReverseComplement {
                args += [oppositeFlag, PlatformAdapters.reverseComplement(seq)]
            }
        } else if let fp = fastaPath, !fp.isEmpty {
            let resolvedPath: String
            if fp.hasPrefix("/") {
                resolvedPath = fp
            } else {
                resolvedPath = sourceBundleURL.appendingPathComponent(fp).path
            }
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                throw FASTQDerivativeError.invalidOperation("Adapter FASTA not found: \(resolvedPath)")
            }
            args += [adapterFlag, "file:\(resolvedPath)"]
        } else {
            throw FASTQDerivativeError.invalidOperation("Adapter presence filter requires a sequence or FASTA file")
        }

        args += ["-o", outputFASTQ.path, sourceFASTQ.path]

        let result = try await runner.run(.cutadapt, arguments: args, timeout: 1800)
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("cutadapt adapter presence filter failed: \(result.stderr)")
        }
        return BBToolResult(toolCommand: "cutadapt \(args.joined(separator: " "))")
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

    private struct SelectedReadIDLookup {
        let rawIDs: Set<String>
        let normalizedIDs: Set<String>
        let baseReadIDs: Set<String>

        func contains(_ identifier: String) -> Bool {
            let normalized = identifier.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? identifier
            let positionalBase = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? normalized
            let mateBase: String
            if positionalBase.hasSuffix("/1") || positionalBase.hasSuffix("/2") {
                mateBase = String(positionalBase.dropLast(2))
            } else {
                mateBase = positionalBase
            }

            return rawIDs.contains(identifier)
                || rawIDs.contains(normalized)
                || rawIDs.contains(positionalBase)
                || normalizedIDs.contains(identifier)
                || normalizedIDs.contains(normalized)
                || normalizedIDs.contains(positionalBase)
                || baseReadIDs.contains(identifier)
                || baseReadIDs.contains(positionalBase)
                || baseReadIDs.contains(mateBase)
        }
    }

    private func loadSelectedReadIDLookup(from url: URL) throws -> SelectedReadIDLookup {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rawIDs: Set<String> = []
        var normalizedIDs: Set<String> = []
        var baseReadIDs: Set<String> = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let rawID = String(line)
            let normalizedID = normalizedIdentifier(rawID)
            let baseReadID = detectMateFromHeader(identifier: normalizedID, description: nil).readID
            rawIDs.insert(rawID)
            normalizedIDs.insert(normalizedID)
            baseReadIDs.insert(baseReadID)
        }

        return SelectedReadIDLookup(
            rawIDs: rawIDs,
            normalizedIDs: normalizedIDs,
            baseReadIDs: baseReadIDs
        )
    }

    private func propagateVirtualSubsetSidecars(
        from sourceBundleURL: URL,
        selectedReadIDsFile: URL,
        to outputBundleURL: URL
    ) throws {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)

        if let sourceTrimURL = bundleTrimPositionsURL(sourceBundleURL) {
            let outputTrimURL = outputBundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
            if isAbsoluteTrimPositionsFile(sourceTrimURL) {
                let records = try FASTQTrimPositionFile.loadRecords(from: sourceTrimURL)
                let filtered = records.filter { selectedReadIDs.contains($0.readID) }
                if !filtered.isEmpty {
                    try FASTQTrimPositionFile.write(filtered, to: outputTrimURL)
                }
            } else if let filteredTrimContent = try filteredRelativeTrimPositionsContent(
                from: sourceTrimURL,
                selectedReadIDsFile: selectedReadIDsFile
            ) {
                try filteredTrimContent.write(to: outputTrimURL, atomically: true, encoding: .utf8)
            }
        }

        if let sourceOrientURL = bundleOrientMapURL(sourceBundleURL) {
            let content = try String(contentsOf: sourceOrientURL, encoding: .utf8)
            var filteredLines: [String] = []
            filteredLines.reserveCapacity(1024)

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let firstField = fields.first else { continue }
                if selectedReadIDs.contains(String(firstField)) {
                    filteredLines.append(String(line))
                }
            }

            if !filteredLines.isEmpty {
                let outputURL = outputBundleURL.appendingPathComponent("orient-map.tsv")
                try filteredLines.joined(separator: "\n").appending("\n").write(
                    to: outputURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    private func filteredTrimPositions(
        from trimPositionsURL: URL,
        selectedReadIDsFile: URL
    ) throws -> [String: (start: Int, end: Int)] {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)
        let positions = try FASTQTrimPositionFile.load(from: trimPositionsURL)
        return positions.reduce(into: [String: (start: Int, end: Int)]()) { result, entry in
            if selectedReadIDs.contains(entry.key) {
                result[entry.key] = entry.value
            }
        }
    }

    private func isAbsoluteTrimPositionsFile(_ url: URL) -> Bool {
        guard let header = try? String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first else {
            return false
        }
        return String(header) == FASTQTrimPositionFile.formatHeader
    }

    private func filteredRelativeTrimPositionsContent(
        from trimPositionsURL: URL,
        selectedReadIDsFile: URL
    ) throws -> String? {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)
        let content = try String(contentsOf: trimPositionsURL, encoding: .utf8)
        var headerLines: [String] = []
        var filteredLines: [String] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            if lineString.hasPrefix("#") || lineString.hasPrefix("read_id") {
                headerLines.append(lineString)
                continue
            }

            let fields = lineString.split(separator: "\t", omittingEmptySubsequences: false)
            guard let firstField = fields.first else { continue }
            let canonicalReadID = canonicalDemuxTrimReadID(String(firstField))
            if selectedReadIDs.contains(canonicalReadID) {
                if fields.count >= 2 {
                    filteredLines.append(([canonicalReadID] + fields.dropFirst().map(String.init)).joined(separator: "\t"))
                } else {
                    filteredLines.append(canonicalReadID)
                }
            }
        }

        guard !filteredLines.isEmpty else { return nil }
        let allLines = headerLines + filteredLines
        return allLines.joined(separator: "\n").appending("\n")
    }

    private func writePreviewFASTQ(
        from sourceFASTQ: URL,
        to outputURL: URL,
        readLimit: Int = 1_000
    ) async throws {
        let headResult = try? await runner.run(
            .seqkit,
            arguments: ["head", "-n", String(max(1, readLimit)), sourceFASTQ.path, "-o", outputURL.path],
            timeout: 60
        )
        if headResult?.isSuccess == true, FileManager.default.fileExists(atPath: outputURL.path) {
            return
        }

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        var count = 0
        for try await record in reader.records(from: sourceFASTQ) {
            try writer.write(record)
            count += 1
            if count >= readLimit {
                break
            }
        }
    }

    private func bundleTrimPositionsURL(_ bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func bundleOrientMapURL(_ bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent("orient-map.tsv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func canonicalDemuxTrimReadID(_ rawValue: String) -> String {
        let normalized = normalizedIdentifier(rawValue)
        return detectMateFromHeader(identifier: normalized, description: nil).readID
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
        // Build a lookup by base ID in a single pass.
        // Dictionary of arrays handles PE reads with same base ID (R1/R2).
        var trimmedByBaseID: [String: [(index: Int, record: FASTQRecord)]] = [:]
        var idx = 0
        let trimmedReader = FASTQReader(validateSequence: false)
        for try await record in trimmedReader.records(from: trimmedFASTQ) {
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
        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: sourceBundleURL)
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let base = "\(operation.shortLabel)-\(shortID)"

        var candidate = derivDir.appendingPathComponent("\(base).\(FASTQBundle.directoryExtension)", isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = derivDir.appendingPathComponent("\(base)-\(suffix).\(FASTQBundle.directoryExtension)", isDirectory: true)
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

    /// Computes a filesystem-relative path from one bundle to another.
    ///
    /// Used as a fallback when no `.lungfish` project root exists (e.g. in tests).
    private func relativePathFromBundle(_ fromBundle: URL, to targetBundle: URL) -> String {
        relativePath(from: fromBundle, to: targetBundle)
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

}
