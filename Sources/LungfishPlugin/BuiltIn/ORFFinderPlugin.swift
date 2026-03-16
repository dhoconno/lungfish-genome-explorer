// ORFFinderPlugin.swift - Open reading frame detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Sequence Viewer Specialist (Role 03)

import Foundation
import LungfishCore

// MARK: - ORF Finder Plugin

/// Plugin that finds open reading frames (ORFs) in nucleotide sequences.
///
/// This plugin searches for potential protein-coding regions by identifying
/// start codons (typically ATG) followed by in-frame stop codons.
///
/// ## Features
/// - Search all six reading frames
/// - Configurable minimum ORF length
/// - Support for alternative start codons
/// - Direct annotation creation
public struct ORFFinderPlugin: AnnotationGeneratorPlugin {

    // MARK: - Plugin Metadata

    public let id = "com.lungfish.orf-finder"
    public let name = "ORF Finder"
    public let version = "1.0.0"
    public let description = "Find open reading frames in nucleotide sequences"
    public let category = PluginCategory.annotationTools
    public let capabilities: PluginCapabilities = [
        .worksOnWholeSequence,
        .generatesAnnotations,
        .requiresNucleotide,
        .producesReport
    ]
    public let iconName = "rectangle.3.group"
    public let minimumSequenceLength = 30  // Minimum to find even a tiny ORF

    // MARK: - Default Options

    public var defaultOptions: AnnotationOptions {
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(100)  // Nucleotides
        options["startCodons"] = .stringArray(["ATG"])
        options["allowAlternativeStarts"] = .bool(false)
        options["includePartial"] = .bool(false)
        options["frames"] = .stringArray(["+1", "+2", "+3", "-1", "-2", "-3"])
        return options
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Annotation Generation

    public func generateAnnotations(_ input: AnnotationInput) async throws -> [AnnotationResult] {
        guard input.alphabet.isNucleotide else {
            throw PluginError.unsupportedAlphabet(expected: .dna, got: input.alphabet)
        }

        let sequence = input.sequence.uppercased()
        let minLength = input.options.integer(for: "minimumLength", default: 100)
        let allowAlternative = input.options.bool(for: "allowAlternativeStarts", default: false)
        let includePartial = input.options.bool(for: "includePartial", default: false)
        let frameStrings = input.options.stringArray(for: "frames", default: ["+1", "+2", "+3", "-1", "-2", "-3"])

        var startCodons = Set(["ATG"])
        if allowAlternative {
            startCodons.formUnion(["GTG", "TTG", "CTG"])
        }
        let stopCodons = Set(["TAA", "TAG", "TGA"])

        var annotations: [AnnotationResult] = []
        var orfNumber = 1

        // Process each requested frame
        for frameStr in frameStrings {
            let isReverse = frameStr.hasPrefix("-")
            let frameOffset = abs(Int(frameStr.dropFirst()) ?? 1) - 1

            let workingSequence: String
            if isReverse {
                workingSequence = reverseComplement(sequence)
            } else {
                workingSequence = sequence
            }

            let orfs = findORFs(
                in: workingSequence,
                offset: frameOffset,
                startCodons: startCodons,
                stopCodons: stopCodons,
                minLength: minLength,
                includePartial: includePartial
            )

            for orf in orfs {
                let (start, end) = convertCoordinates(
                    orfStart: orf.start,
                    orfEnd: orf.end,
                    sequenceLength: sequence.count,
                    isReverse: isReverse
                )

                let proteinLength = (orf.end - orf.start) / 3

                annotations.append(AnnotationResult(
                    name: "ORF\(orfNumber)",
                    type: "ORF",
                    start: start,
                    end: end,
                    strand: isReverse ? .reverse : .forward,
                    qualifiers: [
                        "frame": frameStr,
                        "length_nt": String(orf.end - orf.start),
                        "length_aa": String(proteinLength),
                        "start_codon": orf.startCodon,
                        "partial": orf.isPartial ? "true" : "false"
                    ]
                ))

                orfNumber += 1
            }
        }

        return annotations.sorted { $0.start < $1.start }
    }

    // MARK: - ORF Finding

    private struct FoundORF {
        let start: Int
        let end: Int
        let startCodon: String
        let isPartial: Bool
    }

    private func findORFs(
        in sequence: String,
        offset: Int,
        startCodons: Set<String>,
        stopCodons: Set<String>,
        minLength: Int,
        includePartial: Bool
    ) -> [FoundORF] {
        var orfs: [FoundORF] = []
        let chars = Array(sequence)
        let length = chars.count

        // Track open ORFs for each start codon position
        var openORFStarts: [(position: Int, codon: String)] = []

        // If including partial, consider position 0 as a potential start
        if includePartial && offset < length {
            openORFStarts.append((offset, "---"))
        }

        var position = offset
        while position + 3 <= length {
            let codon = String(chars[position..<(position + 3)])

            if startCodons.contains(codon) {
                // Found a start codon
                openORFStarts.append((position, codon))
            }

            if stopCodons.contains(codon) {
                // Found a stop codon - close all open ORFs
                for (startPos, startCodon) in openORFStarts {
                    let orfLength = position + 3 - startPos
                    if orfLength >= minLength {
                        orfs.append(FoundORF(
                            start: startPos,
                            end: position + 3,
                            startCodon: startCodon,
                            isPartial: startCodon == "---"
                        ))
                    }
                }
                openORFStarts.removeAll()

                // If including partial, start a new potential ORF after this stop
                if includePartial && position + 3 + 3 <= length {
                    openORFStarts.append((position + 3, "---"))
                }
            }

            position += 3
        }

        // Handle partial ORFs at sequence end
        if includePartial {
            let seqEnd = ((length - offset) / 3) * 3 + offset
            for (startPos, startCodon) in openORFStarts {
                let orfLength = seqEnd - startPos
                if orfLength >= minLength {
                    orfs.append(FoundORF(
                        start: startPos,
                        end: seqEnd,
                        startCodon: startCodon,
                        isPartial: true
                    ))
                }
            }
        }

        return orfs
    }

    private func convertCoordinates(
        orfStart: Int,
        orfEnd: Int,
        sequenceLength: Int,
        isReverse: Bool
    ) -> (Int, Int) {
        if isReverse {
            // Convert reverse complement coordinates back to forward coordinates
            let start = sequenceLength - orfEnd
            let end = sequenceLength - orfStart
            return (start, end)
        } else {
            return (orfStart, orfEnd)
        }
    }

    private func reverseComplement(_ sequence: String) -> String {
        TranslationEngine.reverseComplement(sequence)
    }
}

// ReadingFrame is now imported from LungfishCore (SequenceAlphabet.swift)
