// RecipeStepOutputFile.swift - Execution-time evidence for a recipe step output that may be deleted
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

/// Execution-time evidence for a recipe step output that may be deleted after downstream use.
public struct RecipeStepOutputFile: Codable, Sendable, Equatable {
    public let path: String
    public let checksumSHA256: String
    public let sizeBytes: UInt64

    public init(path: String, checksumSHA256: String, sizeBytes: UInt64) {
        self.path = path
        self.checksumSHA256 = checksumSHA256
        self.sizeBytes = sizeBytes
    }
}
