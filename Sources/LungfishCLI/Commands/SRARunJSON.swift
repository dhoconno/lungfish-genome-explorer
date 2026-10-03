// SRARunJSON.swift - JSON output for SRA run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for SRA run
struct SRARunJSON: Codable {
    let accession: String
    let organism: String?
    let platform: String?
    let libraryStrategy: String?
    let libraryLayout: String?
    let spots: Int?
    let bases: Int?
    let size: Int?
}
