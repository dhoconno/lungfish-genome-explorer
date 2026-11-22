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
/// loose files pair by common R1/R2 naming patterns.
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

            // Typical case: one R1 + one R2.
            if read1.count == 1, read2.count == 1, singles.isEmpty {
                samples.append(
                    MetagenomicsSampleInput(
                        sampleId: sampleKey,
                        fastq1: read1[0],
                        fastq2: read2[0]
                    )
                )
                continue
            }

            // If there are explicit R1/R2 files, pair by index.
            if !read1.isEmpty || !read2.isEmpty {
                let pairCount = max(read1.count, read2.count)
                for index in 0..<pairCount {
                    let r1AtIndex = read1.indices.contains(index) ? read1[index] : nil
                    let r2AtIndex = read2.indices.contains(index) ? read2[index] : nil
                    guard let r1 = r1AtIndex ?? r2AtIndex else { continue }
                    let r2 = r1AtIndex != nil ? r2AtIndex : nil
                    let suffix = pairCount == 1 ? "" : "_\(index + 1)"
                    samples.append(
                        MetagenomicsSampleInput(
                            sampleId: sanitizeSampleId(sampleKey + suffix),
                            fastq1: r1,
                            fastq2: r2
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

    private static func parseSampleKeyAndRole(from url: URL) -> (String, ReadRole) {
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".gz") {
            name = String(name.dropLast(3))
        }
        let lower = name.lowercased()
        let withoutExt: String
        if lower.hasSuffix(".fastq") {
            withoutExt = String(name.dropLast(6))
        } else if lower.hasSuffix(".fq") {
            withoutExt = String(name.dropLast(3))
        } else {
            withoutExt = url.deletingPathExtension().lastPathComponent
        }

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
