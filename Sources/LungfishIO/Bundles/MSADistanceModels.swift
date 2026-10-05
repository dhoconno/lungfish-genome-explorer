// MSADistanceModels.swift - Models, alphabet, gap policy and order options for MSA distance matrices
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Shared by `lungfish-cli msa distance` and the MSA distance matrix pane. Raw values are the
// CLI spellings, so a GUI choice maps onto the command line without a lookup table.

import Foundation

/// Distance model for `MSADistanceMatrix`. Raw values are the CLI `--model` spellings.
///
/// Let L be the comparable sites of a pair, D the differing sites and p = D / L.
/// - `identity` is 1 - p, a similarity.
/// - `pDistance` is p.
/// - `jc69` is -(3/4) ln(1 - (4/3) p), saturated when p >= 0.75.
/// - `k2p` is -(1/2) ln(1 - 2P - Q) - (1/4) ln(1 - 2Q), with P and Q the transition and
///   transversion proportions, saturated when either log argument is <= 0.
/// - `poisson` is -ln(1 - p), saturated when p >= 1.
public enum MSADistanceModel: String, CaseIterable, Sendable, Codable, Identifiable {
    case identity = "identity"
    case pDistance = "p-distance"
    case jc69 = "jc69"
    case k2p = "k2p"
    case poisson = "poisson"

    public var id: String { rawValue }

    /// Label for pickers, legends and column headers.
    public var displayName: String {
        switch self {
        case .identity: return "Identity"
        case .pDistance: return "p-distance"
        case .jc69: return "Jukes-Cantor (JC69)"
        case .k2p: return "Kimura 2-parameter (K2P)"
        case .poisson: return "Poisson"
        }
    }

    /// True for the multiple-hit corrected distances, which are unbounded and can saturate.
    public var isCorrectedDistance: Bool {
        switch self {
        case .jc69, .k2p, .poisson: return true
        case .identity, .pDistance: return false
        }
    }

    /// True when a higher value means more similar sequences.
    public var isSimilarity: Bool { self == .identity }

    /// The models that are valid for an alphabet, in picker order.
    public static func models(for alphabet: MSASequenceAlphabet) -> [MSADistanceModel] {
        switch alphabet {
        case .nucleotide: return [.identity, .pDistance, .jc69, .k2p]
        case .protein: return [.identity, .pDistance, .poisson]
        }
    }

    /// Whether this model may be computed for `alphabet`.
    public func isValid(for alphabet: MSASequenceAlphabet) -> Bool {
        Self.models(for: alphabet).contains(self)
    }
}

/// The residue alphabet that decides which characters are comparable and which models apply.
public enum MSASequenceAlphabet: String, Sendable, Codable {
    case nucleotide
    case protein

    /// Maps the bundle manifest's `alphabet` string. Only "protein" maps to protein. DNA, RNA
    /// and "unknown" map to nucleotide.
    public init(manifestAlphabet: String) {
        self = manifestAlphabet.lowercased() == "protein" ? .protein : .nucleotide
    }

    /// Reads the alphabet recorded in a `.lungfishmsa` bundle's manifest without loading or
    /// verifying the rest of the bundle.
    public static func load(fromBundle bundleURL: URL) throws -> MSASequenceAlphabet {
        struct AlphabetOnly: Decodable { let alphabet: String }
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(AlphabetOnly.self, from: data)
        return MSASequenceAlphabet(manifestAlphabet: manifest.alphabet)
    }
}

/// How sites with a gap or an ambiguous character are dropped.
public enum MSAGapPolicy: String, CaseIterable, Sendable, Codable {
    /// Each pair skips only the sites where one of its own two rows has a gap or ambiguity.
    case pairwise
    /// Every pair skips every column where any selected row has a gap or ambiguity, so all
    /// cells are computed over the same sites.
    case complete

    public var displayName: String {
        switch self {
        case .pairwise: return "Pairwise deletion"
        case .complete: return "Complete deletion"
        }
    }

    /// The spelling recorded in provenance sidecars.
    public var provenanceValue: String {
        switch self {
        case .pairwise: return "pairwise-delete"
        case .complete: return "complete-delete"
        }
    }
}

/// Row and column order of the matrix.
public enum MSADistanceOrder: String, CaseIterable, Sendable, Codable {
    /// The order of the rows in the alignment.
    case alignment
    /// UPGMA leaf order computed on p-distance (no comparable sites counts as 1.0).
    case averageLinkage = "average-linkage"

    public var displayName: String {
        switch self {
        case .alignment: return "Alignment order"
        case .averageLinkage: return "Average linkage (UPGMA)"
        }
    }
}

/// Every option that changes the numbers or the layout of an `MSADistanceMatrix`.
public struct MSADistanceOptions: Sendable, Equatable, Codable {
    public var model: MSADistanceModel
    public var gaps: MSAGapPolicy
    public var order: MSADistanceOrder
    public var alphabet: MSASequenceAlphabet

    public init(
        model: MSADistanceModel = .identity,
        gaps: MSAGapPolicy = .pairwise,
        order: MSADistanceOrder = .alignment,
        alphabet: MSASequenceAlphabet = .nucleotide
    ) {
        self.model = model
        self.gaps = gaps
        self.order = order
        self.alphabet = alphabet
    }
}

/// The counts behind one cell of the matrix.
public struct MSAPairDetail: Sendable, Equatable {
    /// The displayed value. `nan` when there is no comparable site, `+inf` when saturated.
    public let value: Double
    public let comparableSites: Int
    public let differences: Int
    public let identicalSites: Int
    /// Purine to purine or pyrimidine to pyrimidine differences. Always 0 for protein.
    public let transitions: Int
    /// Purine to pyrimidine differences. Always 0 for protein.
    public let transversions: Int
    /// Sites dropped because of a gap.
    public let gapSkipped: Int
    /// Sites dropped because of an ambiguous character.
    public let ambiguitySkipped: Int

    public init(
        value: Double,
        comparableSites: Int,
        differences: Int,
        identicalSites: Int,
        transitions: Int,
        transversions: Int,
        gapSkipped: Int,
        ambiguitySkipped: Int
    ) {
        self.value = value
        self.comparableSites = comparableSites
        self.differences = differences
        self.identicalSites = identicalSites
        self.transitions = transitions
        self.transversions = transversions
        self.gapSkipped = gapSkipped
        self.ambiguitySkipped = ambiguitySkipped
    }

    public var isUndefined: Bool { value.isNaN }
    public var isSaturated: Bool { value == .infinity }
    public var formattedValue: String { MSADistanceMatrix.formatValue(value) }
}
