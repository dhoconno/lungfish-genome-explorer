// FASTQBatchImporter+PairDetection.swift - Detection pairs mates in one folder first, and across folders by unique names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {

    // MARK: - Pair Detection

    /// The samples detection made of a list of read files, and why it left
    /// a file of another folder unpaired.
    public struct PairDetection: Sendable {
        /// The samples, sorted by name.
        public let samples: [SamplePair]
        /// One notice for each R1 that a mate of another folder would have
        /// paired, and each pair that a run's file of another folder would
        /// have joined, but for a name another listed file has, in the order
        /// detection met them.
        public let notices: [PairingNotice]
    }

    /// Why detection did not pair a mate, or join a run's file of reads
    /// whose mate is missing, across folders. `import fastq` prints it. The
    /// Import FASTQ sheet runs the command once a sample, so the sample's
    /// row logs it instead.
    public struct PairingNotice: Sendable, Equatable {
        /// The sample the notice is about, by its name and its first file.
        public let sample: String
        public let r1: URL
        public let message: String

        /// The event `import fastq` prints the notice as.
        public var event: ImportLogEvent { .notice(sample: sample, message: message) }
    }

    /// Groups a flat list of FASTQ URLs into R1/R2 pairs (``detectingPairs(from:)``).
    public static func detectPairs(from urls: [URL]) -> [SamplePair] {
        detectingPairs(from: urls).samples
    }

    /// Groups a flat list of FASTQ URLs into R1/R2 pairs.
    ///
    /// Supported patterns (checked in priority order):
    /// - `_R1_001` / `_R2_001`  (Illumina bcl2fastq standard)
    /// - `_R1` / `_R2`           (simplified Illumina)
    /// - `_1` / `_2`             (older convention)
    ///
    /// A mate pairs with a file of its own folder first (``FolderName``), as
    /// `import fastq <folder> --recursive` groups them, so two folders that
    /// share names pair each folder's mates inside it (review B-S1). An R1
    /// with no mate in its folder pairs with a mate of another folder only
    /// when no other listed file has the R1's name or the mate's. Mates kept
    /// in `R1/` and `R2/` folders pair, as they did before B-S1, and a name
    /// two folders share never pairs across folders (re-review N1). A notice
    /// names the files a shared name kept apart.
    ///
    /// Files that don't match any R1 pattern are treated as single-end samples,
    /// except an SRA run's reads without a mate (``joiningUnpairedReads(_:)``), a join by name
    /// that ``checkingUnpairedReads(_:)`` keeps only when the first reads bear it out.
    public static func detectingPairs(from urls: [URL]) -> PairDetection {
        var consumed: Set<URL> = []
        var pairs = matesInsideFolders(of: urls, consumed: &consumed)
        let across = matesAcrossFolders(of: urls, consumed: &consumed)
        pairs += across.pairs

        // Everything not consumed is single-end
        for url in urls where !consumed.contains(url) {
            let name = fastqStem(url)
            pairs.append(SamplePair(sampleName: name, r1: url, r2: nil))
        }

        let joined = joiningUnpairedReads(pairs)
        return PairDetection(
            samples: joined.samples.sorted { $0.sampleName < $1.sampleName },
            notices: across.notices + joined.notices
        )
    }

    /// The mate patterns, from the most specific to the least.
    private static let matePatterns: [(r1Suffix: String, r2Suffix: String)] = [
        ("_R1_001", "_R2_001"),
        ("_R1", "_R2"),
        ("_1", "_2"),
    ]

    /// The sample an R1 of `pattern` names and the name of its mate, or nil
    /// for a file that is not such an R1.
    private static func mateNames(
        of url: URL,
        _ pattern: (r1Suffix: String, r2Suffix: String)
    ) -> (sample: String, mate: String)? {
        let stem = fastqStem(url)
        guard stem.hasSuffix(pattern.r1Suffix) else { return nil }
        let sample = String(stem.dropLast(pattern.r1Suffix.count))
        return (sample, sample + pattern.r2Suffix)
    }

    /// Pairs each R1 with the mate of its own folder.
    private static func matesInsideFolders(of urls: [URL], consumed: inout Set<URL>) -> [SamplePair] {
        // A stem→URL lookup for R2 matching, by folder, so a mate pairs inside its own folder first
        var stemToURL: [FolderName: URL] = [:]
        for url in urls {
            stemToURL[FolderName(of: url, fastqStem(url))] = url
        }
        var pairs: [SamplePair] = []
        // Process each pattern in priority order
        for pattern in matePatterns {
            for url in urls where !consumed.contains(url) {
                guard let names = mateNames(of: url, pattern) else { continue }
                if let r2URL = stemToURL[FolderName(of: url, names.mate)], !consumed.contains(r2URL) {
                    pairs.append(SamplePair(sampleName: names.sample, r1: url, r2: r2URL))
                    consumed.insert(url)
                    consumed.insert(r2URL)
                }
                // If no R2 found yet, leave url for the next pass
            }
        }
        return pairs
    }

    /// Pairs each R1 left without a mate in its folder with the mate of
    /// another folder, when no other listed file has the R1's name or the
    /// mate's. An R1 whose mates of other folders share a name with another
    /// listed file stays a sample of its own, and a notice names it and them.
    private static func matesAcrossFolders(
        of urls: [URL],
        consumed: inout Set<URL>
    ) -> (pairs: [SamplePair], notices: [PairingNotice]) {
        let listed = Dictionary(grouping: urls, by: fastqStem)
        var pairs: [SamplePair] = []
        var notices: [PairingNotice] = []
        for pattern in matePatterns {
            for url in urls where !consumed.contains(url) {
                guard let names = mateNames(of: url, pattern) else { continue }
                let folder = FolderName.folder(of: url)
                let mates = (listed[names.mate] ?? []).filter {
                    !consumed.contains($0) && FolderName.folder(of: $0) != folder
                }
                guard let mate = mates.first else { continue }
                guard listed[fastqStem(url)]?.count == 1, listed[names.mate]?.count == 1 else {
                    notices.append(PairingNotice(
                        sample: fastqStem(url), r1: url, message: notPairedAcrossFolders(url, with: mates)
                    ))
                    continue
                }
                pairs.append(SamplePair(sampleName: names.sample, r1: url, r2: mate))
                consumed.insert(url)
                consumed.insert(mate)
            }
        }
        return (pairs, notices)
    }

    /// Why `r1` stays a sample of its own, though `mates` of other folders
    /// are named as its mate.
    private static func notPairedAcrossFolders(_ r1: URL, with mates: [URL]) -> String {
        "\(pathForNotice(r1)) was not paired with \(pathsForNotice(mates, joinedBy: "or")), because mates pair "
            + "across folders only when their names are unique among the listed files."
    }

    /// A file as a notice about folders names it, by its whole path.
    static func pathForNotice(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Files as a notice about folders names them, `a`, `a and b` or `a, b and c`.
    static func pathsForNotice(_ urls: [URL], joinedBy conjunction: String) -> String {
        let paths = urls.map(pathForNotice)
        guard let last = paths.last else { return "" }
        guard paths.count > 1 else { return last }
        return paths.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }
}
