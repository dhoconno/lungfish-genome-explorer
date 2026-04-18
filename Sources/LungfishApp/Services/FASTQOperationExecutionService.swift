import Foundation
import LungfishIO

struct CLIInvocation: Sendable, Equatable {
    let subcommand: String
    let arguments: [String]
}

enum FASTQOperationExecutionError: Error, LocalizedError {
    case unsupportedAdapterTrim(String)
    case unsupportedPrimerRemoval(String)
    case unsupportedDemultiplex(String)
    case unsupportedOrient(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAdapterTrim(let reason):
            return "FASTQ adapter trimming request is not supported by the CLI builder: \(reason)"
        case .unsupportedPrimerRemoval(let reason):
            return "FASTQ primer trimming request is not supported by the CLI builder: \(reason)"
        case .unsupportedDemultiplex(let reason):
            return "FASTQ demultiplex request is not supported by the CLI builder: \(reason)"
        case .unsupportedOrient(let reason):
            return "FASTQ orient request is not supported by the CLI builder: \(reason)"
        }
    }
}

struct FASTQOperationExecutionService {
    func buildInvocation(for request: FASTQOperationLaunchRequest) throws -> CLIInvocation {
        switch request {
        case .refreshQCSummary(let inputURLs):
            return CLIInvocation(
                subcommand: "fastq",
                arguments: ["qc-summary"] + inputURLs.map(\.path) + ["--output", derivedOutputPlaceholder]
            )

        case .derivative(let request, let inputURLs, _):
            return CLIInvocation(subcommand: "fastq", arguments: try fastqArguments(for: request, inputURLs: inputURLs))

        case .map(let inputURLs, let referenceURL, _):
            var arguments = inputURLs.map(\.path)
            arguments += ["--reference", referenceURL.path]
            if inputURLs.count == 2 {
                arguments.append("--paired")
            }
            return CLIInvocation(subcommand: "map", arguments: arguments)

        case .assemble(let inputURLs, _):
            var arguments = inputURLs.map(\.path)
            if inputURLs.count == 2 {
                arguments.append("--paired")
            }
            return CLIInvocation(subcommand: "assemble", arguments: arguments)

        case .classify(let tool, let inputURLs, let databaseName):
            let arguments = inputURLs.map(\.path) + ["--db", databaseName]
            switch tool {
            case .kraken2:
                return CLIInvocation(subcommand: "classify", arguments: arguments)
            case .esViritu:
                return CLIInvocation(subcommand: "esviritu", arguments: ["detect"] + arguments)
            case .taxTriage:
                return CLIInvocation(subcommand: "taxtriage", arguments: ["run"] + arguments)
            default:
                return CLIInvocation(subcommand: "classify", arguments: arguments)
            }
        }
    }

