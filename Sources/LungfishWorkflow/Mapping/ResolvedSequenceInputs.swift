// ResolvedSequenceInputs.swift - Sequence inputs resolved to the files a tool reads, with their lineage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The files a tool reads for the sequence inputs a user chose, each paired
/// with the input it came from.
///
/// This is the resolution the Map Reads window applies to every input, and
/// the one `AppDelegate.resolveInputFiles` applies for the classifiers. A
/// bundle contributes every FASTQ file it holds, through
/// ``FASTQSourceResolver``, and a virtual bundle (subset, trim,
/// demultiplexed or oriented reads) is materialized into
/// `materializationDirectory` first. `lungfish-cli map` resolves its inputs
/// the same way, so a bundle maps the same reads through the window and
/// through the recorded CLI command; `classify` still resolves one primary
/// file per input through
/// ``CLISequenceInputMaterialization/resolveExecutionInputs(for:tempDirectory:materializer:operationName:progress:)``,
/// so the two are not interchangeable for a bundle that holds several files.
///
/// A mapper reads one unpaired file at a time (BBMap takes one `in=`, and
/// bwa-mem2 treats a second positional file as the mate file), so with
/// `concatenateUnpairedFiles` the several unpaired files of one bundle are
/// concatenated into one execution file, recorded beside it as a
/// ``SequenceInputConcatenation`` so provenance can record the step. The R1
/// and R2 files of a mate pair stay apart.
///
/// `originalInputURLs` has one entry per execution file, so index `i` of
/// ``executionInputURLs`` came from index `i` of ``originalInputURLs``. That
/// is the pairing ``ManagedMappingPipeline`` records lineage by.
public struct ResolvedSequenceInputs: Sendable, Equatable {
    /// One input the user chose and the files it resolved to.
    public struct Input: Sendable, Equatable {
        /// The input as the user chose it, standardized.
        public let originalURL: URL
        /// The file or files the tool reads for it, standardized.
        public let executionURLs: [URL]
        /// Whether `executionURLs` were written for this run rather than
        /// found on disk: a materialized virtual bundle or a concatenation.
        public let wasMaterialized: Bool
        /// Whether `executionURLs` are the R1 and R2 files of one mate pair,
        /// in that order, from the bundle's manifest or from their names
        /// (``MatePairFileNaming``).
        public let isMatePair: Bool
        /// The files a concatenated execution file was made from, in the
        /// order they were written, or empty.
        public let concatenatedFrom: [URL]

        public init(
            originalURL: URL,
            executionURLs: [URL],
            wasMaterialized: Bool,
            isMatePair: Bool = false,
            concatenatedFrom: [URL] = []
        ) {
            self.originalURL = originalURL.standardizedFileURL
            self.executionURLs = executionURLs.map(\.standardizedFileURL)
            self.wasMaterialized = wasMaterialized
            self.isMatePair = isMatePair
            self.concatenatedFrom = concatenatedFrom.map(\.standardizedFileURL)
        }
    }

    public let inputs: [Input]
    /// When the first materialization began, or nil when nothing was materialized.
    public let materializationStartedAt: Date?
    /// When the last materialization ended, or nil when nothing was materialized.
    public let materializationEndedAt: Date?

    public init(inputs: [Input], materializationStartedAt: Date?, materializationEndedAt: Date?) {
        self.inputs = inputs
        self.materializationStartedAt = materializationStartedAt
        self.materializationEndedAt = materializationEndedAt
    }

    /// The files the tool reads, in input order.
    public var executionInputURLs: [URL] {
        inputs.flatMap(\.executionURLs)
    }

    /// The input each execution file came from, one entry per execution file.
    public var originalInputURLs: [URL] {
        inputs.flatMap { input in input.executionURLs.map { _ in input.originalURL } }
    }

    /// The execution files written for this run.
    public var materializedExecutionURLs: [URL] {
        inputs.filter(\.wasMaterialized).flatMap(\.executionURLs)
    }

    public var didMaterialize: Bool {
        inputs.contains(where: \.wasMaterialized)
    }

