// TwelveSDetailPayload.swift — Sendable detail snapshot for the Inspector tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A `Sendable` snapshot of the currently-selected 12S row, carried from the
/// leaf view controller to the App's Inspector detail tab.
///
/// Defined in the leaf so both the leaf VC and the App glue can pass it without
/// the leaf importing `LungfishApp` (preserving the kernel/leaf boundary).
public struct TwelveSDetailPayload: Equatable, Sendable {

    /// Detail for a resolved target (scientific-name) row.
    public struct TargetDetail: Equatable, Sendable {
        public let scientificName: String
        public let totalExactReads: Int
        public let referenceTargetCount: Int
        public let sampleEvidence: [TwelveSDetailSampleEvidenceRow]
        public let alternateTexts: [String]

        public init(
            scientificName: String,
            totalExactReads: Int,
            referenceTargetCount: Int,
            sampleEvidence: [TwelveSDetailSampleEvidenceRow],
            alternateTexts: [String]
        ) {
            self.scientificName = scientificName
            self.totalExactReads = totalExactReads
            self.referenceTargetCount = referenceTargetCount
            self.sampleEvidence = sampleEvidence
            self.alternateTexts = alternateTexts
        }
    }

    /// Detail for an unresolved (unmatched) sequence cluster.
    public struct UnresolvedDetail: Equatable, Sendable {
        public let sequenceID: String
        public let readCount: Int
        public let chimeraStatusName: String
        public let sequence: String
        public let sampleEvidence: [TwelveSDetailSampleEvidenceRow]

        public init(
            sequenceID: String,
            readCount: Int,
            chimeraStatusName: String,
            sequence: String,
            sampleEvidence: [TwelveSDetailSampleEvidenceRow]
        ) {
            self.sequenceID = sequenceID
            self.readCount = readCount
            self.chimeraStatusName = chimeraStatusName
            self.sequence = sequence
            self.sampleEvidence = sampleEvidence
        }
    }

    public enum Kind: Equatable, Sendable {
        case target(TargetDetail)
        case unresolved(UnresolvedDetail)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    /// Builds a target payload from a row plus a sample-ID → display-name map.
    public init(targetRow row: TwelveSScientificNameCountRow, sampleDisplayNames: [String: String]) {
        let evidence = row.sampleCounts
            .filter { $0.value > 0 }
            .map { sampleID, count -> TwelveSDetailSampleEvidenceRow in
                let denominator = row.sampleExactReadTotals[sampleID, default: 0]
                let percent = denominator > 0 ? Double(count) / Double(denominator) * 100 : 0
                return TwelveSDetailSampleEvidenceRow(
                    sampleID: sampleID,
                    displayName: sampleDisplayNames[sampleID] ?? sampleID,
                    exactReads: count,
                    percentOfSampleExactReads: percent
                )
            }
            .sorted {
                if $0.exactReads != $1.exactReads { return $0.exactReads > $1.exactReads }
                return $0.sampleID < $1.sampleID
            }
        let alternates = row.alternateMatches.isEmpty
            ? row.potentialMatches
            : row.alternateMatches.map(\.displayName)
        self.kind = .target(TargetDetail(
            scientificName: row.scientificName,
            totalExactReads: row.totalExactReads,
            referenceTargetCount: row.referenceTargetCount,
            sampleEvidence: evidence,
            alternateTexts: alternates
        ))
    }

    /// Builds an unresolved payload from a row plus a sample-ID → display-name map.
    public init(unresolvedRow row: TwelveSUnresolvedSequence, sampleDisplayNames: [String: String]) {
        let evidence = row.sampleCounts
            .filter { $0.value > 0 }
            .map { sampleID, count in
                TwelveSDetailSampleEvidenceRow(
                    sampleID: sampleID,
                    displayName: sampleDisplayNames[sampleID] ?? sampleID,
                    exactReads: count,
                    percentOfSampleExactReads: 0
                )
            }
            .sorted {
                if $0.exactReads != $1.exactReads { return $0.exactReads > $1.exactReads }
                return $0.sampleID < $1.sampleID
            }
        self.kind = .unresolved(UnresolvedDetail(
            sequenceID: row.sequenceID,
            readCount: row.readCount,
            chimeraStatusName: row.chimeraStatus.displayName,
            sequence: row.sequence,
            sampleEvidence: evidence
        ))
    }
}
