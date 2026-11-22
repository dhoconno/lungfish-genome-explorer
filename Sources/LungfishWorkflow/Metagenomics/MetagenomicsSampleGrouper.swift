// MetagenomicsSampleGrouper.swift - Shared FASTQ sample grouping for the metagenomics wizards and the CLI
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A logical metagenomics sample inferred from one or two FASTQ files.
public struct MetagenomicsSampleInput: Sendable, Equatable, Identifiable {
    public let sampleId: String
    public let fastq1: URL
    public let fastq2: URL?

    public init(sampleId: String, fastq1: URL, fastq2: URL?) {
        self.sampleId = sampleId
        self.fastq1 = fastq1
        self.fastq2 = fastq2
    }

    public var id: String { sampleId }
    public var inputFiles: [URL] { [fastq1] + (fastq2.map { [$0] } ?? []) }
    public var isPairedEnd: Bool { fastq2 != nil }
}

/// Groups FASTQ URLs into per-sample inputs. Each `.lungfishfastq` bundle is one sample under its whole stem, and
/// loose files of one folder pair by common R1/R2 naming patterns.
public enum MetagenomicsSampleGrouper {
    private enum ReadRole {
        case read1
        case read2
        case single
    }

    public static func group(_ inputFiles: [URL]) -> [MetagenomicsSampleInput] {
        struct Candidate {
            let url: URL
            let sampleKey: String
            let role: ReadRole
        }

        // A `.lungfishfastq` bundle, or a file inside one, is one sample named by the bundle's whole stem, as
        // `TaxTriageAnalysisRunTool.firstMatePair` reads bundles (BIO-TT-PAIR). Two bundles are never the two reads
        // of one sample, so only loose files pair by their mate endings. Several files of one bundle are that
        // bundle, once, as `AssemblyInputSamples` reads them.
        var candidates: [Candidate] = []
        var bundlePaths: [String] = []
        var bundleInputs: [String: (bundle: URL, inputs: [URL])] = [:]
        for url in inputFiles {
            guard let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: url) else {
                let (sampleKey, role) = parseSampleKeyAndRole(from: url)
                candidates.append(Candidate(url: url, sampleKey: sampleKey, role: role))
                continue
            }
            if bundleInputs[bundle.path] == nil {
                bundlePaths.append(bundle.path)
                bundleInputs[bundle.path] = (bundle, [])
            }
            bundleInputs[bundle.path]?.inputs.append(url)
        }
        for path in bundlePaths {
            guard let entry = bundleInputs[path] else { continue }
            candidates.append(
                Candidate(
                    url: entry.inputs.count == 1 ? entry.inputs[0] : entry.bundle,
                    sampleKey: sanitizeSampleId(entry.bundle.deletingPathExtension().lastPathComponent),
                    role: .single
                )
            )
        }

        let grouped = Dictionary(grouping: candidates, by: \.sampleKey)
        var samples: [MetagenomicsSampleInput] = []

