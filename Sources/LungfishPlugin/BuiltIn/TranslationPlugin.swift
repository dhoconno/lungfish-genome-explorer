// TranslationPlugin.swift - DNA/RNA to protein translation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Bioinformatics Architect (Role 05)

import Foundation
import LungfishCore

// MARK: - Translation Plugin

/// Plugin that translates nucleotide sequences to protein.
///
/// Supports multiple genetic codes and all six reading frames.
/// Delegates to `TranslationEngine` and `CodonTable` from LungfishCore.
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
            workingSequence = TranslationEngine.reverseComplement(sequence)
        } else {
            workingSequence = sequence
        }

        let protein = TranslationEngine.translate(
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
        TranslationEngine.reverseComplement(sequence)
    }
}
