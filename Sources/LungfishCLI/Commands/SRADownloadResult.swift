// SRADownloadResult.swift - JSON output for SRA download
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for SRA download
struct SRADownloadResult: Codable {
    let accession: String
    let files: [String]
    let outputDir: String
}
