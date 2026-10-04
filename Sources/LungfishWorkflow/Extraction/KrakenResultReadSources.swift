// KrakenResultReadSources.swift - The read files a Kraken2 result classified, each with its role
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The read files a Kraken2 result classified, each with its role (D7 and
/// D8, Phase 1.5 lane A3).
///
/// The app's read extraction, `lungfish-cli extract reads --by-classifier`,
/// the app's BLAST verification and `lungfish-cli blast verify` all resolve a
/// result's reads here, so they read the same files.
///
/// - A `.lungfishfastq` bundle gives its files by the roles
///   ``ReadSetResolver`` reads: a paired derivative its R1 and R2 files, a
///   merge or repair derivative its R1, R2, merged and unpaired files, and a
///   chunked root every chunk. A file whose mates sit next to each other is
///   read as it is.
/// - A virtual subset reads the paired or mixed bundle its reads come from,
///   or else its recorded root, since its read IDs pick exactly the records
///   kraken2 classified. A trim or orientation map, which changes the
///   records, is materialized once into `materializationDirectory`.
/// - A file is read as it is. When kraken2 classified pairs (its per-read
///   lengths read `L|L`), the first two loose files are the R1 and R2 the run
///   named with `--paired`.
public struct KrakenResultReadSources: Sendable, Equatable {

    /// What one file holds.
    public enum Role: String, Sendable, Equatable {
        /// The R1 file of pairs whose records correspond by position.
        case r1
        /// The R2 file of the same pairs.
        case r2
        /// A file whose mates sit next to each other, an interleaved file or
        /// one that mixes adjacent mates with single reads.
        case adjacentMates
        /// Single reads, or a loose file read as it is.
        case reads
    }

    public struct File: Sendable, Equatable {
        public let url: URL
        public let role: Role
        /// The kind of the single reads in the file, when the bundle records it.
        public let singleReadRole: ReadSetReadRole?

        public init(url: URL, role: Role, singleReadRole: ReadSetReadRole? = nil) {
            self.url = url.standardizedFileURL
            self.role = role
            self.singleReadRole = singleReadRole
        }
    }

    /// The inputs the files come from, one `--source` each in a recorded
    /// `lungfish-cli blast verify` command.
    public let inputs: [URL]
    /// Every file: each pair's R1 then its R2, then the files read as they are.
    public let files: [File]

    public var urls: [URL] { files.map(\.url) }

    /// Whether any file holds mates, as a pair of files or side by side.
    public var holdsMates: Bool {
        files.contains { $0.role != .reads }
    }

    /// The files as a BLAST verification reads them, in the same order. A
    /// record of an R1 file whose header names no mate is mate 1, and one of
    /// an R2 file mate 2. Any other file numbers unmarked mates in the order
    /// they appear, as an interleaved file stores a pair (D8).
    public var blastReadSources: [BlastReadSource] {
        files.map { file in
            switch file.role {
            case .r1: return BlastReadSource(url: file.url, unmarkedMate: 1)
            case .r2: return BlastReadSource(url: file.url, unmarkedMate: 2)
            case .adjacentMates, .reads: return BlastReadSource(url: file.url)
            }
        }
    }

    /// The sources of a result: the inputs it recorded, each resolved to its
    /// files. A trim or orientation map is materialized into
    /// `materializationDirectory`, which the caller removes.
    public static func resolve(
        result: ClassificationResult,
        materializationDirectory: URL
    ) async throws -> KrakenResultReadSources {
        try await resolve(
            inputs: recordedInputs(of: result),
            classificationOutput: result.outputURL,
            materializationDirectory: materializationDirectory
        )
    }

    /// The sources of `inputs`, the bundles and files a recorded command names.
    public static func resolve(
        inputs: [URL],
        classificationOutput: URL,
        materializationDirectory: URL
    ) async throws -> KrakenResultReadSources {
        let inputs = inputs.map(\.standardizedFileURL)
        let looseFiles = inputs.filter { !FASTQBundle.isBundleURL($0) }
        let loosePair = looseFiles.count >= 2 && classifiedPairs(in: classificationOutput)
            ? Array(looseFiles.prefix(2))
            : []
        var mates: [File] = []
        var reads: [File] = []
        for input in inputs {
            let resolved: [File]
            if let index = loosePair.firstIndex(of: input) {
                resolved = [File(url: input, role: index == 0 ? .r1 : .r2)]
            } else {
                resolved = try await files(of: input, materializationDirectory: materializationDirectory)
            }
            for file in resolved {
                guard FileManager.default.fileExists(atPath: file.url.path) else {
                    throw ClassifierExtractionError.kraken2SourceMissing
                }
                if file.role == .r1 || file.role == .r2 { mates.append(file) } else { reads.append(file) }
            }
        }
        guard !mates.isEmpty || !reads.isEmpty else { throw ClassifierExtractionError.kraken2SourceMissing }
        return KrakenResultReadSources(inputs: inputs, files: mates + reads)
    }

    /// The inputs a result's reads come from: the inputs the classification
    /// named, else the bundle a legacy result sits in, else its input files.
    /// A file the run wrote into its `.lungfish-classify-inputs` folder is
    /// never one of them. A pair of loose files adds the files of single
    /// reads named beside it with `--unpaired`.
    public static func recordedInputs(of result: ClassificationResult) throws -> [URL] {
        let config = result.config
        let fileManager = FileManager.default
        let scratchPrefix = config.outputDirectory
            .appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
            .standardizedFileURL.path + "/"
        func durable(_ urls: [URL]) -> [URL]? {
            let standardized = urls.map(\.standardizedFileURL)
            guard !standardized.isEmpty, standardized.allSatisfy({
                fileManager.fileExists(atPath: $0.path) && !$0.path.hasPrefix(scratchPrefix)
            }) else { return nil }
            return standardized
        }
        let named: [URL]
        if let originals = durable(config.originalInputFiles ?? []) {
            named = originals
        } else if let bundle = legacyEnclosingBundle(of: config) {
            return [bundle]
        } else if let inputs = durable(config.inputFiles) {
            named = inputs
        } else {
            throw ClassifierExtractionError.kraken2SourceMissing
        }
        guard !named.contains(where: FASTQBundle.isBundleURL) else { return named }
        let singles = config.singleReadFiles.map(\.standardizedFileURL).filter {
            fileManager.fileExists(atPath: $0.path) && !$0.path.hasPrefix(scratchPrefix) && !named.contains($0)
        }
        return named + singles
    }

    /// The bundle a result written before `originalInputFiles` existed sits
    /// in: `<bundle>.lungfishfastq/derivatives/<result>/`.
    private static func legacyEnclosingBundle(of config: ClassificationConfig) -> URL? {
        let bundle = config.outputDirectory.deletingLastPathComponent().deletingLastPathComponent()
        return FASTQBundle.isBundleURL(bundle) ? bundle.standardizedFileURL : nil
    }

    /// Whether kraken2 classified pairs: the first line of its per-read
    /// output gives the length as `L|L`. An empty or unreadable output says no.
    static func classifiedPairs(in classificationOutput: URL) -> Bool {
        guard let reader = try? FASTQRawLineReader(url: classificationOutput) else { return false }
        defer { reader.close() }
        while let line = try? reader.nextLine() {
            guard !line.isEmpty else { continue }
            let columns = line.split(separator: UInt8(ascii: "\t"), maxSplits: 4, omittingEmptySubsequences: false)
            return columns.count > 3 && columns[3].contains(UInt8(ascii: "|"))
        }
        return false
    }

    /// The files of one input.
    private static func files(of input: URL, materializationDirectory: URL) async throws -> [File] {
        guard FASTQBundle.isBundleURL(input) else { return [File(url: input, role: .reads)] }
        var materializer: (any CLISequenceInputMaterializing & Sendable)?
        if let manifest = FASTQBundle.loadDerivedManifest(in: input) {
            switch manifest.payload {
            case .subset, .trim, .demuxedVirtual, .orientMap:
                let root = FASTQBundle.resolveBundle(relativePath: manifest.rootBundleRelativePath, from: input)
                let source = FASTQDerivedPayloadRoot.pairedOrMixedSource(of: input, recordedRoot: root) ?? root
                if selectsRecordsUnchanged(input, payload: manifest.payload),
                   FASTQBundle.isBundleURL(source), !KrakenReadSetPlanner.isVirtual(source) {
                    return try await files(of: source, materializationDirectory: materializationDirectory)
                }
                materializer = FASTQCLIMaterializer(runner: .shared)
            case .full, .fullFASTA, .fullPaired, .fullMixed, .demuxGroup:
                break
            }
        }
        let resolver = materializer.map {
            ReadSetResolver(materializationDirectory: materializationDirectory, materializer: $0)
        } ?? ReadSetResolver(materializationDirectory: materializationDirectory)
        let source = try await resolver.inspect(input, written: WrittenFiles(), progress: nil)
        return source.parts.flatMap { part -> [File] in
            switch part {
            case .pair(let pair):
                switch pair.files {
                case .separate(let r1, let r2): return [File(url: r1, role: .r1), File(url: r2, role: .r2)]
                case .interleaved(let url): return [File(url: url, role: .adjacentMates)]
                }
            case .single(let single):
                return [File(url: single.url, role: .reads, singleReadRole: single.role)]
            case .mixed(let stream):
                return [File(url: stream.url, role: .adjacentMates, singleReadRole: stream.singleReadRole)]
            }
        }
    }

    /// Whether a virtual derivative only picks records of its source
    /// unchanged, a subset or demultiplexed reads with no trim and no
    /// orientation file, so its read IDs pick from the source's files.
    private static func selectsRecordsUnchanged(_ bundle: URL, payload: FASTQDerivativePayload) -> Bool {
        let fileManager = FileManager.default
        switch payload {
        case .subset:
            return !fileManager.fileExists(atPath: bundle.appendingPathComponent(FASTQBundle.trimPositionFilename).path)
                && !fileManager.fileExists(atPath: bundle.appendingPathComponent("orient-map.tsv").path)
        case .demuxedVirtual(_, _, _, let trimPositionsFilename, let orientMapFilename):
            return trimPositionsFilename == nil && orientMapFilename == nil
        case .trim, .orientMap, .full, .fullPaired, .fullMixed, .fullFASTA, .demuxGroup:
            return false
        }
    }
}
