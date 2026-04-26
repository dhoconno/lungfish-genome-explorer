// BAMPrimerTrimDialogState.swift - @Observable state model for the BAM primer-trim dialog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// `@Observable` state backing the BAM primer-trim dialog.
///
/// Holds the source `ReferenceBundle`, the operation's
/// `DatasetOperationAvailability` (typically derived from
/// ``BAMPrimerTrimCatalog``), the available built-in and project-local primer
/// scheme bundles, and transient UI state for the four iVar-compatible
/// advanced-option text fields. View bindings consume the derived
/// ``isRunEnabled`` and ``readinessText`` properties.
@MainActor
@Observable
final class BAMPrimerTrimDialogState {
    let bundle: ReferenceBundle
    let availability: DatasetOperationAvailability
    let builtInSchemes: [PrimerSchemeBundle]
    private(set) var projectSchemes: [PrimerSchemeBundle]

    var selectedSchemeID: String?
    var minReadLengthText: String = "30"
    var minQualityText: String = "20"
    var slidingWindowText: String = "4"
    var primerOffsetText: String = "0"

    /// Alignment track ID (from the bundle's manifest) the operation will trim.
    /// Auto-populated with the first eligible alignment track at init time;
    /// future UI work can let the user override this when bundles have
    /// multiple eligible BAMs. Nil only when the bundle has no eligible tracks
    /// (in which case `isRunEnabled` is already false).
    var alignmentTrackID: String?

    /// Display name for the new primer-trimmed alignment track. Auto-populated
    /// from the source track + selected scheme but exposed as a `var` so
    /// future UI work (or a power user) can override.
    var outputTrackName: String = ""

    private(set) var pendingRequest: BAMPrimerTrimRequest?

    init(
        bundle: ReferenceBundle,
        availability: DatasetOperationAvailability,
        builtInSchemes: [PrimerSchemeBundle],
        projectSchemes: [PrimerSchemeBundle]
    ) {
        self.bundle = bundle
        self.availability = availability
        self.builtInSchemes = builtInSchemes
        self.projectSchemes = projectSchemes

        let eligible = BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
        self.alignmentTrackID = eligible.first?.id
        // Note: `selectedSchemeID` is nil at init, so refreshing the default
        // output track name now would no-op. The helper fires when the user
        // picks a scheme via `selectScheme(id:)`.
    }

    // MARK: - Derived State

    var allSchemes: [PrimerSchemeBundle] {
        builtInSchemes + projectSchemes
    }

    var selectedScheme: PrimerSchemeBundle? {
        allSchemes.first { $0.manifest.name == selectedSchemeID }
    }

    func selectScheme(id: String) {
        guard allSchemes.contains(where: { $0.manifest.name == id }) else { return }
        selectedSchemeID = id
        refreshDefaultOutputTrackNameIfEmpty()
    }

    func addProjectSchemeAndSelect(_ scheme: PrimerSchemeBundle) {
        if let existingIndex = projectSchemes.firstIndex(where: { $0.manifest.name == scheme.manifest.name }) {
            projectSchemes[existingIndex] = scheme
        } else {
            projectSchemes.append(scheme)
            projectSchemes.sort { $0.manifest.displayName.localizedStandardCompare($1.manifest.displayName) == .orderedAscending }
        }
        outputTrackName = ""
        selectScheme(id: scheme.manifest.name)
    }

    /// Synthesizes the default output track name from the source track name
    /// and the selected scheme. Idempotent: callers can invoke this whenever
    /// the source track or scheme selection changes; will not overwrite a
    /// non-empty name the user has typed.
    func refreshDefaultOutputTrackNameIfEmpty() {
        guard outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let trackID = alignmentTrackID,
              let track = bundle.alignmentTrack(id: trackID),
              let scheme = selectedScheme else {
            return
        }
        outputTrackName = "\(track.name) • Primer-trimmed (\(scheme.manifest.displayName))"
    }

    /// `true` when the operation is `.available`, a primer scheme is selected,
    /// and all four advanced-option text fields parse as non-negative integers.
    var isRunEnabled: Bool {
        guard availability == .available else { return false }
        guard selectedScheme != nil else { return false }
        guard alignmentTrackID != nil else { return false }
        guard !outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard parsedInt(minReadLengthText) != nil else { return false }
        guard parsedInt(minQualityText) != nil else { return false }
        guard parsedInt(slidingWindowText) != nil else { return false }
        guard parsedInt(primerOffsetText) != nil else { return false }
        return true
    }

    /// Human-readable readiness summary surfaced near the Run button.
    /// Mirrors the wording of `BAMVariantCallingDialogState.readinessText`:
    /// reports the disabled reason first, then prompts for a scheme, and
    /// finally announces ready-to-run with the selected scheme's display name.
    var readinessText: String {
        if case .disabled(let reason) = availability { return reason }
        guard alignmentTrackID != nil else {
            return "This bundle has no analysis-ready BAM alignment tracks to primer-trim."
        }
        guard let scheme = selectedScheme else { return "Select a primer scheme." }
        guard !outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a name for the primer-trimmed alignment track."
        }
        return "Ready to trim using \(scheme.manifest.displayName)."
    }

    private func parsedInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    // MARK: - Run Preparation

    /// Validates the form and populates ``pendingRequest`` from the current state.
    /// Called by the dialog's Run button before invoking the run handler; mirrors
    /// ``BAMVariantCallingDialogState/prepareForRun()`` in intent but returns the
    /// assembled request so callers can inspect it directly.
    ///
    /// Returns `nil` (and leaves ``pendingRequest`` unchanged) if validation
    /// fails. The launcher (`InspectorViewController.launchPrimerTrimOperation`)
    /// translates the validated parameters into a `lungfish-cli bam primer-trim`
    /// argv via `CLIPrimerTrimRunner.buildCLIArguments(...)`; the BAM output
    /// path is owned by the CLI subcommand, not by this state.
    @discardableResult
    func prepareForRun() -> BAMPrimerTrimRequest? {
        guard let scheme = selectedScheme else { return nil }
        guard let trackID = alignmentTrackID,
              let track = bundle.alignmentTrack(id: trackID) else { return nil }
        guard !outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let minReadLength = parsedInt(minReadLengthText),
              let minQuality = parsedInt(minQualityText),
              let slidingWindow = parsedInt(slidingWindowText),
              let primerOffset = parsedInt(primerOffsetText) else {
            return nil
        }

        // The CLI subcommand owns the actual output BAM placement. The
        // `BAMPrimerTrimRequest` we build here is informational only — it
        // captures the validated parameters for the launcher to translate
        // into CLI args. The launcher reads `state.alignmentTrackID`,
        // `state.outputTrackName`, and the iVar parameters directly. The
        // request type still requires an `outputBAMURL`, so we set it to the
        // source URL purely to satisfy the initializer; nothing reads it.
        let sourceBAMURL = bundle.url.appendingPathComponent(track.sourcePath)
        let request = BAMPrimerTrimRequest(
            sourceBAMURL: sourceBAMURL,
            primerSchemeBundle: scheme,
            outputBAMURL: sourceBAMURL,
            minReadLength: minReadLength,
            minQuality: minQuality,
            slidingWindow: slidingWindow,
            primerOffset: primerOffset
        )
        pendingRequest = request
        return request
    }
}
