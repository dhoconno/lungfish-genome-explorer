// RunStatus.swift - Status of a workflow run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - RunStatus

/// Status of a workflow run.
public enum RunStatus: String, Codable, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}
