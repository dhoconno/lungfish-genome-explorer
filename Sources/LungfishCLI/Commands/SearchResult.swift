// SearchResult.swift - Search result for JSON output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Search result for JSON output
struct SearchResult: Codable {
    let query: String
    let database: String
    let ids: [String]
}
