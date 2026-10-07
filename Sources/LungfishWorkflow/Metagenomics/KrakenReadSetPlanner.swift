// KrakenReadSetPlanner.swift - How a Kraken2 sample's reads reach kraken2, pairs as pairs and single reads beside them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. Owner decisions 1 and 2 of
// 2026-10-03: pairs are classified as pairs, and merged or single reads are
// classified beside them in the same kraken2 run.

import Foundation
import LungfishIO

/// How many fragments a Kraken2 run classified, by kind. A pair counts once
/// and a merged read counts once. Written to a result only when the run held
/// pairs.
public struct ClassificationFragmentComposition: Codable, Sendable, Equatable {
    public var pairedFragments: Int
    public var mergedReads: Int
    public var orphanReads: Int
    public var singleEndReads: Int
    /// Reads without a mate split from a file that mixes them with pairs,
    /// when the file does not say whether they are merged or orphans. Nil
    /// when there are none.
    public var mergedOrOrphanReads: Int?

    public init(
        pairedFragments: Int,
        mergedReads: Int,
        orphanReads: Int,
        singleEndReads: Int,
        mergedOrOrphanReads: Int? = nil
    ) {
        self.pairedFragments = pairedFragments
        self.mergedReads = mergedReads
        self.orphanReads = orphanReads
        self.singleEndReads = singleEndReads
        self.mergedOrOrphanReads = mergedOrOrphanReads == 0 ? nil : mergedOrOrphanReads
    }

    /// The composition of a plan, or nil when a kind present was not counted.
    public init?(_ composition: ReadSetComposition) {
        guard let paired = composition.pairedFragments,
              let merged = composition.mergedReads,
              let orphan = composition.orphanReads,
              let singleEnd = composition.singleEndReads,
              let mergedOrOrphan = composition.mergedOrOrphanReads else { return nil }
        self.init(
            pairedFragments: paired,
            mergedReads: merged,
            orphanReads: orphan,
            singleEndReads: singleEnd,
            mergedOrOrphanReads: mergedOrOrphan
        )
    }

    /// Fragments from merged, orphan and single-end reads.
    public var singleReadFragments: Int {
        mergedReads + orphanReads + singleEndReads + (mergedOrOrphanReads ?? 0)
    }

    /// Every fragment kraken2 classified.
    public var fragmentCount: Int { pairedFragments + singleReadFragments }

    /// The line the result viewer shows under its fragment count.
    public var summaryLine: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        func format(_ value: Int) -> String { formatter.string(from: NSNumber(value: value)) ?? String(value) }
        return "\(format(fragmentCount)) fragments, \(format(pairedFragments)) from read pairs "
            + "and \(format(singleReadFragments)) from merged or single reads"
    }
}

/// What a bundle holds for Kraken2, read from its manifest and a bounded
/// header scan only, so the wizard can show it before the run.
public enum KrakenReadSetPreview: Sendable, Equatable {
    /// Single reads only. The run is today's single-end run.
    case singleReads
    /// One strictly interleaved file, split by position as today.
    case interleavedPairs
    /// Separate R1 and R2 reads, with single reads beside them or not.
    case pairs(withSingleReads: Bool)
    /// A virtual bundle whose lineage holds pairs or merged reads. The run
    /// materializes it and plans the result.
    case decidedAtRunTime

    /// Whether `conda classify --read-format auto` must plan this bundle for
    /// the recorded command to reproduce the run.
    public var plansReadSet: Bool {
        switch self {
        case .pairs, .decidedAtRunTime: return true
        case .singleReads, .interleavedPairs: return false
        }
    }

    /// The wizard's input label for a bundle that plans its read set.
    public var inputLabel: String? {
        switch self {
        case .pairs(let withSingleReads):
            return withSingleReads ? "Read pairs and merged or single reads" : "Read pairs"
        case .decidedAtRunTime:
            return "Read pairs and merged reads, found when the reads are materialized"
        case .singleReads, .interleavedPairs:
            return nil
        }
    }
}

