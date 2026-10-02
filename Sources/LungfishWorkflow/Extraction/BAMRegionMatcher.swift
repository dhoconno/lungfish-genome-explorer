// BAMRegionMatcher.swift — Multi-strategy BAM reference matching
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - BAMRegionMatcher

/// Matches caller-supplied genomic region strings against BAM `@SQ` reference
/// names using progressively fuzzier strategies.
///
/// Strategies are tried in order — the first that produces at least one match
/// wins:
///
/// 1. **Exact** — region string == BAM reference name verbatim, or samtools
///    region notation on such a name (`chr1:11-25`, `chr1:500-`, `chr1:-200`,
///    `chr1:500`, or the braced `{name}` and `{name}:range` for a name that
///    holds a colon). Notation passes to samtools as given, so samtools selects
///    the reads that overlap it.
/// 2. **Prefix** — a BAM reference name starts with the region string.
/// 3. **Contains** — a BAM reference name contains the region string as a
///    substring.
/// 4. **Fallback** — no strategy matched; all BAM references are returned so
///    the caller can still extract reads (with a warning).
///
/// If `bamRefs` is empty the `.noBAM` strategy is returned, indicating that
/// BAM extraction is unavailable for this dataset.
public enum BAMRegionMatcher {

    // MARK: - Public Interface

    /// Match requested regions against BAM reference names.
    ///
    /// - Parameters:
    ///   - regions: Genomic region strings to resolve (e.g. accession numbers,
    ///     chromosome names). Duplicates are collapsed before matching.
    ///   - bamRefs: Reference names parsed from the BAM `@SQ` header lines.
    /// - Returns: A ``RegionMatchResult`` describing which regions were resolved
    ///   and which strategy was used.
    public static func match(
        regions: [String],
        againstReferences bamRefs: [String]
    ) -> RegionMatchResult {
        guard !bamRefs.isEmpty else {
            return RegionMatchResult(
                matchedRegions: [],
                unmatchedRegions: Array(Set(regions)),
                strategy: .noBAM,
                bamReferenceNames: []
            )
        }

        // Deduplicate while preserving a stable order for reproducible results.
        let uniqueRegions = deduplicated(regions)
        let bamRefSet = Set(bamRefs)

        // Strategy 1: exact
        if let result = tryExact(uniqueRegions: uniqueRegions, bamRefs: bamRefs, bamRefSet: bamRefSet) {
            return result
        }

        // Strategy 2: prefix — a BAM ref name starts with the region string
        if let result = tryPrefix(uniqueRegions: uniqueRegions, bamRefs: bamRefs) {
            return result
        }

        // Strategy 3: contains — a BAM ref name contains the region string
        if let result = tryContains(uniqueRegions: uniqueRegions, bamRefs: bamRefs) {
            return result
        }

        // Strategy 4: fallback — return all BAM refs
        return RegionMatchResult(
            matchedRegions: bamRefs,
            unmatchedRegions: uniqueRegions,
            strategy: .fallbackAll,
            bamReferenceNames: bamRefs
        )
    }

    // MARK: - BAM Header Parsing

    /// Read `@SQ` reference names from a BAM header via `samtools view -H`.
    ///
    /// - Parameters:
    ///   - bamURL: URL of the sorted, indexed BAM file.
    ///   - runner: The ``NativeToolRunner`` actor to use for subprocess execution.
    /// - Returns: An array of reference sequence names in header order.
    /// - Throws: ``ExtractionError/samtoolsFailed(_:)`` if samtools exits
    ///   non-zero, or propagates any error thrown by ``NativeToolRunner``.
    public static func readBAMReferences(
        bamURL: URL,
        runner: NativeToolRunner
    ) async throws -> [String] {
        let result = try await runner.run(
            .samtools,
            arguments: ["view", "-H", bamURL.path]
        )

        guard result.isSuccess else {
            throw ExtractionError.samtoolsFailed(result.stderr)
        }

        // Parse @SQ lines: "@SQ\tSN:<name>\t..."
        var names: [String] = []
        for line in result.stdout.components(separatedBy: "\n") {
            guard line.hasPrefix("@SQ\t") else { continue }
            for field in line.components(separatedBy: "\t") {
                if field.hasPrefix("SN:") {
                    let name = String(field.dropFirst(3))
                    if !name.isEmpty {
                        names.append(name)
                    }
                    break
                }
            }
        }
        return names
    }

