// RestrictionSiteFinderPlugin.swift - Find restriction enzyme sites
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Bioinformatics Architect (Role 05)

import Foundation
import LungfishCore

// MARK: - Restriction Site Finder Plugin

/// Plugin that finds restriction enzyme recognition sites in DNA sequences.
///
/// This plugin searches for recognition sites of restriction endonucleases
/// and reports their positions, cut sites, and resulting fragment sizes.
///
/// ## Features
/// - Search for single or multiple enzymes
/// - Support for degenerate recognition sequences (IUPAC codes)
/// - Fragment size prediction
/// - Compatible ends detection for cloning
public struct RestrictionSiteFinderPlugin: AnnotationGeneratorPlugin {

    // MARK: - Plugin Metadata

    public let id = "com.lungfish.restriction-finder"
    public let name = "Restriction Site Finder"
    public let version = "1.0.0"
    public let description = "Find restriction enzyme recognition sites in DNA sequences"
    public let category = PluginCategory.annotationTools
    public let capabilities: PluginCapabilities = [
        .worksOnWholeSequence,
        .generatesAnnotations,
        .requiresNucleotide,
        .producesReport
    ]
    public let iconName = "scissors"

    // MARK: - Default Options

    public var defaultOptions: AnnotationOptions {
        var options = AnnotationOptions()
        options["enzymes"] = .stringArray(["EcoRI", "BamHI", "HindIII"])
        options["showCutSites"] = .bool(true)
        options["showFragments"] = .bool(true)
        options["circular"] = .bool(false)
        return options
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Annotation Generation

    public func generateAnnotations(_ input: AnnotationInput) async throws -> [AnnotationResult] {
        guard input.alphabet.isNucleotide else {
            throw PluginError.unsupportedAlphabet(expected: .dna, got: input.alphabet)
        }

        let enzymeNames = input.options.stringArray(for: "enzymes", default: ["EcoRI"])
        let sequence = input.sequence.uppercased()

        var annotations: [AnnotationResult] = []

        for enzymeName in enzymeNames {
            guard let enzyme = RestrictionEnzymeDatabase.shared.enzyme(named: enzymeName) else {
                continue
            }

            let sites = findSites(for: enzyme, in: sequence)
            for site in sites {
                annotations.append(AnnotationResult(
                    name: enzyme.name,
                    type: "restriction_site",
                    start: site.position,
                    end: site.position + enzyme.recognitionSite.count,
                    strand: site.strand,
                    qualifiers: [
                        "enzyme": enzyme.name,
                        "recognition_site": enzyme.recognitionSite,
                        "cut_position": String(site.cutPosition),
                        "overhang": enzyme.overhangType.rawValue
                    ]
                ))
            }
        }

        return annotations
    }

    // MARK: - Site Finding

    private func findSites(for enzyme: RestrictionEnzyme, in sequence: String) -> [RestrictionSite] {
        var sites: [RestrictionSite] = []
        let pattern = enzyme.recognitionPattern

        // Search forward strand
        let forwardMatches = findMatches(pattern: pattern, in: sequence)
        for position in forwardMatches {
            sites.append(RestrictionSite(
                position: position,
                strand: .forward,
                cutPosition: position + enzyme.cutPositionForward
            ))
        }

        // Search reverse strand (complement)
        if !enzyme.isPalindromic {
            let reversePattern = reverseComplement(pattern)
            let reverseMatches = findMatches(pattern: reversePattern, in: sequence)
            for position in reverseMatches {
                sites.append(RestrictionSite(
                    position: position,
                    strand: .reverse,
                    cutPosition: position + enzyme.cutPositionReverse
                ))
            }
        }

        return sites.sorted { $0.position < $1.position }
    }

    private func findMatches(pattern: String, in sequence: String) -> [Int] {
        var matches: [Int] = []
        let regex = try? patternToRegex(pattern)

        guard let regex = regex else { return matches }

        let range = NSRange(sequence.startIndex..., in: sequence)
        let nsMatches = regex.matches(in: sequence, range: range)

        for match in nsMatches {
            if let range = Range(match.range, in: sequence) {
                let position = sequence.distance(from: sequence.startIndex, to: range.lowerBound)
                matches.append(position)
            }
        }

        return matches
    }

    private func patternToRegex(_ pattern: String) throws -> NSRegularExpression {
        var regexPattern = ""
        for char in pattern.uppercased() {
            regexPattern += iupacToRegex(char)
        }
        return try NSRegularExpression(pattern: regexPattern, options: [])
    }

    private func iupacToRegex(_ char: Character) -> String {
        switch char {
        case "A": return "A"
        case "T": return "T"
        case "C": return "C"
        case "G": return "G"
        case "R": return "[AG]"     // puRine
        case "Y": return "[CT]"     // pYrimidine
        case "S": return "[GC]"     // Strong
        case "W": return "[AT]"     // Weak
        case "K": return "[GT]"     // Keto
        case "M": return "[AC]"     // aMino
        case "B": return "[CGT]"    // not A
        case "D": return "[AGT]"    // not C
        case "H": return "[ACT]"    // not G
        case "V": return "[ACG]"    // not T
        case "N": return "[ATCG]"   // aNy
        default: return String(char)
        }
    }

    private func reverseComplement(_ sequence: String) -> String {
        TranslationEngine.reverseComplement(sequence)
    }
}

// MARK: - Restriction Site

/// A found restriction site location.
struct RestrictionSite {
    let position: Int
    let strand: Strand
    let cutPosition: Int
}

// MARK: - Restriction Enzyme

/// A restriction enzyme definition.
public struct RestrictionEnzyme: Sendable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let recognitionSite: String
    public let cutPositionForward: Int
    public let cutPositionReverse: Int
    public let overhangType: OverhangType
    public let supplier: [String]

