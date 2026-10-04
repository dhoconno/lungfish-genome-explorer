// ReadSetPlan.swift - The reads of one sample as pairs and single reads, in the form one tool takes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// What a file of single reads holds.
public enum ReadSetReadRole: String, Codable, Sendable, CaseIterable {
    /// Overlap-merged reads. Each is one fragment.
    case merged
    /// Reads whose mate was removed. Each is one fragment.
    case orphan
    /// Reads of a single-end run, or of a file with no mates in it.
    case singleEnd = "single_end"
    /// The reads without a mate in a file that mixes them with pairs. They
    /// are merged or orphan reads, and the file does not say which.
    case mergedOrOrphan = "merged_or_orphan"
    /// Mates of pairs, possibly with other reads, handed to the tool as
    /// single reads because the tool cannot pair them in this sample.
    case pairsRunAsSingle = "pairs_run_as_single"
}

/// The R1 and R2 reads of a set of mate pairs.
public struct ReadSetMatePair: Sendable, Equatable {
    public enum Files: Sendable, Equatable {
        /// Two files whose records correspond by position.
        case separate(r1: URL, r2: URL)
        /// One file in which every R1 record is followed by its R2 record.
        case interleaved(URL)
    }

    public let files: Files
    /// The number of pairs, when known.
    public let pairCount: Int?

    public init(files: Files, pairCount: Int? = nil) {
        switch files {
        case .separate(let r1, let r2):
            self.files = .separate(r1: r1.standardizedFileURL, r2: r2.standardizedFileURL)
        case .interleaved(let url):
            self.files = .interleaved(url.standardizedFileURL)
        }
        self.pairCount = pairCount
    }

    /// The files in the order a tool reads them, R1 first.
    public var urls: [URL] {
        switch files {
        case .separate(let r1, let r2): return [r1, r2]
        case .interleaved(let url): return [url]
        }
    }
}

/// One file of single reads and what they are.
public struct ReadSetSingleReads: Sendable, Equatable {
    public let url: URL
    public let role: ReadSetReadRole
    /// The number of reads, when known.
    public let readCount: Int?

    public init(url: URL, role: ReadSetReadRole, readCount: Int? = nil) {
        self.url = url.standardizedFileURL
        self.role = role
        self.readCount = readCount
    }
}

/// One file that holds adjacent mate pairs and single reads, paired by
/// fragment name (a VSP2 import, or the stream the resolver writes for a
/// ``ReadPairingCapability/MixedInput/nameInterleavedStream`` tool).
public struct ReadSetMixedStream: Sendable, Equatable {
    public let url: URL
    public let pairCount: Int?
    public let singleReadCount: Int?
    /// What the reads without a mate are.
    public let singleReadRole: ReadSetReadRole

    public init(url: URL, pairCount: Int? = nil, singleReadCount: Int? = nil, singleReadRole: ReadSetReadRole) {
        self.url = url.standardizedFileURL
        self.pairCount = pairCount
        self.singleReadCount = singleReadCount
        self.singleReadRole = singleReadRole
    }
}

/// The reads one tool run receives.
public struct ReadSetRun: Sendable, Equatable {
    public let matePairs: [ReadSetMatePair]
    public let singleReads: [ReadSetSingleReads]
    public let mixedStreams: [ReadSetMixedStream]

    public init(
        matePairs: [ReadSetMatePair] = [],
        singleReads: [ReadSetSingleReads] = [],
        mixedStreams: [ReadSetMixedStream] = []
    ) {
        self.matePairs = matePairs
        self.singleReads = singleReads
        self.mixedStreams = mixedStreams
    }

    /// Every file of the run: pairs first, then single reads, then mixed streams.
    public var executionURLs: [URL] {
        matePairs.flatMap(\.urls) + singleReads.map(\.url) + mixedStreams.map(\.url)
    }
}

