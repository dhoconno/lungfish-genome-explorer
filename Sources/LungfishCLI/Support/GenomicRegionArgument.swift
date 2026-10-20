// GenomicRegionArgument.swift - The region argument that bam consensus and bundle export-graphic share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

enum GenomicRegionArgument {
    /// `contig:start-end`, 1-based and inclusive, as zero-based half-open bounds. The last colon
    /// ends the contig, so a contig name may hold one.
    static func parseRegion(_ text: String) -> (contig: String, start: Int, end: Int)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let contig = String(text[..<colon])
        let bounds = text[text.index(after: colon)...]
            .replacingOccurrences(of: ",", with: "")
            .split(separator: "-", omittingEmptySubsequences: false)
        guard !contig.isEmpty, bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]),
              first >= 1, last >= first else { return nil }
        return (contig, first - 1, last)
    }
}
