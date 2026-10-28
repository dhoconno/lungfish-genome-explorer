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
}
