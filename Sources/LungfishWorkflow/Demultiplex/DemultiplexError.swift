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
    case binCountExceeded(count: Int, limit: Int)
    case exactBareBarcodeUnsupported

    public var errorDescription: String? {
        switch self {
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
        case .binCountExceeded(let count, let limit):
            return "Bin count (\(count)) exceeds maximum (\(limit)). Reduce the number of barcode combinations or use fewer demux steps."
        case .exactBareBarcodeUnsupported:
            return "Exact bare-barcode demultiplexing requires a single-index bare barcode kit with A/C/G/T sequences. Use cutadapt for adapter-context, dual-index, or fuzzy barcode matching."
        }
    }
}
