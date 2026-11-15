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
    ///
    /// Once the count and the pair hash are in `metadata`, a library that another bundle of the project already holds is
    /// logged as a notice of `sample` (row RS-INSTRUMENT, ``warnOfRepeatedReads(sample:bundleURL:metadata:projectDirectory:log:)``).
    /// The call sits here so that the importer itself holds no line for it.
    static func recordCount(
        ofStored fastqURL: URL,
        named name: String,
        pairing: RecordedPairing,
        fromMateFiles: Bool,
        in metadata: inout PersistedFASTQMetadata,
        sample: String,
        bundleURL: URL,
        projectDirectory: URL,
        log: (@Sendable (ImportLogEvent) -> Void)?
    ) throws {
        // One pass takes the counts, the order-free pair hash (ruling ADJ-BULK G5) and the instrument facts of the names
        // (row RS-INSTRUMENT), so a repeated library is known without a second read of the file.
        let scan: FASTQReadLayoutClassifier.MateScan
        do {
            scan = try FASTQReadLayoutClassifier.scanMates(in: fastqURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
        guard scan.scannedRecords > 0, scan.scannedWholeFile,
              let size = (try? FileManager.default.attributesOfItem(atPath: fastqURL.path)[.size] as? NSNumber)?.int64Value else {
            return
        }
        // A pair imported from R1 and R2 files records its count like any other file, so a wizard names its layout at
        // once. Row READ-LAYOUT-DOTTED-MATES removed the guard of BIO ruling 2 here, since the scan now reads dotted mates.
        metadata.sequencerInstrument = scan.instrument
        metadata.recordedReadCount = FASTQRecordedReadCount(
            pairedR1: scan.matePairs,
            pairedR2: scan.matePairs,
            unpaired: scan.unpairedRecords,
            storedSizeBytes: size,
            pairHash: scan.pairHash
        )
        warnOfRepeatedReads(sample: sample, bundleURL: bundleURL, metadata: metadata, projectDirectory: projectDirectory, log: log)
        let chosenSingle = pairing.mode == .singleEnd && pairing.source == .explicit
        guard metadata.readClassification == nil, !chosenSingle, scan.matePairs > 0, scan.unpairedRecords > 0 else { return }
        metadata.readClassification = ReadClassification(files: [
            ReadClassification.FileEntry(filename: name, role: .pairedR1, readCount: scan.matePairs),
            ReadClassification.FileEntry(filename: name, role: .pairedR2, readCount: scan.matePairs),
            ReadClassification.FileEntry(filename: name, role: .unpaired, readCount: scan.unpairedRecords),
        ])
    }
}
