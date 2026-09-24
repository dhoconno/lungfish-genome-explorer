import Foundation
import LungfishIO
import LungfishWorkflow

struct FASTQOperationCLIInvocationBuilder: Sendable {
    func buildInvocation(for request: FASTQOperationLaunchRequest) throws -> FASTQCLIInvocation {
        try buildInvocation(for: request, outputTargetPath: "<derived>")
    }

    /// Builds the `lungfish-cli` invocation for a request.
    ///
    /// - Parameter pairingMode: the pairing recorded by the input's bundle,
    ///   when the caller already knows it (the execution service reads it
    ///   from the ORIGINAL input, because a derived bundle is materialized
    ///   to a scratch file that carries no metadata). When `nil`, the
    ///   builder looks next to the input path itself.
    /// - Parameter pairingMetadataURL: the ORIGINAL input (bundle or the file
    ///   inside it) whose metadata describes the reads, used as hints when a
    ///   recorded `interleaved` pairing is verified against the records.
    func buildInvocation(
        for request: FASTQOperationLaunchRequest,
        outputTargetPath: String,
        pairingMode: IngestionMetadata.PairingMode? = nil,
        pairingMetadataURL: URL? = nil
    ) throws -> FASTQCLIInvocation {
        try legacyBuildInvocation(
            for: request,
            outputTargetPath: outputTargetPath,
            pairingMode: pairingMode,
            pairingMetadataURL: pairingMetadataURL
        )
    }

    /// The `--pairing` arguments that make a `fastq` subcommand treat its
    /// input the way the bundle recorded it, so the CLI never has to guess
    /// from read names and `Copy CLI Command` reproduces the GUI run.
    ///
    /// `.pairedEnd` (separate R1/R2 files) and `nil` leave the CLI in auto
    /// mode, which reads bundle metadata and then read names on its own.
    static func pairingArguments(for pairingMode: IngestionMetadata.PairingMode?) -> [String] {
        switch pairingMode {
        case .interleaved: return ["--pairing", "interleaved"]
        case .singleEnd: return ["--pairing", "single"]
        case .pairedEnd, .none: return []
        }
    }

    /// ``pairingArguments(for:)`` with a recorded `interleaved` pairing
    /// verified against the records of `inputURL` (metadata of
    /// `metadataURL` as hints): a VSP2 bundle records `interleaved` while
    /// holding merged reads, and only a strictly interleaved file may ask
    /// the CLI to pair by position. Mixed input is passed as `single`.
    static func pairingArguments(
        for pairingMode: IngestionMetadata.PairingMode?,
        verifiedAgainst inputURL: URL?,
        metadataFrom metadataURL: URL?
    ) -> [String] {
        guard pairingMode == .interleaved, let inputURL else {
            return pairingArguments(for: pairingMode)
        }
        let layout = FASTQInputLayoutResolver.resolve(fastqURL: inputURL, metadataFrom: metadataURL).layout
        switch layout {
        case .strictlyInterleaved: return ["--pairing", "interleaved"]
        case .mixedMergedAndPairs, .singleEnd: return ["--pairing", "single"]
        case .pairedFiles: return []
        }
    }