    /// The regex pattern for this enzyme's recognition site
    var recognitionPattern: String { recognitionSite }

    /// Whether the recognition site is palindromic
    public var isPalindromic: Bool {
        let rc = String(recognitionSite.reversed().map { complement($0) })
        return recognitionSite == rc
    }

    private func complement(_ char: Character) -> Character {
        switch char.uppercased().first! {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        default: return char
        }
    }

    public init(
        name: String,
        recognitionSite: String,
        cutPositionForward: Int,
        cutPositionReverse: Int,
        overhangType: OverhangType = .fivePrime,
        supplier: [String] = []
    ) {
        self.id = name
        self.name = name
        self.recognitionSite = recognitionSite
        self.cutPositionForward = cutPositionForward
        self.cutPositionReverse = cutPositionReverse
        self.overhangType = overhangType
        self.supplier = supplier
    }
}

/// Type of overhang produced by restriction enzyme.
public enum OverhangType: String, Sendable, Codable {
    case fivePrime = "5' overhang"
    case threePrime = "3' overhang"
    case blunt = "blunt"
}

// MARK: - Enzyme Database

/// Database of common restriction enzymes.
public final class RestrictionEnzymeDatabase: Sendable {

    public static let shared = RestrictionEnzymeDatabase()

    private let enzymes: [String: RestrictionEnzyme]

