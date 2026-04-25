// BAMPrimerTrimDialogState.swift - @Observable state model for the BAM primer-trim dialog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
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
    let projectSchemes: [PrimerSchemeBundle]

    var selectedSchemeID: String?
    var minReadLengthText: String = "30"
    var minQualityText: String = "20"
    var slidingWindowText: String = "4"
    var primerOffsetText: String = "0"

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
    }

    /// `true` when the operation is `.available`, a primer scheme is selected,
    /// and all four advanced-option text fields parse as non-negative integers.
    var isRunEnabled: Bool {
        guard availability == .available else { return false }
        guard selectedScheme != nil else { return false }
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
        guard let scheme = selectedScheme else { return "Select a primer scheme." }
        return "Ready to trim using \(scheme.manifest.displayName)."
    }

    private func parsedInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }
}
