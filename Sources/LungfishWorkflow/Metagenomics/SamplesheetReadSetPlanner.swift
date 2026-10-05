// SamplesheetReadSetPlanner.swift - How EsViritu and TaxTriage take the reads of one sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. Owner decision 1 of
// 2026-10-03: pairs that were not merged reach a tool as pairs whenever it can
// take them, and nothing is dropped. EsViritu (`-r R1 R2`) and TaxTriage
// (samplesheet `fastq_1` and `fastq_2`) take one file per mate and cannot pair
// part of a sample, so a sample that holds pairs and single reads runs with
// every read single-end and the plan says why (manager ruling 1, Phase 1.5).

import Foundation
import LungfishIO

/// The reads of one sample in the form EsViritu and TaxTriage take them.
public struct SamplesheetReadSet: Sendable, Equatable {

    /// The one file, or the two files, the tool reads.
    public enum Reads: Sendable, Equatable {
        /// One file read as single reads. A sample that mixes pairs and
        /// single reads, and a sample of several files joined into one, end
        /// up here.
        case singleEnd(URL)
        /// An R1 file and an R2 file whose records correspond by position.
        case matePair(r1: URL, r2: URL)
        /// One file in which each R1 record is followed by its R2 record.
        case interleaved(URL)
    }

    public let reads: Reads
    /// The input as the user chose it, a `.lungfishfastq` bundle or a file.
    public let inputURL: URL
    /// The plan the reads came from, with its stated reason when mates run as
    /// single reads and its composition.
    public let plan: ReadSetPlan
    /// What joining several files of single reads into one file wrote, or nil.
    public let concatenation: SequenceInputConcatenation?
    /// When a materialization or a join began and ended, or nil when neither ran.
    public let writeStartedAt: Date?
    public let writeEndedAt: Date?

    /// The files the tool reads, R1 first.
    public var executionURLs: [URL] {
        switch reads {
        case .singleEnd(let url), .interleaved(let url): return [url]
        case .matePair(let r1, let r2): return [r1, r2]
        }
    }

    /// Whether the plan changes what a run reads or records: separate mates,
    /// a joined file, or mates that run as single reads with a stated reason.
    /// A plain single-end file and one interleaved file are what the run reads
    /// without the planner, so they change nothing. The one exception is an
    /// interleaved file that the layout scan sent single-end, which
    /// ``EsVirituConfig/apply(_:)`` runs as interleaved whatever this says.
    public var changesTheRun: Bool {
        switch reads {
        case .matePair: return true
        case .interleaved: return false
        case .singleEnd: return concatenation != nil || plan.singleReadReason != nil
        }
    }

    /// The input and the files the tool reads for it, in the form the
    /// provenance helpers take (``CLISequenceInputMaterialization``).
    public var resolvedInputs: ResolvedSequenceInputs {
        var isMatePair = false
        if case .matePair = reads { isMatePair = true }
        return ResolvedSequenceInputs(
            inputs: [ResolvedSequenceInputs.Input(
                originalURL: inputURL,
                executionURLs: executionURLs,
                wasMaterialized: plan.wasMaterialized || concatenation != nil,
                isMatePair: isMatePair,
                concatenatedFrom: concatenation?.memberURLs ?? []
            )],
            materializationStartedAt: writeStartedAt,
            materializationEndedAt: writeEndedAt
        )
    }
}

/// What the planner will do for an input, from its metadata and a bounded
/// header scan only, so a wizard can show it before the run. Nothing is
/// materialized or written.
public enum SamplesheetReadSetPreview: Sendable, Equatable {
    /// One file of single reads, run as it is.
    case singleReads
    /// One strictly interleaved file, run as it is.
    case interleavedPairs
    /// Separate R1 and R2 files, or one file that mixes pairs and single
    /// reads (`withSingleReads`), which runs with every read single-end.
    case pairs(withSingleReads: Bool)
    /// Several files of single reads, joined into one file when the run starts.
    case severalFiles
    /// A virtual bundle whose lineage holds pairs or merged reads. The run
    /// materializes it and plans the result.
    case decidedAtRunTime