    // MARK: - Private Helpers

    private static func deduplicated(_ regions: [String]) -> [String] {
        var seen = Set<String>()
        return regions.filter { seen.insert($0).inserted }
    }

    private static func tryExact(
        uniqueRegions: [String],
        bamRefs: [String],
        bamRefSet: Set<String>
    ) -> RegionMatchResult? {
        let coordinateRegions = uniqueRegions.filter { isRegionNotation($0, onReferences: bamRefSet) }
        let matched = uniqueRegions.filter { bamRefSet.contains($0) || coordinateRegions.contains($0) }
        guard !matched.isEmpty else { return nil }
        let unmatched = uniqueRegions.filter { !matched.contains($0) }
        return RegionMatchResult(
            matchedRegions: matched,
            unmatchedRegions: unmatched,
            strategy: .exact,
            bamReferenceNames: bamRefs,
            coordinateRegions: coordinateRegions
        )
    }

    /// Whether `region` is samtools region notation on one of `references`,
    /// as htslib's region parser reads it: `NAME:BEG-END`, `NAME:BEG-`,
    /// `NAME:-END` or `NAME:BEG` with digits that may hold thousands commas,
    /// or `{NAME}` and `{NAME}:RANGE` for a name that holds a colon itself. A
    /// region that is itself a reference name is that whole reference, not
    /// notation. samtools still reports a range it cannot read.
    static func isRegionNotation(_ region: String, onReferences references: Set<String>) -> Bool {
        guard !references.contains(region) else { return false }
        if region.hasPrefix("{"), let close = region.lastIndex(of: "}") {
            let name = String(region[region.index(after: region.startIndex)..<close])
            let rest = region[region.index(after: close)...]
            guard references.contains(name) else { return false }
            return rest.isEmpty || (rest.first == ":" && isRange(rest.dropFirst()))
        }
        guard let colon = region.lastIndex(of: ":") else { return false }
        return references.contains(String(region[..<colon])) && isRange(region[region.index(after: colon)...])
    }

    private static func isRange(_ text: Substring) -> Bool {
        text.range(of: #"^([0-9][0-9,]*(-([0-9][0-9,]*)?)?|-[0-9][0-9,]*)$"#, options: .regularExpression) != nil
    }

    private static func tryPrefix(
        uniqueRegions: [String],
        bamRefs: [String]
    ) -> RegionMatchResult? {
        var matched: [String] = []
        var unmatched: [String] = []

        for region in uniqueRegions {
            let hits = bamRefs.filter { $0.hasPrefix(region) }
            if hits.isEmpty {
                unmatched.append(region)
            } else {
                matched.append(contentsOf: hits)
            }
        }

        guard !matched.isEmpty else { return nil }
        // Deduplicate matched BAM refs in case multiple regions hit the same ref.
        let deduped = deduplicated(matched)
        return RegionMatchResult(
            matchedRegions: deduped,
            unmatchedRegions: unmatched,
            strategy: .prefix,
            bamReferenceNames: bamRefs
        )
    }

    private static func tryContains(
        uniqueRegions: [String],
        bamRefs: [String]
    ) -> RegionMatchResult? {
        var matched: [String] = []
        var unmatched: [String] = []

        for region in uniqueRegions {
            let hits = bamRefs.filter { $0.contains(region) }
            if hits.isEmpty {
                unmatched.append(region)
            } else {
                matched.append(contentsOf: hits)
            }
        }

        guard !matched.isEmpty else { return nil }
        let deduped = deduplicated(matched)
        return RegionMatchResult(
            matchedRegions: deduped,
            unmatchedRegions: unmatched,
            strategy: .contains,
            bamReferenceNames: bamRefs
        )
    }
}
