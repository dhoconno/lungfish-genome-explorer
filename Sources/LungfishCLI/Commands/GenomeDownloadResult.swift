// GenomeDownloadResult.swift - JSON output for genome download
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for genome download
struct GenomeDownloadResult: Codable {
    let accession: String
    let organism: String
    let fastaPath: String?
    let gffPath: String?
    let bundlePath: String?
}