        for (sampleKey, entries) in grouped.sorted(by: { isOrderedBefore($0.key, $1.key) }) {
            let read1 = entries
                .filter { $0.role == .read1 }
                .map(\.url)
                .sorted(by: compareURLs)
            let read2 = entries
                .filter { $0.role == .read2 }
                .map(\.url)
                .sorted(by: compareURLs)
            let singles = entries
                .filter { $0.role == .single }
                .map(\.url)
                .sorted(by: compareURLs)

            // A single beside mates of one stem, as loose `X.fastq` with `X_1.fastq` and `X_2.fastq` (what
            // `fasterq-dump --split-3` writes), or a bundle `X` with them. The mate branch below pairs the mates
            // under the name `X` and leaves the single out with no word. Such a group pairs nothing: each file is
            // its own sample under its whole stem, so none is lost, none is renamed and no two share a name
            // (BIO TT-GROUP F1).
            if !singles.isEmpty, !read1.isEmpty || !read2.isEmpty {
                for entry in entries.sorted(by: { compareURLs($0.url, $1.url) }) {
                    samples.append(
                        MetagenomicsSampleInput(
                            sampleId: entry.role == .single ? sampleKey : sanitizeSampleId(wholeStem(of: entry.url)),
                            fastq1: entry.url,
                            fastq2: nil
                        )
                    )
                }
                continue
            }

            // Explicit R1/R2 files pair by index within each folder (GROUPER-CROSS-FOLDER-PAIR). One R1 and one R2
            // in one folder are the typical sample. The samples of the stem number across folders as one list: one
            // sample keeps the stem, more take `_1`, `_2` and on.
            if !read1.isEmpty || !read2.isEmpty {
                let pairs = folderPairs(read1: read1, read2: read2)
                for (index, pair) in pairs.enumerated() {
                    let suffix = pairs.count == 1 ? "" : "_\(index + 1)"
                    samples.append(
                        MetagenomicsSampleInput(
                            sampleId: sanitizeSampleId(sampleKey + suffix),
                            fastq1: pair.fastq1,
                            fastq2: pair.fastq2
                        )
                    )
                }
                continue
            }

            // Single-end files: one sample per file.
            for (index, file) in singles.enumerated() {
                let suffix = singles.count == 1 ? "" : "_\(index + 1)"
                samples.append(
                    MetagenomicsSampleInput(
                        sampleId: sanitizeSampleId(sampleKey + suffix),
                        fastq1: file,
                        fastq2: nil
                    )
                )
            }
        }

