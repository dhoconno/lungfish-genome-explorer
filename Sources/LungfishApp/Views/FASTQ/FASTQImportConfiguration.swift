// FASTQImportConfiguration.swift - Data model for FASTQ import settings
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// User-configured settings for FASTQ file import, captured by the import config sheet.
public struct FASTQImportConfiguration: Sendable {
    /// Input files for this sample. [R1] for single-end, [R1, R2] for paired-end.
    public let inputFiles: [URL]
    /// Platform auto-detected from the FASTQ header.
    public let detectedPlatform: SequencingPlatform
    /// Platform confirmed or overridden by the user.
    public let confirmedPlatform: SequencingPlatform
    /// Pairing mode selected by the user.
    public let pairingMode: FASTQIngestionConfig.PairingMode
    /// Quality score binning scheme.
    public let qualityBinning: QualityBinningScheme
    /// Whether to skip clumpify (k-mer sorting). Useful for low-memory machines.
    public let skipClumpify: Bool
    /// Whether to delete original files after successful ingestion.
    public let deleteOriginals: Bool
    /// Optional processing recipe to apply after ingestion.
    public let postImportRecipe: ProcessingRecipe?
    /// Filled placeholder values for the recipe, keyed by placeholder key.
    public let resolvedPlaceholders: [String: String]
}

/// A detected R1/R2 pair (or unpaired single file) from a batch of dropped FASTQ files.
public struct FASTQFilePair: Sendable {
    /// The R1 (forward) file, or the only file for single-end.
    public let r1: URL
    /// The R2 (reverse) file, if paired-end.
    public let r2: URL?

    /// Human-readable sample name derived from the filename.
    public var sampleName: String {
        var name = r1.deletingPathExtension().lastPathComponent
        // Strip .fastq from .fastq.gz
        if name.hasSuffix(".fastq") || name.hasSuffix(".fq") {
            name = (name as NSString).deletingPathExtension
        }
        // Strip read suffix to get the sample base name
        for suffix in ["_R1_001", "_R2_001", "_R1", "_R2", "_1", "_2", ".1", ".2"] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    /// Total file size in bytes across both files.
    public var totalSizeBytes: Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: r1.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }
        if let r2, let attrs = try? fm.attributesOfItem(atPath: r2.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }
        return total
    }

    /// Whether this represents paired-end data.
    public var isPaired: Bool { r2 != nil }
}

// MARK: - R1/R2 Pair Grouping

/// Groups an array of FASTQ file URLs into R1/R2 pairs.
///
/// Recognizes Illumina-style naming patterns:
/// - `_R1_001` / `_R2_001` (Illumina bcl2fastq/DRAGEN)
/// - `_R1` / `_R2` (common shorthand)
/// - `_1` / `_2` (SRA/ENA convention)
/// - `.1` / `.2` (rare but valid)
///
/// Unmatched files are returned as single-end pairs (r2 = nil).
public func groupFASTQByPairs(_ urls: [URL]) -> [FASTQFilePair] {
    // Read suffix patterns: (R1 suffix, R2 suffix) before extension
    let suffixPairs: [(r1: String, r2: String)] = [
        ("_R1_001", "_R2_001"),
        ("_R1", "_R2"),
        ("_1", "_2"),
    ]

    // Strip .gz then .fastq/.fq to get the stem
    func stem(of url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".gz") { name = String(name.dropLast(3)) }
        if name.hasSuffix(".fastq") { name = String(name.dropLast(6)) }
        else if name.hasSuffix(".fq") { name = String(name.dropLast(3)) }
        return name
    }

    var matched = Set<URL>()
    var pairs: [FASTQFilePair] = []

    // Build a lookup by stem for quick matching
    let stemMap = Dictionary(grouping: urls, by: { stem(of: $0) })

    for url in urls {
        guard !matched.contains(url) else { continue }
        let s = stem(of: url)

        var foundPair = false
        for (r1Suffix, r2Suffix) in suffixPairs {
            if s.hasSuffix(r1Suffix) {
                // This is an R1 — look for R2
                let r2Stem = String(s.dropLast(r1Suffix.count)) + r2Suffix
                if let r2Candidates = stemMap[r2Stem], let r2 = r2Candidates.first, !matched.contains(r2) {
                    pairs.append(FASTQFilePair(r1: url, r2: r2))
                    matched.insert(url)
                    matched.insert(r2)
                    foundPair = true
                    break
                }
            } else if s.hasSuffix(r2Suffix) {
                // This is an R2 — look for R1
                let r1Stem = String(s.dropLast(r2Suffix.count)) + r1Suffix
                if let r1Candidates = stemMap[r1Stem], let r1 = r1Candidates.first, !matched.contains(r1) {
                    pairs.append(FASTQFilePair(r1: r1, r2: url))
                    matched.insert(url)
                    matched.insert(r1)
                    foundPair = true
                    break
                }
            }
        }

        if !foundPair {
            pairs.append(FASTQFilePair(r1: url, r2: nil))
            matched.insert(url)
        }
    }

    return pairs.sorted { $0.r1.lastPathComponent < $1.r1.lastPathComponent }
}
