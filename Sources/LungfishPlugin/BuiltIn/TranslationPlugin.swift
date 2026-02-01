// TranslationPlugin.swift - DNA/RNA to protein translation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Bioinformatics Architect (Role 05)

import Foundation

// MARK: - Translation Plugin

/// Plugin that translates nucleotide sequences to protein.
///
/// Supports multiple genetic codes and all six reading frames.
///
/// ## Features
/// - Standard and alternative genetic codes
/// - All six reading frames
/// - Three-frame or six-frame translation
/// - Stop codon handling options
public struct TranslationPlugin: SequenceOperationPlugin {

    // MARK: - Plugin Metadata

    public let id = "com.lungfish.translation"
    public let name = "Translate"
    public let version = "1.0.0"
    public let description = "Translate DNA/RNA sequence to protein"
    public let category = PluginCategory.sequenceOperations
    public let capabilities: PluginCapabilities = [
        .worksOnSelection,
        .worksOnWholeSequence,
        .producesSequence,
        .requiresNucleotide,
        .supportsLivePreview
    ]
    public let iconName = "character.textbox"
    public let keyboardShortcut = KeyboardShortcut(key: "T", modifiers: [.command, .shift])

    // MARK: - Default Options

    public var defaultOptions: OperationOptions {
        var options = OperationOptions()
        options["codonTable"] = .string("standard")
        options["frame"] = .string("+1")
        options["showStopAsAsterisk"] = .bool(true)
        options["trimToFirstStop"] = .bool(false)
        return options
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Transform

    public func transform(_ input: OperationInput) async throws -> OperationResult {
        guard input.alphabet.isNucleotide else {
            throw PluginError.unsupportedAlphabet(expected: .dna, got: input.alphabet)
        }

        let sequence = input.regionToTransform.uppercased()
        let tableName = input.options.string(for: "codonTable", default: "standard")
        let frameStr = input.options.string(for: "frame", default: "+1")
        let showStopAsAsterisk = input.options.bool(for: "showStopAsAsterisk", default: true)
        let trimToFirstStop = input.options.bool(for: "trimToFirstStop", default: false)

        guard let table = CodonTable.table(named: tableName) else {
            return .failure("Unknown codon table: \(tableName)")
        }

        let frame = ReadingFrame(rawValue: frameStr) ?? .plus1
        let workingSequence: String
        if frame.isReverse {
            workingSequence = reverseComplement(sequence)
        } else {
            workingSequence = sequence
        }

        let protein = translate(
            workingSequence,
            offset: frame.offset,
            table: table,
            showStopAsAsterisk: showStopAsAsterisk,
            trimToFirstStop: trimToFirstStop
        )

        let resultName: String
        if let baseName = input.sequenceName.split(separator: ".").first {
            resultName = "\(baseName)_\(frame.rawValue)_protein"
        } else {
            resultName = "\(input.sequenceName)_\(frame.rawValue)_protein"
        }

        return OperationResult(
            sequence: protein,
            sequenceName: resultName,
            alphabet: .protein,
            metadata: [
                "source_length": String(sequence.count),
                "protein_length": String(protein.count),
                "codon_table": tableName,
                "frame": frameStr
            ]
        )
    }

    // MARK: - Translation Logic

    private func translate(
        _ sequence: String,
        offset: Int,
        table: CodonTable,
        showStopAsAsterisk: Bool,
        trimToFirstStop: Bool
    ) -> String {
        let chars = Array(sequence)
        var protein = ""
        var position = offset

        while position + 3 <= chars.count {
            let codon = String(chars[position..<(position + 3)])
            let aminoAcid = table.translate(codon)

            if aminoAcid == "*" {
                if trimToFirstStop {
                    break
                }
                protein.append(showStopAsAsterisk ? "*" : "")
            } else {
                protein.append(aminoAcid)
            }

            position += 3
        }

        return protein
    }

    private func reverseComplement(_ sequence: String) -> String {
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "U": "A", "C": "G", "G": "C",
            "a": "t", "t": "a", "u": "a", "c": "g", "g": "c",
            "N": "N", "n": "n"
        ]
        return String(sequence.reversed().map { complementMap[$0] ?? $0 })
    }
}

// MARK: - Reverse Complement Plugin

/// Plugin that produces the reverse complement of a nucleotide sequence.
public struct ReverseComplementPlugin: SequenceOperationPlugin {

    // MARK: - Plugin Metadata

    public let id = "com.lungfish.reverse-complement"
    public let name = "Reverse Complement"
    public let version = "1.0.0"
    public let description = "Generate the reverse complement of a nucleotide sequence"
    public let category = PluginCategory.sequenceOperations
    public let capabilities: PluginCapabilities = [
        .worksOnSelection,
        .worksOnWholeSequence,
        .producesSequence,
        .requiresNucleotide,
        .supportsLivePreview
    ]
    public let iconName = "arrow.uturn.backward"
    public let keyboardShortcut = KeyboardShortcut(key: "R", modifiers: [.command, .shift])

    // MARK: - Initialization

    public init() {}

    // MARK: - Transform

    public func transform(_ input: OperationInput) async throws -> OperationResult {
        guard input.alphabet.isNucleotide else {
            throw PluginError.unsupportedAlphabet(expected: .dna, got: input.alphabet)
        }

        let sequence = input.regionToTransform
        let result = reverseComplement(sequence)

        return OperationResult(
            sequence: result,
            sequenceName: "\(input.sequenceName)_rc",
            alphabet: input.alphabet
        )
    }

    private func reverseComplement(_ sequence: String) -> String {
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "U": "A", "C": "G", "G": "C",
            "a": "t", "t": "a", "u": "a", "c": "g", "g": "c",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N",
            "r": "y", "y": "r", "s": "s", "w": "w",
            "k": "m", "m": "k", "b": "v", "v": "b",
            "d": "h", "h": "d", "n": "n"
        ]
        return String(sequence.reversed().map { complementMap[$0] ?? $0 })
    }
}

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
    return table
}()
