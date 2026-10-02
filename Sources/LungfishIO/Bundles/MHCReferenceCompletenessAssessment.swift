// MHCReferenceCompletenessAssessment.swift - Completeness assessment of an MHC reference record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public struct MHCReferenceCompletenessAssessment: Codable, Equatable, Sendable {
    public static let topologyPolicyDescription = "class-I=7,8;DRA=5;DRB,DPA,DPB,DQA,DQB=6"

    public let status: MHCReferenceCompletenessStatus
    public let reason: MHCReferenceCompletenessReason
    public let observedExons: [Int]
    public let observedIntrons: [Int]
    public let acceptedTerminalExons: [Int]
    public let annotationTrackIDs: [String]

    public init(
        status: MHCReferenceCompletenessStatus,
        reason: MHCReferenceCompletenessReason,
        observedExons: [Int] = [],
        observedIntrons: [Int] = [],
        acceptedTerminalExons: [Int] = [],
        annotationTrackIDs: [String] = []
    ) {
        self.status = status
        self.reason = reason
        self.observedExons = observedExons
        self.observedIntrons = observedIntrons
        self.acceptedTerminalExons = acceptedTerminalExons
        self.annotationTrackIDs = annotationTrackIDs
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case reason
        case observedExons
        case observedIntrons
        case acceptedTerminalExons
        case annotationTrackIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(MHCReferenceCompletenessStatus.self, forKey: .status)
        reason = try values.decode(MHCReferenceCompletenessReason.self, forKey: .reason)
        observedExons = try values.decodeIfPresent([Int].self, forKey: .observedExons) ?? []
        observedIntrons = try values.decodeIfPresent([Int].self, forKey: .observedIntrons) ?? []
        acceptedTerminalExons = try values.decodeIfPresent([Int].self, forKey: .acceptedTerminalExons) ?? []
        annotationTrackIDs = try values.decodeIfPresent([String].self, forKey: .annotationTrackIDs) ?? []
    }

    public static let unknown = MHCReferenceCompletenessAssessment(
        status: .unknown,
        reason: .missingAnnotationDatabase
    )
}
