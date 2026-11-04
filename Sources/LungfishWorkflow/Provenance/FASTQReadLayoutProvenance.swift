// FASTQReadLayoutProvenance.swift - The read layout and the scan behind it, as run record parameters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQReadLayoutClassification {
    /// `readLayout`, `readLayoutReason`, `scannedRecords`, `scannedWholeFile`, `pairs` and `unpairedReads`, so a record
    /// says what was read to decide the layout (row READ-LAYOUT-PARTIAL-SCAN).
    public var provenanceParameters: [String: ParameterValue] {
        [
            "readLayout": .string(layout.rawValue),
            "readLayoutReason": .string(reason),
            "scannedRecords": .integer(scannedRecords),
            "scannedWholeFile": .boolean(scannedWholeFile),
            "pairs": .integer(matePairs),
            "unpairedReads": .integer(unpairedRecords),
        ]
    }
}

extension FASTQInputLayoutResolution {
    /// Null when the layout was stated or settled with nothing read.
    public var scannedRecordsProvenanceValue: ParameterValue {
        classification.map { .integer($0.scannedRecords) } ?? .null
    }

    public var scannedWholeFileProvenanceValue: ParameterValue {
        classification.map { .boolean($0.scannedWholeFile) } ?? .null
    }

    public var pairsProvenanceValue: ParameterValue {
        classification.map { .integer($0.matePairs) } ?? .null
    }

    public var unpairedReadsProvenanceValue: ParameterValue {
        classification.map { .integer($0.unpairedRecords) } ?? .null
    }
}
