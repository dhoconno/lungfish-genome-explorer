// MHCReferenceRecord.swift - One resolved MHC reference record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public struct MHCReferenceRecord: Codable, Equatable, Sendable {
    public let sequenceID: String
    public let alleleName: String
    public let locus: String
    public let moleculeClass: MHCReferenceMoleculeClass
    public let classEvidence: MHCReferenceClassEvidence
    public let sequenceLength: Int
    public let completeness: MHCReferenceCompletenessAssessment

    public init(
        sequenceID: String,
        alleleName: String,
        locus: String,
        moleculeClass: MHCReferenceMoleculeClass,
        classEvidence: MHCReferenceClassEvidence,
        sequenceLength: Int,
        completeness: MHCReferenceCompletenessAssessment = .unknown
    ) {
        self.sequenceID = sequenceID
        self.alleleName = alleleName
        self.locus = locus
        self.moleculeClass = moleculeClass
        self.classEvidence = classEvidence
        self.sequenceLength = sequenceLength
        self.completeness = completeness
    }

    private enum CodingKeys: String, CodingKey {
        case sequenceID
        case alleleName
        case locus
        case moleculeClass
        case classEvidence
        case sequenceLength
        case completeness
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequenceID = try values.decode(String.self, forKey: .sequenceID)
        alleleName = try values.decode(String.self, forKey: .alleleName)
        locus = try values.decode(String.self, forKey: .locus)
        moleculeClass = try values.decode(MHCReferenceMoleculeClass.self, forKey: .moleculeClass)
        classEvidence = try values.decode(MHCReferenceClassEvidence.self, forKey: .classEvidence)
        sequenceLength = try values.decode(Int.self, forKey: .sequenceLength)
        completeness = try values.decodeIfPresent(
            MHCReferenceCompletenessAssessment.self,
            forKey: .completeness
        ) ?? .unknown
    }
}
