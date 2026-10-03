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
    case noMaterializedInput(bundlePath: String)
    case unpairedNeedsAPair

    public var errorDescription: String? {
        switch self {
        case .severalMatePairs(let count):
            return "The sample holds \(count) separate R1 and R2 pairs of files. Kraken2 classifies one pair of files per sample, so the run stops rather than leave reads out."
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

    /// The bundle a sample names when it names exactly one `.lungfishfastq`
    /// bundle, the only input `--read-format auto` plans.
    public static func plannableBundle(_ inputURLs: [URL]) -> URL? {
        guard inputURLs.count == 1, let url = inputURLs.first?.standardizedFileURL,
              url.pathExtension.lowercased() == FASTQBundle.directoryExtension else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    /// The plan for one bundle. A virtual bundle is planned from the file
    /// `materializedInputs` already holds, so nothing is materialized twice.
    /// Splits are written into `materializationDirectory`.
    public static func plan(
        bundle: URL,
        materializedInputs: [URL],
        materializationDirectory: URL
    ) async throws -> ReadSetPlan {
        let resolver = ReadSetResolver(
            materializationDirectory: materializationDirectory,
            materializer: AlreadyMaterialized(files: materializedInputs),
            countReads: true
        )
        return try await resolver.plan(for: bundle, capability: capability)
    }

    /// The plan for loose files the user named: an R1 and R2 file and files
    /// of merged or single reads (`--unpaired`).
    public static func plan(
        r1: URL,
        r2: URL,
        singleReads: [URL],
        materializationDirectory: URL
    ) throws -> ReadSetPlan {
        let resolver = ReadSetResolver(materializationDirectory: materializationDirectory, countReads: true)
        return try resolver.plan(r1: r1, r2: r2, singleReads: singleReads, capability: capability)
    }

    /// Sets `config`'s inputs from `plan`. A plan of single reads only leaves
    /// the config as it is. Returns whether the config changed.
    @discardableResult
    public static func apply(_ plan: ReadSetPlan, to config: inout ClassificationConfig) throws -> Bool {
        let pairs = plan.matePairs
        guard !pairs.isEmpty else { return false }
        guard pairs.count == 1, let pair = pairs.first else {
            throw KrakenReadSetPlannerError.severalMatePairs(count: pairs.count)
        }
        switch pair.files {
        case .interleaved(let url):
            // An interleaved file keeps today's positional split.
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
            // A bundle is recorded with `auto`. Loose files keep `--paired`
            // with each file of single reads as `--unpaired`.
            config.plansReadSet = plannableBundle([plan.inputURL]) != nil
            return true
        }
    }

    /// What `bundle` holds for Kraken2, from metadata and a bounded header
    /// scan. Nothing is materialized or written.
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
    /// `singleReadFile` with an empty sequence and an empty quality line.
    public func emptyMateURL(for singleReadFile: URL) -> URL {
        var stem = singleReadFile.lastPathComponent
        for suffix in [".gz", ".fastq", ".fq"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        let position = singleReadFiles.firstIndex(of: singleReadFile) ?? 0
        let clashes = singleReadFiles.filter { $0.lastPathComponent == singleReadFile.lastPathComponent }.count > 1
        let name = clashes ? "\(position + 1)-\(stem).emptymate.fastq" : "\(stem).emptymate.fastq"
        return outputDirectory
            .appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
            .appendingPathComponent(name)
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
