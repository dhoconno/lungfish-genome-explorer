// MHCReferenceClassEvidence.swift - Evidence behind an MHC reference molecule class
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public enum MHCReferenceClassEvidence: String, Codable, Equatable, Sendable {
    case annotatedMetadata
    case lengthThresholdFallback
}
