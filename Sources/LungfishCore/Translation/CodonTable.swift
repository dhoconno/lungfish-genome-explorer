// CodonTable.swift - Genetic code tables for translation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Codon Table

/// A genetic code table for translation.
public struct CodonTable: Sendable {
    public let id: Int
    public let name: String
    public let shortName: String
    private let translations: [String: Character]
    private let startCodons: Set<String>

    /// Standard genetic code (Table 1)
    public static let standard = CodonTable(
        id: 1,
        name: "Standard",
        shortName: "standard",
        translations: standardTranslations,
        startCodons: ["ATG", "TTG", "CTG"]
    )

    /// Vertebrate Mitochondrial (Table 2)
    public static let vertebrateMitochondrial = CodonTable(
        id: 2,
        name: "Vertebrate Mitochondrial",
        shortName: "vertebrate_mito",
        translations: vertebrateMitoTranslations,
        startCodons: ["ATG", "ATA", "ATC", "ATT", "GTG"]
    )

    /// Bacterial/Archaeal/Plant Plastid (Table 11)
    public static let bacterial = CodonTable(
        id: 11,
        name: "Bacterial, Archaeal and Plant Plastid",
        shortName: "bacterial",
        translations: standardTranslations,  // Same as standard but different starts
        startCodons: ["ATG", "GTG", "TTG"]
    )

    /// Yeast Mitochondrial (Table 3)
    public static let yeastMitochondrial = CodonTable(
        id: 3,
        name: "Yeast Mitochondrial",
        shortName: "yeast_mito",
        translations: yeastMitoTranslations,
        startCodons: ["ATG", "ATA"]
    )

    public init(id: Int, name: String, shortName: String, translations: [String: Character], startCodons: Set<String>) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.translations = translations
        self.startCodons = startCodons
    }

    /// Translates a single codon to an amino acid.
    public func translate(_ codon: String) -> Character {
        let upperCodon = codon.uppercased().replacingOccurrences(of: "U", with: "T")
        return translations[upperCodon] ?? "X"
    }

    /// Whether a codon is a start codon in this table.
    public func isStartCodon(_ codon: String) -> Bool {
        let upperCodon = codon.uppercased().replacingOccurrences(of: "U", with: "T")
        return startCodons.contains(upperCodon)
    }

    /// Whether a codon is a stop codon.
    public func isStopCodon(_ codon: String) -> Bool {
        translate(codon) == "*"
    }

    /// All available codon tables.
    public static var allTables: [CodonTable] {
        [standard, vertebrateMitochondrial, bacterial, yeastMitochondrial]
    }

    /// Returns a table by name.
    public static func table(named name: String) -> CodonTable? {
        allTables.first { $0.shortName == name || $0.name == name }
    }

    /// Returns a table by NCBI ID.
    public static func table(id: Int) -> CodonTable? {
        allTables.first { $0.id == id }
    }
}

// MARK: - Translation Tables

private let standardTranslations: [String: Character] = [
    "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
    "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
    "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
    "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
    "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
    "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
    "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
    "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
    "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
    "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
    "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
    "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
    "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
    "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
    "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
    "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
]

private let vertebrateMitoTranslations: [String: Character] = {
    var table = standardTranslations
    table["AGA"] = "*"  // Stop instead of Arg
    table["AGG"] = "*"  // Stop instead of Arg
    table["ATA"] = "M"  // Met instead of Ile
    table["TGA"] = "W"  // Trp instead of Stop
    return table
}()

private let yeastMitoTranslations: [String: Character] = {
    var table = standardTranslations
    table["CTA"] = "T"  // Thr instead of Leu
    table["CTC"] = "T"  // Thr instead of Leu
    table["CTG"] = "T"  // Thr instead of Leu
    table["CTT"] = "T"  // Thr instead of Leu
    table["TGA"] = "W"  // Trp instead of Stop
    table["ATA"] = "M"  // Met instead of Ile
    return table
}()
