// MainWindowFailureReports.swift - Failure words for the main window's imports and opens
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the main split view shows, each as a `FailureReport`
/// whose error text goes only to the details area (ALERT-PRESENTER, Phase 3.1).
enum MainWindowFailureReports {
    static func replaceExistingFASTQBundle(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Replace the existing FASTQ bundle",
            whatHappened: "Lungfish could not remove the bundle that already has this name, so the FASTQ file was not imported.",
            nextStep: "Check that the project folder can be written to and that no other app is using the bundle, then import the file again.",
            underlying: error
        )
    }

    static func importFASTQFile(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the FASTQ file",
            whatHappened: "The FASTQ file was not added to the project.",
            nextStep: "Check that the file is a complete, readable FASTQ file and that the disk has free space, then import it again.",
            underlying: error
        )
    }

    static func importPairedFASTQFiles(sampleName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the FASTQ files of \(sampleName)",
            whatHappened: "The read files of this sample were not added to the project.",
            nextStep: "Check that both read files of the sample are complete and readable and that the disk has free space, then import the sample again.",
            underlying: error
        )
    }

    static func splitONTReadsBySample(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Split the ONT reads by sample",
            whatHappened: "The split stopped before it finished.",
            nextStep: "Open the Operations panel to read the log of this run, check the sample sheet and barcode kit, then run the split again.",
            underlying: error
        )
    }

    static func demultiplexReadsByBarcode(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Demultiplex the reads by barcode",
            whatHappened: "Demultiplexing stopped before it finished.",
            nextStep: "Open the Operations panel to read the log of this run, check the barcode kit and sample sheet, then run it again.",
            underlying: error
        )
    }

    static func importONTRunFolder(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the ONT run folder",
            whatHappened: "The reads in the folder were not added to the project.",
            nextStep: "Check that the folder is an ONT run folder with readable FASTQ files and that the disk has free space, then import it again.",
            underlying: error
        )
    }

    static func importVCFFiles(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the VCF files",
            whatHappened: "Lungfish could not read the files into a variant bundle, so no variants were added.",
            nextStep: "Check that each file is a complete VCF file (.vcf or .vcf.gz) and that the disk has free space, then import the files again.",
            underlying: error
        )
    }

    static func readFASTQFile(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Read the FASTQ file",
            whatHappened: "Lungfish could not count the reads in the file, so its summary is not shown.",
            nextStep: "Check that the file is a complete, readable FASTQ file, then select it in the sidebar again.",
            underlying: error
        )
    }

    static func openFile(named fileName: String, _ error: any Error) -> FailureReport {
        // A BAM or CRAM file is refused with a sentence the app wrote, which names the import step to use instead.
        // That sentence is the next step, and the details keep the whole error (ALERT review SF1a).
        if let loadError = error as? DocumentLoadError,
           case .unsupportedFormat(let reason) = loadError,
           reason.hasPrefix("BAM/CRAM files are imported") {
            return FailureReport(
                failedStep: "Open \(fileName)",
                whatHappened: "Lungfish does not open this kind of file as a document.",
                nextStep: reason,
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Open \(fileName)",
            whatHappened: "Lungfish could not read the file as a document it can show.",
            nextStep: "Check that the file is complete and in a format Lungfish opens, then open it again.",
            underlying: error
        )
    }
}
