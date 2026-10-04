// FASTQDerivativeServiceModels.swift - FASTQDerivativeRequest + CLI command modeling
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

public enum FASTQDerivativeRequest: Sendable, Equatable {
    // Subset operations (produce read ID lists)
    case subsampleProportion(Double)
    case subsampleCount(Int)
    case lengthFilter(min: Int?, max: Int?)
    case searchText(query: String, field: FASTQSearchField, regex: Bool)
    case searchMotif(pattern: String, regex: Bool)
    case deduplicate(preset: FASTQDeduplicatePreset, substitutions: Int, optical: Bool, opticalDistance: Int)

    // Trim operations (produce trim position records)
    case fastpTrim(
        threshold: Int,
        windowSize: Int,
        mode: FASTQQualityTrimMode,
        adapterMode: FASTQAdapterMode,
        adapterSequence: String?
    )
    case qualityTrim(threshold: Int, windowSize: Int, mode: FASTQQualityTrimMode, extraArguments: [String] = [])
    case adapterTrim(mode: FASTQAdapterMode, sequence: String?, sequenceR2: String?, fastaFilename: String?)
    case fixedTrim(from5Prime: Int, from3Prime: Int)

    // BBTools operations
    case contaminantFilter(mode: FASTQContaminantFilterMode, referenceFasta: String?, kmerSize: Int, hammingDistance: Int)
    /// bbduk entropy filter that discards low-complexity reads (homopolymers, tandem repeats).
    case lowComplexityFilter(entropy: Double, window: Int, kmer: Int)
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
    case reverseComplement
    case translate(frameOffset: Int)

    // Demultiplexing (produces per-barcode bundles)
    case demultiplex(
        kitID: String,
        customCSVPath: String?,
        location: String,
        symmetryMode: BarcodeSymmetryMode?,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        errorRate: Double,
        engine: DemultiplexEngine,
        trimBarcodes: Bool,
        sampleAssignments: [FASTQSampleBarcodeAssignment]?,
        kitOverride: BarcodeKitDefinition?
    )

    // Orient sequences against a reference
    case orient(
        referenceURL: URL,
        wordLength: Int,
        dbMask: String,
        saveUnoriented: Bool,
        extraArguments: [String] = []
    )

    // Human read removal. `removeReads` is retained for backward compatibility,
    // but the managed Deacon path always removes matched reads.
    case humanReadScrub(databaseID: String, removeReads: Bool)

    // Deacon rRNA operation for retaining non-rRNA, rRNA, or both classes.
    case ribosomalRNAFilter(retention: FASTQRiboDetectorRetention, ensure: FASTQRiboDetectorEnsure)

    /// Human-readable label for this operation, used in the Operations panel.
    var operationLabel: String {
        switch self {
        case .subsampleProportion(let p): return "Subsample \(Int(p * 100))%"
        case .subsampleCount(let n): return "Subsample \(n) reads"
        case .lengthFilter: return "Length Filter"
        case .searchText: return "Search"
        case .searchMotif: return "Motif Search"
        case .deduplicate: return "Deduplicate"
        case .fastpTrim: return "fastp Adapter + Quality Trim"
        case .qualityTrim: return "Quality Trim"
        case .adapterTrim: return "Adapter Trim"
        case .fixedTrim: return "Fixed Trim"
        case .contaminantFilter: return "Contaminant Filter"
        case .lowComplexityFilter: return "Low-Complexity Filter"
        case .pairedEndMerge: return "Paired-End Merge"
        case .pairedEndRepair: return "Paired-End Repair"
        case .primerRemoval: return "PCR Primer Trimming"
        case .sequencePresenceFilter: return "Sequence Presence Filter"
        case .errorCorrection: return "Error Correction"
        case .reverseComplement: return "Reverse Complement"
        case .translate: return "Translate"
        case .demultiplex: return "Demultiplex"
        case .orient: return "Orient Sequences"
        case .humanReadScrub: return "Human Read Scrub"
        case .ribosomalRNAFilter: return "Remove ribosomal RNA sequences"
        }
    }

