// DemultiplexError.swift - Errors thrown by the demultiplexing pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

// MARK: - Demultiplex Error

public enum DemultiplexError: Error, LocalizedError, Sendable {
    case inputFileNotFound(URL)
    case cutadaptFailed(exitCode: Int32, stderr: String)
    case noBarcodes
    case combinatorialRequiresSampleAssignments
    case outputParsingFailed(String)
    case bundleCreationFailed(barcode: String, underlying: String)
    case noOutputResults
    case emptyAdapterSequences(kitName: String)
    case ambiguousAdapterSequences(kitName: String)
    case kitSequencesUnderCheck(kitName: String)
    case dualKitNeedsBothEnds(kitName: String)
    case binCountExceeded(count: Int, limit: Int)
    case exactBareBarcodeUnsupported
    case fileSetNeedsInterleaving(bundleName: String, fileNames: [String])
    /// The read names carry the kit's index, which no run splits by yet (the floor of L1, 3.3 tally).
    case readNameIndexNotSplitYet
    /// ``DemultiplexSearchRouteOwner`` refused the run, for the reason the words give.
    case searchRouteRefused(String)
    /// No barcode of a search of the read bases beat BIO's chance floor (L5, 3.3 tally).
    case noBarcodeAboveChance(kitName: String)

    public var errorDescription: String? {
        switch self {
        case .noBarcodeAboveChance(let kitName):
            return "No barcode of \(kitName) matched more reads than chance alone gives, so Demultiplex Barcodes made no sample files. The index in the read names may match no barcode of this kit, the index may sit in index reads that are not in this file, or the reads may already be split into one file per sample. Choose the kit the library was made with, check the barcode sequences and the end of the read you chose for a Custom Definition, or import this file as one sample."
        case .readNameIndexNotSplitYet:
            return "These reads carry their index in the read names. Demultiplex Barcodes searches the read sequences and cannot split them by that index yet, so it did not start and wrote no files. Get one FASTQ file per sample, as bcl2fastq or BCL Convert writes them from the run's sample sheet, and import those."
        case .searchRouteRefused(let words):
            return words
        case .inputFileNotFound(let url):
            return "Input FASTQ not found: \(url.lastPathComponent)"
        case .cutadaptFailed(let code, let stderr):
            return "cutadapt failed (exit \(code)): \(String(stderr.suffix(500)))"
        case .noBarcodes:
            return "Barcode kit has no barcodes defined"
        case .combinatorialRequiresSampleAssignments:
            return "Combinatorial kits require explicit sample barcode assignments."
        case .outputParsingFailed(let msg):
            return "Failed to parse cutadapt output: \(msg)"
        case .bundleCreationFailed(let barcode, let error):
            return "Failed to create bundle for \(barcode): \(error)"
        case .noOutputResults:
            return "Multi-step demultiplexing produced no output results."
        case .emptyAdapterSequences(let kitName):
            return "No barcode sequences could be built for the kit \"\(kitName)\", so nothing was run and no files changed. Choose Custom Definition (on the command line, pass --kit with your own barcode file) and enter the barcode sequences from your index sheet, or choose the kit named in your library preparation record."
        case .ambiguousAdapterSequences(let kitName):
            return "Two barcodes in the kit \"\(kitName)\" give the same search sequence, so their reads could not be told apart and nothing was run. Choose Custom Definition and enter the barcodes from your index sheet."
        case .kitSequencesUnderCheck(let kitName):
            return "The built-in sequences for \"\(kitName)\" are being checked, so this kit is off for now and nothing was run. Choose Custom Definition and enter the i7 and i5 sequences from your index sheet."
        case .dualKitNeedsBothEnds(let kitName):
            return "The kit \"\(kitName)\" has its first index at the start of a read and its second at the end, so it can be searched only at Both Ends, and nothing was run. Choose Both Ends (on the command line, --location bothends) and run it again."
        case .binCountExceeded(let count, let limit):
            return "Bin count (\(count)) exceeds maximum (\(limit)). Reduce the number of barcode combinations or use fewer demux steps."
        case .exactBareBarcodeUnsupported:
            return "Exact bare-barcode demultiplexing requires a single-index bare barcode kit with A/C/G/T sequences. Use cutadapt for adapter-context, dual-index, or fuzzy barcode matching."
        case .fileSetNeedsInterleaving(let bundleName, let fileNames):
            return "The bundle \"\(bundleName)\" holds \(fileNames.count) FASTQ files (\(fileNames.joined(separator: ", "))) and no source-files.json, so they are the R1 and R2 of one sample. Exact-barcode demultiplexing calls every read on its own, so the two mates of a pair would not follow one call, and nothing was run. Make one interleaved FASTQ file of the pair (lungfish-cli fastq interleave), then demultiplex that file."
        }
    }
}