    private func legacyBuildInvocation(
        for request: FASTQOperationLaunchRequest,
        outputTargetPath: String,
        pairingMode: IngestionMetadata.PairingMode?,
        pairingMetadataURL: URL?
    ) throws -> FASTQCLIInvocation {
        switch request {
        case .refreshQCSummary(let inputURLs):
            return FASTQCLIInvocation(
                subcommand: "fastq",
                arguments: ["qc-summary"] + inputURLs.map(\.path) + ["--output", outputTargetPath]
            )

        case .derivative(let request, let inputURLs, _):
            let resolvedPairingMode = pairingMode
                ?? inputURLs.first.flatMap(FASTQPairingModeResolver.bundlePairingMode(for:))
            return FASTQCLIInvocation(
                subcommand: "fastq",
                arguments: try fastqArguments(
                    for: request,
                    inputURLs: inputURLs,
                    outputTarget: outputTargetPath,
                    pairingArguments: Self.pairingArguments(
                        for: resolvedPairingMode,
                        verifiedAgainst: inputURLs.first,
                        metadataFrom: pairingMetadataURL ?? inputURLs.first
                    )
                )
            )

        case .ontFluidigmSampleSplit(let inputFASTQURL, let barcodeDefinitionsURL, let threads):
            return FASTQCLIInvocation(
                subcommand: "fastq",
                arguments: [
                    "ont-fluidigm-samples",
                    inputFASTQURL.path,
                    "--barcodes", barcodeDefinitionsURL.path,
                    "--output", outputTargetPath,
                    "--threads", String(threads),
                ]
            )

        case .ontPacBioBarcodeDemux(
            let inputFASTQURL,
            let barcodeDefinitionsURL,
            let threads,
            let chunkJobs,
            let maxReadsPerSlice,
            let maxBytesPerCutadapt
        ):
            return FASTQCLIInvocation(
                subcommand: "fastq",
                arguments: [
                    "ont-pacbio-barcode-demux",
                    inputFASTQURL.path,
                    "--barcodes", barcodeDefinitionsURL.path,
                    "--output", outputTargetPath,
                    "--threads", String(threads),
                    "--chunk-jobs", String(chunkJobs),
                    "--max-reads-per-slice", String(maxReadsPerSlice),
                    "--max-bytes-per-cutadapt", String(maxBytesPerCutadapt),
                ]
            )

        case .map(let inputURLs, let referenceURL, _):
            var arguments = inputURLs.map(\.path)
            arguments += ["--reference", referenceURL.path]
            if inputURLs.count == 2 {
                arguments.append("--paired")
            }
            return FASTQCLIInvocation(subcommand: "map", arguments: arguments)

        case .assemble(let request, _):
            let executionRequest = request.normalizedForExecution()
            var arguments = executionRequest.inputURLs.map(\.path)
            if executionRequest.pairedEnd {
                arguments.append("--paired")
            }
            arguments += [
                "--assembler", executionRequest.tool.rawValue,
                "--read-type", executionRequest.readType.cliArgument,
                "--project-name", executionRequest.projectName,
                "--threads", "\(executionRequest.threads)",
                "--output", outputTargetPath,
            ]
            if let memoryGB = executionRequest.memoryGB {
                arguments += ["--memory-gb", "\(memoryGB)"]
            }
            if let minContigLength = executionRequest.effectiveMinContigLength {
                arguments += ["--min-contig-length", "\(minContigLength)"]
            }
            if let selectedProfileID = executionRequest.selectedProfileID {
                arguments += ["--profile", selectedProfileID]
            }
            if !executionRequest.extraArguments.isEmpty {
                arguments += ["--extra-args", AdvancedCommandLineOptions.join(executionRequest.extraArguments)]
            }
            return FASTQCLIInvocation(subcommand: "assemble", arguments: arguments)

        case .classify(let tool, let inputURLs, let databaseName, let extraArguments):
            var arguments = inputURLs.map(\.path) + ["--db", databaseName]
            if !extraArguments.isEmpty {
                arguments += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
            }
            switch tool {
            case .kraken2:
                return FASTQCLIInvocation(subcommand: "conda classify", arguments: arguments)
            case .esViritu:
                return FASTQCLIInvocation(subcommand: "esviritu", arguments: ["detect"] + arguments)
            case .taxTriage:
                return FASTQCLIInvocation(subcommand: "taxtriage", arguments: ["run"] + arguments)
            default:
                return FASTQCLIInvocation(subcommand: "conda classify", arguments: arguments)
            }

        case .pbaa(let request):
            let outputDirectoryPath = outputTargetPath == "<derived>"
                ? request.outputDirectory.path
                : outputTargetPath
            var arguments = [
                "pbaa-cluster",
                request.inputFASTQURL.path,
                "--guide", request.guideSourceURL.path,
                "--output-dir", outputDirectoryPath,
                "--output-name", request.outputName,
                "--threads", String(request.threads),
                "--seed", String(request.seed),
            ]
            if !request.extraArgumentsText.isEmpty {
                arguments += ["--extra-args", request.extraArgumentsText]
            }
            return FASTQCLIInvocation(subcommand: "fastq", arguments: arguments)

        case .savont(let request):
            guard let inputURL = request.inputURLs.first else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "Savont clustering requires one FASTQ input per CLI invocation."
                ])
            }
            var arguments = [
                "savont-cluster", inputURL.path,
                "--output", outputTargetPath,
                "--threads", String(request.threads),
                "--quality-value-cutoff", String(request.qualityValueCutoff),
                "--min-cluster-size", String(request.minimumClusterSize),
            ]
            if let minimumReadLength = request.minimumReadLength {
                arguments += ["--min-read-length", String(minimumReadLength)]
            }
            if let maximumReadLength = request.maximumReadLength {
                arguments += ["--max-read-length", String(maximumReadLength)]
            }
            if request.singleStrand {
                arguments.append("--single-strand")
            }
            return FASTQCLIInvocation(subcommand: "fastq", arguments: arguments)

        case .ontGenotyping(let request):
            let outputDirectoryPath = outputTargetPath == "<derived>"
                ? request.outputDirectory.path
                : outputTargetPath
            var arguments = ["genotype"] + request.inputFASTQURLs.map(\.path)
            arguments += [
                "--mode", request.mode.cliArgument,
                "--read-type", request.readType.cliArgument,
                "--reference", request.referenceSourceURL.path,
                "--output-dir", outputDirectoryPath,
                "--output-name", request.outputName,
                "--analysis-name", request.analysisName,
                "--threads", String(request.threads),
                "--sort-threads", String(request.sortThreads),
                "--min-support", String(request.minSupport),
            ]
            request.appendHaplotypeThresholdArguments(to: &arguments)
            if let barcodeDefinitionsURL = request.barcodeDefinitionsURL {
                arguments += ["--barcodes", barcodeDefinitionsURL.path]
            }
            if let demuxManifestURL = request.demuxManifestURL {
                arguments += ["--demux-manifest", demuxManifestURL.path]
            }
            if let haplotypeDefinitionSetID = request.haplotypeDefinitionSetID {
                if let haplotypeAssayID = request.haplotypeAssayID {
                    arguments += ["--haplotype-assay", haplotypeAssayID]
                }
                if let haplotypeSpeciesCode = request.haplotypeSpeciesCode {
                    arguments += ["--haplotype-species", haplotypeSpeciesCode]
                }
                if let haplotypeDefinitionScope = request.haplotypeDefinitionScope {
                    arguments += ["--haplotype-definition-scope", haplotypeDefinitionScope.rawValue]
                }
                arguments += ["--haplotype-definition", haplotypeDefinitionSetID]
            }
            if let projectURL = request.projectURL {
                arguments += ["--project", projectURL.path]
            }
            if !request.extraArguments.isEmpty {
                arguments += ["--extra-args", AdvancedCommandLineOptions.join(request.extraArguments)]
            }
            return FASTQCLIInvocation(subcommand: "fastq", arguments: arguments)
        }
    }

    private func qualityTrimModeArgument(for mode: FASTQQualityTrimMode) -> String {
        switch mode {
        case .cutRight:
            return "cut-right"
        case .cutFront:
            return "cut-front"
        case .cutTail:
            return "cut-tail"
        case .cutBoth:
            return "cut-both"
        }
    }

    private func sequenceSearchEndArgument(for searchEnd: FASTQAdapterSearchEnd) -> String {
        switch searchEnd {
        case .fivePrime:
            return "left"
        case .threePrime:
            return "right"
        }
    }

    private func fastqArguments(
        for request: FASTQDerivativeRequest,
        inputURLs: [URL],
        outputTarget: String,
        pairingArguments: [String]
    ) throws -> [String] {
        guard let inputURL = inputURLs.first else {
            return ["qc-summary", "--output", outputTarget]
        }

        switch request {
        case .subsampleProportion(let proportion):
            return ["subsample", inputURL.path, "--proportion", String(proportion)] + pairingArguments + ["-o", outputTarget]
        case .subsampleCount(let count):
            return ["subsample", inputURL.path, "--count", "\(count)"] + pairingArguments + ["-o", outputTarget]
        case .lengthFilter(let min, let max):
            var arguments = ["length-filter", inputURL.path]
            if let min { arguments += ["--min", "\(min)"] }
            if let max { arguments += ["--max", "\(max)"] }
            arguments += ["-o", outputTarget]
            return arguments
        case .searchText(let query, let field, let regex):
            var arguments = ["search-text", inputURL.path, "--query", query, "--field", field.rawValue]
            if regex { arguments.append("--regex") }
            arguments += pairingArguments
            arguments += ["-o", outputTarget]
            return arguments
        case .searchMotif(let pattern, let regex):
            var arguments = ["search-motif", inputURL.path, "--pattern", pattern]
            if regex { arguments.append("--regex") }
            arguments += pairingArguments
            arguments += ["-o", outputTarget]
            return arguments
        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            var arguments = ["deduplicate", inputURL.path, "--subs", "\(substitutions)"] + pairingArguments + ["-o", outputTarget]
            if optical { arguments += ["--optical", "--dupedist", "\(opticalDistance)"] }
            _ = preset
            return arguments
        case .fastpTrim(let threshold, let windowSize, let mode, let adapterMode, let adapterSequence):
            var arguments = [
                "trim", inputURL.path,
                "--threshold", "\(threshold)",
                "--window", "\(windowSize)",
                "--mode", qualityTrimModeArgument(for: mode),
            ]
            switch adapterMode {
            case .autoDetect:
                arguments.append("--adapter-trimming")
            case .specified:
                guard let adapterSequence else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                        "manual adapter mode requires a literal adapter sequence"
                    )
                }
                arguments += ["--adapter-trimming", "--adapter", adapterSequence]
            case .fastaFile:
                throw FASTQOperationExecutionError.unsupportedAdapterTrim("fastaFile mode is not encodable")
            }
            arguments += ["-o", outputTarget]
            return arguments
        case .qualityTrim(let threshold, let windowSize, let mode, let extraArguments):
            var arguments = [
                "quality-trim", inputURL.path,
                "--threshold", "\(threshold)",
                "--window", "\(windowSize)",
                "--mode", qualityTrimModeArgument(for: mode),
                "-o", outputTarget,
            ]
            if !extraArguments.isEmpty {
                arguments += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
            }
            return arguments
        case .adapterTrim(let mode, let sequence, let sequenceR2, let fastaFilename):
            guard sequenceR2 == nil, fastaFilename == nil else {
                throw FASTQOperationExecutionError.unsupportedAdapterTrim("sequenceR2 and fastaFilename are not encodable")
            }
            var arguments = ["adapter-trim", inputURL.path]
            switch mode {
            case .autoDetect:
                guard sequence == nil else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                        "auto-detect cannot carry a literal adapter sequence"
                    )
                }
            case .specified:
                guard let sequence else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim(
                        "manual adapter mode requires a literal adapter sequence"
                    )
                }
                arguments += ["--adapter", sequence]
            case .fastaFile:
                throw FASTQOperationExecutionError.unsupportedAdapterTrim("fastaFile mode is not encodable")
            }
            arguments += ["-o", outputTarget]
            return arguments
        case .fixedTrim(let from5Prime, let from3Prime):
            var arguments = ["fixed-trim", inputURL.path]
            if from5Prime > 0 { arguments += ["--front", "\(from5Prime)"] }
            if from3Prime > 0 { arguments += ["--tail", "\(from3Prime)"] }
            arguments += ["-o", outputTarget]
            return arguments
        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            var arguments = [
                "contaminant-filter", inputURL.path,
                "--mode", mode.rawValue,
                "--kmer", "\(kmerSize)",
                "--hdist", "\(hammingDistance)",
            ] + pairingArguments + ["-o", outputTarget]
            if let referenceFasta {
                arguments.insert(contentsOf: ["--ref", referenceFasta], at: 4)
            }
            return arguments
        case .lowComplexityFilter(let entropy, let window, let kmer):
            return [
                "entropy-filter", inputURL.path,
                "--entropy", FASTQDerivativeRequest.entropyArgument(entropy),
                "--window", "\(window)",
                "--kmer", "\(kmer)",
            ] + pairingArguments + ["-o", outputTarget]
        case .pairedEndMerge(let strictness, let minOverlap):
            var arguments = ["merge", inputURL.path, "--min-overlap", "\(minOverlap)", "-o", outputTarget]
            if strictness == .strict { arguments.append("--strict") }
            arguments.append("--count-duplicates")
            return arguments
        case .pairedEndRepair:
            return ["repair", inputURL.path, "-o", outputTarget]
        case .reverseComplement:
            return ["reverse-complement", inputURL.path, "-o", outputTarget]
        case .translate(let frameOffset):
            return ["translate", inputURL.path, "--frame", "\(frameOffset + 1)", "-o", outputTarget]
        case .primerRemoval(let configuration):
            if configuration.tool == .cutadapt {
                guard configuration.source == .reference,
                      configuration.readMode == .single,
                      configuration.mode == .linked,
                      let referenceFasta = configuration.referenceFasta
                else {
                    throw FASTQOperationExecutionError.unsupportedPrimerRemoval(
                        "only reference cutadapt linked primer trimming is encodable"
                    )
                }
                return [
                    "primer-remove",
                    inputURL.path,
                    "--ref", referenceFasta,
                    "--engine", "cutadapt-linked",
                    "--minimum-overlap", "\(configuration.minimumOverlap)",
                    "--error-rate", String(format: "%.2f", configuration.errorRate),
                    "-o", outputTarget,
                ]
            }
            guard configuration.readMode == .single,
                  configuration.mode == .fivePrime,
                  configuration.anchored5Prime,
                  configuration.anchored3Prime,
                  configuration.errorRate == 0.12,
                  configuration.minimumOverlap == 12,
                  configuration.allowIndels,
                  !configuration.keepUntrimmed,
                  configuration.searchReverseComplement,
                  configuration.pairFilter == .any,
                  configuration.ktrimDirection == .left
            else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval(
                    "only the literal/reference bbduk subset with the default read-mode flags is encodable"
                )
            }
            var arguments = ["primer-remove", inputURL.path]
            if let sequence = configuration.forwardSequence, configuration.source == .literal {
                arguments += ["--literal", sequence]
            } else if let referenceFasta = configuration.referenceFasta, configuration.source == .reference {
                arguments += ["--ref", referenceFasta]
            } else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval(
                    "literal and reference primer inputs must match the selected source"
                )
            }
            arguments += [
                "--kmer", "\(configuration.kmerSize)",
                "--mink", "\(configuration.minKmer)",
                "--hdist", "\(configuration.hammingDistance)",
                "-o", outputTarget,
            ]
            return arguments
        case .sequencePresenceFilter(
            let sequence,
            let fastaPath,
            let searchEnd,
            let minOverlap,
            let errorRate,
            let keepMatched,
            let searchReverseComplement
        ):
            var arguments = [
                "sequence-filter", inputURL.path,
                "--search-end", sequenceSearchEndArgument(for: searchEnd),
                "--min-overlap", "\(minOverlap)",
                "--error-rate", String(format: "%.2f", errorRate),
                "-o", outputTarget,
            ]
            if let sequence {
                arguments += ["--sequence", sequence]
            } else if let fastaPath {
                arguments += ["--fasta-path", fastaPath]
            }
            if keepMatched { arguments.append("--keep-matched") }
            if searchReverseComplement { arguments.append("--search-rc") }
            arguments += pairingArguments
            return arguments
        case .errorCorrection(let kmerSize):
            return ["error-correct", inputURL.path, "--kmer", "\(kmerSize)", "-o", outputTarget]
        case .interleaveReformat(let direction):
            switch direction {
            case .interleave:
                return ["interleave", "--in1", inputURL.path, "--in2", "<R2>", "-o", outputTarget]
            case .deinterleave:
                return [
                    "deinterleave", inputURL.path,
                    "--out1", "\(outputTarget).R1.fastq",
                    "--out2", "\(outputTarget).R2.fastq",
                ]
            }
        case .demultiplex(
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
        ):
            guard sampleAssignments?.isEmpty ?? true else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex("sampleAssignments are not encodable")
            }
            guard symmetryMode == nil else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex("symmetryMode is not encodable")
            }
            guard kitOverride == nil else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex("kitOverride is not encodable")
            }
            if engine == .exactBareBarcode {
                return [
                    "demultiplex", inputURL.path,
                    "--kit", customCSVPath ?? kitID,
                    "-o", outputTarget,
                    "--engine", engine.rawValue,
                ]
            }
            var arguments = [
                "demultiplex", inputURL.path,
                "--kit", customCSVPath ?? kitID,
                "-o", outputTarget,
                "--location", location,
                "--max-distance-5prime", "\(maxDistanceFrom5Prime)",
                "--max-distance-3prime", "\(maxDistanceFrom3Prime)",
                "--error-rate", String(format: "%.2f", errorRate),
                "--engine", engine.rawValue,
            ]
            if !trimBarcodes { arguments.append("--no-trim") }
            return arguments
        case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented, let extraArguments):
            guard !saveUnoriented else {
                throw FASTQOperationExecutionError.unsupportedOrient("saveUnoriented is not encodable")
            }
            var arguments = [
                "orient", inputURL.path,
                "--reference", referenceURL.path,
                "--word-length", "\(wordLength)",
                "--db-mask", dbMask,
                "-o", outputTarget,
            ]
            if !extraArguments.isEmpty {
                arguments += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
            }
            return arguments
        case .humanReadScrub(let databaseID, _):
            return ["scrub-human", inputURL.path, "--database-id", databaseID] + pairingArguments + ["-o", outputTarget]
        case .ribosomalRNAFilter(let retention, _):
            return [
                "deacon-ribo", inputURL.path,
                "--database-id", DeaconRibokmersDatabaseInstaller.databaseID,
                "--retain", retention.rawValue,
            ] + pairingArguments + ["-o", outputTarget]
        }
    }
}