    private init() {
        var db: [String: RestrictionEnzyme] = [:]

        // Common 6-cutters
        db["EcoRI"] = RestrictionEnzyme(
            name: "EcoRI",
            recognitionSite: "GAATTC",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["BamHI"] = RestrictionEnzyme(
            name: "BamHI",
            recognitionSite: "GGATCC",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["HindIII"] = RestrictionEnzyme(
            name: "HindIII",
            recognitionSite: "AAGCTT",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["XhoI"] = RestrictionEnzyme(
            name: "XhoI",
            recognitionSite: "CTCGAG",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["SalI"] = RestrictionEnzyme(
            name: "SalI",
            recognitionSite: "GTCGAC",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["NotI"] = RestrictionEnzyme(
            name: "NotI",
            recognitionSite: "GCGGCCGC",
            cutPositionForward: 2,
            cutPositionReverse: 6,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["XbaI"] = RestrictionEnzyme(
            name: "XbaI",
            recognitionSite: "TCTAGA",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["NcoI"] = RestrictionEnzyme(
            name: "NcoI",
            recognitionSite: "CCATGG",
            cutPositionForward: 1,
            cutPositionReverse: 5,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["NdeI"] = RestrictionEnzyme(
            name: "NdeI",
            recognitionSite: "CATATG",
            cutPositionForward: 2,
            cutPositionReverse: 4,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        // Blunt cutters
        db["EcoRV"] = RestrictionEnzyme(
            name: "EcoRV",
            recognitionSite: "GATATC",
            cutPositionForward: 3,
            cutPositionReverse: 3,
            overhangType: .blunt,
            supplier: ["NEB", "Thermo"]
        )

        db["SmaI"] = RestrictionEnzyme(
            name: "SmaI",
            recognitionSite: "CCCGGG",
            cutPositionForward: 3,
            cutPositionReverse: 3,
            overhangType: .blunt,
            supplier: ["NEB", "Thermo"]
        )

        db["HpaI"] = RestrictionEnzyme(
            name: "HpaI",
            recognitionSite: "GTTAAC",
            cutPositionForward: 3,
            cutPositionReverse: 3,
            overhangType: .blunt,
            supplier: ["NEB", "Thermo"]
        )

        // 3' overhang
        db["PstI"] = RestrictionEnzyme(
            name: "PstI",
            recognitionSite: "CTGCAG",
            cutPositionForward: 5,
            cutPositionReverse: 1,
            overhangType: .threePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["KpnI"] = RestrictionEnzyme(
            name: "KpnI",
            recognitionSite: "GGTACC",
            cutPositionForward: 5,
            cutPositionReverse: 1,
            overhangType: .threePrime,
            supplier: ["NEB", "Thermo"]
        )

        // Common 4-cutters
        db["MspI"] = RestrictionEnzyme(
            name: "MspI",
            recognitionSite: "CCGG",
            cutPositionForward: 1,
            cutPositionReverse: 3,
            overhangType: .fivePrime,
            supplier: ["NEB", "Thermo"]
        )

        db["HaeIII"] = RestrictionEnzyme(
            name: "HaeIII",
            recognitionSite: "GGCC",
            cutPositionForward: 2,
            cutPositionReverse: 2,
            overhangType: .blunt,
            supplier: ["NEB", "Thermo"]
        )

        self.enzymes = db
    }

    /// Returns an enzyme by name.
    public func enzyme(named name: String) -> RestrictionEnzyme? {
        enzymes[name]
    }

    /// Returns all available enzymes.
    public var allEnzymes: [RestrictionEnzyme] {
        Array(enzymes.values).sorted { $0.name < $1.name }
    }

    /// Returns enzymes that produce compatible ends with the given enzyme.
    public func compatibleEnzymes(with enzyme: RestrictionEnzyme) -> [RestrictionEnzyme] {
        allEnzymes.filter { other in
            other.name != enzyme.name &&
            other.overhangType == enzyme.overhangType &&
            abs(other.cutPositionForward - other.cutPositionReverse) ==
            abs(enzyme.cutPositionForward - enzyme.cutPositionReverse)
        }
    }

    /// Returns enzyme names matching a search string.
    public func search(_ query: String) -> [RestrictionEnzyme] {
        let lowercaseQuery = query.lowercased()
        return allEnzymes.filter { enzyme in
            enzyme.name.lowercased().contains(lowercaseQuery) ||
            enzyme.recognitionSite.lowercased().contains(lowercaseQuery)
        }
    }
}