public enum KrakenReadSetPlannerError: LocalizedError, Sendable, Equatable {
    case severalMatePairs(count: Int)
    case singleReadsBesideAnInterleavedPair(count: Int)
    case noMaterializedInput(bundlePath: String)
    case unpairedNeedsAPair

    public var errorDescription: String? {
        switch self {
        case .severalMatePairs(let count):
            return "The sample holds \(count) separate R1 and R2 pairs of files. Kraken2 classifies one pair of files per sample, so the run stops rather than leave reads out."
        case .singleReadsBesideAnInterleavedPair(let count):
            return "The sample holds an interleaved file of pairs and \(count) file(s) of single reads. Kraken2 splits an interleaved file by position and runs it alone, so the run stops rather than leave the single reads out."
        case .noMaterializedInput(let bundlePath):
            return "The virtual bundle \(bundlePath) was not materialized before it was planned."
        case .unpairedNeedsAPair:
            return "--unpaired needs --paired and exactly two input files, the R1 and R2 the single reads run beside."
        }
    }
}

/// The one function the app and `lungfish-cli conda classify` share to turn
/// a sample into the files kraken2 reads (decisions 1 and 2).
///
/// It wraps ``ReadSetResolver`` with Kraken2's capability. A sample of single
/// reads only, or one interleaved file, keeps today's kraken2 command byte for
/// byte. A sample with separate R1 and R2 reads runs `--paired R1 R2`, and any
/// merged or single reads run beside the pair in the same process.
public enum KrakenReadSetPlanner {

    public static let consumerID = "classify.kraken2"

    /// Kraken2's declared capability, pairs and single reads in one run as
    /// separate files.
    public static var capability: ReadPairingCapability {
        ReadPairingCapabilityRegistry.capability(for: consumerID) ?? .bothInOneRunAsSeparateFiles
    }

    /// The directory inside a run's output folder that holds materialized,
    /// split and staged inputs.
    public static let inputsDirectoryName = ".lungfish-classify-inputs"

