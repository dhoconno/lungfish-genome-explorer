// AppDelegate+FailureReports.swift - Failure words for the app's imports and exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

extension AppDelegate {
    /// Shows a failure report as a sheet on the window `showAlert` uses, and
    /// shows nothing when no window is open, as `showAlert` does.
    internal func showFailure(_ report: FailureReport, presentingWindow: NSWindow? = nil) {
        if let window = presentingWindow ?? mainWindowController?.window ?? NSApp.keyWindow {
            FailurePresenter.present(report, in: window)
        }
    }
}

/// The failure alerts the app delegate's import and export paths show, each
/// as a `FailureReport` whose error text goes only to the details area
/// (ALERT-PRESENTER, Phase 3.1).
enum AppFailureReports {
    static func prepareReferenceSequencesFolder(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Prepare the Reference Sequences folder",
            whatHappened: "Lungfish could not make the project's Reference Sequences folder, so the import did not start.",
            nextStep: "Check that the project folder can be written to and that the disk has free space, then import the reference again.",
            underlying: error
        )
    }

    static func importReferenceSequence(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the reference sequence",
            whatHappened: "The reference bundle was not made.",
            nextStep: "Open the Operations panel to read the log of this import, check that the file is a complete sequence file, then import it again.",
            underlying: error
        )
    }

    static func prepareAnalysesFolder(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Prepare the Analyses folder",
            whatHappened: "Lungfish could not make the project's Analyses folder, so the import did not start.",
            nextStep: "Check that the project folder can be written to and that the disk has free space, then import the results again.",
            underlying: error
        )
    }

    static func showImportedAlignments(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Show the imported alignments",
            whatHappened: "The alignments were imported into the bundle, but the bundle could not be reloaded to show them.",
            nextStep: "Select the bundle in the sidebar again to reload it.",
            underlying: error
        )
    }

    static func importBAMFile(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the BAM file",
            whatHappened: "The alignments were not added to the bundle.",
            nextStep: "Open the Operations panel to read the log of this import, check that the reads were aligned to this bundle's reference, then import the file again.",
            underlying: error
        )
    }

    static func importAnnotationTrack(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the annotation track",
            whatHappened: "The annotations were not added to the bundle.",
            nextStep: "Open the Operations panel to read the log of this import, check that the file is a complete annotation file such as GFF3 or BED, then import it again.",
            underlying: error
        )
    }

    static func readBundleForVCFImport(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Read the bundle for the VCF import",
            whatHappened: "Lungfish could not read the bundle's manifest, so the VCF file was not imported.",
            nextStep: "Select the bundle in the sidebar again, then import the VCF file again.",
            underlying: error
        )
    }

    /// The staging of a sequence export failed before any row began. A cause the app words for the person, such as
    /// "No sequences found in selected files.", stays in the body (2.13 decision MD59, ALERT review R1).
    static func stageSequenceExport(_ error: any Error) -> FailureReport {
        let cause = error.localizedDescription
        if cause.hasPrefix("No sequences found in "), !cause.contains("\n") {
            return FailureReport(
                failedStep: "Export the sequences",
                whatHappened: cause,
                nextStep: "Choose files that hold sequences, then export again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Export the sequences",
            whatHappened: "Lungfish could not prepare the chosen sequences for export, so no file was written.",
            nextStep: "Check that each chosen file is still there and can be read and that the disk has free space, then export again.",
            underlying: error
        )
    }

    /// The export command failed behind an Operations row. Its two causes that name the person's own file stay
    /// in the body, and any other text of the command stays behind Show Details.
    static func exportSequences(_ error: any Error) -> FailureReport {
        let cause = error.localizedDescription
        let missingFile = "Input file not found: "
        if cause.hasPrefix("No sequences found in "), !cause.contains("\n") {
            return FailureReport(
                failedStep: "Export the sequences",
                whatHappened: cause,
                nextStep: "Choose files that hold sequences, then export again.",
                underlying: error
            )
        }
        if cause.hasPrefix(missingFile), !cause.contains("\n") {
            return FailureReport(
                failedStep: "Export the sequences",
                whatHappened: "Lungfish could not find the file \(cause.dropFirst(missingFile.count)).",
                nextStep: "Check that the file is still where it was, then export again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Export the sequences",
            whatHappened: "The export stopped before it wrote the file.",
            nextStep: "Open the Operations panel to read the log of this export, check that the chosen files are complete sequence files and that the folder you save to can be written to and has free space, then export again.",
            underlying: error
        )
    }

    static func showImportedVariants(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Show the imported variants",
            whatHappened: "The variants were imported into the bundle, but the bundle could not be reloaded to show them.",
            nextStep: "Select the bundle in the sidebar again to reload it.",
            underlying: error
        )
    }

    static func importVCFFile(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the VCF file",
            whatHappened: "The variants were not added to the bundle.",
            nextStep: "Open the Operations panel to read the log of this import, check that the file is a complete VCF file, then import it again.",
            underlying: error
        )
    }

    static func importGeneiousExport(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the Geneious export",
            whatHappened: "The Geneious export was not added to the project.",
            nextStep: "Open the Operations panel to read the log of this import, check that the file is a complete Geneious export, then import it again.",
            underlying: error
        )
    }

    static func runSequenceOperation(named name: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Run \(name)",
            whatHappened: "The operation stopped before it finished.",
            nextStep: "Open the Operations panel to read the log of this run, check the selected sequence, then run it again.",
            underlying: error
        )
    }

    static func readCzIdResult(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Read the CZ-ID result",
            whatHappened: "Lungfish could not read the file as a CZ-ID result, so the import did not start.",
            nextStep: "Check that the file is a complete CZ-ID result, then import it again.",
            underlying: error
        )
    }

    static func importCzIdResult(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the CZ-ID result",
            whatHappened: "The CZ-ID result was not added to the project.",
            nextStep: "Open the Operations panel to read the log of this import, check that the file is a complete CZ-ID result, then import it again.",
            underlying: error
        )
    }

    /// A refusal the sample sheet reader words about the person's own file, such as a missing column, stays in
    /// the body. Any other error is a file that could not be read (ALERT-C2, UX review P1).
    static func readFASTQSampleSheet(_ error: any Error) -> FailureReport {
        if error is FASTQSampleSheetError {
            return FailureReport(
                failedStep: "Read the FASTQ sample sheet",
                whatHappened: error.localizedDescription,
                nextStep: "Fix the sample sheet so each row has a sample, an r1 and an r2 value, then import it again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Read the FASTQ sample sheet",
            whatHappened: "Lungfish could not read the file as a FASTQ sample sheet, so the import did not start.",
            nextStep: "Check that the file can be read and is a table with sample, r1 and r2 columns, then import it again.",
            underlying: error
        )
    }

    static func importApplicationExport(named name: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Import the \(name) export",
            whatHappened: "The \(name) export was not added to the project.",
            nextStep: "Open the Operations panel to read the log of this import, check that the chosen file or folder is a complete \(name) export, then import it again.",
            underlying: error
        )
    }

    static func importNativeBundle(_ kind: CLINativeBundleImportRunner.BundleKind, _ error: any Error) -> FailureReport {
        let noun: String
        switch kind {
        case .msa: noun = "multiple sequence alignment"
        case .tree: noun = "phylogenetic tree"
        }
        return FailureReport(
            failedStep: "Import the \(noun)",
            whatHappened: "The \(noun) was not added to the project.",
            nextStep: "Open the Operations panel to read the log of this import, check that the file is a complete \(noun) file, then import it again.",
            underlying: error
        )
    }

    /// The sources of a sequence export could not be resolved before the destination sheet. The three refusals
    /// the resolver words about the person's selection keep their facts in the body, and any other error is
    /// worded in general terms.
    static func startSequenceExport(_ error: any Error) -> FailureReport {
        if let capture = error as? SequenceExportSourceResolver.CaptureError {
            switch capture {
            case .staleDocument(let name):
                return FailureReport(
                    failedStep: "Start the sequence export",
                    whatHappened: "The selected document \(name) is no longer open.",
                    nextStep: "Select it again, then export again.",
                    underlying: error
                )
            case .unavailableNativeDocument(let name):
                return FailureReport(
                    failedStep: "Start the sequence export",
                    whatHappened: "The selected project sequence \(name) is unavailable.",
                    nextStep: "Reopen the project, then export again.",
                    underlying: error
                )
            case .missingFileURL(let name):
                return FailureReport(
                    failedStep: "Start the sequence export",
                    whatHappened: "The selected source \(name) has no file location.",
                    nextStep: "Select a sequence that is stored in a file or in the project, then export again.",
                    underlying: error
                )
            }
        }
        return FailureReport(
            failedStep: "Start the sequence export",
            whatHappened: "Lungfish could not read the selected sequences, so no file was written.",
            nextStep: "Check that the project and the chosen files are still there and can be read, then export again.",
            underlying: error
        )
    }

    static func readAnnotationsForExport(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Read the annotations for export",
            whatHappened: "Lungfish could not read the annotations from the bundle, so no file was written.",
            nextStep: "Check that the bundle is still in the project and can be read, then export the annotations again.",
            underlying: error
        )
    }

    /// An annotation edit on a reference bundle runs behind an Operations row, and one catch covers the write and
    /// the reload that follows it. The words say the edit did not finish and how to check the bundle.
    static func addReferenceBundleAnnotation(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Add the annotation",
            whatHappened: "The annotation did not finish being added, so the bundle may not show it.",
            nextStep: "Open the Operations panel to read the log of this edit, select the bundle in the sidebar again to see whether the annotation is there, then add it again if it is not.",
            underlying: error
        )
    }

    static func reloadBundleAfterSequenceAnnotation(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Reload the bundle",
            whatHappened: "The operation finished, but the bundle could not be reloaded to show the result.",
            nextStep: "Select the bundle in the sidebar again to reload it.",
            underlying: error
        )
    }

    static func prepareProvenanceForExport(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Prepare the provenance for export",
            whatHappened: "Lungfish could not write the provenance record to its temporary folder, so the export did not start.",
            nextStep: "Check that the disk has free space, then export the provenance again.",
            underlying: error
        )
    }
}