/// Where the reads of a sample came from, before any split.
public enum ReadSetSourceLayout: String, Codable, Sendable, CaseIterable {
    /// One file with no mates in it.
    case singleEndFile = "single_end_file"
    /// One file in which every record is followed by its mate.
    case interleavedFile = "interleaved_file"
    /// One file that mixes adjacent mate pairs with merged or orphan reads.
    case mixedFile = "mixed_file"
    /// Several files of single reads (a chunked root such as an ONT import).
    case multiFileRoot = "multi_file_root"
    /// An R1 file and an R2 file.
    case pairedFiles = "paired_files"
    /// Separate files with roles (a merge or repair derivative).
    case mixedDerivative = "mixed_derivative"
    /// One or more single-read files given together with an R1 and R2 file.
    case pairedFilesWithSingleReads = "paired_files_with_single_reads"
    /// A FASTA file, read as single records.
    case fasta
}

/// How many fragments a sample holds, by kind. A pair counts once and a
/// merged read counts once. A count is nil when it was not read.
public struct ReadSetComposition: Sendable, Equatable {
    public var pairedFragments: Int?
    public var mergedReads: Int?
    public var orphanReads: Int?
    public var singleEndReads: Int?
    /// Reads without a mate in a mixed file, merged or orphan.
    public var mergedOrOrphanReads: Int?

    public init(
        pairedFragments: Int? = nil,
        mergedReads: Int? = nil,
        orphanReads: Int? = nil,
        singleEndReads: Int? = nil,
        mergedOrOrphanReads: Int? = nil
    ) {
        self.pairedFragments = pairedFragments
        self.mergedReads = mergedReads
        self.orphanReads = orphanReads
        self.singleEndReads = singleEndReads
        self.mergedOrOrphanReads = mergedOrOrphanReads
    }

    /// The total fragment count, or nil when any kind present was not counted.
    public var fragmentCount: Int? {
        let counts = [pairedFragments, mergedReads, orphanReads, singleEndReads, mergedOrOrphanReads]
        guard counts.allSatisfy({ $0 != nil }) else { return nil }
        return counts.reduce(0) { $0 + ($1 ?? 0) }
    }
}

extension ReadSetComposition {

    /// What one part of a sample adds to its composition.
    enum Contribution {
        /// Mate pairs, each one fragment.
        case pairs(Int?)
        /// Single reads of one role, each one fragment.
        case singleReads(Int?, ReadSetReadRole)
    }

    /// The one rule that turns parts into fragment counts by kind. A kind
    /// that is absent counts zero, and a kind that is present with no count
    /// makes its total nil.
    init(counting contributions: [Contribution]) {
        self.init(pairedFragments: 0, mergedReads: 0, orphanReads: 0, singleEndReads: 0, mergedOrOrphanReads: 0)
        for contribution in contributions {
            let keyPath: WritableKeyPath<ReadSetComposition, Int?>
            let value: Int?
            switch contribution {
            case .pairs(let count):
                keyPath = \.pairedFragments
                value = count
            case .singleReads(let count, let role):
                value = count
                switch role {
                case .merged: keyPath = \.mergedReads
                case .orphan: keyPath = \.orphanReads
                case .singleEnd, .pairsRunAsSingle: keyPath = \.singleEndReads
                case .mergedOrOrphan: keyPath = \.mergedOrOrphanReads
                }
            }
            guard let current = self[keyPath: keyPath] else { continue }
            self[keyPath: keyPath] = value.map { current + $0 }
        }
    }

    /// The fragment counts of the reads `runs` hand a tool.
    init(runs: [ReadSetRun]) {
        self.init(counting: runs.flatMap { run -> [Contribution] in
            run.matePairs.map { .pairs($0.pairCount) }
                + run.singleReads.map { .singleReads($0.readCount, $0.role) }
                + run.mixedStreams.flatMap { [.pairs($0.pairCount), .singleReads($0.singleReadCount, $0.singleReadRole)] }
        })
    }
}

