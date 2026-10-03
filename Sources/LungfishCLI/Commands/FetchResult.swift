// FetchResult.swift - Fetch result for JSON output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Fetch result for JSON output
struct FetchResult: Codable {
    let accessions: [String]
    let database: String
    let format: String
    let outputFile: String?
}
