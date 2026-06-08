// GenotypeNotifications.swift — Notification.Name constants for the Genotype result viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public extension Notification.Name {
    /// Posted when the user picks a Summary view mode in the Inspector Document section
    /// for a `.lungfishgenotype` bundle. The `userInfo["mode"]` value is the rawValue of
    /// `GenotypeSummaryViewMode` (outline / matrix).
    static let genotypeResultViewModeChanged = Notification.Name("com.lungfish.genotypeResultViewModeChanged")

    /// Posted when the user wants to open the haplotype definition manager
    /// for a `.lungfishgenotype` bundle.
    static let genotypeResultOpenHaplotypeDefinitions = Notification.Name("com.lungfish.genotypeResultOpenHaplotypeDefinitions")

    /// Posted when the user selects a Smart Cohort in the Inspector Document section
    /// for a `.lungfishgenotype` bundle. `userInfo["cohort"]` is the
    /// `GenotypeCohortSmartFilter` JSON. The viewport applies the predicate to its
    /// cohort list. Posting with `userInfo[:]` clears the filter.
    static let genotypeResultSmartCohortApplied = Notification.Name("com.lungfish.genotypeResultSmartCohortApplied")

    /// Posted when the analyst saves the current genotype filter as a Smart Cohort.
    static let genotypeResultSmartCohortSaveRequested = Notification.Name("com.lungfish.genotypeResultSmartCohortSaveRequested")

    /// Posted when the analyst deletes a saved genotype Smart Cohort.
    /// `userInfo["cohort"]` is the `GenotypeCohortSmartFilter` JSON.
    static let genotypeResultSmartCohortDeleteRequested = Notification.Name("com.lungfish.genotypeResultSmartCohortDeleteRequested")

    /// Posted when the analyst requests applying Review viewport haplotype edits
    /// and the audit timeline to the bundle's `artifacts/workbooks/current.xlsx`.
    static let genotypeResultCurrentWorkbookUpdateRequested = Notification.Name("com.lungfish.genotypeResultCurrentWorkbookUpdateRequested")

    /// Posted when the analyst clicks "Edit calls…" in the Selected Item
    /// Inspector tab for a `.lungfishgenotype` bundle. The viewport reopens
    /// the Sample Detail sheet for the named sample. `userInfo["sample"]` is
    /// the animal ID.
    static let genotypeResultRequestSampleDetailSheet = Notification.Name("com.lungfish.genotypeResultRequestSampleDetailSheet")

    /// Posted when the analyst toggles "Show observed-only loci" in the
    /// Inspector Document section for a `.lungfishgenotype` bundle. The
    /// viewport reconfigures the Outline / Matrix to include or exclude loci
    /// not covered by the active haplotype definition set.
    /// `userInfo["showsAncillaryLoci"]` is a Bool.
    static let genotypeResultShowsAncillaryLociChanged = Notification.Name("com.lungfish.genotypeResultShowsAncillaryLociChanged")
}
