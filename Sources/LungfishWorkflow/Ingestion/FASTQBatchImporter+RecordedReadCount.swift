// FASTQBatchImporter+RecordedReadCount.swift - The count of a lone file's stored reads, recorded in its sidecar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQBatchImporter {

    /// Records the count of a lone file's stored reads and the stored file's size (row READ-LAYOUT-PARTIAL-SCAN).
    ///
    /// The count is taken from the stored bytes, after any recipe and any clumping, on every route, so what it proves
    /// is true of the file a later run reads. A file that holds pairs beside single reads also records the roles of
    /// `readClassification`, as every importer does for such a file, and a file of one kind records none, since the
    /// roles of a file of single reads read as merge evidence.
    ///
    /// A person's own Single-end records no roles, so that nothing overrules the choice. It is the workaround the
    /// 2026.10.29 known-issue line gives. A count that cannot be taken never fails an import, since a later run then
    /// scans the file itself. A cancel still stops the import.
    static func recordCount(
        ofStored fastqURL: URL,
        named name: String,
        pairing: RecordedPairing,
        in metadata: inout PersistedFASTQMetadata
    ) throws {
        let scan: (scannedRecords: Int, matePairs: Int, unpairedRecords: Int, scannedWholeFile: Bool)
        do {
            scan = try FASTQReadLayoutClassifier.countMates(in: fastqURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
        guard scan.scannedRecords > 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: fastqURL.path)[.size] as? NSNumber)?.int64Value else {
            return
        }
        metadata.recordedReadCount = FASTQRecordedReadCount(
            pairedR1: scan.matePairs,
            pairedR2: scan.matePairs,
            unpaired: scan.unpairedRecords,
            storedSizeBytes: size
        )
        let chosenSingle = pairing.mode == .singleEnd && pairing.source == .explicit
        guard metadata.readClassification == nil, !chosenSingle, scan.matePairs > 0, scan.unpairedRecords > 0 else { return }
        metadata.readClassification = ReadClassification(files: [
            ReadClassification.FileEntry(filename: name, role: .pairedR1, readCount: scan.matePairs),
            ReadClassification.FileEntry(filename: name, role: .pairedR2, readCount: scan.matePairs),
            ReadClassification.FileEntry(filename: name, role: .unpaired, readCount: scan.unpairedRecords),
        ])
    }
}
