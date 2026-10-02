// MatePairFileNaming.swift - The R1/R2 file-naming convention a mate pair is recognised by
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Recognises the R1 and R2 files of one mate pair by their names.
///
/// This is the convention the Map Reads window pairs resolved files by
/// (`MetagenomicsSampleGrouper` in LungfishApp, which the CLI cannot see):
/// two files are mates when their stems agree once a read-one marker
/// (`_R1_001`, `_R1`, `_1`, `.r1`, `-r1`) and the matching read-two marker
/// are removed. `lungfish-cli map` applies it to the files a bundle resolves
/// to, so a bundle maps the same reads, paired the same way, through the
/// window and through the recorded CLI command.
public enum MatePairFileNaming {
    public enum Role: Sendable, Equatable {
        case read1
        case read2
        case single
    }

    /// The two files of a mate pair as R1 and R2, when `files` holds exactly
    /// two files that name themselves as the mates of one sample.
    public static func matePair(in files: [URL]) -> (r1: URL, r2: URL)? {
        guard files.count == 2 else { return nil }
        let first = stemAndRole(of: files[0])
        let second = stemAndRole(of: files[1])
        guard first.stem == second.stem else { return nil }
        switch (first.role, second.role) {
        case (.read1, .read2):
            return (files[0], files[1])
        case (.read2, .read1):
            return (files[1], files[0])
        default:
            return nil
        }
    }

    /// The sample stem of a file name and the mate it names, by the markers
    /// above. `stem` is sanitized the way the window's sample IDs are, so two
    /// names compare the way the window compares them.
    public static func stemAndRole(of url: URL) -> (stem: String, role: Role) {
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".gz") {
            name = String(name.dropLast(3))
        }
        let lower = name.lowercased()
        let withoutExtension: String
        if lower.hasSuffix(".fastq") {
            withoutExtension = String(name.dropLast(6))
        } else if lower.hasSuffix(".fq") {
            withoutExtension = String(name.dropLast(3))
        } else {
            withoutExtension = url.deletingPathExtension().lastPathComponent
        }

        let markers: [(suffix: String, role: Role)] = [
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
        let lowerStem = withoutExtension.lowercased()
        for (suffix, role) in markers where lowerStem.hasSuffix(suffix) {
            let base = String(withoutExtension.dropLast(suffix.count))
            return (sanitizedStem(base), role)
        }
        return (sanitizedStem(withoutExtension), .single)
    }

    /// `MetagenomicsSampleGrouper.sanitizeSampleId`, so stems compare equal
    /// exactly when the window would group the files as one sample.
    static func sanitizedStem(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "sample" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return collapsed.isEmpty ? "sample" : collapsed
    }
}
