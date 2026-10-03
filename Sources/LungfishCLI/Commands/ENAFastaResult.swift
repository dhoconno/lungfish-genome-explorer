// ENAFastaResult.swift - JSON output for ENA FASTA fetch
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// JSON output for ENA FASTA fetch
struct ENAFastaResult: Codable {
    let accession: String
    let outputFile: String?
    let length: Int
}