    /// Whether `esviritu detect --read-format auto` must plan this input for
    /// the recorded command to reproduce the run.
    public var plansReadSet: Bool {
        switch self {
        case .pairs, .severalFiles, .decidedAtRunTime: return true
        case .singleReads, .interleavedPairs: return false
        }
    }
}

public enum SamplesheetReadSetPlannerError: LocalizedError, Sendable, Equatable {
    /// The sample holds several R1 and R2 pairs of files, and the tool takes one pair.
    case severalMatePairs(count: Int)
    /// The files the join wrote are not the files the plan found.
    case joinedFilesDiffer(bundlePath: String)
    /// A virtual bundle was not materialized before it was planned.
    case noMaterializedInput(bundlePath: String)
    /// An input that must be one plain read file is not.
    case notOneReadFile(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .severalMatePairs(let count):
            return "The sample holds \(count) separate R1 and R2 pairs of files. The tool takes one pair per sample, so the run stops rather than leave reads out."
        case .joinedFilesDiffer(let bundlePath):
            return "The files joined for \(bundlePath) are not the files its read plan found, so the run stops rather than read part of the sample."
        case .noMaterializedInput(let bundlePath):
            return "The virtual bundle \(bundlePath) was not materialized before it was planned."
        case .notOneReadFile(let path, let detail):
            return "\(path) is named as one read file of a pair, but \(detail)."
        }
    }
}

/// The one function the apps and the commands share to turn one input into the
/// files EsViritu and TaxTriage read (owner decision 1 of 2026-10-03).
///
/// It wraps ``ReadSetResolver`` with the tool's declared
/// ``ReadPairingCapability``, which is ``ReadPairingCapability/Kind/pairsOnlyWhenAllPaired``.
/// A sample of pairs only becomes one mate pair or one interleaved file, a
/// sample of single reads only becomes one file, and a sample that mixes pairs
/// and single reads becomes one file of every read with the plan's stated
/// reason. Several files of single reads (a chunked root, a merge or repair
/// derivative) are joined into one file with the `cat` step and sidecar of
/// ``SequenceInputConcatenation``.
public enum SamplesheetReadSetPlanner {

