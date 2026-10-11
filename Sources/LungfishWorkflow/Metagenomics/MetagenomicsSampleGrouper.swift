// MetagenomicsSampleInput.swift - Shared FASTQ sample grouping utilities for metagenomics wizards
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A logical metagenomics sample inferred from one or two FASTQ files.
struct MetagenomicsSampleInput: Sendable, Equatable, Identifiable {
    let sampleId: String
    let fastq1: URL
    let fastq2: URL?

    var id: String { sampleId }
    var inputFiles: [URL] { [fastq1] + (fastq2.map { [$0] } ?? []) }
    var isPairedEnd: Bool { fastq2 != nil }
}

/// Groups FASTQ URLs into per-sample inputs using common R1/R2 naming patterns.
enum MetagenomicsSampleGrouper {
    private enum ReadRole {
        case read1
        case read2
        case single
    }

    static func group(_ inputFiles: [URL]) -> [MetagenomicsSampleInput] {
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

        for (sampleKey, entries) in grouped.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
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

        return samples.sorted {
            $0.sampleId.localizedCaseInsensitiveCompare($1.sampleId) == .orderedAscending
        }
    }

    static func sanitizeSampleId(_ raw: String) -> String {
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
        lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
    }
}