    /// The one input `--read-format auto` plans: a sample that names exactly
    /// one `.lungfishfastq` bundle or one sequence file.
    public static func plannableInput(_ inputURLs: [URL]) -> URL? {
        guard inputURLs.count == 1, let url = inputURLs.first?.standardizedFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return url.pathExtension.lowercased() == FASTQBundle.directoryExtension ? url : nil
        }
        return url
    }

    /// The plan for one input, a bundle or a sequence file. A virtual bundle
    /// is planned from the file `materializedInputs` already holds, so nothing
    /// is materialized twice. Splits are written into `materializationDirectory`.
    /// Only a plan that holds pairs is counted (``countedIfItHoldsPairs(_:)``).
    public static func plan(
        bundle: URL,
        materializedInputs: [URL],
        materializationDirectory: URL
    ) async throws -> ReadSetPlan {
        let resolver = ReadSetResolver(
            materializationDirectory: materializationDirectory,
            materializer: AlreadyMaterialized(files: materializedInputs)
        )
        return try countedIfItHoldsPairs(try await resolver.plan(for: bundle, capability: capability))
    }

    /// The plan for loose files the user named: an R1 and R2 file and files
    /// of merged or single reads (`--unpaired`).
    public static func plan(
        r1: URL,
        r2: URL,
        singleReads: [URL],
        materializationDirectory: URL
    ) throws -> ReadSetPlan {
        let resolver = ReadSetResolver(materializationDirectory: materializationDirectory)
        return try countedIfItHoldsPairs(
            try resolver.plan(r1: r1, r2: r2, singleReads: singleReads, capability: capability)
        )
    }

    /// `plan` with every count it lacks read from its files, when it holds
    /// pairs. Only then are the counts used, by the fragment guard and the
    /// result's composition, which follows the resolver's one rule
    /// (``ReadSetComposition/init(runs:)``). A plan of single reads applies nothing, so its
    /// files are not read a second time. Counts the plan already has are kept:
    /// a split counts what it writes, a merge or repair derivative records its
    /// roles' counts, and a materialization is counted whole when it is read.
    static func countedIfItHoldsPairs(_ plan: ReadSetPlan) throws -> ReadSetPlan {
        guard !plan.matePairs.isEmpty else { return plan }
        let runs: [ReadSetRun]
        do {
            runs = try plan.runs.map { run in
                ReadSetRun(
                    matePairs: try run.matePairs.map { pair in
                        guard pair.pairCount == nil else { return pair }
                        let records = try FASTQPairInterleaver.countRecords(in: pair.urls[0])
                        if case .interleaved = pair.files {
                            return ReadSetMatePair(files: pair.files, pairCount: records / 2)
                        }
                        return ReadSetMatePair(files: pair.files, pairCount: records)
                    },
                    singleReads: try run.singleReads.map { single in
                        guard single.readCount == nil, SequenceFormat.from(url: single.url) != .fasta else { return single }
                        let records = try FASTQPairInterleaver.countRecords(in: single.url)
                        return ReadSetSingleReads(url: single.url, role: single.role, readCount: records)
                    },
                    mixedStreams: try run.mixedStreams.map { stream in
                        guard stream.pairCount == nil || stream.singleReadCount == nil else { return stream }
                        let counts = try FASTQPairInterleaver.countMixed(interleaved: stream.url)
                        return ReadSetMixedStream(
                            url: stream.url,
                            pairCount: counts.pairs,
                            singleReadCount: counts.unpaired,
                            singleReadRole: stream.singleReadRole
                        )
                    }
                )
            }
        } catch {
            // The files a split wrote for this plan go with it.
            for url in plan.steps.flatMap(\.outputURLs) { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return ReadSetPlan(
            inputURL: plan.inputURL,
            capability: plan.capability,
            sourceLayout: plan.sourceLayout,
            layoutReason: plan.layoutReason,
            sequencingPlatform: plan.sequencingPlatform,
            wasMaterialized: plan.wasMaterialized,
            sampleHoldsPairsAndSingleReads: plan.sampleHoldsPairsAndSingleReads,
            runs: runs,
            steps: plan.steps,
            singleReadReason: plan.singleReadReason,
            composition: ReadSetComposition(runs: runs)
        )
    }

    /// Sets `config`'s inputs from `plan`. A plan of single reads only leaves
    /// the config as it is. Returns whether the config changed.
    /// `recordedWithAuto` is false for loose files named as a pair with
    /// `--unpaired`, which the recorded command names as such.
    @discardableResult
    public static func apply(
        _ plan: ReadSetPlan,
        to config: inout ClassificationConfig,
        recordedWithAuto: Bool = true
    ) throws -> Bool {
        let pairs = plan.matePairs
        guard !pairs.isEmpty else { return false }
        guard pairs.count == 1, let pair = pairs.first else {
            throw KrakenReadSetPlannerError.severalMatePairs(count: pairs.count)
        }
        switch pair.files {
        case .interleaved(let url):
            // An interleaved file keeps today's positional split. kraken2
            // reads it alone, so no file of single reads can run beside it,
            // and the run stops rather than leave them out (final review N3).
            guard plan.singleReads.isEmpty else {
                throw KrakenReadSetPlannerError.singleReadsBesideAnInterleavedPair(count: plan.singleReads.count)
            }
            let before = config
            config.inputFiles = [url]
            config.isPairedEnd = false
            config.interleavedInput = true
            config.singleReadFiles = []
            config.readSetPlan = plan
            return before.inputFiles != config.inputFiles || !before.interleavedInput
        case .separate(let r1, let r2):
            config.inputFiles = [r1, r2]
            config.isPairedEnd = true
            config.interleavedInput = false
            config.singleReadFiles = plan.singleReads.map(\.url)
            config.readSetPlan = plan
            // One input is recorded with `auto`. Loose files named as a pair
            // keep `--paired` with each file of single reads as `--unpaired`.
            config.plansReadSet = recordedWithAuto
            return true
        }
    }

    /// What `bundle` (a bundle or a sequence file) holds for Kraken2, from
    /// metadata and a bounded header scan. Nothing is materialized or written.
    public static func preview(bundle: URL) async -> KrakenReadSetPreview {
        let bundle = bundle.standardizedFileURL
        if isVirtual(bundle) {
            let hasPairEvidence = ReadSetResolver.lineageEvidence(of: bundle).evidence != nil
                || pairingModeHoldsPairs(FASTQBundle.loadDerivedManifest(in: bundle)?.pairingMode)
            if hasPairEvidence { return .decidedAtRunTime }
            guard let physical = ReadSetResolver.ancestors(of: bundle).first(where: { !isVirtual($0) }) else {
                return .singleReads
            }
            return await preview(bundle: physical) == .singleReads ? .singleReads : .decidedAtRunTime
        }
        let resolver = ReadSetResolver(materializationDirectory: FileManager.default.temporaryDirectory)
        guard let source = try? await resolver.inspect(bundle, written: WrittenFiles(), progress: nil) else {
            return .singleReads
        }
        if !source.mixedStreams.isEmpty { return .pairs(withSingleReads: true) }
        let pairs = source.pairs
        guard !pairs.isEmpty else { return .singleReads }
        if pairs.allSatisfy({ if case .interleaved = $0.files { return true } else { return false } }),
           source.singles.isEmpty {
            return .interleavedPairs
        }
        return .pairs(withSingleReads: !source.singles.isEmpty)
    }

    /// Whether a result's original inputs hold read pairs, from metadata and
    /// a bounded header scan only (manager ruling 3). Nil when an input is
    /// gone or is virtual, so the answer is unknown and no label is shown.
    public static func originalInputsHoldPairs(_ originalInputs: [URL]) async -> Bool? {
        guard !originalInputs.isEmpty else { return nil }
        var holdsPairs = false
        for input in originalInputs {
            let url = input.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: url), isVirtual(bundle) {
                return nil
            }
            let resolver = ReadSetResolver(materializationDirectory: FileManager.default.temporaryDirectory)
            guard let source = try? await resolver.inspect(url, written: WrittenFiles(), progress: nil) else {
                return nil
            }
            holdsPairs = holdsPairs || source.holdsPairs
        }
        return holdsPairs
    }

    // MARK: - Helpers

    /// Whether `bundle` is a virtual derivative, which holds a recipe and a
    /// preview rather than its reads.
    static func isVirtual(_ bundle: URL) -> Bool {
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

/// Hands the resolver the file a virtual bundle was already materialized to.
private struct AlreadyMaterialized: CLISequenceInputMaterializing, Sendable {
    let files: [URL]

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        guard files.count == 1, let file = files.first else {
            throw KrakenReadSetPlannerError.noMaterializedInput(bundlePath: bundleURL.path)
        }
        return file
    }
}

extension ClassificationConfig {

    /// The header-only mate staged for a file of single reads, inside the
    /// run's `.lungfish-classify-inputs` folder. It repeats each header of
    /// `singleReadFile` with an empty sequence and an empty quality line, and
    /// it is gzip-compressed when R1 is (``kraken2SingleReadURL(for:)``).
    public func emptyMateURL(for singleReadFile: URL) -> URL {
        stagedInputURL(for: singleReadFile, kind: "emptymate")
    }

    /// The file kraken2 reads for `singleReadFile`. The kraken2 wrapper reads
    /// every input in the compression of its first, R1, so a file of single
    /// reads in the other compression is read from a staged copy
    /// (final review S1).
    func kraken2SingleReadURL(for singleReadFile: URL) -> URL {
        stagedSingleReadCopyURL(for: singleReadFile) ?? singleReadFile
    }

    /// The copy of `singleReadFile` staged in the compression of R1, or nil
    /// when the file has that compression and is read as it is.
    func stagedSingleReadCopyURL(for singleReadFile: URL) -> URL? {
        Self.isGzipCompressed(singleReadFile) == r1IsGzipCompressed
            ? nil
            : stagedInputURL(for: singleReadFile, kind: "staged")
    }

    /// Whether R1 starts with the gzip magic bytes, the test the kraken2
    /// wrapper makes of its first input.
    var r1IsGzipCompressed: Bool {
        inputFiles.first.map(Self.isGzipCompressed) ?? false
    }

    /// The files kraken2 reads for ``inputFiles``, each in the compression
    /// of R1, the first. The kraken2 wrapper pipes every input through the
    /// decompressor of its first input, so a plain R2 beside a gzip R1 reads
    /// as empty and a gzip R2 beside a plain R1 reads as one unreadable
    /// record, and kraken2 still exits 0. A file in the other compression is
    /// read from a staged copy (``stagedInputCopyURL(at:)``).
    var kraken2InputURLs: [URL] {
        inputFiles.indices.map { stagedInputCopyURL(at: $0) ?? inputFiles[$0] }
    }

    /// The copy of input `index` staged in the compression of R1, or nil
    /// when the file has that compression and is read as it is. The copy is
    /// `<n>-<stem>.input.<fastq|fasta>` in the run's inputs folder, numbered
    /// by its input position, with `.gz` when R1 is gzip.
    func stagedInputCopyURL(at index: Int) -> URL? {
        guard index > 0, index < inputFiles.count,
              Self.isGzipCompressed(inputFiles[index]) != r1IsGzipCompressed else { return nil }
        var stem = inputFiles[index].lastPathComponent
        if stem.lowercased().hasSuffix(".gz") { stem = String(stem.dropLast(3)) }
        let fastaExtensions = ["fa", "fasta", "fna"]
        let isFASTA = fastaExtensions.contains(URL(fileURLWithPath: stem).pathExtension.lowercased())
        stem = URL(fileURLWithPath: stem).deletingPathExtension().lastPathComponent
        let filename = "\(index + 1)-\(stem).input.\(isFASTA ? "fasta" : "fastq")" + (r1IsGzipCompressed ? ".gz" : "")
        return outputDirectory
            .appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Every input copy a run stages, with the input it copies.
    var stagedInputCopies: [(source: URL, copy: URL)] {
        inputFiles.indices.compactMap { index in stagedInputCopyURL(at: index).map { (inputFiles[index], $0) } }
    }

    static func isGzipCompressed(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data([0x1F, 0x8B])
    }

    /// `<stem>.<kind>.fastq` in the run's inputs folder, with `.gz` when R1
    /// is gzip. Files of single reads whose stems match, ignoring case, are
    /// numbered, so `merged.fastq` and `merged.fastq.gz` stage apart.
    private func stagedInputURL(for singleReadFile: URL, kind: String) -> URL {
        func stem(_ url: URL) -> String {
            var stem = url.lastPathComponent
            for suffix in [".gz", ".fastq", ".fq"] where stem.lowercased().hasSuffix(suffix) {
                stem = String(stem.dropLast(suffix.count))
            }
            return stem
        }
        let name = stem(singleReadFile)
        let position = singleReadFiles.firstIndex(of: singleReadFile) ?? 0
        let clashes = singleReadFiles.filter { stem($0).lowercased() == name.lowercased() }.count > 1
        let filename = (clashes ? "\(position + 1)-\(name)" : name) + ".\(kind).fastq" + (r1IsGzipCompressed ? ".gz" : "")
        return outputDirectory
            .appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// The input label the CLI prints and the wizard shows for this run.
    public var inputLabel: String {
        singleReadFiles.isEmpty
            ? ReadFormat.inputLabel(format: readFormat, layout: inputLayout?.layout)
            : "Read pairs and merged or single reads"
    }

    /// The fragment composition of this run's plan, when the plan held pairs.
    public var fragmentComposition: ClassificationFragmentComposition? {
        guard let plan = readSetPlan, !plan.matePairs.isEmpty else { return nil }
        return ClassificationFragmentComposition(plan.composition)
    }

    /// Copies the read-set fields that the memberwise initializer leaves out.
    mutating func copyReadSet(from other: ClassificationConfig) {
        singleReadFiles = other.singleReadFiles
        plansReadSet = other.plansReadSet
        readSetPlan = other.readSetPlan
    }
}
