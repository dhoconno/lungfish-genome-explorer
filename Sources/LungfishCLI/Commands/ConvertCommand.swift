// ConvertCommand.swift - Format conversion command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Convert between sequence file formats
struct ConvertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert between sequence file formats",
        discussion: """
            Convert sequences between FASTA, GenBank, GFF3, and other formats.
            Format is auto-detected from input file extension or can be specified.
            Input and output must be different files; in-place, symlink and hard-link aliases are rejected.
            Several inputs are written to one output, in the order given. --compress writes the output as gzip or zstd under the --to name as given, and publishes it only when the compressed file is whole.

            Examples:
              lungfish-cli convert input.gb --to output.fa --to-format fasta
              lungfish-cli convert input.fasta --to output.gb --to-format genbank
              lungfish-cli convert first.fa second.fa --to both.fa.gz --compress gzip
            """
    )

    @Argument(help: "Input file paths. Several inputs are written to one output, in the order given")
    var inputs: [String]

    @Option(
        name: .customLong("to-format"),
        help: "Output format: fasta, genbank, gff3, fastq"
    )
    var toFormat: String = "fasta"

    @Option(
        name: .customLong("to"),
        help: "Output file path (required)"
    )
    var outputFile: String

    @Flag(
        name: .customLong("include-annotations"),
        help: "Include annotations in output (if supported)"
    )
    var includeAnnotations: Bool = false

    @Flag(
        name: .customLong("force"),
        help: "Overwrite existing output file"
    )
    var force: Bool = false

    @Option(
        name: .customLong("compress"),
        help: "Compress the output with gzip or zstd (the --to name is used as given)"
    )
    var compress: ConvertCompression?

    @OptionGroup var globalOptions: GlobalOptions

    /// The words a cancelled run prints, unless `--quiet` is given.
    static let cancelledMessage = "Conversion cancelled. Nothing was published."

    /// Runs the conversion with SIGTERM, which is the Import Center's Cancel, turned into a cancel of its task
    /// (review A49-M3, fix F3). The checkpoints of the task reach the rollback of the publication transaction and
    /// the `defer` blocks that remove the stage entries, so a cancel keeps the earlier output and leaves no
    /// recovery folder in the temporary folder. A cancelled run exits 125. `convert` is a result leaf, so standard
    /// output holds the JSON result alone and a cancel prints no event line.
    func run() async throws {
        let pendingCancel = PendingTaskCancel<Result<Void, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let command = self
        let task = Task { () -> Result<Void, any Error> in
            do {
                try await command.convert()
                return .success(())
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel. A rollback that
                // could not restore keeps its error, which names the recovery folder.
                let restoreFailed = error is ScientificPublicationRecoveryRequired
                return .failure(Task.isCancelled && !restoreFailed ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        guard case .failure(let error) = outcome else { return }
        guard error is CancellationError else { throw error }
        if !globalOptions.quiet {
            printHumanLine(Self.cancelledMessage, eventsOn: globalOptions.outputFormat == .json)
        }
        throw CLIExitCode.cancelled.exitCode
    }

    /// The conversion, which `run()` runs as a task that a SIGTERM can cancel.
    private func convert() async throws {
        let runClock = ProvenanceRunClock()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate every input file exists
        for path in inputs where !FileManager.default.fileExists(atPath: path) {
            throw CLIError.inputFileNotFound(path: path)
        }

        let inputURLs = inputs.map { URL(fileURLWithPath: $0) }
        let outputURL = URL(fileURLWithPath: outputFile)
        let outputAlreadyExists = FileManager.default.fileExists(atPath: outputFile)
        if outputAlreadyExists, !force {
            throw CLIError.outputWriteFailed(
                path: outputFile,
                reason: "File already exists. Use --force to overwrite."
            )
        }
        let outputIdentity = try? FileManager.default.attributesOfItem(atPath: outputURL.resolvingSymlinksInPath().path)
        for inputURL in inputURLs {
            let inputIdentity = try FileManager.default.attributesOfItem(atPath: inputURL.resolvingSymlinksInPath().path)
            let sameInode = outputIdentity != nil
                && (inputIdentity[.systemNumber] as? NSNumber) == (outputIdentity?[.systemNumber] as? NSNumber)
                && (inputIdentity[.systemFileNumber] as? NSNumber) == (outputIdentity?[.systemFileNumber] as? NSNumber)
            guard inputURL.canonicalFilePath != outputURL.canonicalFilePath,
                  !sameInode else {
                throw CLIError.outputWriteFailed(path: outputFile,
                    reason: "Input and output must be different files. In-place, symlink and hard-link aliases are not supported.")
            }
        }

        // Show progress. Under `--format json` the text goes to standard error, so standard output
        // holds the JSON result alone (2.6 row 213).
        if !globalOptions.quiet {
            let source = inputURLs.count == 1 ? inputURLs[0].lastPathComponent : "\(inputURLs.count) files"
            printHumanLine(
                formatter.info("Converting \(source) to \(toFormat.uppercased())..."),
                eventsOn: globalOptions.outputFormat == .json
            )
        }

        // Read every input in the order given. Each keeps its own annotations beside its sequences.
        var sourced: [(sequence: Sequence, annotations: [SequenceAnnotation])] = []
        var allAnnotations: [SequenceAnnotation] = []
        var provenanceInputs: [FileRecord] = []
        var inputFormats: [String] = []
        for inputURL in inputURLs {
            let read = try await readInput(inputURL)
            provenanceInputs += read.records
            if !inputFormats.contains(read.format) { inputFormats.append(read.format) }
            sourced += read.sequences.map { ($0, read.annotations) }
            allAnnotations += read.annotations
        }
        let sequences = sourced.map(\.sequence)
        let annotations = allAnnotations
        let ext = inputFormats.joined(separator: ",")

        // Validate the output format (and any format-specific preconditions,
        // e.g. GFF3 needing non-empty annotations) BEFORE touching the
        // existing --to file. This is the validation half of the
        // R3-R3H-7 fix: everything that can still fail must fail before any
        // destructive removeItem happens.
        let normalizedToFormat = toFormat.lowercased()
        switch normalizedToFormat {
        case "fasta", "fa", "genbank", "gb", "fastq", "fq":
            break
        case "gff3", "gff":
            guard !annotations.isEmpty else {
                throw CLIError.conversionFailed(reason: "No annotations to write to GFF3")
            }
        default:
            throw CLIError.unsupportedFormat(format: toFormat)
        }

        let outputDirectory = outputURL.deletingLastPathComponent()
        // The file that is published. Without --compress the writers below fill it. With --compress they write
        // export.<ext> in a stage folder, the name the app's export gave it, and the compressor turns that into
        // this file, so a gzip header names export.<ext> as it did.
        let publishedStageURL = outputDirectory.appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID()).convert.tmp")
        defer { try? FileManager.default.removeItem(at: publishedStageURL) }
        let rawStageDirectory = outputDirectory.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID()).convert.d", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rawStageDirectory) }
        let stagedOutputURL = compress == nil
            ? publishedStageURL
            : rawStageDirectory.appendingPathComponent("export.\(Self.exportExtension(normalizedToFormat))")
        if compress != nil {
            try FileManager.default.createDirectory(at: rawStageDirectory, withIntermediateDirectories: true)
        }
        let rootArtifacts = ProvenancePublicationArtifacts.bundleRootArtifacts(for: outputDirectory)
        let fileArtifacts = ProvenancePublicationArtifacts.fileSidecarArtifacts(for: outputURL)
        let publication = try ScientificFilePublicationTransaction(
            protectedURLs: [outputURL] + rootArtifacts + fileArtifacts,
            fileDestinations: [outputURL] + Array(rootArtifacts.prefix(3)) + fileArtifacts)
        do {
        // Write output
        switch normalizedToFormat {
        case "fasta", "fa":
            let writer = FASTAWriter(url: stagedOutputURL)
            try writer.write(sequences)

        case "genbank", "gb":
            let writer = GenBankWriter(url: stagedOutputURL)
            let records = sourced.map { seq, sourceAnnotations in
                GenBankRecord(
                    sequence: seq,
                    annotations: includeAnnotations ? sourceAnnotations.filter { $0.chromosome == seq.name } : [],
                    locus: LocusInfo(
                        name: seq.name,
                        length: seq.length,
                        moleculeType: seq.alphabet == .dna ? .dna : (seq.alphabet == .rna ? .rna : .protein),
                        topology: .linear,
                        division: nil,
                        date: Self.currentDateString()
                    ),
                    definition: seq.description,
                    accession: nil,
                    version: nil
                )
            }
            try writer.write(records)

        case "fastq", "fq":
            // Convert Sequence to FASTQRecord with default high quality scores
            let fastqRecords = sequences.map { seq in
                FASTQRecord(
                    identifier: seq.name,
                    description: seq.description,
                    sequence: seq.asString(),
                    qualityString: String(repeating: "I", count: seq.length),  // Q40 quality
                    encoding: .phred33
                )
            }
            try FASTQWriter.write(fastqRecords, to: stagedOutputURL)

        case "gff3", "gff":
            try await GFF3Writer.write(annotations, to: stagedOutputURL)

        default:
            // Unreachable: normalizedToFormat was already validated above.
            throw CLIError.unsupportedFormat(format: toFormat)
        }
        var compressionReceipt: SequenceExportCompressor.Receipt?
        var compressionSeconds: TimeInterval = 0
        if let compress {
            let compressStartedAt = runClock.now
            compressionReceipt = try await SequenceExportCompressor.compress(
                source: stagedOutputURL, to: publishedStageURL, kind: compress.kind
            )
            compressionSeconds = runClock.now.timeIntervalSince(compressStartedAt)
        }
        let completedAt = runClock.now
        try Task.checkCancellation()
        try publication.publish(stagedURL: publishedStageURL, to: outputURL, replacingExisting: force)

        var recordedParameters: [String: ParameterValue] = [
            "input": .file(inputURLs[0]),
            "output": .file(outputURL),
            "inputFormat": .string(ext),
            "toFormat": .string(toFormat),
            "includeAnnotations": .boolean(includeAnnotations),
            "force": .boolean(force),
            "sequenceCount": .integer(sequences.count),
            "annotationCount": .integer(includeAnnotations ? annotations.count : 0)
        ]
        if inputURLs.count > 1 {
            recordedParameters["inputs"] = .array(inputURLs.map { .file($0) })
        }
        if let compress {
            recordedParameters["compress"] = .string(compress.rawValue)
        }
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish convert",
            parameters: recordedParameters,
            defaults: [
                "toFormat": .string("fasta"),
                "includeAnnotations": .boolean(false),
                "force": .boolean(false)
            ],
            resolved: recordedParameters,
            toolName: "lungfish convert",
            toolVersion: LungfishCLI.configuration.version,
            command: provenanceCommand(inputURLs: inputURLs, outputURL: outputURL),
            extraSteps: compressionReceipt.map {
                [SequenceExportCompressor.provenanceStep(for: $0, wallTimeSeconds: compressionSeconds)]
            } ?? [],
            inputs: provenanceInputs,
            outputs: [
                ProvenanceRecorder.fileRecord(url: outputURL, role: .output)
            ],
            consumedInputSnapshotPaths: Set(provenanceInputs.map { URL(fileURLWithPath: $0.path).canonicalFilePath }),
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(runClock.startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputDirectory,
            publicationArtifactDidWrite: { try publication.observe($0) }
        )
        try Task.checkCancellation()
        publication.commit()
        } catch {
            try publication.rollback(after: error)
        }

        // Success message, on standard error under `--format json`
        if !globalOptions.quiet {
            printHumanLine(
                formatter.success("Converted \(sequences.count) sequence(s) to \(outputURL.lastPathComponent)"),
                eventsOn: globalOptions.outputFormat == .json
            )
        }

        // JSON output
        if globalOptions.outputFormat == .json {
            let result = ConvertResult(
                inputFile: inputs[0],
                outputFile: outputFile,
                inputFormat: ext,
                outputFormat: toFormat,
                sequenceCount: sequences.count,
                annotationCount: includeAnnotations ? annotations.count : 0,
                inputFiles: inputs.count > 1 ? inputs : nil,
                compression: compress?.rawValue
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }

    /// Reads one input by its extension. The record names the files it read, and they are checked again after
    /// the read, so an input that changed while it was read fails the conversion.
    private func readInput(_ inputURL: URL) async throws -> (
        format: String, sequences: [Sequence], annotations: [SequenceAnnotation], records: [FileRecord]
    ) {
        // Strip .gz extension for format detection
        var detectURL = inputURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }
        let ext = detectURL.pathExtension.lowercased()
        let provenanceInputs = try Self.provenanceInputFiles(inputURL: inputURL, inputFormat: ext,
            includeAnnotations: includeAnnotations)
        let sequences: [Sequence]
        let annotations: [SequenceAnnotation]
        switch ext {
        case "fa", "fasta", "fna", "faa":
            let reader = try FASTAReader(url: inputURL)
            sequences = try await reader.readAll()
            annotations = []

        case "gb", "gbk", "genbank", "gbff":
            let reader = try GenBankReader(url: inputURL)
            let records = try await reader.readAll()
            sequences = records.map { $0.sequence }
            annotations = records.flatMap { $0.annotations }

        case "fastq", "fq":
            let reader = FASTQReader()
            let fastqRecords = try await reader.readAll(from: inputURL)
            // Convert FASTQRecord to Sequence
            sequences = try fastqRecords.map { record in
                try Sequence(
                    name: record.identifier,
                    description: record.description,
                    alphabet: .dna,
                    bases: record.sequence
                )
            }
            annotations = []

        case "lungfishref":
            (sequences, annotations) = try await Self.readReferenceBundle(
                inputURL,
                includeAnnotations: includeAnnotations
            )

        default:
            throw CLIError.formatDetectionFailed(path: inputURL.path)
        }

        let observedInputs = try Self.provenanceInputFiles(inputURL: inputURL, inputFormat: ext,
            includeAnnotations: includeAnnotations)
        guard observedInputs == provenanceInputs else {
            throw CLIError.conversionFailed(reason: "Input files changed while conversion was reading them; retry with a stable source.")
        }
        return (ext, sequences, annotations, provenanceInputs)
    }

    /// The extension of the text file the writers fill before it is compressed.
    private static func exportExtension(_ normalizedToFormat: String) -> String {
        switch normalizedToFormat {
        case "genbank", "gb": return "gb"
        case "fastq", "fq": return "fastq"
        case "gff3", "gff": return "gff3"
        default: return "fa"
        }
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }

    private func provenanceCommand(inputURLs: [URL], outputURL: URL) -> [String] {
        var command = [CLICommandIdentity.executableName, "convert"]
        command += inputURLs.map(\.path)
        command += ["--to", outputURL.path, "--to-format", toFormat]
        // The order is the order of the app's `SequenceExportRoute.arguments`, so the argv of the record, the
        // command of the row and the run are one (review A49-M3, fix F4).
        if includeAnnotations {
            command.append("--include-annotations")
        }
        if let compress {
            command += ["--compress", compress.rawValue]
        }
        if force {
            command.append("--force")
        }
        if globalOptions.outputFormat == .json {
            command += ["--format", "json"]
        }
        if globalOptions.quiet {
            command.append("--quiet")
        }
        return command
    }

    private static func provenanceInputFiles(
        inputURL: URL,
        inputFormat: String,
        includeAnnotations: Bool
    ) throws -> [FileRecord] {
        guard inputFormat == "lungfishref" else {
            return [ProvenanceRecorder.fileRecord(url: inputURL, role: .input)]
        }

        let manifest = try BundleManifest.load(from: inputURL)
        var urls: [(URL, FileRole)] = [
            (inputURL.appendingPathComponent("manifest.json"), .input)
        ]

        if let genome = manifest.genome {
            urls.append((inputURL.appendingPathComponent(genome.path), .input))
            urls.append((inputURL.appendingPathComponent(genome.indexPath), .index))
            if let gzipIndexPath = genome.gzipIndexPath {
                urls.append((inputURL.appendingPathComponent(gzipIndexPath), .index))
            }
        }

        if includeAnnotations {
            for track in manifest.annotations {
                guard let dbPath = track.databasePath else { continue }
                urls.append((inputURL.appendingPathComponent(dbPath), .input))
            }
        }

        var seen = Set<String>()
        return urls.compactMap { url, role -> FileRecord? in
            let standardizedURL = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardizedURL.path) else { return nil }
            guard seen.insert(standardizedURL.path).inserted else { return nil }
            return ProvenanceRecorder.fileRecord(url: standardizedURL, role: role)
        }
    }

    private static func readReferenceBundle(
        _ bundleURL: URL,
        includeAnnotations: Bool
    ) async throws -> ([Sequence], [SequenceAnnotation]) {
        let manifest = try BundleManifest.load(from: bundleURL)
        guard let genome = manifest.genome else {
            throw CLIError.conversionFailed(reason: "Reference bundle has no genome sequence: \(bundleURL.path)")
        }

        let bundle = try await ReferenceBundle(url: bundleURL)
        let sequences = try await genome.chromosomes.mapAsync { chromosome in
            let region = GenomicRegion(chromosome: chromosome.name, start: 0, end: Int(chromosome.length))
            let bases = try await bundle.fetchSequence(region: region)
            return try Sequence(
                name: chromosome.name,
                description: chromosome.fastaDescription,
                alphabet: .dna,
                bases: bases
            )
        }

        guard includeAnnotations else {
            return (sequences, [])
        }

        var annotations: [SequenceAnnotation] = []
        for track in manifest.annotations {
            guard let dbPath = track.databasePath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            let db = try AnnotationDatabase(url: dbURL)
            annotations.append(contentsOf: db.query(limit: Int.max).map { $0.toAnnotation() })
        }

        return (sequences, annotations)
    }
}

private extension Array {
    func mapAsync<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            let value = try await transform(element)
            values.append(value)
        }
        return values
    }
}

/// Result data for convert command
struct ConvertResult: Codable {
    let inputFile: String
    let outputFile: String
    let inputFormat: String
    let outputFormat: String
    let sequenceCount: Int
    let annotationCount: Int
    /// Every input, when there are several. The first is `inputFile`.
    var inputFiles: [String]? = nil
    /// The compressor of the output, when `--compress` was given.
    var compression: String? = nil
}

/// The compressors `convert --compress` offers.
enum ConvertCompression: String, CaseIterable, ExpressibleByArgument {
    case gzip
    case zstd

    var kind: SequenceExportCompressor.Kind {
        switch self {
        case .gzip: return .gzip
        case .zstd: return .zstd
        }
    }
}
