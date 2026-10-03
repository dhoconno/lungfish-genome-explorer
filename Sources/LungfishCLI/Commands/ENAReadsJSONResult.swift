// ENAReadsJSONResult.swift - JSON output for ENA reads
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for ENA reads
struct ENAReadsJSONResult: Codable {
    let accession: String
    let records: [ENAReadJSON]
}
