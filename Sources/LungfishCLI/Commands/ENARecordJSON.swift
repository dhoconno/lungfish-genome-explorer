// ENARecordJSON.swift - JSON output for ENA record
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for ENA record
struct ENARecordJSON: Codable {
    let accession: String
    let title: String
    let organism: String?
    let length: Int?
}