/// The reads of one sample, in the form one tool takes them.
///
/// ``ReadSetResolver`` makes a plan from what the sample holds and the
/// tool's ``ReadPairingCapability``. A plan whose sample holds only single
/// reads or only pairs makes no step and records nothing new
/// (``recordsNothingNew``), so a tool that adopts the resolver keeps its
/// command for such a sample.
public struct ReadSetPlan: Sendable, Equatable {
    /// The input as the user chose it.
    public let inputURL: URL
    public let capability: ReadPairingCapability
    public let sourceLayout: ReadSetSourceLayout
    /// Why the sample was read as ``sourceLayout``.
    public let layoutReason: String
    /// The platform the bundle records, when it records one.
    public let sequencingPlatform: SequencingPlatform?
    /// Whether a virtual bundle was materialized for this plan.
    public let wasMaterialized: Bool
    /// Whether the sample holds both pairs and single reads.
    public let sampleHoldsPairsAndSingleReads: Bool
    /// The tool runs, usually one. A ``ReadPairingCapability/Kind/pairsOrSinglesPerRun``
    /// tool gets a run of pairs and a run of single reads.
    public let runs: [ReadSetRun]
    /// The splits and interleaves this plan wrote, in order.
    public let steps: [ReadSetStep]
    /// Why mates are handed to the tool as single reads, or nil when they are not.
    public let singleReadReason: String?
    public let composition: ReadSetComposition

    public init(
        inputURL: URL,
        capability: ReadPairingCapability,
        sourceLayout: ReadSetSourceLayout,
        layoutReason: String,
        sequencingPlatform: SequencingPlatform?,
        wasMaterialized: Bool,
        sampleHoldsPairsAndSingleReads: Bool,
        runs: [ReadSetRun],
        steps: [ReadSetStep],
        singleReadReason: String?,
        composition: ReadSetComposition
    ) {
        self.inputURL = inputURL.standardizedFileURL
        self.capability = capability
        self.sourceLayout = sourceLayout
        self.layoutReason = layoutReason
        self.sequencingPlatform = sequencingPlatform
        self.wasMaterialized = wasMaterialized
        self.sampleHoldsPairsAndSingleReads = sampleHoldsPairsAndSingleReads
        self.runs = runs
        self.steps = steps
        self.singleReadReason = singleReadReason
        self.composition = composition
    }

    public var matePairs: [ReadSetMatePair] { runs.flatMap(\.matePairs) }
    public var singleReads: [ReadSetSingleReads] { runs.flatMap(\.singleReads) }
    public var mixedStreams: [ReadSetMixedStream] { runs.flatMap(\.mixedStreams) }

    /// Every file the tool reads, run by run.
    public var executionURLs: [URL] { runs.flatMap(\.executionURLs) }

    /// Whether the plan made no step and runs no mate as a single read, so
    /// it adds nothing to a run's provenance.
    public var recordsNothingNew: Bool {
        steps.isEmpty && singleReadReason == nil && !sampleHoldsPairsAndSingleReads
    }

    /// The run parameters that record the plan: the capability used, the
    /// counts by kind and the reason mates ran as single reads. Empty when
    /// ``recordsNothingNew``, so earlier runs compare byte for byte.
    public var provenanceParameters: [String: ParameterValue] {
        guard !recordsNothingNew else { return [:] }
        func count(_ value: Int?) -> ParameterValue { value.map(ParameterValue.integer) ?? .null }
        return [
            "readSetPlan": .dictionary([
                "capability": .string(capability.provenanceName),
                "sourceLayout": .string(sourceLayout.rawValue),
                "pairedFragments": count(composition.pairedFragments),
                "mergedReads": count(composition.mergedReads),
                "orphanReads": count(composition.orphanReads),
                "singleEndReads": count(composition.singleEndReads),
                "mergedOrOrphanReads": count(composition.mergedOrOrphanReads),
                "runs": .integer(runs.count),
                "singleReadReason": singleReadReason.map(ParameterValue.string) ?? .null,
            ]),
        ]
    }
}
