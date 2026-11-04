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

    /// The four scan fields of a run record, each null where no scan decided the layout. A stated layout, a pool and a
    /// person's Single-end read nothing, and a 0 there would say a read found no records.
    public static func scanProvenanceParameters(of scan: FASTQReadLayoutClassification?) -> [String: ParameterValue] {
        guard let scan else {
            return ["scannedRecords": .null, "scannedWholeFile": .null, "pairs": .null, "unpairedReads": .null]
        }
        return [
            "scannedRecords": .integer(scan.scannedRecords),
            "scannedWholeFile": .boolean(scan.scannedWholeFile),
            "pairs": .integer(scan.matePairs),
            "unpairedReads": .integer(scan.unpairedRecords),
        ]
    }

    /// This scan with the counts of a read of the whole file, which outrank a scan's by-layout counts for `pairs` and
    /// `unpairedReads`. A materialized input is counted that way when it is written.
    public func countedWhole(pairs: Int, unpaired: Int) -> FASTQReadLayoutClassification {
        FASTQReadLayoutClassification(
            layout: layout,
            scannedRecords: pairs * 2 + unpaired,
            matePairs: pairs,
            unpairedRecords: unpaired,
            scannedWholeFile: true,
            metadata: metadata,
            reason: reason
        )
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

    /// The scan a record of `inputURL` may name. None when nothing was read, and none when the scanned file holds only
    /// part of the input, since a preview's `scannedWholeFile` true is about the preview.
    public func recordedScan(of inputURL: URL?) -> FASTQReadLayoutClassification? {
        guard let classification, let inputURL, FASTQReadLayoutClassifier.scanHoldsEveryRead(of: inputURL) else {
            return nil
        }
        return classification
    }
}
