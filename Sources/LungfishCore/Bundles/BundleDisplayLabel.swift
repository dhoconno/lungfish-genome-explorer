// BundleDisplayLabel.swift - Shared display-string helper for reference bundle names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Produces the user-facing bundle-name-primary / contig-id-secondary display
// strings used by the mapping viewer's reference selector cells
// (`MappingContigTableView`, `ReferenceBundleRecordTable`) and reference track
// header (`TrackHeaderView`). The underlying FASTA contig id (accession) stays
// the functional identity everywhere else (coordinates, samtools regions,
// exports, `@RG`/BAM headers, selection keys, view-state persistence, copy/
// sort/filter column values, notifications, AI context, logging) — this type
// only decides what gets DISPLAYED.

/// Produces the two display forms used to show a reference bundle's
/// human-readable name alongside its underlying FASTA contig id.
public enum BundleDisplayLabel {

    /// The dimmed secondary line shown under a selector cell's primary
    /// (bundle name) line.
    ///
    /// Returns `nil` when the contig id already equals the bundle name (no
    /// secondary line needed — showing the same string twice adds no
    /// information and clutters the row). Otherwise returns the contig id,
    /// with the FASTA description appended in parentheses when present and
    /// non-empty.
    ///
    /// - Parameters:
    ///   - bundleName: The reference bundle's `manifest.name`.
    ///   - contigName: The underlying FASTA contig id (accession).
    ///   - fastaDescription: The FASTA defline description text, if any.
    public static func secondaryLine(
        bundleName: String,
        contigName: String,
        fastaDescription: String? = nil
    ) -> String? {
        guard contigName != bundleName else { return nil }
        if let fastaDescription, !fastaDescription.isEmpty {
            return "\(contigName) (\(fastaDescription))"
        }
        return contigName
    }

    /// The single-string label shown in the space-constrained reference
    /// track header.
    ///
    /// For a single-contig bundle, the bundle name alone is unambiguous and
    /// is returned as-is. For a multi-contig bundle, the contig identity
    /// (FASTA description when present and non-empty, else the contig id) is
    /// appended in parentheses — never an em dash, to avoid FASTA-defline
    /// dash ambiguity and per the project's no-em-dash prose rule.
    ///
    /// - Parameters:
    ///   - bundleName: The reference bundle's `manifest.name`.
    ///   - contigName: The underlying FASTA contig id (accession) currently displayed.
    ///   - fastaDescription: The FASTA defline description text for this contig, if any.
    ///   - isSingleContig: Whether the bundle contains exactly one contig.
    public static func trackHeaderLabel(
        bundleName: String,
        contigName: String,
        fastaDescription: String? = nil,
        isSingleContig: Bool
    ) -> String {
        guard !isSingleContig else { return bundleName }
        let detail: String
        if let fastaDescription, !fastaDescription.isEmpty {
            detail = fastaDescription
        } else {
            detail = contigName
        }
        return "\(bundleName) (\(detail))"
    }
}