        return samples.sorted { isOrderedBefore($0.sampleId, $1.sampleId) }
    }

    public static func sanitizeSampleId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "sample" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return collapsed.isEmpty ? "sample" : collapsed
    }

    /// The pairs of `.lungfishfastq` bundles among `inputFiles` whose whole stems differ only by a mate ending, such as
    /// `Swab_1` and `Swab_2`, each as its R1 stem and its R2 stem, in the grouper's order. Each bundle runs as its own
    /// sample, so the Classification and EsViritu dialogs say so in one line (BIO-TT-PAIR, question 1).
    public static func nearMateBundlePairs(in inputFiles: [URL]) -> [(read1: String, read2: String)] {
        var seen = Set<String>()
        var read1Stems: [String: [String]] = [:]
        var read2Stems: [String: [String]] = [:]
        for url in inputFiles {
            guard let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: url),
                  seen.insert(bundle.path).inserted else { continue }
            let stem = bundle.deletingPathExtension().lastPathComponent
            switch parseSampleKeyAndRole(from: bundle) {
            case let (key, .read1): read1Stems[key, default: []].append(stem)
            case let (key, .read2): read2Stems[key, default: []].append(stem)
            case (_, .single): continue
            }
        }
        var pairs: [(read1: String, read2: String)] = []
        for key in read1Stems.keys.sorted(by: { isOrderedBefore($0, $1) }) {
            let firsts = read1Stems[key, default: []].sorted { isOrderedBefore($0, $1) }
            let seconds = read2Stems[key, default: []].sorted { isOrderedBefore($0, $1) }
            pairs += zip(firsts, seconds).map { (read1: $0, read2: $1) }
        }
        return pairs
    }

    /// The dialogs' line for one pair of ``nearMateBundlePairs(in:)``, in the words decided as row P4 of
    /// `TT-PAIR-decided.md`. The Run button stays on.
    public static func nearMateBundleLine(read1: String, read2: String) -> String {
        "\(read1) and \(read2) run as two samples because each FASTQ bundle is one sample. "
            + "To run them as two reads of one sample, import both read files together as a pair."
    }

    /// The file name without `.gz` and `.fastq` or `.fq`, mate ending kept: `X_1` for `X_1.fastq.gz`.
    private static func wholeStem(of url: URL) -> String {
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".gz") {
            name = String(name.dropLast(3))
        }
        let lower = name.lowercased()
        if lower.hasSuffix(".fastq") {
            return String(name.dropLast(6))
        }
        if lower.hasSuffix(".fq") {
            return String(name.dropLast(3))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func parseSampleKeyAndRole(from url: URL) -> (String, ReadRole) {
        let withoutExt = wholeStem(of: url)

        let patterns: [(suffix: String, role: ReadRole)] = [
            ("_r1_001", .read1),
            ("_r2_001", .read2),
            ("_r1", .read1),
            ("_r2", .read2),
            ("_1", .read1),
            ("_2", .read2),
            (".r1", .read1),
            (".r2", .read2),
            ("-r1", .read1),
            ("-r2", .read2),
        ]

        let lowerStem = withoutExt.lowercased()
        for (suffix, role) in patterns {
            if lowerStem.hasSuffix(suffix) {
                let dropCount = suffix.count
                let base = String(withoutExt.dropLast(dropCount))
                return (sanitizeSampleId(base), role)
            }
        }

        return (sanitizeSampleId(withoutExt), .single)
    }

    private static func compareURLs(_ lhs: URL, _ rhs: URL) -> Bool {
        isOrderedBefore(lhs.lastPathComponent, rhs.lastPathComponent)
    }

    /// The R1 and R2 files of one stem, each role in file-name order, paired by index within each parent folder,
    /// folders in path order. A file with no mate at its index in its folder runs alone. Same-named files of two
    /// folders tie in the name sort and keep their input order, so pairing across folders joined two specimens
    /// whenever a list named the folders in one order for the R1 files and in another for the R2 files
    /// (GROUPER-CROSS-FOLDER-PAIR, BIO-REACH row A).
    private static func folderPairs(read1: [URL], read2: [URL]) -> [(fastq1: URL, fastq2: URL?)] {
        let folderPath: (URL) -> String = { $0.deletingLastPathComponent().standardizedFileURL.path }
        let read1ByFolder = Dictionary(grouping: read1, by: folderPath)
        let read2ByFolder = Dictionary(grouping: read2, by: folderPath)
        let folders = Set(read1ByFolder.keys).union(read2ByFolder.keys).sorted { isOrderedBefore($0, $1) }
        var pairs: [(fastq1: URL, fastq2: URL?)] = []
        for folder in folders {
            let firsts = read1ByFolder[folder, default: []]
            let seconds = read2ByFolder[folder, default: []]
            for index in 0..<max(firsts.count, seconds.count) {
                let r1AtIndex = firsts.indices.contains(index) ? firsts[index] : nil
                let r2AtIndex = seconds.indices.contains(index) ? seconds[index] : nil
                guard let r1 = r1AtIndex ?? r2AtIndex else { continue }
                pairs.append((fastq1: r1, fastq2: r1AtIndex != nil ? r2AtIndex : nil))
            }
        }
        return pairs
    }

    /// The locale that orders sample names and file names. It is fixed, so a batch lists its samples and
    /// numbers the files of one stem the same way in the app and in `lungfish-cli`, whatever language the
    /// process runs in.
    static let collationLocale = Locale(identifier: "en_US")

    /// Whether `lhs` sorts before `rhs` in the collation of `locale`, ignoring case. Names that differ only
    /// in case tie in that collation, so a tie falls to the Unicode scalars of the two names, which lists
    /// upper case first. That makes the order total. A tie left to the sorts would keep the iteration order
    /// of `Dictionary(grouping:)`, which changes with the hash seed of each process, and the app and
    /// `lungfish-cli` could then list `Sample` and `sample` in different orders.
    static func isOrderedBefore(_ lhs: String, _ rhs: String, locale: Locale = collationLocale) -> Bool {
        switch lhs.compare(rhs, options: [.caseInsensitive], range: nil, locale: locale) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
        }
    }
}
