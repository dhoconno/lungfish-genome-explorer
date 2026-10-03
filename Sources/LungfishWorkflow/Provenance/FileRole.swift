// FileRole.swift - Role of a file in a workflow step
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - FileRole

/// Role of a file in a workflow step.
public enum FileRole: String, Codable, Sendable {
    case input
    case output
    case reference
    case index
    case log
    case report
}
