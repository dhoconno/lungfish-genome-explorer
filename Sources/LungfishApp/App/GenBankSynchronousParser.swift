// GenBankSynchronousParser.swift - synchronous GenBank parsing helper for AppDelegate imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Simple synchronous parser for GenBank files.
/// This avoids async/await and MainActor completely.
final class GenBankParser {
    func parseContent(_ content: String) throws -> [GenBankRecord] {
        let lines = content.components(separatedBy: .newlines)
        var records: [GenBankRecord] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            // Skip empty lines between records
            while lineIndex < lines.count && lines[lineIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                lineIndex += 1
            }

            if lineIndex >= lines.count {
                break
            }

            let (record, nextIndex) = try parseRecord(lines: lines, startIndex: lineIndex)
            if let record = record {
                records.append(record)
            }
            lineIndex = nextIndex
        }

        return records
    }

    private func parseRecord(lines: [String], startIndex: Int) throws -> (GenBankRecord?, Int) {
        var lineIndex = startIndex
        var locusName: String?
        var locusLength = 0
        var locusMoleculeType: MoleculeType = .dna
        var locusTopology: Topology = .linear
        var locusDivision: String?
        var locusDate: String?
        var definition: String?
        var accession: String?
        var version: String?
        var features: [SequenceAnnotation] = []
        var sequenceBases = ""

        enum Section {
            case header
            case features
            case origin
        }
        var currentSection = Section.header
        var currentFeatureType: String?
        var currentFeatureLocation: String?
        var currentQualifiers: [String: String] = [:]
        var currentQualifierKey: String?
        var currentQualifierValue: String = ""

        while lineIndex < lines.count {
            let line = lines[lineIndex]

            if line.hasPrefix("//") {
                if let featureType = currentFeatureType,
                   let location = currentFeatureLocation,
                   let annotation = createAnnotation(type: featureType, location: location, qualifiers: currentQualifiers) {
                    features.append(annotation)
                }
                lineIndex += 1
                break
            }

            switch currentSection {
            case .header:
                if line.hasPrefix("LOCUS") {
                    let parsed = parseLocusLine(line)
                    locusName = parsed.name
                    locusLength = parsed.length
                    locusMoleculeType = parsed.moleculeType
                    locusTopology = parsed.topology
                    locusDivision = parsed.division
                    locusDate = parsed.date
                } else if line.hasPrefix("DEFINITION") {
                    definition = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("ACCESSION") {
                    accession = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("VERSION") {
                    version = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("FEATURES") {
                    currentSection = .features
                } else if line.hasPrefix("ORIGIN") {
                    currentSection = .origin
                }

            case .features:
                if line.hasPrefix("ORIGIN") {
                    if let featureType = currentFeatureType,
                       let location = currentFeatureLocation,
                       let annotation = createAnnotation(type: featureType, location: location, qualifiers: currentQualifiers) {
                        features.append(annotation)
                    }
                    currentSection = .origin
                } else if line.count >= 21 && !line.hasPrefix(" ") {
                    break
                } else if line.count >= 21 {
                    let featureKey = String(line.prefix(21)).trimmingCharacters(in: .whitespaces)
                    let rest = line.count > 21 ? String(line.dropFirst(21)) : ""

                    if !featureKey.isEmpty && !featureKey.hasPrefix("/") {
                        if let featureType = currentFeatureType,
                           let location = currentFeatureLocation,
                           let annotation = createAnnotation(type: featureType, location: location, qualifiers: currentQualifiers) {
                            features.append(annotation)
                        }

                        currentFeatureType = featureKey
                        currentFeatureLocation = rest.trimmingCharacters(in: .whitespaces)
                        currentQualifiers = [:]
                        currentQualifierKey = nil
                        currentQualifierValue = ""
                    } else if featureKey.isEmpty || featureKey.hasPrefix("/") {
                        let trimmed = rest.trimmingCharacters(in: .whitespaces)

                        if trimmed.hasPrefix("/") {
                            if let key = currentQualifierKey {
                                currentQualifiers[key] = currentQualifierValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            }

                            let qualLine = String(trimmed.dropFirst())
                            if let eqIndex = qualLine.firstIndex(of: "=") {
                                currentQualifierKey = String(qualLine[..<eqIndex])
                                currentQualifierValue = String(qualLine[qualLine.index(after: eqIndex)...])
                            } else {
                                currentQualifierKey = qualLine
                                currentQualifierValue = "true"
                            }
                        } else if currentQualifierKey != nil {
                            currentQualifierValue += trimmed
                        } else if currentFeatureLocation != nil {
                            currentFeatureLocation! += trimmed
                        }
                    }
                }

            case .origin:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("//") {
                    sequenceBases += trimmed.filter { $0.isLetter }
                }
            }

            lineIndex += 1
        }

        guard let name = locusName else {
            return (nil, lineIndex)
        }

        let locusInfo = LocusInfo(
            name: name,
            length: locusLength,
            moleculeType: locusMoleculeType,
            topology: locusTopology,
            division: locusDivision,
            date: locusDate
        )

        let sequence = try Sequence(
            name: name,
            description: definition,
            alphabet: locusMoleculeType.alphabet,
            bases: sequenceBases
        )

        let record = GenBankRecord(
            sequence: sequence,
            annotations: features,
            locus: locusInfo,
            definition: definition,
            accession: accession,
            version: version
        )

        return (record, lineIndex)
    }

    private func parseLocusLine(_ line: String) -> (name: String, length: Int, moleculeType: MoleculeType, topology: Topology, division: String?, date: String?) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            return ("unknown", 0, .dna, .linear, nil, nil)
        }

        let name = String(parts[1])
        var length = 0
        var moleculeType: MoleculeType = .dna
        var topology: Topology = .linear
        var division: String?
        var date: String?

        for (index, part) in parts.enumerated() {
            let partString = String(part)
            if partString == "bp" && index > 0 {
                length = Int(parts[index - 1]) ?? 0
            } else if let molType = MoleculeType(rawValue: partString.uppercased()) {
                moleculeType = molType
            } else if let molType = MoleculeType(rawValue: partString) {
                moleculeType = molType
            } else if partString.lowercased() == "circular" {
                topology = .circular
            } else if partString.lowercased() == "linear" {
                topology = .linear
            }
        }

        if parts.count >= 2 {
            let lastPart = String(parts.last!)
            if lastPart.contains("-") {
                date = lastPart
                if parts.count >= 3 {
                    let secondLast = String(parts[parts.count - 2])
                    if secondLast.count == 3 && secondLast.uppercased() == secondLast {
                        division = secondLast
                    }
                }
            }
        }

        return (name, length, moleculeType, topology, division, date)
    }

    private func createAnnotation(type: String, location: String, qualifiers: [String: String]) -> SequenceAnnotation? {
        let (start, end, strand) = parseLocation(location)
        guard start >= 0 && end >= start else { return nil }

        let name = qualifiers["gene"] ?? qualifiers["product"] ?? qualifiers["label"] ?? type
        let annotationType = AnnotationType(rawValue: type.lowercased()) ?? .region

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            intervals: [AnnotationInterval(start: start, end: end)],
            strand: strand,
            qualifiers: qualifiers.mapValues { AnnotationQualifier($0) }
        )
    }

    private func parseLocation(_ location: String) -> (start: Int, end: Int, strand: Strand) {
        var loc = location
        var strand: Strand = .forward

        if loc.hasPrefix("complement(") {
            strand = .reverse
            loc = String(loc.dropFirst(11).dropLast())
        }

        if loc.hasPrefix("join(") {
            loc = String(loc.dropFirst(5).dropLast())
            if let firstRange = loc.split(separator: ",").first {
                loc = String(firstRange)
            }
        }

        let parts = loc.replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .split(separator: ".")

        if parts.count >= 2 {
            let start = Int(parts[0]) ?? 0
            let end = Int(parts.last!) ?? 0
            return (start - 1, end, strand)
        } else if let single = Int(loc.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")) {
            return (single - 1, single, strand)
        }

        return (0, 0, strand)
    }
}
