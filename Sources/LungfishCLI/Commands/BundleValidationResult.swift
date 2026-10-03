// BundleValidationResult.swift - Validation result for a single bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Validation result for a single bundle
struct BundleValidationResult: Codable {
    let path: String
    let valid: Bool
    let errors: [String]
}