    /// The one input a command plans: a sample that names exactly one
    /// `.lungfishfastq` bundle or one sequence file.
    public static func plannableInput(_ inputURLs: [URL]) -> URL? {
        guard inputURLs.count == 1, let url = inputURLs.first?.standardizedFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return url.pathExtension.lowercased() == FASTQBundle.directoryExtension ? url : nil
        }
        return url
    }

    /// The bundle `inputURLs` name when they are every member file of one
    /// `.lungfishfastq` bundle, or nil. `assemble` reads the files of one
    /// bundle given separately as that bundle once, and a sample that names
    /// every file a bundle holds has named the bundle. The inputs must be two
    /// or more distinct files that all sit inside one bundle that stores its
    /// reads, and together they must be exactly the files the bundle resolves
    /// to (``FASTQSourceResolver``, the files ``ResolvedSequenceInputs`` reads).
    /// A part of a bundle's files, files of two bundles, a bundle path and a
    /// virtual bundle are not this case, so each file named is that file.
    public static func bundleNamedByEveryMemberFile(_ inputURLs: [URL]) async -> URL? {
        let files = inputURLs.map(\.standardizedFileURL)
        guard files.count > 1,
              Set(files.map(\.path)).count == files.count,
              let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: files[0]),
              files.allSatisfy({ file in
                  file.path != bundleURL.path
                      && SequenceInputResolver.enclosingFASTQBundleURL(for: file)?.path == bundleURL.path
              }),
              SequenceInputResolver.unmaterializedDerivedBundleURL(for: bundleURL) == nil else {
            return nil
        }
        // A bundle that stores its reads resolves to its files without writing.
        guard let members = try? await FASTQSourceResolver().resolve(
            bundleURL: bundleURL,
            tempDirectory: FileManager.default.temporaryDirectory,
            progress: { _, _ in }
        ) else {
            return nil
        }
        func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        return Set(files.map(key)) == Set(members.map(key)) ? bundleURL : nil
    }

    /// The declared capability of `consumerID`.
    public static func capability(for consumerID: String) -> ReadPairingCapability {
        ReadPairingCapabilityRegistry.capability(for: consumerID) ?? .pairsOnlyWhenAllPaired
    }

    /// The plan for one input. A virtual bundle is materialized by
    /// `materializer` into `materializationDirectory`, and so are the files a
    /// join writes. The directory is created when first needed.
    public static func plan(
        input: URL,
        consumerID: String,
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SamplesheetReadSet {
        try await plan(
            input: input,
            consumerID: consumerID,
            materializationDirectory: materializationDirectory,
            materializer: materializer,
            resolverProgress: progress,
            progress: progress
        )
    }

    /// The plan with the resolver's own progress told apart from the join's,
    /// so a caller whose virtual bundle is already materialized does not
    /// report a second materialization.
    private static func plan(
        input: URL,
        consumerID: String,
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        resolverProgress: (@Sendable (String) -> Void)?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> SamplesheetReadSet {
        let input = input.standardizedFileURL
        let startedAt = Date()
        let resolver = ReadSetResolver(materializationDirectory: materializationDirectory, materializer: materializer)
        let plan = try await resolver.plan(for: input, capability: capability(for: consumerID), progress: resolverProgress)
        let singleReads = plan.singleReads
        switch (plan.matePairs.count, singleReads.count) {
        case (1, 0):
            let pair = plan.matePairs[0]
            let reads: SamplesheetReadSet.Reads
            switch pair.files {
            case .separate(let r1, let r2): reads = .matePair(r1: r1, r2: r2)
            case .interleaved(let url): reads = .interleaved(url)
            }
            return readSet(reads, input: input, plan: plan, concatenation: nil, startedAt: startedAt)
        case (0, 1):
            return readSet(.singleEnd(singleReads[0].url), input: input, plan: plan, concatenation: nil, startedAt: startedAt)
        case (0, _) where singleReads.count > 1:
            guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: input) else {
                throw SamplesheetReadSetPlannerError.joinedFilesDiffer(bundlePath: input.path)
            }
            progress?("Joining \(singleReads.count) files of \(bundleURL.lastPathComponent) into one file...")
            let concatenation = try await join(singleReads.map(\.url), of: bundleURL, into: materializationDirectory)
            return readSet(.singleEnd(concatenation.outputURL), input: input, plan: plan, concatenation: concatenation, startedAt: startedAt)
        case (0, 0):
            throw ReadSetResolverError.noReads(path: input.path)
        default:
            throw SamplesheetReadSetPlannerError.severalMatePairs(count: plan.matePairs.count)
        }
    }

    /// The plan for one input whose virtual bundle was already materialized
    /// into `materializedInputs`, so nothing is materialized twice and the
    /// resolver reports no materialization. A join still reports its progress.
    public static func plan(
        input: URL,
        consumerID: String,
        materializedInputs: [URL],
        materializationDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SamplesheetReadSet {
        try await plan(
            input: input,
            consumerID: consumerID,
            materializationDirectory: materializationDirectory,
            materializer: AlreadyMaterialized(files: materializedInputs),
            resolverProgress: nil,
            progress: progress
        )
    }

    /// What `input` holds for these tools, from metadata and a bounded header
    /// scan. Nothing is materialized or written.
    public static func preview(input: URL) async -> SamplesheetReadSetPreview {
        let input = input.standardizedFileURL
        if let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: input), isVirtual(bundle) {
            let hasPairEvidence = ReadSetResolver.lineageEvidence(of: bundle).evidence != nil
                || pairingModeHoldsPairs(FASTQBundle.loadDerivedManifest(in: bundle)?.pairingMode)
            if hasPairEvidence { return .decidedAtRunTime }
            guard let physical = ReadSetResolver.ancestors(of: bundle).first(where: { !isVirtual($0) }) else {
                return .singleReads
            }
            // A virtual bundle materializes to one file, so several files of
            // single reads in what it derives from need no join.
            switch await preview(input: physical) {
            case .singleReads, .severalFiles: return .singleReads
            default: return .decidedAtRunTime
            }
        }
        let resolver = ReadSetResolver(materializationDirectory: FileManager.default.temporaryDirectory)
        guard let source = try? await resolver.inspect(input, written: WrittenFiles(), progress: nil) else {
            return .singleReads
        }
        if !source.mixedStreams.isEmpty { return .pairs(withSingleReads: true) }
        let pairs = source.pairs
        guard !pairs.isEmpty else { return source.singles.count > 1 ? .severalFiles : .singleReads }
        let everyPairIsInterleaved = pairs.allSatisfy { pair in
            if case .interleaved = pair.files { return true }
            return false
        }
        if everyPairIsInterleaved, source.singles.isEmpty { return .interleavedPairs }
        return .pairs(withSingleReads: !source.singles.isEmpty)
    }

    // MARK: - Helpers

    private static func readSet(
        _ reads: SamplesheetReadSet.Reads,
        input: URL,
        plan: ReadSetPlan,
        concatenation: SequenceInputConcatenation?,
        startedAt: Date
    ) -> SamplesheetReadSet {
        let wroteFiles = plan.wasMaterialized || concatenation != nil
        return SamplesheetReadSet(
            reads: reads,
            inputURL: input,
            plan: plan,
            concatenation: concatenation,
            writeStartedAt: wroteFiles ? startedAt : nil,
            writeEndedAt: wroteFiles ? Date() : nil
        )
    }

    /// Joins `files`, the files of single reads one bundle holds, into one
    /// file in `directory`, with the `cat` sidecar of ``SequenceInputConcatenation``.
    /// A chunked root is joined in `source-files.json` order, any other bundle
    /// (a merge or repair derivative) as ``ResolvedSequenceInputs`` joins the
    /// unpaired files of one bundle. The joined files must be exactly `files`,
    /// so no read is left out and none is read twice.
    private static func join(_ files: [URL], of bundleURL: URL, into directory: URL) async throws -> SequenceInputConcatenation {
        let concatenation: SequenceInputConcatenation
        if let rootJoin = try ResolvedSequenceInputs.concatenateMultiFileBundle(bundleURL, into: directory) {
            concatenation = rootJoin
        } else {
            let resolved = try await ResolvedSequenceInputs.resolve(
                inputURLs: [bundleURL],
                materializationDirectory: directory,
                materializer: AlreadyMaterialized(files: []),
                concatenateUnpairedFiles: true
            )
            guard resolved.inputs.count == 1,
                  let input = resolved.inputs.first,
                  !input.concatenatedFrom.isEmpty,
                  input.executionURLs.count == 1,
                  let output = input.executionURLs.first,
                  let written = SequenceInputConcatenation.load(for: output) else {
                throw SamplesheetReadSetPlannerError.joinedFilesDiffer(bundlePath: bundleURL.path)
            }
            concatenation = written
        }
        let joined = Set(concatenation.memberURLs.map(\.standardizedFileURL))
        guard joined == Set(files.map(\.standardizedFileURL)) else {
            concatenation.removeOutput()
            throw SamplesheetReadSetPlannerError.joinedFilesDiffer(bundlePath: bundleURL.path)
        }
        return concatenation
    }

    /// Whether `bundle` is a virtual derivative, which holds a recipe and a
    /// preview rather than its reads.
    private static func isVirtual(_ bundle: URL) -> Bool {
        switch FASTQBundle.loadDerivedManifest(in: bundle)?.payload {
        case nil, .full, .fullPaired, .fullMixed, .fullFASTA: return false
        case .some: return true
        }
    }

    private static func pairingModeHoldsPairs(_ mode: IngestionMetadata.PairingMode?) -> Bool {
        switch mode {
        case .interleaved, .pairedEnd: return true
        default: return false
        }
    }
}

/// Hands the resolver the file a virtual bundle was already materialized to,
/// and refuses to materialize anything else.
private struct AlreadyMaterialized: CLISequenceInputMaterializing, Sendable {
    let files: [URL]

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        guard files.count == 1, let file = files.first else {
            throw SamplesheetReadSetPlannerError.noMaterializedInput(bundlePath: bundleURL.path)
        }
        return file
    }
}