    /// Whether the tool receives exactly the R1 and R2 files of one mate
    /// pair, so it maps them as pairs.
    public var resolvedAsMatePair: Bool {
        inputs.count == 1 && inputs[0].isMatePair
    }

    /// The layout a concatenated input keeps: its files were pooled as
    /// single reads, the decision ``FASTQInputLayoutResolver`` makes for
    /// several files. `nil` when nothing was concatenated, so the caller
    /// resolves the layout from the execution files as usual.
    public var pooledLayoutResolution: FASTQInputLayoutResolution? {
        guard inputs.contains(where: { !$0.concatenatedFrom.isEmpty }) else { return nil }
        let fileCount = inputs.reduce(0) { count, input in
            count + (input.concatenatedFrom.isEmpty ? input.executionURLs.count : input.concatenatedFrom.count)
        }
        return FASTQInputLayoutResolution(
            layout: .singleEnd,
            source: .pooledFiles,
            reason: "\(fileCount) input files are pooled as single reads."
        )
    }

    /// Resolves `inputURLs` to the files a tool reads.
    ///
    /// A URL inside a `.lungfishfastq` bundle, or the bundle itself, resolves
    /// through ``FASTQSourceResolver`` to every file of the bundle, with a
    /// virtual bundle materialized by `materializer` into
    /// `materializationDirectory`, which is created when first needed. A
    /// `fullFASTA` derivative is read in place. A URL outside a bundle
    /// resolves to its primary sequence file, or passes through unchanged
    /// when it has none. With `concatenateUnpairedFiles`, a bundle that
    /// resolves to several files that are not one mate pair is concatenated
    /// into one file in `materializationDirectory`. On an error, every file
    /// this call wrote is removed, and so is the directory when it did not
    /// exist before. Cancellation is checked before each input.
    public static func resolve(
        inputURLs: [URL],
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        concatenateUnpairedFiles: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedSequenceInputs {
        let fileManager = FileManager.default
        let directory = materializationDirectory.standardizedFileURL
        var directoryWasDirectory = ObjCBool(false)
        let directoryExisted = fileManager.fileExists(atPath: directory.path, isDirectory: &directoryWasDirectory)
        let preexistingEntries: Set<String>? = directoryExisted && directoryWasDirectory.boolValue
            ? (try? fileManager.contentsOfDirectory(atPath: directory.path)).map(Set.init)
            : nil

        let resolver = FASTQSourceResolver()
        resolver.materializer = { bundleURL, outputDirectory, progressCallback in
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            return try await materializer.materialize(
                bundleURL: bundleURL,
                tempDirectory: outputDirectory,
                progress: progressCallback
            )
        }

        var inputs: [Input] = []
        var materializationStartedAt: Date?
        var materializationEndedAt: Date?
        func noteMaterialization(began: Date, ended: Date) {
            materializationStartedAt = materializationStartedAt ?? began
            materializationEndedAt = ended
        }
        do {
            for inputURL in inputURLs {
                try Task.checkCancellation()
                let originalURL = inputURL.standardizedFileURL

                if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: originalURL) {
                    // A fullFASTA derivative stores its whole FASTA in place.
                    // FASTQSourceResolver finds no FASTQ file in it and would
                    // have the materializer copy the FASTA, so the file is
                    // used where it is, as lungfish-cli map does.
                    if let fastaURL = inPlaceFASTA(of: bundleURL) {
                        inputs.append(Input(originalURL: originalURL, executionURLs: [fastaURL], wasMaterialized: false))
                        continue
                    }
                    let began = Date()
                    let urls = try await resolver.resolve(
                        bundleURL: bundleURL,
                        tempDirectory: directory,
                        progress: { _, message in progress?(message) }
                    )
                    let ended = Date()
                    if urls.contains(where: { isInside(directory, $0) }) {
                        noteMaterialization(began: began, ended: ended)
                        inputs.append(Input(originalURL: originalURL, executionURLs: urls, wasMaterialized: true))
                        continue
                    }
                    if let pair = matePair(among: urls, in: bundleURL) {
                        inputs.append(Input(
                            originalURL: originalURL,
                            executionURLs: [pair.r1, pair.r2],
                            wasMaterialized: false,
                            isMatePair: true
                        ))
                        continue
                    }
                    if urls.count > 1, concatenateUnpairedFiles {
                        progress?("Concatenating \(urls.count) files of \(bundleURL.lastPathComponent)...")
                        let began = Date()
                        let concatenation = try concatenate(urls, of: bundleURL, into: directory)
                        noteMaterialization(began: began, ended: Date())
                        inputs.append(Input(
                            originalURL: originalURL,
                            executionURLs: [concatenation.outputURL],
                            wasMaterialized: true,
                            concatenatedFrom: concatenation.memberURLs
                        ))
                        continue
                    }
                    inputs.append(Input(originalURL: originalURL, executionURLs: urls, wasMaterialized: false))
                    continue
                }

                if let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: originalURL) {
                    inputs.append(Input(originalURL: originalURL, executionURLs: [resolvedURL], wasMaterialized: false))
                    continue
                }

                inputs.append(Input(originalURL: originalURL, executionURLs: [originalURL], wasMaterialized: false))
            }
        } catch {
            removeMaterializedOutputs(
                in: directory,
                directoryExisted: directoryExisted,
                preexistingEntries: preexistingEntries
            )
            throw error
        }