    /// Whether this request produces an orient-map derivative.
    var isOrientOperation: Bool {
        if case .orient = self { return true }
        return false
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
        case .fastpTrim: return "fastpTrim"
        case .qualityTrim: return "qualityTrim"
        case .adapterTrim: return "adapterTrim"
        case .fixedTrim: return "fixedTrim"
        case .contaminantFilter: return "contaminantFilter"
        case .lowComplexityFilter: return "lowComplexityFilter"
        case .pairedEndMerge: return "pairedEndMerge"
        case .pairedEndRepair: return "pairedEndRepair"
        case .primerRemoval: return "primerRemoval"
        case .sequencePresenceFilter: return "sequencePresenceFilter"
        case .errorCorrection: return "errorCorrection"
        case .reverseComplement: return "reverseComplement"
        case .translate: return "translate"
        case .demultiplex: return "demultiplex"
        case .orient: return "orient"
        case .humanReadScrub: return "humanReadScrub"
        case .ribosomalRNAFilter: return "ribosomalRNAFilter"
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
        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            var params: [String: String] = [
                "threshold": "\(threshold)",
                "windowSize": "\(windowSize)",
                "mode": "\(mode)",
                "adapterMode": "\(adapterMode)",
                "combinedFastpPass": "true",
            ]
            if let adapterSequence { params["adapterSequence"] = adapterSequence }
            return params
        case .qualityTrim(let threshold, let windowSize, let mode, let extraArguments):
            var params = ["threshold": "\(threshold)", "windowSize": "\(windowSize)", "mode": "\(mode)"]
            if !extraArguments.isEmpty {
                params["extraArgs"] = AdvancedCommandLineOptions.join(extraArguments)
            }
            return params
        case .adapterTrim(let mode, let sequence, _, _):
            var params: [String: String] = ["mode": "\(mode)"]
            if let seq = sequence { params["sequence"] = seq }
            return params
        case .fixedTrim(let from5, let from3):
            return ["from5Prime": "\(from5)", "from3Prime": "\(from3)"]
        case .contaminantFilter(let mode, _, let kmerSize, let hammingDistance):
            return ["mode": "\(mode)", "kmerSize": "\(kmerSize)", "hammingDistance": "\(hammingDistance)"]
        case .lowComplexityFilter(let entropy, let window, let kmer):
            return [
                "entropy": String(format: "%.2f", entropy),
                "entropyWindow": "\(window)",
                "entropyKmer": "\(kmer)",
            ]
        case .pairedEndMerge(let strictness, let minOverlap):
            return [
                "strictness": "\(strictness)",
                "minOverlap": "\(minOverlap)",
                "countDuplicatesAfterMerge": "true",
                "duplicateCountEncoding": "size=N",
            ]
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
        case .reverseComplement:
            return [:]
        case .translate(let frameOffset):
            return ["frame": "\(frameOffset + 1)"]
        case .demultiplex(let kitID, _, let location, _, _, _, let errorRate, let engine, let trimBarcodes, _, _):
            if engine == .exactBareBarcode {
                return [
                    "kitID": kitID,
                    "engine": engine.rawValue,
                    "searchMode": "whole-read",
                    "searchReverseComplement": "true",
                    "trimBarcodes": "false",
                ]
            }
            return ["kitID": kitID, "location": location, "errorRate": "\(errorRate)", "engine": engine.rawValue, "trimBarcodes": "\(trimBarcodes)"]
        case .orient(_, let wordLength, _, _, let extraArguments):
            var params = ["wordLength": "\(wordLength)"]
            if !extraArguments.isEmpty {
                params["extraArgs"] = AdvancedCommandLineOptions.join(extraArguments)
            }
            return params
        case .humanReadScrub(let databaseID, _):
            return ["databaseID": Self.canonicalHumanScrubDatabaseID(for: databaseID)]
        case .ribosomalRNAFilter(let retention, let ensure):
            return [
                "tool": "deacon",
                "databaseID": DeaconRibokmersDatabaseInstaller.databaseID,
                "retention": retention.rawValue,
                "ensure": ensure.rawValue,
            ]
        }
    }
}

// MARK: - CLI Command Construction

extension FASTQDerivativeRequest {
    private static func canonicalHumanScrubDatabaseID(for databaseID: String) -> String {
        let canonical = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        if canonical == HumanScrubberDatabaseInstaller.databaseID {
            return DeaconPanhumanDatabaseInstaller.databaseID
        }
        return canonical
    }

    func outputSequenceFormat(sourceSequenceFormat: SequenceFormat) -> SequenceFormat {
        guard let kind = FASTQDerivativeOperationKind(rawValue: operationKindString) else {
            return sourceSequenceFormat
        }
        let output = OperationContract.output(
            for: kind, inputPairing: .single,
            inputFormat: sourceSequenceFormat == .fasta ? .fasta : .fastq
        )
        return output.format == .fasta ? .fasta : .fastq
    }

    /// The `lungfish-cli` command that runs this derivative on `inputPath` and
    /// writes `outputPath`, or nil when no `lungfish-cli` command reproduces it.
    ///
    /// `FASTQOperationCLIInvocationBuilder` builds it, the builder whose
    /// invocation the FASTQ operations dialog executes, so the command is the
    /// one that runs (findings R3 and R8). The dialog's Operations row and the
    /// derivative manifests' `toolCommand` that `FASTQOperationOutputImporter`
    /// writes both record it. This used to be a
    /// second encoding that recorded native tool commands, such as `seqkit seq
    /// --reverse --complement` for a reverse complement that ran as
    /// `lungfish-cli fastq reverse-complement`, and that left out values the
    /// run used.
    ///
    /// The builder refuses a request that carries a setting no `lungfish-cli`
    /// option expresses, such as an adapter FASTA, a read 2 adapter, orient
    /// keeping unoriented reads, a demultiplex symmetry mode, sample
    /// assignments or kit override, and primer trimming outside the encodable
    /// subsets. Those are CLI parity gaps, and the command is nil for them.
    ///
    /// - Parameters:
    ///   - inputPath: the input bundle or file, as the request names it.
    ///   - outputPath: the `-o` value, a file or, for the subcommands that
    ///     write several files, a directory.
    ///   - pairingMode: the pairing the input bundle recorded. When nil the
    ///     builder reads it from the input, as the dialog launch does.
    func cliCommand(
        inputPath: String,
        outputPath: String,
        pairingMode: IngestionMetadata.PairingMode? = nil
    ) -> String? {
        let request = FASTQOperationLaunchRequest.derivative(
            request: self,
            inputURLs: [URL(fileURLWithPath: inputPath)],
            outputMode: .perInput
        )
        guard let invocation = try? FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: request,
            outputTargetPath: outputPath,
            pairingMode: pairingMode
        ) else {
            return nil
        }
        return FASTQOperationCLIInvocationBuilder.commandLine(for: invocation)
    }
}

extension FASTQDerivativeRequest {
    /// Formats an entropy threshold for the command line.
    ///
    /// The entropy control steps by 0.05, so two decimals are always enough;
    /// trailing zeros are trimmed so the recorded command reads `--entropy 0.6`
    /// rather than `--entropy 0.60`.
    static func entropyArgument(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") && !text.hasSuffix(".0") {
            text.removeLast()
        }
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text
    }
}
