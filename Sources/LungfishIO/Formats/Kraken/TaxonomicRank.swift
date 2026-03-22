// TaxonomicRank.swift - Taxonomic rank enumeration for Kraken2 report parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A taxonomic rank in the NCBI taxonomy hierarchy.
///
/// Kraken2 reports use single-letter rank codes (`R`, `D`, `K`, `P`, `C`, `O`,
/// `F`, `G`, `S`) plus numeric suffixes for intermediate ranks (`R1`, `D1`,
/// `S1`, `S2`, etc.). This enum maps all standard codes to named cases, with
/// intermediate ranks grouped under ``intermediate(_:)`` and unrecognized codes
/// handled by ``unknown(_:)``.
///
/// ## Rank Ordering
///
/// The ``ringIndex`` property provides a strictly increasing integer for each
/// rank from root (0) to subspecies (9), suitable for ring-based visualizations
/// such as sunburst charts.
///
/// ## Kraken2 Report Codes
///
/// | Code | Rank |
/// |------|------|
/// | `U`  | Unclassified |
/// | `R`  | Root |
/// | `D`  | Domain (superkingdom) |
/// | `K`  | Kingdom |
/// | `P`  | Phylum |
/// | `C`  | Class |
/// | `O`  | Order |
/// | `F`  | Family |
/// | `G`  | Genus |
/// | `S`  | Species |
/// | `R1` | Intermediate below root |
/// | `D1` | Intermediate below domain |
/// | `S1` | Subspecies |
/// | `S2` | Strain |
public enum TaxonomicRank: Sendable, Equatable, Hashable, Codable {

    /// Unclassified reads (rank code `U`).
    case unclassified

    /// Root of the taxonomy tree (rank code `R`).
    case root

    /// Domain / superkingdom (rank code `D`).
    case domain

    /// Kingdom (rank code `K`).
    case kingdom

    /// Phylum (rank code `P`).
    case phylum

    /// Class (rank code `C`).
    case `class`

    /// Order (rank code `O`).
    case order

    /// Family (rank code `F`).
    case family

    /// Genus (rank code `G`).
    case genus

    /// Species (rank code `S`).
    case species

    /// An intermediate rank between two standard ranks (e.g., `R1`, `D1`, `S1`, `S2`).
    ///
    /// The associated value is the raw rank code from the Kraken2 report.
    case intermediate(String)

    /// An unrecognized rank code.
    ///
    /// This case exists to ensure parsing never fails on unexpected rank codes.
    case unknown(String)

    // MARK: - Initialization

    /// Creates a taxonomic rank from a Kraken2 report rank code.
    ///
    /// Standard single-letter codes map to the corresponding case. Codes with
    /// numeric suffixes (e.g., `R1`, `D1`, `S1`, `S2`, `P1`) are mapped to
    /// ``intermediate(_:)``. Unrecognized codes produce ``unknown(_:)``.
    ///
    /// - Parameter code: The rank code string from the Kraken2 report.
    public init(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "U":
            self = .unclassified
        case "R":
            self = .root
        case "D":
            self = .domain
        case "K":
            self = .kingdom
        case "P":
            self = .phylum
        case "C":
            self = .`class`
        case "O":
            self = .order
        case "F":
            self = .family
        case "G":
            self = .genus
        case "S":
            self = .species
        default:
            // Check if this is an intermediate rank (letter + digit(s))
            if trimmed.count >= 2,
               let first = trimmed.first,
               first.isUppercase,
               trimmed.dropFirst().allSatisfy({ $0.isNumber }) {
                self = .intermediate(trimmed)
            } else {
                self = .unknown(trimmed)
            }
        }
    }

    // MARK: - Properties

    /// A human-readable display name for this rank.
    public var displayName: String {
        switch self {
        case .unclassified: return "Unclassified"
        case .root: return "Root"
        case .domain: return "Domain"
        case .kingdom: return "Kingdom"
        case .phylum: return "Phylum"
        case .class: return "Class"
        case .order: return "Order"
        case .family: return "Family"
        case .genus: return "Genus"
        case .species: return "Species"
        case .intermediate(let code):
            // Map common intermediate codes to friendly names
            switch code {
            case "S1": return "Subspecies"
            case "S2": return "Strain"
            case "S3": return "Sub-strain"
            default:
                if let parent = parentStandardRank {
                    return "Sub-\(parent.displayName.lowercased())"
                }
                return code
            }
        case .unknown(let code):
            return code
        }
    }

    /// The rank code as it appears in a Kraken2 report.
    public var code: String {
        switch self {
        case .unclassified: return "U"
        case .root: return "R"
        case .domain: return "D"
        case .kingdom: return "K"
        case .phylum: return "P"
        case .class: return "C"
        case .order: return "O"
        case .family: return "F"
        case .genus: return "G"
        case .species: return "S"
        case .intermediate(let code): return code
        case .unknown(let code): return code
        }
    }

    /// A numeric index representing the ring position in a sunburst chart.
    ///
    /// Standard ranks produce strictly increasing values from root (0) to
    /// species (8). Intermediate ranks are assigned a fractional index between
    /// their parent standard rank and the next standard rank.
    ///
    /// - Returns: An integer ring index where 0 = root and higher values are
    ///   deeper in the taxonomy.
    public var ringIndex: Int {
        switch self {
        case .unclassified: return -1
        case .root: return 0
        case .domain: return 1
        case .kingdom: return 2
        case .phylum: return 3
        case .class: return 4
        case .order: return 5
        case .family: return 6
        case .genus: return 7
        case .species: return 8
        case .intermediate(let code):
            // S1 = subspecies, S2 = strain, etc.
            if code.hasPrefix("S") { return 9 }
            if let parent = parentStandardRank { return parent.ringIndex }
            return 0
        case .unknown:
            return 10
        }
    }

    /// Whether this is a standard (non-intermediate) rank.
    public var isStandard: Bool {
        switch self {
        case .intermediate, .unknown: return false
        default: return true
        }
    }

    /// The nearest standard parent rank for intermediate ranks.
    ///
    /// For standard ranks, returns `self`. For intermediate ranks like `D1`,
    /// returns the corresponding standard rank (`.domain`). For unknown ranks,
    /// returns `nil`.
    public var parentStandardRank: TaxonomicRank? {
        switch self {
        case .intermediate(let code):
            guard let letter = code.first else { return nil }
            return TaxonomicRank(code: String(letter))
        case .unknown:
            return nil
        default:
            return self
        }
    }

    /// All standard ranks in taxonomic order from root to species.
    public static let standardRanks: [TaxonomicRank] = [
        .root, .domain, .kingdom, .phylum, .class, .order, .family, .genus, .species
    ]

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case code
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        self.init(code: code)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

// MARK: - CustomStringConvertible

extension TaxonomicRank: CustomStringConvertible {
    public var description: String {
        displayName
    }
}
