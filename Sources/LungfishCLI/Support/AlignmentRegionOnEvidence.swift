// AlignmentRegionOnEvidence.swift - Whether a region lies on the contigs of an alignment's header
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why a region is not on the alignment evidence, as the sentence a refusal prints.
struct AlignmentRegionRefusal: Error, Equatable, Sendable {
    let message: String
}

/// Whether a region lies on the alignment evidence, which `bam consensus` and `extract reads --index`
/// both ask of the alignment's header before samtools reads a base (Phase 2.10, review A51 F2). A
/// region on a contig the header does not name, or one that runs past the end of its contig, is
/// refused with a sentence that names the fix. samtools would not refuse the second case. It stops
/// the region at the end of the contig, so a run would publish the reads of a shorter region than the
/// one its record names. The viewer's coordinator refused both cases in the app before the alignment
/// actions ran on `lungfish-cli`.
enum AlignmentRegionOnEvidence {
    /// The length of the contig a region names, or why the region is not on the evidence. `start` and
    /// `end` are the 1-based inclusive positions the region names, nil for one it leaves open.
    static func contigLength(
        of contig: String,
        start: Int? = nil,
        end: Int?,
        inHeader header: String
    ) -> Result<Int, AlignmentRegionRefusal> {
        guard let length = contigLength(contig, inHeader: header) else {
            return .failure(.init(message: "The alignment has no contig named \(contig). Name one of its contigs in --region."))
        }
        if let end, end > length {
            return .failure(.init(message: "The region ends at \(end), past the end of \(contig) at \(length)."))
        }
        if let start, start > length {
            return .failure(.init(message: "The region starts at \(start), past the end of \(contig) at \(length)."))
        }
        return .success(length)
    }

    /// The length of the contig that the region text `region` names, or why the region is not on the
    /// evidence. The text is a region as samtools takes it.
    static func contigLength(ofRegion region: String, inHeader header: String) -> Result<Int, AlignmentRegionRefusal> {
        let parts = parts(of: region, inHeader: header)
        return contigLength(of: parts.contig, start: parts.start, end: parts.end, inHeader: header)
    }

    /// The contig, start and end of a region as samtools reads it. The forms are `contig`,
    /// `contig:start`, `contig:start-`, `contig:-end` and `contig:start-end`, 1-based and inclusive,
    /// with commas allowed in a number and braces around a contig name that holds a colon. A text that
    /// is a contig of the header whole is that contig, so `HLA-A*01:01` needs no braces. A text that
    /// reads as no range names a contig the header does not carry.
    static func parts(of region: String, inHeader header: String) -> (contig: String, start: Int?, end: Int?) {
        let whole = (contig: region, start: Int?.none, end: Int?.none)
        guard contigLength(region, inHeader: header) == nil, let colon = region.lastIndex(of: ":") else { return whole }
        var contig = String(region[..<colon])
        if contig.hasPrefix("{"), contig.hasSuffix("}") { contig = String(contig.dropFirst().dropLast()) }
        let bounds = region[region.index(after: colon)...]
            .replacingOccurrences(of: ",", with: "")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        // nil when the text is no number, .some(nil) when it is empty, a position that the range leaves open.
        func position(_ text: String) -> Int?? {
            if text.isEmpty { return .some(nil) }
            guard let number = Int(text) else { return nil }
            return .some(number)
        }
        switch bounds.count {
        case 1:
            guard let start = Int(bounds[0]) else { return whole }
            return (contig, start, nil)
        case 2:
            guard let start = position(bounds[0]), let end = position(bounds[1]), start != nil || end != nil else { return whole }
            return (contig, start, end)
        default:
            return whole
        }
    }

    /// The `LN` of the `@SQ` line named `contig` in a SAM header.
    static func contigLength(_ contig: String, inHeader header: String) -> Int? {
        for line in header.split(separator: "\n") where line.hasPrefix("@SQ") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.contains("SN:\(contig)"), let length = fields.first(where: { $0.hasPrefix("LN:") }) else { continue }
            return Int(length.dropFirst(3))
        }
        return nil
    }
}
