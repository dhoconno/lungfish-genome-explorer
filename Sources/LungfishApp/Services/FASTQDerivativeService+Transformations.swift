// FASTQDerivativeService+Transformations.swift - Transformations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Transformations

    func runTransformation(
        request: FASTQDerivativeRequest,
        sourceFASTQ: URL,
        outputFASTQ: URL,
        sourceBundleURL: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> FASTQDerivativeOperation {
        let isInterleaved = isInterleavedBundle(sourceBundleURL)

        switch request {
        case .subsampleProportion(let proportion):
            guard proportion > 0.0, proportion <= 1.0 else {
                throw FASTQDerivativeError.invalidOperation("proportion must be in (0, 1]")
            }
            // seqkit sample -s accepts a signed Int64; clamp to avoid "value out of range" errors.
            let seed = UInt64.random(in: 0...UInt64(Int64.max))
            if isInterleaved {
                // Use reformat.sh with samplerate for pair-aware subsampling
                let env = await bbToolsEnvironment()
                let result = try await runNativeTool(
                    .reformat,
                    arguments: [
                        "in=\(sourceFASTQ.path)",
                        "out=\(outputFASTQ.path)",
                        "samplerate=\(proportion)",
                        "sampleseed=\(seed)",
                        "interleaved=t",
                    ],
                    environment: env,
                    timeout: 1800,
                    provenanceCollector: provenanceCollector
                )
                guard result.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("reformat.sh subsample failed: \(result.stderr)")
                }
            } else {
                let result = try await runNativeTool(
                    .seqkit,
                    arguments: ["sample", "-p", String(proportion), "-s", String(seed), sourceFASTQ.path, "-o", outputFASTQ.path],
                    provenanceCollector: provenanceCollector
                )
                guard result.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("seqkit sample failed: \(result.stderr)")
                }
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
            // seqkit sample -s accepts a signed Int64; clamp to avoid "value out of range" errors.
            let seed = UInt64.random(in: 0...UInt64(Int64.max))
            if isInterleaved {
                // For PE data, sample count/2 pairs to get ~count total reads
                let pairCount = max(1, count / 2)
                let env = await bbToolsEnvironment()
                let result = try await runNativeTool(
                    .reformat,
                    arguments: [
                        "in=\(sourceFASTQ.path)",
                        "out=\(outputFASTQ.path)",
                        "samplereadstarget=\(pairCount)",
                        "sampleseed=\(seed)",
                        "interleaved=t",
                    ],
                    environment: env,
                    timeout: 1800,
                    provenanceCollector: provenanceCollector
                )
                guard result.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("reformat.sh subsample failed: \(result.stderr)")
                }
            } else {
                let result = try await runNativeTool(
                    .seqkit,
                    arguments: ["sample2", "-n", String(count), "-2", "-s", String(seed), sourceFASTQ.path, "-o", outputFASTQ.path],
                    provenanceCollector: provenanceCollector
                )
                guard result.isSuccess else {
                    throw FASTQDerivativeError.invalidOperation("seqkit sample2 failed: \(result.stderr)")
                }
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
                    maxLength: maxLength,
                    provenanceCollector: provenanceCollector
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
                _ = try await runNativeTool(.seqkit, arguments: args, provenanceCollector: provenanceCollector)
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
                    searchArgs: buildSearchArgs(field: field, regex: regex, query: query),
                    provenanceCollector: provenanceCollector
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
                _ = try await runNativeTool(.seqkit, arguments: args, provenanceCollector: provenanceCollector)
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
                    searchArgs: buildMotifSearchArgs(pattern: pattern, regex: regex),
                    provenanceCollector: provenanceCollector
                )
            } else {
                var args = ["grep", "-s", "-j", String(toolThreadCount)]
                if regex {
                    args.append("-r")
                }
                args += ["-p", pattern, sourceFASTQ.path, "-o", outputFASTQ.path]
                _ = try await runNativeTool(.seqkit, arguments: args, provenanceCollector: provenanceCollector)
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
            let result = try await runNativeTool(
                .clumpify,
                arguments: args,
                environment: env,
                timeout: 3600,
                provenanceCollector: provenanceCollector
            )
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

        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            let result = try await runFastpCombinedTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                threshold: threshold,
                windowSize: windowSize,
                mode: mode,
                adapterMode: adapterMode,
                adapterSequence: adapterSequence,
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .fastpTrim,
                qualityThreshold: threshold,
                windowSize: windowSize,
                qualityTrimMode: mode,
                adapterMode: adapterMode,
                adapterSequence: adapterSequence,
                toolUsed: "fastp",
                toolCommand: result.toolCommand
            )

        case .qualityTrim(let threshold, let windowSize, let mode, _):
            let result = try await runFastpQualityTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                threshold: threshold,
                windowSize: windowSize,
                mode: mode,
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
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
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
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
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
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
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
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
                    isInterleaved: isInterleaved,
                    provenanceCollector: provenanceCollector
                )
            case .bbduk:
                result = try await runBBDukPrimerTrim(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    configuration: configuration,
                    sourceBundleURL: sourceBundleURL,
                    isInterleaved: isInterleaved,
                    provenanceCollector: provenanceCollector
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
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
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
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
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
                sourceBundleURL: sourceBundleURL,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .interleaveReformat,
                interleaveDirection: direction,
                toolUsed: "reformat",
                toolCommand: result.toolCommand
            )

        case .reverseComplement:
            try await writeReverseComplementedFASTQ(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ
            )
            return FASTQDerivativeOperation(
                kind: .reverseComplement,
                toolUsed: "lungfish",
                toolCommand: "lungfish fastq reverse-complement \(sourceFASTQ.path) -o \(outputFASTQ.path)"
            )

        case .translate(let frameOffset):
            try await writeTranslatedSyntheticFASTQ(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                frameOffset: frameOffset
            )
            return FASTQDerivativeOperation(
                kind: .translate,
                toolUsed: "lungfish",
                toolCommand: "lungfish fasta translate \(sourceFASTQ.path) --frame \(frameOffset + 1) -o \(outputFASTQ.path)"
            )

        case .demultiplex:
            throw FASTQDerivativeError.invalidOperation(
                "Demultiplexing is not supported by FASTQDerivativeService. Route through DemultiplexingPipeline or FASTQOperationExecutionService."
            )

        case .orient:
            throw FASTQDerivativeError.invalidOperation(
                "Orient is handled via createOrientDerivative."
            )

        case .humanReadScrub(let databaseID, _):
            let outputURL = outputFASTQ
            _ = try await runDeaconHumanReadScrub(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputURL,
                databaseID: databaseID,
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .humanReadScrub,
                humanScrubRemoveReads: true,
                humanScrubDatabaseID: Self.canonicalHumanScrubDatabaseID(for: databaseID),
                toolUsed: "deacon"
            )

        case .ribosomalRNAFilter:
            throw FASTQDerivativeError.invalidOperation(
                "Deacon rRNA filtering is handled by FASTQOperationExecutionService."
            )
        }
    }

    func writeReverseComplementedFASTQ(
        sourceFASTQ: URL,
        outputFASTQ: URL
    ) async throws {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: sourceFASTQ) {
            try writer.write(record.reverseComplement())
        }
    }

    func writeTranslatedSyntheticFASTQ(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        frameOffset: Int
    ) async throws {
        guard (0...2).contains(frameOffset) else {
            throw FASTQDerivativeError.invalidOperation("Translation frame must be 1, 2, or 3.")
        }

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: sourceFASTQ) {
            let protein = TranslationEngine.translate(record.sequence, offset: frameOffset)
            guard !protein.isEmpty else { continue }
            let quality = QualityScore(values: Array(repeating: 40, count: protein.count), encoding: .phred33)
            try writer.write(
                FASTQRecord(
                    identifier: "\(record.identifier)_frame\(frameOffset + 1)",
                    description: record.description,
                    sequence: protein,
                    quality: quality
                )
            )
        }
    }

}
