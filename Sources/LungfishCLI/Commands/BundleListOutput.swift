// BundleListOutput.swift - Output structure for list command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Output structure for list command
struct BundleListOutput: Codable {
    let files: [String]?
    let tracks: BundleTrackList?
}
