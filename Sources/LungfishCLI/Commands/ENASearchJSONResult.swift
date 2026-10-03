// ENASearchJSONResult.swift - JSON output for ENA search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for ENA search
struct ENASearchJSONResult: Codable {
    let query: String
    let totalCount: Int
    let records: [ENARecordJSON]
}
