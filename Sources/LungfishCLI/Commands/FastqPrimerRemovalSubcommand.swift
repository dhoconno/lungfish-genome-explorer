// FastqPrimerRemovalSubcommand.swift - Remove primer sequences from FASTQ reads
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Primer Removal

struct FastqPrimerRemovalSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "primer-remove",
        abstract: "Remove primer sequences from FASTQ reads",
        discussion: """
        The bbduk engine trims a 5' primer and every base before it. It counts \
        a match only when the match ends within the first (longest primer + 67) \
        bases of a read, so a primer behind an untrimmed Nanopore adapter and \
        barcode is found and a primer deeper in the read is not. It matches \
        each primer only as written, so a primer that a read runs through at \
        its 3' end stays. The cutadapt-linked engine keeps only reads that hold \
        both primers of an amplicon, which suits full-length amplicon reads. \
        Interleaved pairs run in the tool's paired mode, so a pair is kept or \
        dropped whole. A file that mixes pairs with merged or single reads is \
        split by name, and the outputs are joined, pairs first.
        """
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("literal"), help: "Primer sequence (bbduk refuses IUPAC ambiguity codes such as R and S)")
    var literalSequence: String?

    @Option(name: .customLong("ref"), help: "Primer reference FASTA file")
    var reference: String?

    @Option(name: .customLong("kmer"), help: "K-mer size (default: 23)")
    var kmerSize: Int = 23

    @Option(name: .customLong("mink"), help: "Minimum k-mer size (default: 11)")
    var minKmer: Int = 11

    @Option(name: .customLong("hdist"), help: "Hamming distance tolerance (default: 1)")
    var hammingDistance: Int = 1

    @Option(name: .customLong("engine"), help: "Primer trimming engine: bbduk or cutadapt-linked")
    var engine: FastqPrimerRemovalEngine = .bbduk

    @Option(name: .customLong("minimum-overlap"), help: "Minimum overlap for cutadapt-linked primer matching")
    var minimumOverlap: Int = 12

    @Option(name: .customLong("error-rate"), help: "Maximum error rate for cutadapt-linked primer matching")
    var errorRate: Double = 0.12

    @OptionGroup var output: OutputOptions

    /// The bases a basecalled native-barcoded ONT read carries ahead of its
    /// insert: the Y-adapter, the outer flank, the 24-base barcode and the
    /// inner flank (`ONTNativeAdapterContext`), 67 bases in all.
    static let leadingAdapterAndBarcodeLength = PlatformAdapters.ontYAdapterTop.count
        + PlatformAdapters.ontNativeOuterFlank5.count
        + 24
        + PlatformAdapters.ontNativeBarcodeFlank5.count

    /// The bbduk `restrictleft` window: a primer is trimmed only when a
    /// matching k-mer ends within the leftmost this many bases.
    ///
    /// bbduk `ktrim=l` trims a match and every base to its left. Unlimited,
    /// it also trims at a primer of another amplicon inside a read, which a
    /// full-length read of a tiled scheme carries, and the read then loses
    /// everything before it. The window holds the longest primer behind the
    /// 67 bases of `leadingAdapterAndBarcodeLength`, so a primer at the start
    /// of a read and one behind an untrimmed ONT adapter and barcode are both
    /// found. The nearest internal primer of another amplicon in a
    /// full-length read starts at 151 bases or later in every bundled scheme
    /// except QIAseq DIRECT (lane A8 report).
    static func primerSearchWindow(longestPrimer: Int) -> Int {
        longestPrimer + leadingAdapterAndBarcodeLength
    }

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "primer-remove", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        guard kmerSize > 0 else { throw ValidationError("--kmer must be > 0") }
        guard minKmer > 0 else { throw ValidationError("--mink must be > 0") }
        guard minKmer <= kmerSize else {
            throw ValidationError("--mink (\(minKmer)) must be <= --kmer (\(kmerSize))")
        }
        guard hammingDistance >= 0 else { throw ValidationError("--hdist must be >= 0") }
        guard minimumOverlap > 0 else { throw ValidationError("--minimum-overlap must be > 0") }
        guard errorRate >= 0.0, errorRate <= 1.0 else {
            throw ValidationError("--error-rate must be between 0 and 1")
        }
        let runner = NativeToolRunner.shared

        let startedAt = Date()
        let referenceURL = reference.map { URL(fileURLWithPath: $0) }
        // Holds the linked primers the cutadapt engine writes.
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-cutadapt-linked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let toolArguments = try await primerRemovalArguments(stagingDirectory: stagingDirectory)

        // The command has no --pairing option, so it reads the layout from
        // the records by name, with the bundle's metadata as hints. Run per
        // record, a mate trimmed below the minimum length was dropped alone
        // and orphaned its partner. A strictly interleaved file now runs in
        // the tool's paired mode, so a pair is kept or dropped whole. A file
        // that mixes pairs with single reads is partitioned by name, its
        // pairs run paired and its single reads per record, and the two
        // outputs are joined, pairs first (FASTQSplitByNameRunner).
        let pairingDecision = FASTQPairingModeResolver.resolvePairing(
            inputURL: inputURL,
            pairsByName: true,
            metadataFrom: resolvedInput.pairingMetadataURL
        )
        let plan = try await Task.detached(priority: .utility) {
            try FastpReadLayoutPlan.resolve(inputURL: inputURL, decision: pairingDecision)
        }.value
        let tool = toolArguments.tool
        let environment: [String: String]? = tool == .bbduk ? await bbToolsEnvironment(runner: runner) : nil

        let nativeArguments: [String]
        let result: NativeToolResult
        var splitOutcome: FASTQSplitByNameRunner.Outcome?
        switch plan {
        case .singleEnd, .interleaved:
            nativeArguments = toolArguments.arguments(input: inputURL.path, output: output.output, paired: plan.isPaired)
            result = try await runner.run(tool, arguments: nativeArguments, environment: environment, timeout: 1800)
            guard result.isSuccess else {
                throw CLIError.conversionFailed(reason: "\(tool.rawValue) primer removal failed: \(result.stderr)")
            }
        case .splitMixed(let pairs, let unpaired):
            let outcome = try await FASTQSplitByNameRunner.run(
                inputURL: inputURL,
                outputPath: output.output,
                counts: FASTQPairInterleaver.MixedCounts(pairs: pairs, unpaired: unpaired),
                tool: tool,
                toolVersion: await runner.getToolVersion(tool) ?? "unknown",
                failureLabel: "\(tool.rawValue) primer removal",
                stepNamePrefix: "lungfish fastq primer-remove"
            ) { partInput, partOutput, paired in
                let partArguments = toolArguments.arguments(input: partInput.path, output: partOutput.path, paired: paired)
                return (
                    try await runner.run(tool, arguments: partArguments, environment: environment, timeout: 1800),
                    partArguments
                )
            }
            nativeArguments = outcome.pairedRun.arguments
            result = outcome.pairedRun.result
            splitOutcome = outcome
        }
        var cliArguments = ["primer-remove", resolvedInput.originalURL.path]
        if let literalSequence {
            cliArguments += ["--literal", literalSequence]
        }
        if let reference {
            cliArguments += ["--ref", reference]
        }
        if engine != .bbduk {
            cliArguments += ["--engine", engine.rawValue]
        }
        if kmerSize != 23 {
            cliArguments += ["--kmer", String(kmerSize)]
        }
        if minKmer != 11 {
            cliArguments += ["--mink", String(minKmer)]
        }
        if hammingDistance != 1 {
            cliArguments += ["--hdist", String(hammingDistance)]
        }
        if engine == .cutadaptLinked || minimumOverlap != 12 {
            cliArguments += ["--minimum-overlap", String(minimumOverlap)]
        }
        if engine == .cutadaptLinked || errorRate != 0.12 {
            cliArguments += ["--error-rate", String(errorRate)]
        }
        cliArguments += ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let outputURL = URL(fileURLWithPath: output.output)
        var parameters: [String: ParameterValue] = [
            "input": .file(resolvedInput.originalURL),
            "output": .file(outputURL),
            "literal": literalSequence.map(ParameterValue.string) ?? .null,
            "reference": reference.map { .file(URL(fileURLWithPath: $0)) } ?? .null,
            "kmer": .integer(kmerSize),
            "mink": .integer(minKmer),
            "hdist": .integer(hammingDistance),
            "engine": .string(engine.rawValue),
            "minimumOverlap": .integer(minimumOverlap),
            "errorRate": .number(errorRate),
            "force": .boolean(output.force),
            "compress": .boolean(output.compress)
        ]
        // A single-end run records the parameters it recorded before. A run
        // that kept mates together also records how.
        if plan.isPaired {
            parameters["readLayout"] = plan.provenanceValue
        }
        if let splitOutcome {
            parameters["pairs"] = .integer(splitOutcome.counts.pairs)
            parameters["unpairedReads"] = .integer(splitOutcome.counts.unpaired)
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq primer-remove",
            nativeTool: tool,
            cliArguments: cliArguments,
            nativeArguments: nativeArguments,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: parameters,
            defaults: [
                "literal": .null,
                "reference": .null,
                "kmer": .integer(23),
                "mink": .integer(11),
                "hdist": .integer(1),
                "engine": .string(FastqPrimerRemovalEngine.bbduk.rawValue),
                "minimumOverlap": .integer(12),
                "errorRate": .number(0.12),
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords()
                + (referenceURL.map { provenanceRecords(for: $0, format: .fasta, role: .reference) } ?? []),
            stepID: splitOutcome?.stepID ?? UUID(),
            stepInputs: splitOutcome?.stepInputs,
            stepOutputs: splitOutcome?.stepOutputs,
            extraSteps: (splitOutcome?.extraSteps ?? []) + (try resolvedInput.materializationSteps()),
            startedAt: startedAt
        )
        FileHandle.standardError.write(Data("Primer-trimmed reads written to \(output.output)\n".utf8))
    }

    /// The argv of one run of the selected engine, for a single-read input
    /// or a strictly interleaved one.
    struct ToolArguments: Sendable {
        enum Engine: Sendable {
            /// bbduk with `literal=` or `ref=` already formed.
            case bbduk(primers: String, kmerSize: Int, minKmer: Int, hammingDistance: Int, searchWindow: Int)
            /// cutadapt with the linked-adapter FASTA it reads.
            case cutadaptLinked(linkedPrimers: String, errorRate: Double, minimumOverlap: Int)
        }

        let engine: Engine

        var tool: NativeTool {
            switch engine {
            case .bbduk: return .bbduk
            case .cutadaptLinked: return .cutadapt
            }
        }

        func arguments(input: String, output: String, paired: Bool) -> [String] {
            switch engine {
            case .bbduk(let primers, let kmerSize, let minKmer, let hammingDistance, let searchWindow):
                // ktrim=l trims a 5' primer and the bases to its left, where
                // bbduk's guide puts 5' adapters. rcomp=f matches a primer
                // only as written: a 5' primer starts a read in its own
                // orientation, and a reverse-complement match left-trimmed a
                // read that ran through into the other end of its amplicon
                // down to the bases after that primer. restrictleft keeps
                // ktrim=l off a primer inside the read (primerSearchWindow).
                // interleaved= is stated either way. Paired, bbduk keeps or
                // drops both mates of a pair. Left to guess, it pairs /1 /2
                // names by position and aborts on an odd record count.
                return [
                    "in=\(input)",
                    "out=\(output)",
                    "ktrim=l",
                    "k=\(kmerSize)",
                    "mink=\(minKmer)",
                    "hdist=\(hammingDistance)",
                    "rcomp=f",
                    "restrictleft=\(searchWindow)",
                    paired ? "interleaved=t" : "interleaved=f",
                    primers,
                ]
            case .cutadaptLinked(let linkedPrimers, let errorRate, let minimumOverlap):
                // Paired, the same linked primers are searched in both mates
                // and --pair-filter any discards a pair when either mate lacks
                // a whole linked primer, so a pair survives exactly when the
                // per-record run kept both of its mates.
                let pairedArguments = paired ? ["--interleaved", "--pair-filter", "any"] : []
                let mateArguments = paired ? ["-G", "file:\(linkedPrimers)"] : []
                return pairedArguments + [
                    "-e", String(errorRate),
                    "-O", String(minimumOverlap),
                    "--discard-untrimmed",
                    "-g", "file:\(linkedPrimers)",
                ] + mateArguments + [
                    "-o", output,
                    input,
                ]
            }
        }
    }

    /// Validates the primer inputs of the selected engine and returns the
    /// arguments every run of it takes.
    private func primerRemovalArguments(stagingDirectory: URL) async throws -> ToolArguments {
        switch engine {
        case .bbduk:
            let primers: String
            let longestPrimer: Int
            if let literalSequence {
                primers = "literal=\(literalSequence)"
                // bbduk takes a comma-separated list of literals.
                longestPrimer = literalSequence.split(separator: Character(",")).map(\.count).max() ?? 0
            } else if let reference {
                guard FileManager.default.fileExists(atPath: reference) else {
                    throw CLIError.inputFileNotFound(path: reference)
                }
                primers = "ref=\(reference)"
                longestPrimer = try await FASTAReader(url: URL(fileURLWithPath: reference)).readAll()
                    .map { $0.asString().count }
                    .max() ?? 0
            } else {
                throw ValidationError("Specify --literal or --ref for primer sequence")
            }
            return ToolArguments(engine: .bbduk(
                primers: primers,
                kmerSize: kmerSize,
                minKmer: minKmer,
                hammingDistance: hammingDistance,
                searchWindow: Self.primerSearchWindow(longestPrimer: longestPrimer)
            ))

        case .cutadaptLinked:
            guard literalSequence == nil else {
                throw ValidationError("--engine cutadapt-linked requires --ref, not --literal")
            }
            guard let reference else {
                throw ValidationError("--engine cutadapt-linked requires --ref")
            }
            guard FileManager.default.fileExists(atPath: reference) else {
                throw CLIError.inputFileNotFound(path: reference)
            }
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let linkedPrimerURL = try await writeLinkedPrimerAdapters(
                from: URL(fileURLWithPath: reference),
                to: stagingDirectory.appendingPathComponent("linked-primers.fasta")
            )
            return ToolArguments(engine: .cutadaptLinked(
                linkedPrimers: linkedPrimerURL.path,
                errorRate: errorRate,
                minimumOverlap: minimumOverlap
            ))
        }
    }

    private func writeLinkedPrimerAdapters(from referenceURL: URL, to destinationURL: URL) async throws -> URL {
        let records = try await FASTAReader(url: referenceURL).readAll()
        var forwardByBase: [String: String] = [:]
        var reverseByBase: [String: String] = [:]

        for record in records {
            guard let parsed = parsePrimerPairName(record.name) else { continue }
            let sequence = record.asString().uppercased()
            switch parsed.role {
            case .forward:
                forwardByBase[parsed.base] = sequence
            case .reverse:
                reverseByBase[parsed.base] = sequence
            }
        }

        var contents = ""
        for base in forwardByBase.keys.sorted() {
            guard let forward = forwardByBase[base], let reverse = reverseByBase[base] else { continue }
            contents += ">\(base)_R_to_rcF\n\(reverse)...\(reverseComplement(forward))\n"
            contents += ">\(base)_F_to_rcR\n\(forward)...\(reverseComplement(reverse))\n"
        }

        guard !contents.isEmpty else {
            throw ValidationError(
                "No paired primers found in \(referenceURL.path). Expected FASTA headers ending in -F/-R or _F/_R."
            )
        }
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        return destinationURL
    }

    private enum PrimerRole {
        case forward
        case reverse
    }

    private func parsePrimerPairName(_ name: String) -> (base: String, role: PrimerRole)? {
        let suffixes: [(String, PrimerRole)] = [
            ("-F", .forward), ("_F", .forward),
            ("-R", .reverse), ("_R", .reverse),
            ("-FORWARD", .forward), ("_FORWARD", .forward),
            ("-REVERSE", .reverse), ("_REVERSE", .reverse),
        ]
        let uppercasedName = name.uppercased()
        for (suffix, role) in suffixes {
            guard uppercasedName.hasSuffix(suffix) else { continue }
            let index = name.index(name.endIndex, offsetBy: -suffix.count)
            return (String(name[..<index]), role)
        }
        return nil
    }

    private func reverseComplement(_ sequence: String) -> String {
        let map: [Character: Character] = [
            "A": "T", "C": "G", "G": "C", "T": "A", "U": "A",
            "R": "Y", "Y": "R", "S": "S", "W": "W", "K": "M", "M": "K",
            "B": "V", "D": "H", "H": "D", "V": "B", "N": "N",
        ]
        return String(sequence.uppercased().reversed().map { map[$0] ?? "N" })
    }
}
