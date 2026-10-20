// SampleFolderNaming.swift - The folder name of each sample of a batch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageSerialBatchRunner {
    public static func sanitizedDirectoryName(for sampleID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = sampleID.unicodeScalars.map { scalar -> UnicodeScalar in
            allowed.contains(scalar) ? scalar : "_"
        }
        let candidate = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            return "sample"
        }
        return candidate
    }

    /// A sanitized directory name that no earlier sample in this batch took.
    ///
    /// Sanitization is lossy: "S 1" and "S_1" both collapse to "S_1". Without
    /// this the second sample writes into the first sample's directory and
    /// silently inherits its results, which attributes one sample's data to
    /// another. Every batch runner that lays out per-sample directories must
    /// use this, not `sanitizedDirectoryName` on its own.
    public static func uniqueDirectoryName(
        for sampleID: String,
        usedNames: inout Set<String>
    ) -> String {
        let base = sanitizedDirectoryName(for: sampleID)
        var candidate = base
        var suffix = 2
        while usedNames.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        usedNames.insert(candidate)
        return candidate
    }
}
