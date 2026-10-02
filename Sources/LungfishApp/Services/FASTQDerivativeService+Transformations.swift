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

    /// Runs `request` on `sourceFASTQ` and returns the operation the
    /// derivative's manifest records. The operation carries no `toolCommand`,
    /// because the final output is not known here. `createDerivative` sets it
    /// with ``derivativeToolCommand(for:sourceBundleURL:finalOutputURL:randomSeed:)``
    /// once the payload is written. The native tools that run here reach the
    /// provenance envelope's steps through `provenanceCollector`.
    func runTransformation(
        request: FASTQDerivativeRequest,
        sourceFASTQ: URL,
        outputFASTQ: URL,
        sourceBundleURL: URL,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> FASTQDerivativeOperation {
        // Every pair-aware branch below pairs records by POSITION (reformat
        // and bbduk interleaved=t, fastp --interleaved_in, cutadapt
        // --interleaved, the deacon R1/R2 split), so only a strictly
        // interleaved input turns them on. A file that mixes merged reads
        // with pairs runs as single reads (owner contract, FASTQInputLayout).
        let readLayout = resolvedReadLayout(of: sourceFASTQ, in: sourceBundleURL)
        let isInterleaved = readLayout.layout == .strictlyInterleaved
        // The fastp trims partition their input by NAME (FastpPairedRunner),
        // so they also run the pairs of a mixed file paired, as the CLI does.
        let pairsByName = isInterleaved || readLayout.layout == .mixedMergedAndPairs
        if readLayout.layout == .mixedMergedAndPairs {
            progress?("Input mixes merged reads and pairs; positional tools treat every record as a single read, and the fastp trims pair records by name")
        }

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
            // The same plan `lungfish-cli fastq length-filter` renders: bbduk
            // interleaved=t keeps or drops both mates together, seqkit seq
            // judges single reads.
            let plan = FASTQLengthFilterPlan.make(
                inputPath: sourceFASTQ.path,
                outputPath: outputFASTQ.path,
                minLength: minLength,
                maxLength: maxLength,
                pairAware: isInterleaved
            )
            try await runLengthFilterPlan(plan, provenanceCollector: provenanceCollector)
            return FASTQDerivativeOperation(
                kind: .lengthFilter,
                minLength: minLength,
                maxLength: maxLength,
                toolUsed: plan.tool.rawValue
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
            let heapGB = ManagedJavaHeapPolicy.heapGB(minimumGB: 1)
            var args = [
                "in=\(sourceFASTQ.path)",
                "out=\(outputFASTQ.path)",
                "-Xmx\(heapGB)g",
                "dedupe=t",
                "subs=\(substitutions)",
                "ow=t"
            ]
            // clumpify interleaved=t compares and clusters whole pairs and
            // keeps both mates adjacent. interleaved=f is stated for the
            // single-read case so BBTools' own name detection cannot pair a
            // mixed file by position.
            args.append(isInterleaved ? "interleaved=t" : "interleaved=f")
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
                toolUsed: "clumpify"
            )

        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            try await runFastpCombinedTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                threshold: threshold,
                windowSize: windowSize,
                mode: mode,
                adapterMode: adapterMode,
                adapterSequence: adapterSequence,
                pairsByName: pairsByName,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .fastpTrim,
                qualityThreshold: threshold,
                windowSize: windowSize,
                qualityTrimMode: mode,
                adapterMode: adapterMode,
                adapterSequence: adapterSequence,
                toolUsed: "fastp"
            )

        case .qualityTrim(let threshold, let windowSize, let mode, let extraArguments):
            try await runFastpQualityTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                threshold: threshold,
                windowSize: windowSize,
                mode: mode,
                extraArguments: extraArguments,
                pairsByName: pairsByName,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .qualityTrim,
                qualityThreshold: threshold,
                windowSize: windowSize,
                qualityTrimMode: mode,
                toolUsed: "fastp"
            )

        case .adapterTrim(let adapterMode, let sequence, let sequenceR2, let fastaFilename):
            try await runFastpAdapterTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                mode: adapterMode,
                sequence: sequence,
                sequenceR2: sequenceR2,
                fastaFilename: fastaFilename,
                sourceBundleURL: sourceBundleURL,
                pairsByName: pairsByName,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .adapterTrim,
                adapterMode: adapterMode,
                adapterSequence: sequence,
                adapterSequenceR2: sequenceR2,
                adapterFastaFilename: fastaFilename,
                toolUsed: "fastp"
            )

        case .fixedTrim(let from5Prime, let from3Prime):
            try await runFastpFixedTrim(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                from5Prime: from5Prime,
                from3Prime: from3Prime,
                pairsByName: pairsByName,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .fixedTrim,
                trimFrom5Prime: from5Prime,
                trimFrom3Prime: from3Prime,
                toolUsed: "fastp"
            )

        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            try await runBBDukContaminantFilter(
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
                toolUsed: "bbduk"
            )

        case .lowComplexityFilter(let entropy, let window, let kmer):
            let result = try await runBBDukEntropyFilter(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                entropy: entropy,
                window: window,
                kmer: kmer,
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
            )
            // Surface the parsed bbduk read/base counts in the operation log so
            // the expanded row shows how much was removed, not just that it ran.
            if let summary = result.summary {
                progress?(summary.displaySummary)
            }
            return FASTQDerivativeOperation(
                kind: .lowComplexityFilter,
                entropyThreshold: entropy,
                entropyWindow: window,
                entropyKmer: kmer,
                toolUsed: "bbduk"
            )

        case .pairedEndMerge, .pairedEndRepair:
            throw FASTQDerivativeError.invalidOperation(
                "Mixed-output operations must be handled via createMixedOutputDerivative"
            )

        case .primerRemoval(let configuration):
            switch configuration.tool {
            case .cutadapt:
                try await runCutadaptPrimerTrim(
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ,
                    configuration: configuration,
                    sourceBundleURL: sourceBundleURL,
                    isInterleaved: isInterleaved,
                    provenanceCollector: provenanceCollector
                )
            case .bbduk:
                try await runBBDukPrimerTrim(
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
                toolUsed: configuration.tool == .bbduk ? "bbduk" : "cutadapt"
            )

        case .sequencePresenceFilter(let sequence, let fastaPath, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchRC):
            try await runCutadaptAdapterPresenceFilter(
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
                toolUsed: "cutadapt"
            )

        case .errorCorrection(let kmerSize):
            try await runTadpole(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                kmerSize: kmerSize,
                isInterleaved: isInterleaved,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .errorCorrection,
                errorCorrectionKmerSize: kmerSize,
                toolUsed: "tadpole"
            )

        case .interleaveReformat(let direction):
            try await runReformat(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                direction: direction,
                sourceBundleURL: sourceBundleURL,
                provenanceCollector: provenanceCollector
            )
            return FASTQDerivativeOperation(
                kind: .interleaveReformat,
                interleaveDirection: direction,
                toolUsed: "reformat"
            )

        case .reverseComplement:
            try await writeReverseComplementedFASTQ(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ
            )
            return FASTQDerivativeOperation(
                kind: .reverseComplement,
                toolUsed: "lungfish"
            )

        case .translate(let frameOffset):
            try await writeTranslatedSyntheticFASTQ(
                sourceFASTQ: sourceFASTQ,
                outputFASTQ: outputFASTQ,
                frameOffset: frameOffset
            )
            return FASTQDerivativeOperation(
                kind: .translate,
                toolUsed: "lungfish"
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

    // MARK: - The command a derivative records (findings R3 and R8)

    /// The `toolCommand` a derivative made in process records in its manifest,
    /// the command the Inspector shows with Copy. It is the `lungfish-cli
    /// fastq` command `FASTQDerivativeRequest.cliCommand` builds for
    /// `request`, the command the FASTQ operations dialog runs and the dataset
    /// viewport's Operations row records, with `sourceBundleURL` as the input,
    /// the pairing the row reads from that bundle, and `finalOutputURL` where
    /// the row shows `<derived>`. A subsample also passes the seed the run
    /// drew, so the command draws the same reads. The command is nil when no
    /// `lungfish-cli` option expresses the request, a CLI parity gap that
    /// MainSplitGenomicsDisplayOperationTests pins.
    ///
    /// The manifest used to record the native tool commands on scratch paths
    /// the run deletes, `lungfish fastq reverse-complement` with the legacy
    /// executable name, `lungfish fasta translate`, which is no command, or no
    /// command at all. The native tools, their versions and their argv stay in
    /// the provenance envelope's steps.
    static func derivativeToolCommand(
        for request: FASTQDerivativeRequest,
        sourceBundleURL: URL,
        finalOutputURL: URL,
        randomSeed: UInt64? = nil
    ) -> String? {
        guard let command = request.cliCommand(
            inputPath: sourceBundleURL.path,
            outputPath: finalOutputURL.path,
            pairingMode: FASTQPairingModeResolver.bundlePairingMode(for: sourceBundleURL)
        ) else {
            return nil
        }
        switch request {
        case .subsampleProportion, .subsampleCount:
            return randomSeed.map { command + " --seed \($0)" } ?? command
        default:
            return command
        }
    }

    /// The output a derivative's command names. It is the payload file when
    /// the derivative holds one file the command writes, `reads.fastq` or
    /// `reads.fasta`, and the derivative bundle otherwise, because a subset,
    /// trim, paired, mixed or orient-map payload holds no single file the
    /// command writes.
    static func derivativeFinalOutputURL(in outputBundleURL: URL, payload: FASTQDerivativePayload) -> URL {
        switch payload {
        case .full(let fastqFilename):
            return outputBundleURL.appendingPathComponent(fastqFilename)
        case .fullFASTA(let fastaFilename):
            return outputBundleURL.appendingPathComponent(fastaFilename)
        default:
            return outputBundleURL
        }
    }

    /// The orient command ``derivativeToolCommand(for:sourceBundleURL:finalOutputURL:randomSeed:)``
    /// builds for the settings `createOrientDerivative` ran vsearch with. It
    /// is nil when the run saves unoriented reads, which no `fastq orient`
    /// option expresses.
    static func derivativeToolCommand(forOrient config: OrientConfig, sourceBundleURL: URL, finalOutputURL: URL) -> String? {
        derivativeToolCommand(
            for: .orient(
                referenceURL: config.referenceURL,
                wordLength: config.wordLength,
                dbMask: config.dbMask,
                saveUnoriented: config.saveUnoriented,
                extraArguments: config.extraArguments
            ),
            sourceBundleURL: sourceBundleURL,
            finalOutputURL: finalOutputURL
        )
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
