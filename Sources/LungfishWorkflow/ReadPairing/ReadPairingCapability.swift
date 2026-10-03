// ReadPairingCapability.swift - What a read consumer can take, pairs, single reads or both
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. Every tool that reads
// FASTQ declares one capability, and ReadSetResolver hands it its reads in
// the matching form.

import Foundation

/// What one read consumer can take in a single run, which decides how
/// ``ReadSetResolver`` hands it a sample that holds pairs, single reads or
/// both.
public struct ReadPairingCapability: Codable, Sendable, Hashable {

    /// The four kinds of consumer the contract names.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The tool takes pairs and single reads together in one run
        /// (bowtie2 `-1 -2 -U`, SPAdes `-1 -2 --merged -s`, Kraken2 staged).
        case bothInOneRun = "both_in_one_run"
        /// The tool takes one kind per run, and the two results merge
        /// exactly (BBMap, then `samtools merge`).
        case pairsOrSinglesPerRun = "pairs_or_singles_per_run"
        /// The tool pairs reads only when every fragment of the sample is a
        /// pair. A sample that also holds single reads runs every read as a
        /// single read, and the result states why (EsViritu, TaxTriage,
        /// Viral Recon).
        case pairsOnlyWhenAllPaired = "pairs_only_when_all_paired"
        /// The tool treats every record on its own (long-read tools and
        /// per-record tools).
        case singleReadsOnly = "single_reads_only"
    }

    /// How a ``Kind/bothInOneRun`` tool receives a sample that holds pairs
    /// and single reads.
    public enum MixedInput: String, Codable, Sendable, CaseIterable {
        /// R1 and R2 files plus separate single-read files (bowtie2,
        /// SPAdes, MEGAHIT, SKESA, Kraken2).
        case separateFiles = "separate_files"
        /// One stream with each R1 record followed by its R2 record and the
        /// single reads after them. The tool pairs adjacent records by name
        /// (minimap2 `-x sr`, bwa-mem2 `-p`, fastp trims, `fastq merge`).
        case nameInterleavedStream = "name_interleaved_stream"
    }

    public let kind: Kind
    /// How a mixed sample reaches the tool. Meaningful for
    /// ``Kind/bothInOneRun`` only, and ``MixedInput/separateFiles`` for the
    /// other kinds.
    public let mixedInput: MixedInput

    public init(kind: Kind, mixedInput: MixedInput = .separateFiles) {
        self.kind = kind
        self.mixedInput = kind == .bothInOneRun ? mixedInput : .separateFiles
    }

    /// Pairs and single reads in one run, as separate files.
    public static let bothInOneRunAsSeparateFiles = ReadPairingCapability(kind: .bothInOneRun, mixedInput: .separateFiles)
    /// Pairs and single reads in one run, as one stream paired by name.
    public static let bothInOneRunAsNameInterleavedStream = ReadPairingCapability(kind: .bothInOneRun, mixedInput: .nameInterleavedStream)
    /// Pairs in one run, single reads in another, results merged.
    public static let pairsOrSinglesPerRun = ReadPairingCapability(kind: .pairsOrSinglesPerRun)
    /// Pairs only when the whole sample is paired.
    public static let pairsOnlyWhenAllPaired = ReadPairingCapability(kind: .pairsOnlyWhenAllPaired)
    /// Every read as a single read.
    public static let singleReadsOnly = ReadPairingCapability(kind: .singleReadsOnly)

    /// A short name for provenance, such as `both_in_one_run/separate_files`.
    public var provenanceName: String {
        kind == .bothInOneRun ? "\(kind.rawValue)/\(mixedInput.rawValue)" : kind.rawValue
    }
}

/// One read consumer's declared capability.
///
/// `consumerID` is the ID the consumer has in ``FASTQConsumerRegistry``, so
/// the two registries describe the same tools. `adopted` turns true when the
/// consumer resolves its inputs through ``ReadSetResolver``. Until then the
/// capability is the form the contract gives it, and the consumer's
/// ``FASTQConsumerDeclaration`` describes what it does today.
public struct ReadPairingCapabilityDeclaration: Sendable, Equatable {
    public let consumerID: String
    public let capability: ReadPairingCapability
    public let rationale: String
    public let adopted: Bool

    public init(consumerID: String, capability: ReadPairingCapability, rationale: String, adopted: Bool = false) {
        self.consumerID = consumerID
        self.capability = capability
        self.rationale = rationale
        self.adopted = adopted
    }
}
