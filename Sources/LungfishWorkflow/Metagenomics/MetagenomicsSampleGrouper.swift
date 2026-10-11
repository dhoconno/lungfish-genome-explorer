// MetagenomicsSampleGrouper.swift - Shared FASTQ sample grouping for the metagenomics wizards and the CLI
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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

/// Groups FASTQ URLs into per-sample inputs using common R1/R2 naming patterns.
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

        let candidates = inputFiles.map { url -> Candidate in
            let (sampleKey, role) = parseSampleKeyAndRole(from: url)
            return Candidate(url: url, sampleKey: sampleKey, role: role)
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
