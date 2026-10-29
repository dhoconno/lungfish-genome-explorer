// AppDelegate+FailureReports.swift - Failure words for the app's imports and exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

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
}
