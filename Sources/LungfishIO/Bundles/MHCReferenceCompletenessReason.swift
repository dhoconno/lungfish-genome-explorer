// MHCReferenceCompletenessReason.swift - Reason behind an MHC reference completeness status
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public enum MHCReferenceCompletenessReason: String, Codable, Equatable, Sendable {
    case annotationTopology
    case missingAnnotationDatabase
    case missingAnnotationFeatures
    case nonGenomicReference
    case unsupportedLocusTopology
    case ambiguousAnnotationEvidence
    case missingOrNoncontinuousExons
    case unsupportedTerminalExon
    case missingBoundaryCoverage
    case missingInterveningIntrons
    case fuzzyOrIncompleteCDS
}
