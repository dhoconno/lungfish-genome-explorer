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
        case .pairedEndMerge: return "Paired-End Merge"
        case .pairedEndRepair: return "Paired-End Repair"
        case .primerRemoval: return "PCR Primer Trimming"
        case .sequencePresenceFilter: return "Sequence Presence Filter"
        case .errorCorrection: return "Error Correction"
        case .interleaveReformat: return "Interleave Reformat"
        case .reverseComplement: return "Reverse Complement"
        case .translate: return "Translate"
        case .demultiplex: return "Demultiplex"
        case .orient: return "Orient Sequences"
        case .humanReadScrub: return "Human Read Scrub"
        case .ribosomalRNAFilter: return "Remove ribosomal RNA sequences"
        }
    }

    /// Whether this request produces a trim derivative (vs subset).
    var isTrimOperation: Bool {
        switch self {
        case .fastpTrim, .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval:
            return true
        case .subsampleProportion, .subsampleCount, .lengthFilter,
             .searchText, .searchMotif, .deduplicate, .contaminantFilter,
             .sequencePresenceFilter, .ribosomalRNAFilter:
            return false
        case .pairedEndMerge, .pairedEndRepair,
             .errorCorrection, .interleaveReformat, .reverseComplement,
             .translate, .demultiplex, .orient, .humanReadScrub:
            return false
        }
    }

    /// Whether this request produces a full materialized FASTQ (content-transforming).
    var isFullOperation: Bool {
        switch self {
        case .pairedEndMerge, .pairedEndRepair,
             .errorCorrection, .interleaveReformat, .demultiplex, .humanReadScrub,
             .reverseComplement, .translate, .ribosomalRNAFilter:
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
        case .fastpTrim: return "fastpTrim"
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
        case .interleaveReformat(let direction):
            return ["direction": "\(direction)"]
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

private extension FASTQQualityTrimMode {
    var cliArgument: String {
        switch self {
        case .cutRight: return "cut-right"
        case .cutFront: return "cut-front"
        case .cutTail: return "cut-tail"
        case .cutBoth: return "cut-both"
        }
    }
}

// MARK: - CLI Command Construction

/// Builds a shell-quoted command string from an array of parts.
private func buildToolCommand(parts: [String]) -> String {
    parts.map { shellEscape($0) }.joined(separator: " ")
}

/// Builds a shell-quoted `lungfish <subcommand> <args>` command string.
private func buildLungfishCommand(subcommand: String, args: [String]) -> String {
    buildToolCommand(parts: ["lungfish", subcommand] + args)
}

extension FASTQDerivativeRequest {
    private static func canonicalHumanScrubDatabaseID(for databaseID: String) -> String {
        let canonical = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        if canonical == HumanScrubberDatabaseInstaller.databaseID {
            return DeaconPanhumanDatabaseInstaller.databaseID
        }
        return canonical
    }

    func outputSequenceFormat(sourceSequenceFormat: SequenceFormat) -> SequenceFormat {
        switch self {
        case .translate:
            return .fasta
        default:
            return sourceSequenceFormat
        }
    }

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

        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            var args = [
                inputPath,
                "--threshold", String(threshold),
                "--window", String(windowSize),
                "--mode", mode.cliArgument,
            ]
            if adapterMode == .autoDetect {
                args.append("--adapter-trimming")
            } else if adapterMode == .specified, let adapterSequence {
                args += ["--adapter-trimming", "--adapter", adapterSequence]
            } else {
                args.append("--no-adapter-trimming")
            }
            args += ["-o", outputPath]
            return buildLungfishCommand(subcommand: "fastq trim", args: args)

        case .qualityTrim(let threshold, let windowSize, let mode, let extraArguments):
            let modeString: String
            switch mode {
            case .cutRight: modeString = "cut-right"
            case .cutFront: modeString = "cut-front"
            case .cutTail: modeString = "cut-tail"
            case .cutBoth: modeString = "cut-both"
            }
            var args = [
                "--threshold", String(threshold),
                "--window", String(windowSize),
                "--mode", modeString,
                inputPath, "-o", outputPath,
            ]
            if !extraArguments.isEmpty {
                args += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
            }
            return buildLungfishCommand(subcommand: "fastq quality-trim", args: args)

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
            args.append("--count-duplicates")
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

        case .reverseComplement:
            return buildToolCommand(parts: ["seqkit", "seq", "--reverse", "--complement", inputPath, "-o", outputPath])

        case .translate(let frameOffset):
            return buildToolCommand(parts: ["seqkit", "translate", "--frame", String(frameOffset + 1), inputPath, "-o", outputPath])

        case .demultiplex(let kitID, let customCSVPath, let location, _, _, _, let errorRate, let engine, let trimBarcodes, _, _):
            var args = [inputPath, "--kit", customCSVPath ?? kitID, "-o", outputPath]
            if engine == .exactBareBarcode {
                args += ["--engine", engine.rawValue]
                return buildLungfishCommand(subcommand: "fastq demultiplex", args: args)
            }
            args += ["--location", location, "--error-rate", String(format: "%.2f", errorRate)]
            if engine != .cutadapt { args += ["--engine", engine.rawValue] }
            if !trimBarcodes { args.append("--no-trim") }
            return buildLungfishCommand(subcommand: "fastq demultiplex", args: args)

        case .orient(let referenceURL, let wordLength, _, _, let extraArguments):
            // No direct lungfish CLI subcommand — show vsearch invocation.
            var parts = [
                "vsearch", "--orient", inputPath,
                "--db", referenceURL.path,
                "--fastaout", outputPath,
                "--wordlength", String(wordLength),
            ]
            parts += extraArguments
            return buildToolCommand(parts: parts)

        case .humanReadScrub(let databaseID, _):
            // No direct lungfish CLI subcommand — show Deacon filter invocation.
            let resolvedDatabaseID = Self.canonicalHumanScrubDatabaseID(for: databaseID)
            return buildToolCommand(parts: [
                "deacon", "filter", "-d", resolvedDatabaseID, inputPath, "-o", outputPath,
            ])

        case .ribosomalRNAFilter(let retention, _):
            return buildLungfishCommand(subcommand: "fastq deacon-ribo", args: [
                inputPath,
                "--database-id", DeaconRibokmersDatabaseInstaller.databaseID,
                "--retain", retention.rawValue,
                "-o", outputPath,
            ])
        }
    }
}


