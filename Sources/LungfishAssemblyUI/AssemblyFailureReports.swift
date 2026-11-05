// AssemblyFailureReports.swift - Failure words for the assembly result view
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

/// The failure alerts the assembly result view shows, each as a `FailureReport` whose error text goes only to
/// the details area (ALERT-PRESENTER, Phase 3.1).
enum AssemblyFailureReports {
    static func copyContigFASTA(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Copy the contig FASTA",
            whatHappened: "Lungfish could not read the selected contigs from the assembly output, so nothing was copied.",
            nextStep: "Check that the assembly output is still in the project, then select the contigs and copy them again.",
            underlying: error
        )
    }

    static func blastContigs(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Send the selected contigs to BLAST",
            whatHappened: "Lungfish could not read the selected contigs from the assembly output, so nothing was sent to NCBI.",
            nextStep: "Check that the assembly output is still in the project, then select the contigs and run BLAST again.",
            underlying: error
        )
    }

    /// The contigs file changed after the result opened (ruling BIO-ASSEMBLY-REPLACED). The cause goes to the details.
    static func resultChangedOnDisk() -> FailureReport {
        FailureReport(
            failedStep: "Use the selected contigs",
            whatHappened: "The contigs file of this assembly changed on disk after it opened, so the contigs on screen are not the ones in the result. Nothing was sent to NCBI, copied or written.",
            nextStep: "Select another item in the sidebar, select this assembly again, and try again.",
            underlying: AssemblyContigsChangedOnDisk()
        )
    }

    static func selectedContigs(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Read the selected contigs",
            whatHappened: "Lungfish could not read all of the selected contigs from the assembly output, so the action did not run.",
            nextStep: "Check that the assembly output is still in the project, open the result again from the sidebar, then select the contigs and try again.",
            underlying: error
        )
    }

    /// The result's contigs could not be opened, so the table is empty (review of lane REPLACED, question 2).
    static func contigsNotOpened(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Open the assembly contigs",
            whatHappened: "Lungfish could not read the contigs file of this assembly, so the table is empty and no contig can be selected.",
            nextStep: "Check that the contigs file is still in the assembly folder and that every contig in it has its own name, then select another item in the sidebar and open this assembly again. The details say what could not be read.",
            underlying: error
        )
    }
}

/// The cause shown in the details when a contigs file holds bytes and no contig (W-30, ASM-7 case b). The catalog reads such a
/// file as an empty list and throws nothing, so the viewer raises this error to refuse it like a file that cannot be opened.
/// An empty file is not this error, since an assembler that found nothing writes one.
struct AssemblyContigsFileHoldsNoContig: LocalizedError {
    let fileName: String
    let byteCount: Int

    var errorDescription: String? {
        let size = byteCount == 1 ? "1 byte" : "\(byteCount) bytes"
        return "The contigs file \"\(fileName)\" holds \(size) but no contig. A contig starts with a line that begins with > and gives its name."
    }
}
