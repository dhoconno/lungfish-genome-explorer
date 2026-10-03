// BundleValidationOutput.swift - Overall validation output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Overall validation output
struct BundleValidationOutput: Codable {
    let bundles: [BundleValidationResult]
    let allValid: Bool
}