extension FASTQDerivativeRequest {
    var provenanceCLIArguments: [String] {
        switch self {
        case .subsampleProportion(let proportion):
            return ["--proportion", String(proportion)]
        case .subsampleCount(let count):
            return ["--count", String(count)]
        case .lengthFilter(let min, let max):
            return optionalFlag("--min-length", min) + optionalFlag("--max-length", max)
        case .searchText(let query, let field, let regex):
            return ["--query", query, "--field", field.rawValue, "--regex", String(regex)]
        case .searchMotif(let pattern, let regex):
            return ["--pattern", pattern, "--regex", String(regex)]
        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            return [
                "--preset", preset.rawValue,
                "--substitutions", String(substitutions),
                "--optical", String(optical),
                "--optical-distance", String(opticalDistance),
            ]
        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            return [
                "--threshold", String(threshold),
                "--window-size", String(windowSize),
                "--mode", mode.rawValue,
                "--adapter-mode", adapterMode.rawValue,
            ] + optionalFlag("--adapter-sequence", adapterSequence)
        case .qualityTrim(let threshold, let windowSize, let mode, let extraArguments):
            var args = [
                "--threshold", String(threshold),
                "--window-size", String(windowSize),
                "--mode", mode.rawValue,
            ]
            if !extraArguments.isEmpty {
                args += ["--extra-arguments", AdvancedCommandLineOptions.join(extraArguments)]
            }
            return args
        case .adapterTrim(let mode, let sequence, let sequenceR2, let fastaFilename):
            return [
                "--adapter-mode", mode.rawValue,
            ] + optionalFlag("--adapter-sequence", sequence)
                + optionalFlag("--adapter-sequence-r2", sequenceR2)
                + optionalFlag("--adapter-fasta", fastaFilename)
        case .fixedTrim(let from5Prime, let from3Prime):
            return ["--from-5-prime", String(from5Prime), "--from-3-prime", String(from3Prime)]
        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            return [
                "--mode", mode.rawValue,
                "--kmer-size", String(kmerSize),
                "--hamming-distance", String(hammingDistance),
            ] + optionalFlag("--reference-fasta", referenceFasta)
        case .pairedEndMerge(let strictness, let minOverlap):
            return [
                "--strictness", strictness.rawValue,
                "--min-overlap", String(minOverlap),
                "--count-duplicates", "true",
            ]
        case .pairedEndRepair:
            return []
        case .primerRemoval(let configuration):
            return [
                "--source", configuration.source.rawValue,
                "--read-mode", configuration.readMode.rawValue,
                "--mode", configuration.mode.rawValue,
                "--minimum-overlap", String(configuration.minimumOverlap),
                "--error-rate", String(configuration.errorRate),
                "--allow-indels", String(configuration.allowIndels),
                "--keep-untrimmed", String(configuration.keepUntrimmed),
                "--search-reverse-complement", String(configuration.searchReverseComplement),
                "--tool", configuration.tool.rawValue,
            ] + optionalFlag("--forward-sequence", configuration.forwardSequence)
                + optionalFlag("--reverse-sequence", configuration.reverseSequence)
                + optionalFlag("--reference-fasta", configuration.referenceFasta)
        case .sequencePresenceFilter(let sequence, let fastaPath, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchRC):
            return [
                "--search-end", searchEnd.rawValue,
                "--min-overlap", String(minOverlap),
                "--error-rate", String(errorRate),
                "--keep-matched", String(keepMatched),
                "--search-reverse-complement", String(searchRC),
            ] + optionalFlag("--sequence", sequence)
                + optionalFlag("--fasta-path", fastaPath)
        case .errorCorrection(let kmerSize):
            return ["--kmer-size", String(kmerSize)]
        case .interleaveReformat(let direction):
            return ["--direction", direction.rawValue]
        case .reverseComplement:
            return []
        case .translate(let frameOffset):
            return ["--frame-offset", String(frameOffset)]
        case .demultiplex(let kitID, let customCSVPath, let location, let symmetryMode, let maxDistanceFrom5Prime, let maxDistanceFrom3Prime, let errorRate, let engine, let trimBarcodes, let sampleAssignments, let kitOverride):
            if engine == .exactBareBarcode {
                return [
                    "--kit-id", kitID,
                    "--engine", engine.rawValue,
                    "--search-mode", "whole-read",
                    "--search-reverse-complement", "true",
                    "--trim-barcodes", "false",
                    "--sample-assignment-count", String(sampleAssignments?.count ?? 0),
                ] + optionalFlag("--custom-csv", customCSVPath)
                    + optionalFlag("--symmetry-mode", symmetryMode?.rawValue)
                    + optionalFlag("--kit-override-id", kitOverride?.id)
            }
            return [
                "--kit-id", kitID,
                "--location", location,
                "--max-distance-from-5-prime", String(maxDistanceFrom5Prime),
                "--max-distance-from-3-prime", String(maxDistanceFrom3Prime),
                "--error-rate", String(errorRate),
                "--engine", engine.rawValue,
                "--trim-barcodes", String(trimBarcodes),
                "--sample-assignment-count", String(sampleAssignments?.count ?? 0),
            ] + optionalFlag("--custom-csv", customCSVPath)
                + optionalFlag("--symmetry-mode", symmetryMode?.rawValue)
                + optionalFlag("--kit-override-id", kitOverride?.id)
        case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented, let extraArguments):
            var args = [
                "--reference", referenceURL.path,
                "--word-length", String(wordLength),
                "--db-mask", dbMask,
                "--save-unoriented", String(saveUnoriented),
            ]
            if !extraArguments.isEmpty {
                args += ["--extra-arguments", AdvancedCommandLineOptions.join(extraArguments)]
            }
            return args
        case .humanReadScrub(let databaseID, let removeReads):
            return ["--database-id", databaseID, "--remove-reads", String(removeReads)]
        case .ribosomalRNAFilter(let retention, let ensure):
            return ["--retention", retention.rawValue, "--ensure", ensure.rawValue]
        }
    }

    var provenanceExplicitOptions: [String: ParameterValue] {
        switch self {
        case .subsampleProportion(let proportion):
            return ["proportion": .number(proportion)]
        case .subsampleCount(let count):
            return ["count": .integer(count)]
        case .lengthFilter(let min, let max):
            return ["minLength": optionalInt(min), "maxLength": optionalInt(max)]
        case .searchText(let query, let field, let regex):
            return ["query": .string(query), "field": .string(field.rawValue), "regex": .boolean(regex)]
        case .searchMotif(let pattern, let regex):
            return ["pattern": .string(pattern), "regex": .boolean(regex)]
        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            return [
                "preset": .string(preset.rawValue),
                "substitutions": .integer(substitutions),
                "optical": .boolean(optical),
                "opticalDistance": .integer(opticalDistance),
            ]
        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            return [
                "threshold": .integer(threshold),
                "windowSize": .integer(windowSize),
                "mode": .string(mode.rawValue),
                "adapterMode": .string(adapterMode.rawValue),
                "adapterSequence": optionalString(adapterSequence),
            ]
        case .qualityTrim(let threshold, let windowSize, let mode, let extraArguments):
            return [
                "threshold": .integer(threshold),
                "windowSize": .integer(windowSize),
                "mode": .string(mode.rawValue),
                "extraArguments": .array(extraArguments.map(ParameterValue.string)),
            ]
        case .adapterTrim(let mode, let sequence, let sequenceR2, let fastaFilename):
            return [
                "mode": .string(mode.rawValue),
                "sequence": optionalString(sequence),
                "sequenceR2": optionalString(sequenceR2),
                "fastaFilename": optionalString(fastaFilename),
            ]
        case .fixedTrim(let from5Prime, let from3Prime):
            return ["from5Prime": .integer(from5Prime), "from3Prime": .integer(from3Prime)]
        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            return [
                "mode": .string(mode.rawValue),
                "referenceFasta": optionalString(referenceFasta),
                "kmerSize": .integer(kmerSize),
                "hammingDistance": .integer(hammingDistance),
            ]
        case .pairedEndMerge(let strictness, let minOverlap):
            return [
                "strictness": .string(strictness.rawValue),
                "minOverlap": .integer(minOverlap),
                "countDuplicatesAfterMerge": .boolean(true),
                "duplicateCountEncoding": .string("size=N"),
            ]
        case .pairedEndRepair:
            return [:]
        case .primerRemoval(let configuration):
            return [
                "source": .string(configuration.source.rawValue),
                "readMode": .string(configuration.readMode.rawValue),
                "mode": .string(configuration.mode.rawValue),
                "forwardSequence": optionalString(configuration.forwardSequence),
                "reverseSequence": optionalString(configuration.reverseSequence),
                "referenceFasta": optionalString(configuration.referenceFasta),
                "minimumOverlap": .integer(configuration.minimumOverlap),
                "errorRate": .number(configuration.errorRate),
                "allowIndels": .boolean(configuration.allowIndels),
                "keepUntrimmed": .boolean(configuration.keepUntrimmed),
                "searchReverseComplement": .boolean(configuration.searchReverseComplement),
                "tool": .string(configuration.tool.rawValue),
            ]
        case .sequencePresenceFilter(let sequence, let fastaPath, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchRC):
            return [
                "sequence": optionalString(sequence),
                "fastaPath": optionalString(fastaPath),
                "searchEnd": .string(searchEnd.rawValue),
                "minOverlap": .integer(minOverlap),
                "errorRate": .number(errorRate),
                "keepMatched": .boolean(keepMatched),
                "searchReverseComplement": .boolean(searchRC),
            ]
        case .errorCorrection(let kmerSize):
            return ["kmerSize": .integer(kmerSize)]
        case .interleaveReformat(let direction):
            return ["direction": .string(direction.rawValue)]
        case .reverseComplement:
            return [:]
        case .translate(let frameOffset):
            return ["frameOffset": .integer(frameOffset), "frame": .integer(frameOffset + 1)]
        case .demultiplex(let kitID, let customCSVPath, let location, let symmetryMode, let maxDistanceFrom5Prime, let maxDistanceFrom3Prime, let errorRate, let engine, let trimBarcodes, let sampleAssignments, let kitOverride):
            if engine == .exactBareBarcode {
                return [
                    "kitID": .string(kitID),
                    "customCSVPath": optionalString(customCSVPath),
                    "symmetryMode": optionalString(symmetryMode?.rawValue),
                    "engine": .string(engine.rawValue),
                    "searchMode": .string("whole-read"),
                    "searchReverseComplement": .boolean(true),
                    "trimBarcodes": .boolean(false),
                    "sampleAssignmentCount": .integer(sampleAssignments?.count ?? 0),
                    "kitOverrideID": optionalString(kitOverride?.id),
                ]
            }
            return [
                "kitID": .string(kitID),
                "customCSVPath": optionalString(customCSVPath),
                "location": .string(location),
                "symmetryMode": optionalString(symmetryMode?.rawValue),
                "maxDistanceFrom5Prime": .integer(maxDistanceFrom5Prime),
                "maxDistanceFrom3Prime": .integer(maxDistanceFrom3Prime),
                "errorRate": .number(errorRate),
                "engine": .string(engine.rawValue),
                "trimBarcodes": .boolean(trimBarcodes),
                "sampleAssignmentCount": .integer(sampleAssignments?.count ?? 0),
                "kitOverrideID": optionalString(kitOverride?.id),
            ]
        case .orient:
            return [:]
        case .humanReadScrub(let databaseID, let removeReads):
            return ["databaseID": .string(databaseID), "removeReads": .boolean(removeReads)]
        case .ribosomalRNAFilter(let retention, let ensure):
            return ["retention": .string(retention.rawValue), "ensure": .string(ensure.rawValue)]
        }
    }

    var provenanceDefaultOptions: [String: ParameterValue] {
        switch self {
        case .lengthFilter:
            return ["minLength": .null, "maxLength": .null]
        case .qualityTrim:
            return [
                "threshold": .integer(20),
                "windowSize": .integer(4),
                "mode": .string(FASTQQualityTrimMode.cutRight.rawValue),
                "extraArguments": .array([]),
            ]
        case .fastpTrim:
            return [
                "threshold": .integer(20),
                "windowSize": .integer(4),
                "mode": .string(FASTQQualityTrimMode.cutRight.rawValue),
                "adapterMode": .string(FASTQAdapterMode.autoDetect.rawValue),
                "adapterSequence": .null,
            ]
        case .adapterTrim:
            return [
                "mode": .string(FASTQAdapterMode.autoDetect.rawValue),
                "sequence": .null,
                "sequenceR2": .null,
                "fastaFilename": .null,
            ]
        case .fixedTrim:
            return ["from5Prime": .integer(0), "from3Prime": .integer(0)]
        case .pairedEndMerge:
            return [
                "strictness": .string(FASTQMergeStrictness.normal.rawValue),
                "minOverlap": .integer(12),
            ]
        case .demultiplex:
            return [
                "customCSVPath": .null,
                "symmetryMode": .null,
                "maxDistanceFrom5Prime": .integer(0),
                "maxDistanceFrom3Prime": .integer(0),
                "errorRate": .number(0.0),
                "trimBarcodes": .boolean(true),
                "sampleAssignmentCount": .integer(0),
                "kitOverrideID": .null,
            ]
        case .primerRemoval:
            return [
                "minimumOverlap": .integer(3),
                "errorRate": .number(0.1),
                "allowIndels": .boolean(true),
                "keepUntrimmed": .boolean(false),
                "searchReverseComplement": .boolean(false),
            ]
        case .sequencePresenceFilter:
            return [
                "minOverlap": .integer(3),
                "errorRate": .number(0.1),
                "keepMatched": .boolean(true),
                "searchReverseComplement": .boolean(false),
            ]
        case .contaminantFilter:
            return ["kmerSize": .integer(31), "hammingDistance": .integer(1), "referenceFasta": .null]
        case .errorCorrection:
            return ["kmerSize": .integer(50)]
        case .interleaveReformat:
            return ["direction": .string(FASTQInterleaveDirection.interleave.rawValue)]
        case .translate:
            return ["frameOffset": .integer(0), "frame": .integer(1)]
        case .humanReadScrub:
            return ["removeReads": .boolean(true)]
        case .subsampleProportion, .subsampleCount, .searchText, .searchMotif,
             .deduplicate, .pairedEndRepair, .reverseComplement, .orient,
             .ribosomalRNAFilter:
            return [:]
        }
    }

    private func optionalString(_ value: String?) -> ParameterValue {
        value.map(ParameterValue.string) ?? .null
    }

    private func optionalInt(_ value: Int?) -> ParameterValue {
        value.map(ParameterValue.integer) ?? .null
    }

    private func optionalFlag(_ flag: String, _ value: String?) -> [String] {
        value.map { [flag, $0] } ?? []
    }

    private func optionalFlag(_ flag: String, _ value: Int?) -> [String] {
        value.map { [flag, String($0)] } ?? []
    }
}