        return ResolvedSequenceInputs(
            inputs: inputs,
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )
    }

    private static func isInside(_ directory: URL, _ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.path + "/")
    }

    /// The FASTA a `fullFASTA` derivative stores, when it exists.
    private static func inPlaceFASTA(of bundleURL: URL) -> URL? {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
              case .fullFASTA = manifest.payload else {
            return nil
        }
        return SequenceInputResolver.resolvePrimarySequenceURL(for: bundleURL)
    }

    /// The R1 and R2 files among `urls` when they are exactly one mate pair:
    /// the pair a `fullPaired` manifest names, else two files named as mates.
    private static func matePair(among urls: [URL], in bundleURL: URL) -> (r1: URL, r2: URL)? {
        guard urls.count == 2 else { return nil }
        if let manifestPair = FASTQBundle.pairedFASTQURLs(forDerivedBundle: bundleURL) {
            let resolved = Set(urls.map(\.standardizedFileURL))
            let named = Set([manifestPair.r1.standardizedFileURL, manifestPair.r2.standardizedFileURL])
            if resolved == named {
                return (manifestPair.r1.standardizedFileURL, manifestPair.r2.standardizedFileURL)
            }
        }
        return MatePairFileNaming.matePair(in: urls)
    }

    /// Writes the bytes of `members` one after another into a new file in
    /// `directory`, with its ``SequenceInputConcatenation`` sidecar. Gzip
    /// members form a multi-member gzip stream, which every mapper and
    /// samtools read as one file. A plain member that does not end in a
    /// newline gets one, so its last record and the next file's first stay
    /// apart.
    private static func concatenate(
        _ members: [URL],
        of bundleURL: URL,
        into directory: URL
    ) throws -> SequenceInputConcatenation {
        let compression = Set(members.map { $0.pathExtension.lowercased() == "gz" })
        guard compression.count == 1, let gzipped = compression.first else {
            throw ResolvedSequenceInputsError.mixedCompression(bundlePath: bundleURL.standardizedFileURL.path)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(
            "concatenated-\(UUID().uuidString).\(gzipped ? "fastq.gz" : "fastq")"
        )
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw ResolvedSequenceInputsError.concatenationFailed(path: outputURL.path)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        for member in members {
            let input = try FileHandle(forReadingFrom: member)
            defer { try? input.close() }
            var lastByte: UInt8?
            while true {
                let chunk = input.readData(ofLength: 4 * 1024 * 1024)
                if chunk.isEmpty { break }
                output.write(chunk)
                lastByte = chunk.last
            }
            if !gzipped, let lastByte, lastByte != UInt8(ascii: "\n") {
                output.write(Data([UInt8(ascii: "\n")]))
            }
        }
        let concatenation = SequenceInputConcatenation(
            bundleURL: bundleURL,
            memberURLs: members,
            outputURL: outputURL
        )
        try concatenation.save()
        return concatenation
    }

    /// Removes what this call wrote into the materialization directory: the
    /// whole directory when it did not exist before, otherwise every entry
    /// that was not there before (a failed materialization can leave a
    /// partial file behind).
    private static func removeMaterializedOutputs(
        in directory: URL,
        directoryExisted: Bool,
        preexistingEntries: Set<String>?
    ) {
        let fileManager = FileManager.default
        guard directoryExisted else {
            try? fileManager.removeItem(at: directory)
            return
        }
        guard let preexistingEntries,
              let currentEntries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for entry in currentEntries where !preexistingEntries.contains(entry) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}

public enum ResolvedSequenceInputsError: LocalizedError, Sendable, Equatable {
    /// A bundle holds both gzip and plain files, which cannot be joined into one stream.
    case mixedCompression(bundlePath: String)
    case concatenationFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .mixedCompression(let bundlePath):
            return "The bundle mixes compressed and uncompressed FASTQ files, which cannot be mapped as one file: \(bundlePath)"
        case .concatenationFailed(let path):
            return "Could not write the concatenated reads file: \(path)"
        }
    }
}

