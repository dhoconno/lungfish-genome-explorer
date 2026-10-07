// FASTQBatchImporter+PairDetection.swift - Detection groups read files into samples by their names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {

    /// Groups a flat list of FASTQ URLs into R1/R2 pairs, each inside one folder (``FolderName``).
    ///
    /// Supported patterns (checked in priority order):
    /// - `_R1_001` / `_R2_001`  (Illumina bcl2fastq standard)
    /// - `_R1` / `_R2`           (simplified Illumina)
    /// - `_1` / `_2`             (older convention)
    ///
    /// Files that don't match any R1 pattern are treated as single-end samples,
    /// except an SRA run's reads without a mate (``joiningUnpairedReads(_:)``), a join by name
    /// that ``checkingUnpairedReads(_:)`` keeps only when the first reads bear it out.
    public static func detectPairs(from urls: [URL]) -> [SamplePair] {
        // Patterns ordered from most to least specific
        let r1Patterns: [(r1Suffix: String, r2Suffix: String)] = [
            ("_R1_001", "_R2_001"),
            ("_R1",     "_R2"),
            ("_1",      "_2"),
        ]

        // A stem→URL lookup for R2 matching, by folder, so a mate pairs only inside its own folder
        var stemToURL: [FolderName: URL] = [:]
        for url in urls {
            stemToURL[FolderName(of: url, fastqStem(url))] = url
        }

        var consumed: Set<URL> = []
        var pairs: [SamplePair] = []

        // Process each pattern in priority order
        for pattern in r1Patterns {
            for url in urls {
                guard !consumed.contains(url) else { continue }
                let stem = fastqStem(url)
                guard stem.hasSuffix(pattern.r1Suffix) else { continue }

                let baseStem = String(stem.dropLast(pattern.r1Suffix.count))
                let r2Stem = baseStem + pattern.r2Suffix

                if let r2URL = stemToURL[FolderName(of: url, r2Stem)], !consumed.contains(r2URL) {
                    pairs.append(SamplePair(sampleName: baseStem, r1: url, r2: r2URL))
                    consumed.insert(url)
                    consumed.insert(r2URL)
                }
                // If no R2 found yet, leave url for the single-end pass
            }
        }

        // Everything not consumed is single-end
        for url in urls where !consumed.contains(url) {
            let name = fastqStem(url)
            pairs.append(SamplePair(sampleName: name, r1: url, r2: nil))
        }

        return joiningUnpairedReads(pairs).sorted { $0.sampleName < $1.sampleName }
    }
}
