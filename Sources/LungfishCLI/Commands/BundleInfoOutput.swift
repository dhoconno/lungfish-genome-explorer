// BundleInfoOutput.swift - Output structure for JSON format
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Output structure for JSON format
struct BundleInfoOutput: Codable {
    let manifest: BundleManifest
    let path: String
}
