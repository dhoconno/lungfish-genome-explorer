// MHCReferenceCompletenessStatus.swift - Completeness status of an MHC reference record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public enum MHCReferenceCompletenessStatus: String, Codable, Equatable, Sendable {
    case complete
    case incomplete
    case unknown
}