/// What a concatenated execution file was made from, kept beside it as
/// `<file>.sources.json` so provenance can record the concatenation as a
/// step whose inputs are the member files and whose command reproduces it.
public struct SequenceInputConcatenation: Codable, Sendable, Equatable {
    /// The tool the provenance step names.
    public static let toolName = "cat"

    public let bundlePath: String
    public let memberPaths: [String]
    public let outputPath: String

    public init(bundleURL: URL, memberURLs: [URL], outputURL: URL) {
        bundlePath = bundleURL.standardizedFileURL.path
        memberPaths = memberURLs.map { $0.standardizedFileURL.path }
        outputPath = outputURL.standardizedFileURL.path
    }

    public var bundleURL: URL { URL(fileURLWithPath: bundlePath) }
    public var memberURLs: [URL] { memberPaths.map { URL(fileURLWithPath: $0) } }
    public var outputURL: URL { URL(fileURLWithPath: outputPath) }

    /// The shell command that writes the same file again.
    public var command: [String] {
        [
            "/bin/sh",
            "-c",
            "cat " + memberPaths.map(shellEscape).joined(separator: " ") + " > " + shellEscape(outputPath),
        ]
    }

    public static func sidecarURL(for outputURL: URL) -> URL {
        URL(fileURLWithPath: outputURL.standardizedFileURL.path + ".sources.json")
    }

    /// The concatenation `executionURL` came from, or nil when it is not a
    /// concatenated file.
    public static func load(for executionURL: URL) -> SequenceInputConcatenation? {
        let sidecarURL = sidecarURL(for: executionURL)
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? JSONDecoder().decode(SequenceInputConcatenation.self, from: data)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.sidecarURL(for: outputURL), options: .atomic)
    }

    /// Removes the concatenated file and its sidecar.
    public func removeOutput() {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: outputURL))
    }

    /// The provenance step that records this concatenation: the member
    /// files as inputs, the concatenated file as the output, `cat` as the
    /// tool and the command that writes the file again.
    public func stepExecution(toolVersion: String, startedAt: Date, endedAt: Date) throws -> StepExecution {
        func record(_ descriptor: ProvenanceFileDescriptor) -> FileRecord {
            FileRecord(
                path: descriptor.path,
                sha256: descriptor.checksumSHA256,
                sizeBytes: descriptor.fileSize,
                format: descriptor.format,
                role: descriptor.role
            )
        }
        return StepExecution(
            toolName: Self.toolName,
            toolVersion: toolVersion,
            command: command,
            durableReplayArgv: command,
            inputs: try CLISequenceInputMaterialization.concatenationMemberDescriptors(for: self).map(record),
            outputs: [
                record(try CLISequenceInputMaterialization.executionInputDescriptor(
                    originalURL: bundleURL,
                    executionURL: outputURL
                )),
            ],
            exitCode: 0,
            wallTime: max(0, endedAt.timeIntervalSince(startedAt)),
            startTime: startedAt,
            endTime: endedAt
        )
    }
}
