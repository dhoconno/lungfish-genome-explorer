// ENAReadJSON.swift - JSON output for ENA read record
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for ENA read record
struct ENAReadJSON: Codable {
    let runAccession: String
    let studyAccession: String?
    let platform: String?
    let libraryStrategy: String?
    let libraryLayout: String?
    let readCount: Int?
    let fileSize: String?
    let fastqURLs: [String]
}
