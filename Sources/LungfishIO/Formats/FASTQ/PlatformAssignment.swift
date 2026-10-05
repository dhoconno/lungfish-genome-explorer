// PlatformAssignment.swift - How a FASTQ bundle's platform label was decided
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How the `sequencingPlatform` and `assemblyReadType` of a FASTQ sidecar were
/// decided, with the evidence. Stored as `platformAssignment` in the sidecar.
///
/// A bundle imported before this record existed has none. The suspect-label
/// check (``PlatformLabelCheck``) only questions those bundles, so a label a
/// person set or confirmed is never questioned again.
public struct PlatformAssignment: Codable, Sendable, Equatable {

    public enum Source: String, Codable, Sendable, CaseIterable {
        /// Inferred from the reads at import (`--platform auto`).
        case inferred
        /// Given at import (`--platform <value>`, or an ENA or SRA record).
        case given
        /// Changed later by a person (`lungfish-cli fastq platform --set`).
        case userCorrected
        /// Kept later by a person after a notice (`lungfish-cli fastq platform --confirm`).
        case userConfirmed
        /// A source a later release recorded that this release does not know.
        /// The label still counts as decided. This release never records it.
        case unknown

        /// An unrecognised raw value decodes as `.unknown` instead of failing
        /// the whole sidecar, as ``SequencingPlatform`` does.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .unknown
        }
    }

    public var source: Source
    public var platform: SequencingPlatform
    public var readClass: FASTQAssemblyReadType?
    public var vendorDetail: String?
    public var confidence: PlatformInference.Confidence?
    public var evidence: [String]
    public var sampledRecords: Int?
    public var detectorVersion: Int?
    public var recordedAt: Date

    public init(
        source: Source,
        platform: SequencingPlatform,
        readClass: FASTQAssemblyReadType?,
        vendorDetail: String? = nil,
        confidence: PlatformInference.Confidence? = nil,
        evidence: [String] = [],
        sampledRecords: Int? = nil,
        detectorVersion: Int? = nil,
        recordedAt: Date = Date()
    ) {
        self.source = source
        self.platform = platform
        self.readClass = readClass
        self.vendorDetail = vendorDetail
        self.confidence = confidence
        self.evidence = evidence
        self.sampledRecords = sampledRecords
        self.detectorVersion = detectorVersion
        self.recordedAt = recordedAt
    }

    /// The record for a platform inferred from the reads.
    public init(inferred inference: PlatformInference, recordedAt: Date = Date()) {
        self.init(
            source: .inferred,
            platform: inference.isActionable ? inference.platform : .unknown,
            readClass: inference.isActionable ? inference.readClass : nil,
            vendorDetail: inference.vendorDetail,
            confidence: inference.confidence,
            evidence: inference.evidence,
            sampledRecords: inference.sampledRecords,
            detectorVersion: PlatformInference.detectorVersion,
            recordedAt: recordedAt
        )
    }
}
