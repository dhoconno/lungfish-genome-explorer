// SRASearchJSONResult.swift - JSON output for SRA search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for SRA search
struct SRASearchJSONResult: Codable {
    let query: String
    let totalCount: Int
    let runs: [SRARunJSON]
}
