import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct FastqTwelveSMatchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "12s-match",
        abstract: "Match merged 12S amplicon FASTQ reads to a deduplicated reference FASTA"
    )

    @Argument(help: "Merged FASTQ input file(s), plain or gzip-compressed")
    var inputs: [String]

    @Option(name: .customLong("reference"), help: "Deduplicated 12S reference FASTA or .lungfish12sref bundle")
    var reference: String

    @Option(name: .customLong("reference-metadata"), help: "Optional 12S target metadata TSV from 12s-reference-metadata")
    var referenceMetadata: String?

    @Option(name: .customLong("sample-metadata"), help: "Optional CSV/TSV sample metadata to freeze into the 12S result")
    var sampleMetadata: String?

    @Option(name: .customLong("output-dir"), help: "Directory where the .lungfish12s bundle will be written")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Output bundle basename")
    var outputName: String

    @Option(name: .customLong("min-soft-clip"), help: "Minimum read bases required before and after the matched target")
    var minimumSoftClipBases: Int = 1

    @Option(name: .customLong("max-indels"), help: "Maximum insertion/deletion edit count allowed for exact no-substitution matching")
    var maximumIndelBases: Int = 3

    @Option(
        name: .customLong("matching-mode"),
        help: "12S matching mode: 'illumina-exact' (exact embedded reference matches only; default) or 'ont-indel' (allow indel-only fallback)."
    )
    var matchingMode: String = TwelveSAmpliconMatchingMode.illuminaExact.rawValue

    @Flag(
        name: .customLong("chimera-review"),
        inversion: .prefixedNo,
        help: "Run vsearch chimera review on unresolved sequences"
    )
    var chimeraReview: Bool = true

    @Flag(name: .customLong("force"), help: "Replace an existing output bundle")
    var force: Bool = false

    @Option(
        name: .customLong("ambiguity-resolution"),
        help: "How cross-species identical-sequence reads are resolved: 'strict' (any nonzero abundance lead wins; default) or 'conservative' (winner must have >=2x the runner-up and >=10 reads)."
    )
    var ambiguityResolution: String = "strict"

    /// Maps the flag to a reassignment policy.
    var resolutionPolicy: TwelveSAbundanceReassigner.ResolutionPolicy {
        switch ambiguityResolution.lowercased() {
        case "conservative": return .conservative(minFoldRatio: 2.0, absoluteFloor: 10)
        default: return .anyNonzeroLead
        }
    }

    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        guard !inputs.isEmpty else {
            throw ValidationError("At least one merged FASTQ input is required.")
        }
        guard minimumSoftClipBases >= 0 else {
            throw ValidationError("--min-soft-clip must be greater than or equal to 0.")
        }
        guard maximumIndelBases >= 0 else {
            throw ValidationError("--max-indels must be greater than or equal to 0.")
        }
        guard TwelveSAmpliconMatchingMode.cliValue(matchingMode) != nil else {
            throw ValidationError("--matching-mode must be 'illumina-exact' or 'ont-indel'.")
        }
        guard ["strict", "conservative"].contains(ambiguityResolution.lowercased()) else {
            throw ValidationError("--ambiguity-resolution must be 'strict' or 'conservative'.")
        }
        guard globalOptions.threads.map({ $0 > 0 }) ?? true else {
            throw ValidationError("--threads must be positive.")
        }
    }

    func run() async throws {
        let result = try await TwelveSAmpliconMatchingWorkflow().run(
            try configurationForTesting(),
            progressHandler: { fraction, message in
                FileHandle.standardError.write(Data(Self.progressLine(fraction: fraction, message: message).utf8))
            }
        )
        FileHandle.standardError.write(Data("12S amplicon result bundle written to \(result.bundleURL.path)\n".utf8))
    }

    func configurationForTesting() throws -> TwelveSAmpliconMatchingConfiguration {
        let referenceURL = URL(fileURLWithPath: reference)
        let resolvedReference = try Self.resolveReference(
            referenceURL: referenceURL,
            explicitMetadata: referenceMetadata.map { URL(fileURLWithPath: $0) }
        )
        return TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: inputs.map { URL(fileURLWithPath: $0) },
            referenceFASTA: resolvedReference.fasta,
            referenceMetadata: resolvedReference.metadata,
            referenceBundleURL: resolvedReference.bundle,
            sampleMetadata: sampleMetadata.map { URL(fileURLWithPath: $0) },
            outputDirectory: URL(fileURLWithPath: outputDir),
            outputName: outputName,
            minimumSoftClipBases: minimumSoftClipBases,
            maximumIndelBases: maximumIndelBases,
            matchingMode: TwelveSAmpliconMatchingMode.cliValue(matchingMode) ?? .illuminaExact,
            threads: max(1, globalOptions.threads ?? ProcessInfo.processInfo.activeProcessorCount),
            runChimeraReview: chimeraReview,
            forceOverwrite: force,
            ambiguityResolution: resolutionPolicy,
            argv: replayArgv()
        )
    }

    private static func resolveReference(
        referenceURL: URL,
        explicitMetadata: URL?
    ) throws -> (fasta: URL, metadata: URL?, bundle: URL?) {
        let standardizedURL = referenceURL.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == TwelveSReferenceBundle.directoryExtension else {
            return (standardizedURL, explicitMetadata?.standardizedFileURL, nil)
        }
        guard let fasta = TwelveSReferenceBundle.referenceFASTAURL(in: standardizedURL) else {
            throw ValidationError("12S reference bundle is missing its reference FASTA: \(standardizedURL.path)")
        }
        let bundledMetadata = TwelveSReferenceBundle.targetMetadataURL(in: standardizedURL)
        return (fasta, explicitMetadata?.standardizedFileURL ?? bundledMetadata, standardizedURL)
    }

    private func replayArgv() -> [String] {
        var argv = [CLICommandIdentity.executableName, "fastq", "12s-match"] + inputs
        argv += ["--reference", reference]
        if let referenceMetadata {
            argv += ["--reference-metadata", referenceMetadata]
        }
        if let sampleMetadata {
            argv += ["--sample-metadata", sampleMetadata]
        }
        argv += ["--output-dir", outputDir]
        argv += ["--output-name", outputName]
        if minimumSoftClipBases != 1 {
            argv += ["--min-soft-clip", String(minimumSoftClipBases)]
        }
        if maximumIndelBases != 3 {
            argv += ["--max-indels", String(maximumIndelBases)]
        }
        let resolvedMatchingMode = TwelveSAmpliconMatchingMode.cliValue(matchingMode) ?? .illuminaExact
        if resolvedMatchingMode != .illuminaExact {
            argv += ["--matching-mode", resolvedMatchingMode.rawValue]
        }
        if let threads = globalOptions.threads {
            argv += ["--threads", String(threads)]
        }
        if !chimeraReview {
            argv.append("--no-chimera-review")
        }
        if ambiguityResolution.lowercased() != "strict" {
            argv += ["--ambiguity-resolution", ambiguityResolution.lowercased()]
        }
        if force {
            argv.append("--force")
        }
        return argv
    }

    static func progressLine(fraction: Double, message: String) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        return String(format: "[%3d%%] %@\n", percent, message)
    }
}
