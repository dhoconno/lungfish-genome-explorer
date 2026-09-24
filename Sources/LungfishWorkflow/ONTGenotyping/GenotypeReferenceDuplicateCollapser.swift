// GenotypeReferenceDuplicateCollapser.swift - Collapses identical amplicon references before mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// GEN-04 (D12): identical reference sequences, including reverse
/// complements, make every perfect read tie across all copies. minimap2
/// then reports only a few secondary hits, so per-allele counts become
/// arbitrary (the audit's `e1` fixture: 8 identical references and 20
/// perfect reads gave counts from 9 to 19) and locus sums are inflated by
/// the tie multiplicity.
///
/// Before mapping, the pipeline collapses each group of identical sequences
/// to one representative (the first record in file order), maps against the
/// collapsed FASTA, and reports the whole group on the representative's row
/// as an ambiguity group. The user's reference file is never modified.
public enum GenotypeReferenceDuplicateCollapser {
    /// One set of reference records whose sequences are identical, directly
    /// or as reverse complements.
    public struct Group: Codable, Equatable, Sendable {
        /// Record name kept in the collapsed FASTA (first member in file order).
        public let representative: String
        /// Every member's record name, in file order, representative first.
        public let members: [String]
        /// Members identical to the representative only after reverse complementing.
        public let reverseComplementMembers: [String]

        public init(representative: String, members: [String], reverseComplementMembers: [String]) {
            self.representative = representative
            self.members = members
            self.reverseComplementMembers = reverseComplementMembers
        }
    }

    public struct Collapse: Equatable, Sendable {
        /// FASTA to map against: the collapsed copy, or the original when
        /// there were no duplicates.
        public let mappingReferenceFASTAURL: URL
        /// Groups with at least two members. Empty when nothing was collapsed.
        public let groups: [Group]
        /// JSON `{representative: [members...]}` for the filter script, or nil.
        public let groupsJSONURL: URL?

        public var collapsedRecordCount: Int {
            groups.reduce(0) { $0 + $1.members.count - 1 }
        }

        /// Human-readable provenance warning, or nil when nothing was collapsed.
        public var warning: String? {
            guard !groups.isEmpty else { return nil }
            let listed = groups.map { $0.members.joined(separator: ", ") }.joined(separator: "; ")
            return "Reference contains \(groups.count) group(s) of identical sequences (including reverse complements); \(collapsedRecordCount) duplicate record(s) were collapsed onto one representative per group before mapping, and each call lists its group in ambiguous_with: \(listed)."
        }
    }

    /// Finds groups of identical sequences (case-insensitive, including
    /// reverse complements). Only groups with two or more members are returned.
    public static func duplicateGroups(inFASTA url: URL) throws -> [Group] {
        try analyze(url).groups
    }

    /// Writes a collapsed FASTA and groups JSON into `outputDirectory` when the
    /// reference has duplicates; otherwise returns the original URL unchanged.
    public static func collapse(referenceFASTAURL: URL, outputDirectory: URL) throws -> Collapse {
        let analysis = try analyze(referenceFASTAURL)
        guard !analysis.groups.isEmpty else {
            return Collapse(mappingReferenceFASTAURL: referenceFASTAURL, groups: [], groupsJSONURL: nil)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let collapsedURL = outputDirectory.appendingPathComponent("reference.collapsed-duplicates.fasta")
        let dropped = Set(analysis.groups.flatMap { $0.members.dropFirst() })
        var text = ""
        for record in analysis.records where !dropped.contains(record.name) {
            text += ">\(record.header)\n"
            var index = record.sequence.startIndex
            while index < record.sequence.endIndex {
                let end = record.sequence.index(index, offsetBy: 80, limitedBy: record.sequence.endIndex)
                    ?? record.sequence.endIndex
                text += record.sequence[index..<end] + "\n"
                index = end
            }
        }
        try text.write(to: collapsedURL, atomically: true, encoding: .utf8)

        let groupsURL = outputDirectory.appendingPathComponent("reference.ambiguity-groups.json")
        let map = Dictionary(uniqueKeysWithValues: analysis.groups.map { ($0.representative, $0.members) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(map).write(to: groupsURL, options: .atomic)
        return Collapse(mappingReferenceFASTAURL: collapsedURL, groups: analysis.groups, groupsJSONURL: groupsURL)
    }

    // MARK: - Internals

    private struct Record {
        let name: String
        let header: String
        let sequence: String
    }

    private static func analyze(_ url: URL) throws -> (records: [Record], groups: [Group]) {
        var records: [Record] = []
        try FASTAReader(url: url).forEachSequenceSync { sequence in
            let header = [sequence.name, sequence.description]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            records.append(Record(name: sequence.name, header: header, sequence: sequence.asString()))
        }
        var groupIndexByKey: [String: Int] = [:]
        var members: [[(name: String, reverseComplement: Bool)]] = []
        var representativeSequences: [String] = []
        for record in records {
            let forward = record.sequence.uppercased()
            let reverse = reverseComplement(forward)
            let key = min(forward, reverse)
            if !key.isEmpty, let index = groupIndexByKey[key] {
                members[index].append((record.name, forward != representativeSequences[index]))
            } else {
                groupIndexByKey[key] = members.count
                members.append([(record.name, false)])
                representativeSequences.append(forward)
            }
        }
        let groups = members.filter { $0.count > 1 }.map { group in
            Group(
                representative: group[0].name,
                members: group.map(\.name),
                reverseComplementMembers: group.filter(\.reverseComplement).map(\.name)
            )
        }
        return (records, groups)
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(String.UnicodeScalarView(sequence.unicodeScalars.reversed().map { scalar -> Unicode.Scalar in
            switch scalar {
            case "A": return "T"
            case "T", "U": return "A"
            case "G": return "C"
            case "C": return "G"
            case "R": return "Y"
            case "Y": return "R"
            case "K": return "M"
            case "M": return "K"
            case "B": return "V"
            case "V": return "B"
            case "D": return "H"
            case "H": return "D"
            default: return scalar
            }
        }))
    }
}
