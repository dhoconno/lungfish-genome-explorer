// InspectorFailureReports.swift - Failure words for the Inspector's metadata, primer and bundle workflows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishKit

extension InspectorViewController {
    /// Shows a failure report as a sheet on `window`, and shows nothing when there is none, as the alert helpers it
    /// replaces did (ALERT-PRESENTER, Phase 3.1).
    func presentFailure(_ report: FailureReport, in window: NSWindow?) {
        guard let window else { return }
        FailurePresenter.present(report, in: window)
    }

    /// Shows a failure report on the window `presentSimpleAlert` uses, the Inspector's window or the key window.
    func presentFailure(_ report: FailureReport) {
        presentFailure(report, in: view.window ?? NSApp.keyWindow)
    }
}

/// The failure alerts the Inspector's workflows show, each as a `FailureReport` whose error text goes only to the
/// details area (ALERT-PRESENTER, Phase 3.1). A workflow that finished and then failed to reload the bundle says
/// that first.
enum InspectorFailureReports {
    static func importSampleMetadata(_ error: any Error) -> FailureReport {
        // Two rows for one sample is a refusal the app words, so it stays in the body (ALERT review SF1, P1).
        if let importError = error as? SampleMetadataBundleImportError,
           case .duplicateCanonicalIdentity = importError {
            return FailureReport(
                failedStep: "Import the sample metadata",
                whatHappened: error.localizedDescription,
                nextStep: "Keep one row for that sample in the metadata file, then import it again.",
                underlying: error
            )
        }
        return FailureReport(
            failedStep: "Import the sample metadata",
            whatHappened: "The sample metadata was not imported.",
            nextStep: "Check that the file is a complete table with a sample column and that the project folder can be written to, then import it again.",
            underlying: error
        )
    }

    static func saveSampleMetadata(sampleName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Save the metadata for \(sampleName)",
            whatHappened: "The edit was not saved in the bundle.",
            nextStep: "Check that the bundle folder can be written to, then make the edit again.",
            underlying: error
        )
    }

    static func loadPrimerScheme(_ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Load the primer scheme",
            whatHappened: "Lungfish could not read the folder as a primer scheme bundle.",
            nextStep: "Check that the folder holds a complete primer scheme bundle, then load it again.",
            underlying: error
        )
    }

    static func openDeduplicatedBundle(at path: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Open the new bundle",
            whatHappened: "The deduplicated bundle was created at \(path), but Lungfish could not open it.",
            nextStep: "Select the new bundle in the sidebar to open it.",
            underlying: error
        )
    }

    static func reloadBundleAfterDerivedAlignmentRemoval(inMappingViewer: Bool, _ error: any Error) -> FailureReport {
        reloadBundle(after: "The derived alignment was removed", inMappingViewer: inMappingViewer, error)
    }

    static func reloadBundleAfterMappedReadsAnnotation(trackName: String, inMappingViewer: Bool, _ error: any Error) -> FailureReport {
        reloadBundle(after: "The annotation track \"\(trackName)\" was created", inMappingViewer: inMappingViewer, error)
    }

    static func reloadBundleAfterFilteredAlignment(trackName: String, inMappingViewer: Bool, _ error: any Error) -> FailureReport {
        reloadBundle(after: "The filtered alignment track \"\(trackName)\" was created", inMappingViewer: inMappingViewer, error)
    }

    static func reloadBundleAfterPrimerTrim(_ error: any Error) -> FailureReport {
        reloadBundle(after: "The primer trim finished", inMappingViewer: false, error)
    }

    static func reloadBundleAfterDuplicateMarking(_ error: any Error) -> FailureReport {
        reloadBundle(after: "Duplicate marking finished", inMappingViewer: false, error)
    }

    /// `finished` is the workflow's own words, such as "GATK completed" or "Variant calling completed".
    static func reloadBundleAfterVariantCalling(finished: String, inMappingViewer: Bool, _ error: any Error) -> FailureReport {
        reloadBundle(after: finished, inMappingViewer: inMappingViewer, error)
    }

    private static func reloadBundle(after finished: String, inMappingViewer: Bool, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: inMappingViewer ? "Reload the mapping viewer" : "Reload the bundle",
            whatHappened: "\(finished), but the bundle could not be reloaded to show the result.",
            nextStep: "Select the bundle in the sidebar again to reload it.",
            underlying: error
        )
    }
}
