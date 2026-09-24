// LungfishUIStrings.swift - Canonical row-action vocabulary shared across classifier viewers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Canonical labels for actions repeated (with drifting wording) across
/// Kraken2, EsViritu, TaxTriage, NAO-MGS and NVD row context menus (UX-07).
///
/// This does not yet drive a shared menu builder — each viewer still builds
/// its own `NSMenuItem`s — but it gives every viewer one place to read the
/// approved wording from, so new call sites and future consolidation start
/// from the same vocabulary instead of inventing another variant.
public enum LungfishUIStrings {
    public enum Classifier {
        /// "Extract Reads…" — the canonical context-menu verb for extracting
        /// the reads backing a row into a new FASTQ/extraction bundle.
        public static let extractReads = "Extract Reads\u{2026}"

        /// "Copy Taxon ID" — canonical label for copying a row's taxonomy
        /// identifier. Previously drifted between "Copy TaxID" (TaxTriage)
        /// and "Copy Taxon ID" (NAO-MGS).
        public static let copyTaxonID = "Copy Taxon ID"

        /// "Look Up on NCBI…" — canonical label for a menu item (flat, no
        /// submenu) that opens NCBI for the row's organism or accession.
        public static let lookUpOnNCBI = "Look Up on NCBI\u{2026}"
    }
}
