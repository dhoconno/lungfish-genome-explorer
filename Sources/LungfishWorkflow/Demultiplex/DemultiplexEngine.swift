// DemultiplexEngine.swift - The tool that splits reads by barcode
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

public enum DemultiplexEngine: String, Codable, Sendable, CaseIterable {
    case cutadapt
    case exactBareBarcode = "exact-bare"
    /// Splits reads by the index bcl2fastq or BCL Convert wrote in their names, and runs no tool (L4 of the 3.3 tally).
    case headerIndex = "header-index"
}

extension DemultiplexEngine {
    /// What a run of Exact Bare Barcode says about chance matches, which it does not check
    /// (DEMUX-EXACT-BARE-NO-FLOOR, rulings BIO-OLDER-DEMUX-ROWS section 2 and UX-EXACT-BARE-WORDS).
    public static let exactBareChanceWords = ""
}
