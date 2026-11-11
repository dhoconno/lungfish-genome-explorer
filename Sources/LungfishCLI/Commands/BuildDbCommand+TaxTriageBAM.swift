// BuildDbCommand+TaxTriageBAM.swift - The BAM that build-db taxtriage records for each sample of a result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved unchanged from BuildDbCommand.swift (Phase 4 close, lane BUILDDB-FIX), which had reached its 800-line
// limit, so the fix of row BUILDDB-BAM-FIT lands here.

import Foundation

extension BuildDbCommand.TaxTriageSubcommand {
    func resolveTaxTriageBAMPaths(
        sample: String,
        resultURL: URL
    ) -> (bamPath: String?, bamIndexPath: String?) {
        let bamRelative = "minimap2/\(sample).\(sample).dwnld.references.bam"
        let bamURL = resultURL.appendingPathComponent(bamRelative)
        if FileManager.default.fileExists(atPath: bamURL.path) {
            return relativeBAMPaths(for: bamURL, resultURL: resultURL)
        }

        let minimap2URL = resultURL.appendingPathComponent("minimap2", isDirectory: true)
        guard let candidate = bestTaxTriageBAMCandidate(
            sample: sample,
            minimap2URL: minimap2URL
        ) else {
            return (nil, nil)
        }
        return relativeBAMPaths(for: candidate, resultURL: resultURL)
    }

    private func bestTaxTriageBAMCandidate(
        sample: String,
        minimap2URL: URL
    ) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: minimap2URL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "bam",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
        guard !candidates.isEmpty else { return nil }

        let scored = candidates.compactMap { candidate -> (url: URL, score: Int)? in
            guard let score = taxTriageBAMCandidateScore(
                filename: candidate.lastPathComponent,
                sample: sample
            ) else {
                return nil
            }
            return (candidate, score)
        }
        let sorted = scored.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.url.path < $1.url.path
        }
        guard let best = sorted.first else { return nil }
        if sorted.dropFirst().contains(where: { $0.score == best.score }) {
            return nil
        }
        return best.url
    }

    private func taxTriageBAMCandidateScore(filename: String, sample: String) -> Int? {
        let name = filename.lowercased()
        let sample = sample.lowercased()
        guard filenameContainsSampleToken(name, sample: sample) else { return nil }

        if name == "\(sample).bam" { return 10 }
        if name.contains("downsample") || name.contains("minibam") { return 20 }
        if name.contains("dwnld.references") { return 30 }
        if name.contains("references") { return 40 }
        return 50
    }

    private func filenameContainsSampleToken(_ filename: String, sample: String) -> Bool {
        guard !sample.isEmpty else { return false }
        let delimiters = CharacterSet(charactersIn: "._-")
        if filename.hasPrefix(sample) {
            let remainder = filename.dropFirst(sample.count)
            if remainder.isEmpty { return true }
            if let first = remainder.unicodeScalars.first, delimiters.contains(first) {
                return true
            }
        }

        for left in [".", "_", "-"] {
            for right in [".", "_", "-"] {
                if filename.contains("\(left)\(sample)\(right)") {
                    return true
                }
            }
        }
        return false
    }

    private func relativeBAMPaths(
        for bamURL: URL,
        resultURL: URL
    ) -> (bamPath: String?, bamIndexPath: String?) {
        guard let bamRelative = relativePath(for: bamURL, root: resultURL) else {
            return (nil, nil)
        }

        let indexCandidates = [
            URL(fileURLWithPath: bamURL.path + ".bai"),
            URL(fileURLWithPath: bamURL.path + ".csi"),
            bamURL.deletingPathExtension().appendingPathExtension("bai"),
            bamURL.deletingPathExtension().appendingPathExtension("csi"),
        ]

        let indexRelative = indexCandidates
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { relativePath(for: $0, root: resultURL) }

        return (bamRelative, indexRelative)
    }

    private func relativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }
}