    private var derivedOutputPlaceholder: String {
        "<derived>"
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

    private func fastqArguments(for request: FASTQDerivativeRequest, inputURLs: [URL]) throws -> [String] {
        guard let inputURL = inputURLs.first else {
            return ["qc-summary", "--output", derivedOutputPlaceholder]
        }

        switch request {
        case .subsampleProportion(let proportion):
            return [
                "subsample",
                inputURL.path,
                "--proportion",
                String(proportion),
                "-o",
                derivedOutputPlaceholder,
            ]

        case .subsampleCount(let count):
            return [
                "subsample",
                inputURL.path,
                "--count",
                "\(count)",
                "-o",
                derivedOutputPlaceholder,
            ]

        case .lengthFilter(let min, let max):
            var arguments = ["length-filter", inputURL.path]
            if let min {
                arguments += ["--min", "\(min)"]
            }
            if let max {
                arguments += ["--max", "\(max)"]
            }
            arguments += ["-o", derivedOutputPlaceholder]
            return arguments

        case .searchText(let query, let field, let regex):
            var arguments = [
                "search-text",
                inputURL.path,
                "--query",
                query,
                "--field",
                field.rawValue,
            ]
            if regex {
                arguments.append("--regex")
            }
            arguments += ["-o", derivedOutputPlaceholder]
            return arguments

        case .searchMotif(let pattern, let regex):
            var arguments = [
                "search-motif",
                inputURL.path,
                "--pattern",
                pattern,
            ]
            if regex {
                arguments.append("--regex")
            }
            arguments += ["-o", derivedOutputPlaceholder]
            return arguments

        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            var arguments = [
                "deduplicate",
                inputURL.path,
                "--subs",
                "\(substitutions)",
                "-o",
                derivedOutputPlaceholder,
            ]
            if optical {
                arguments += ["--optical", "--dupedist", "\(opticalDistance)"]
            }
            _ = preset
            return arguments

        case .qualityTrim(let threshold, let windowSize, let mode):
            return [
                "quality-trim",
                inputURL.path,
                "--threshold",
                "\(threshold)",
                "--window",
                "\(windowSize)",
                "--mode",
                qualityTrimModeArgument(for: mode),
                "-o",
                derivedOutputPlaceholder,
            ]

        case .adapterTrim(let mode, let sequence, let sequenceR2, let fastaFilename):
            guard sequenceR2 == nil, fastaFilename == nil else {
                throw FASTQOperationExecutionError.unsupportedAdapterTrim("sequenceR2 and fastaFilename are not encodable")
            }
            var arguments = ["adapter-trim", inputURL.path]
            switch mode {
            case .autoDetect:
                guard sequence == nil else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim("auto-detect cannot carry a literal adapter sequence")
                }
            case .specified:
                guard let sequence else {
                    throw FASTQOperationExecutionError.unsupportedAdapterTrim("manual adapter mode requires a literal adapter sequence")
                }
                arguments += ["--adapter", sequence]
            case .fastaFile:
                throw FASTQOperationExecutionError.unsupportedAdapterTrim("fastaFile mode is not encodable")
            }
            arguments += ["-o", derivedOutputPlaceholder]
            return arguments

        case .fixedTrim(let from5Prime, let from3Prime):
            var arguments = ["fixed-trim", inputURL.path]
            if from5Prime > 0 {
                arguments += ["--front", "\(from5Prime)"]
            }
            if from3Prime > 0 {
                arguments += ["--tail", "\(from3Prime)"]
            }
            arguments += ["-o", derivedOutputPlaceholder]
            return arguments

        case .contaminantFilter(let mode, let referenceFasta, let kmerSize, let hammingDistance):
            var arguments = [
                "contaminant-filter",
                inputURL.path,
                "--mode",
                mode.rawValue,
                "--kmer",
                "\(kmerSize)",
                "--hdist",
                "\(hammingDistance)",
                "-o",
                derivedOutputPlaceholder,
            ]
            if let referenceFasta {
                arguments.insert(contentsOf: ["--ref", referenceFasta], at: 4)
            }
            return arguments

        case .pairedEndMerge(let strictness, let minOverlap):
            var arguments = [
                "merge",
                inputURL.path,
                "--min-overlap",
                "\(minOverlap)",
                "-o",
                derivedOutputPlaceholder,
            ]
            if strictness == .strict {
                arguments.append("--strict")
            }
            return arguments

        case .pairedEndRepair:
            return [
                "repair",
                inputURL.path,
                "-o",
                derivedOutputPlaceholder,
            ]

        case .primerRemoval(let configuration):
            guard configuration.tool == .bbduk else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval("only the bbduk subset is encodable")
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
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval("only the literal/reference bbduk subset with the default read-mode flags is encodable")
            }
            var arguments = ["primer-remove", inputURL.path]
            if let sequence = configuration.forwardSequence, configuration.source == .literal {
                arguments += ["--literal", sequence]
            } else if let referenceFasta = configuration.referenceFasta, configuration.source == .reference {
                arguments += ["--ref", referenceFasta]
            } else {
                throw FASTQOperationExecutionError.unsupportedPrimerRemoval("literal and reference primer inputs must match the selected source")
            }
            arguments += [
                "--kmer",
                "\(configuration.kmerSize)",
                "--mink",
                "\(configuration.minKmer)",
                "--hdist",
                "\(configuration.hammingDistance)",
            ]
            arguments += ["-o", derivedOutputPlaceholder]
            return arguments

        case .sequencePresenceFilter(let sequence, let fastaPath, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchReverseComplement):
            var arguments = [
                "sequence-filter",
                inputURL.path,
                "--search-end",
                sequenceSearchEndArgument(for: searchEnd),
                "--min-overlap",
                "\(minOverlap)",
                "--error-rate",
                String(format: "%.2f", errorRate),
                "-o",
                derivedOutputPlaceholder,
            ]
            if let sequence {
                arguments += ["--sequence", sequence]
            } else if let fastaPath {
                arguments += ["--fasta-path", fastaPath]
            }
            if keepMatched {
                arguments.append("--keep-matched")
            }
            if searchReverseComplement {
                arguments.append("--search-rc")
            }
            return arguments

        case .errorCorrection(let kmerSize):
            return [
                "error-correct",
                inputURL.path,
                "--kmer",
                "\(kmerSize)",
                "-o",
                derivedOutputPlaceholder,
            ]

        case .interleaveReformat(let direction):
            switch direction {
            case .interleave:
                return [
                    "interleave",
                    "--in1",
                    inputURL.path,
                    "--in2",
                    "<R2>",
                    "-o",
                    derivedOutputPlaceholder,
                ]
            case .deinterleave:
                return [
                    "deinterleave",
                    inputURL.path,
                    "--out1",
                    "\(derivedOutputPlaceholder).R1.fastq",
                    "--out2",
                    "\(derivedOutputPlaceholder).R2.fastq",
                ]
            }

        case .demultiplex(let kitID, let customCSVPath, let location, let symmetryMode, let maxDistanceFrom5Prime, let maxDistanceFrom3Prime, let errorRate, let trimBarcodes, let sampleAssignments, let kitOverride):
            guard sampleAssignments?.isEmpty ?? true else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex("sampleAssignments are not encodable")
            }
            guard symmetryMode == nil else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex("symmetryMode is not encodable")
            }
            guard kitOverride == nil else {
                throw FASTQOperationExecutionError.unsupportedDemultiplex("kitOverride is not encodable")
            }
            var arguments = [
                "demultiplex",
                inputURL.path,
                "--kit",
                customCSVPath ?? kitID,
                "-o",
                derivedOutputPlaceholder,
                "--location",
                location,
                "--max-distance-5prime",
                "\(maxDistanceFrom5Prime)",
                "--max-distance-3prime",
                "\(maxDistanceFrom3Prime)",
                "--error-rate",
                String(format: "%.2f", errorRate),
            ]
            if !trimBarcodes {
                arguments.append("--no-trim")
            }
            return arguments

        case .orient(let referenceURL, let wordLength, let dbMask, let saveUnoriented):
            guard !saveUnoriented else {
                throw FASTQOperationExecutionError.unsupportedOrient("saveUnoriented is not encodable")
            }
            return [
                "orient",
                inputURL.path,
                "--reference",
                referenceURL.path,
                "--word-length",
                "\(wordLength)",
                "--db-mask",
                dbMask,
                "-o",
                derivedOutputPlaceholder,
            ]

        case .humanReadScrub(let databaseID, _):
            return [
                "scrub-human",
                inputURL.path,
                "--database-id",
                databaseID,
                "-o",
                derivedOutputPlaceholder,
            ]
        }
    }
}
