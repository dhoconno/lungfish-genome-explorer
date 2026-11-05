// TaxTriageReadStaging.swift - The file names LGE hands the TaxTriage samplesheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Stages the read files of a TaxTriage run under names that Nextflow and the pipeline's own steps read back.
///
/// Nextflow writes the name of each staged file into the task script and escapes a shell character in it with a
/// backslash, so `Water_(blank).fastq.gz` reaches the script as `Water_\(blank\).fastq.gz`. The pipeline's COUNT_READS
/// step puts that text in double quotes, where the backslashes stay, so its file test looks for a file that does not
/// exist and the step exits 1 (walk row W-1, where the same reads ran under the name `Water`). The pipeline's
/// samplesheet schema also rejects a space anywhere in a read path.
///
/// A read file whose path holds a space, or whose name holds anything but ASCII letters, digits, `_`, `-` and `.`, is
/// linked into a folder of the run's own under a name made of those characters. A sample keeps the name the person gave
/// it, since the link changes the file name only, and a file that needs nothing stays where it is.
enum TaxTriageReadStaging {

    /// Whether `scalar` may appear in a staged file name.
    private static func isSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D, 0x2E:
            return true
        default:
            return false
        }
    }

    /// Whether `name` is a file name the pipeline reads as it stands. It holds only ASCII letters, digits, `_`, `-`
    /// and `.`, and it starts with none of `-` (a shell tool reads it as an option) or `.` (a hidden file).
    static func isSafeFileName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != "-", first != "." else { return false }
        return name.unicodeScalars.allSatisfy(isSafeScalar)
    }

    /// Whether the pipeline cannot read `url` where it is, for a space in its path or a name that is not plain.
    static func needsStaging(_ url: URL) -> Bool {
        url.path.contains(" ") || !isSafeFileName(url.lastPathComponent)
    }

    /// Whether any read file of `samples` needs staging.
    static func needsStaging(_ samples: [TaxTriageSample]) -> Bool {
        samples.contains { needsStaging($0.fastq1) || ($0.fastq2.map(needsStaging) ?? false) }
    }

    /// `name` with each run of other characters turned into one `_`, and a leading `-` or `.` into `_`, so
    /// `Water (blank).fastq.gz` becomes `Water_blank_.fastq.gz`.
    static func safeFileName(for name: String) -> String {
        var scalars = String.UnicodeScalarView()
        var inRun = false
        for scalar in name.unicodeScalars {
            if isSafeScalar(scalar) {
                scalars.append(scalar)
                inRun = false
            } else if !inRun {
                scalars.append("_")
                inRun = true
            }
        }
        var safe = String(scalars)
        if let first = safe.unicodeScalars.first, first == "-" || first == "." {
            safe = "_" + safe.dropFirst()
        }
        return safe.isEmpty ? "reads" : safe
    }

    /// `name`, or when `taken` holds it `name` with `_2`, `_3` and so on before its extension (the text from the first
    /// dot), so that no two staged files share a name. Names compare without case, since the volumes that hold a
    /// temporary folder ignore it. The name used goes into `taken`.
    static func uniqueFileName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        if taken.contains(candidate.lowercased()) {
            let dot = name.firstIndex(of: ".")
            let stem = dot.map { String(name[..<$0]) } ?? name
            let ending = dot.map { String(name[$0...]) } ?? ""
            var counter = 2
            repeat {
                candidate = "\(stem)_\(counter)\(ending)"
                counter += 1
            } while taken.contains(candidate.lowercased())
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Links each read file of `samples` that needs staging into `directory` under a safe, unique name and returns the
    /// samples with the links in place of those files. Every other field of a sample stays as it was.
    static func stage(_ samples: [TaxTriageSample], in directory: URL) throws -> [TaxTriageSample] {
        var taken = Set<String>()
        func stagedURL(of file: URL) throws -> URL {
            guard needsStaging(file) else { return file }
            let name = uniqueFileName(safeFileName(for: file.lastPathComponent), taken: &taken)
            let stagedFile = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: stagedFile, withDestinationURL: file)
            return stagedFile
        }
        return try samples.map { sample in
            var staged = sample
            staged.fastq1 = try stagedURL(of: sample.fastq1)
            staged.fastq2 = try sample.fastq2.map(stagedURL(of:))
            return staged
        }
    }
}
