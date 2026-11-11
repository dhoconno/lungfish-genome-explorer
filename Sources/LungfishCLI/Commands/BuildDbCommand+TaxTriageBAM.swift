// BuildDbCommand+TaxTriageBAM.swift - The BAM that build-db taxtriage records for each sample of a result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved unchanged from BuildDbCommand.swift (Phase 4 close, lane BUILDDB-FIX), which had reached its 800-line
// limit, so the fix of row BUILDDB-BAM-FIT lands here. A sample whose own BAM is gone from a `minimap2/` folder that
// holds several samples took any file whose name held its id, such as `S1_2.S1_2.dwnld.references.bam` for S1, with
// no mark (`SCR rulings/WALK-BIO.md` 1.1). The BAMs of a result are now resolved once all of its samples are parsed,
// with the extract scan's fit, a file that fits a longer sample id of the same result is refused, and each fit is
// named in a build line and in the database metadata.

import Foundation
import LungfishIO
import LungfishWorkflow

extension BuildDbCommand.TaxTriageSubcommand {
    /// The BAM paths of every sample of one result folder, resolved once all of its samples are parsed, so a sample
    /// whose own BAM is gone never takes the file of another sample of the same result (BUILDDB-BAM-FIT).
    func resolveTaxTriageBAMPaths(
        samples: Set<String>,
        resultURL: URL
    ) -> [String: (bamPath: String?, bamIndexPath: String?)] {
        var resolved: [String: (bamPath: String?, bamIndexPath: String?)] = [:]
        for sample in samples {
            resolved[sample] = resolveTaxTriageBAMPaths(sample: sample, samples: samples, resultURL: resultURL)
        }
        return resolved
    }

    private func resolveTaxTriageBAMPaths(
        sample: String,
        samples: Set<String>,
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
            samples: samples,
            minimap2URL: minimap2URL
        ) else {
            return (nil, nil)
        }
        return relativeBAMPaths(for: candidate, resultURL: resultURL)
    }

    private func bestTaxTriageBAMCandidate(
        sample: String,
        samples: Set<String>,
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
            guard Self.taxTriageBAMNameFits(candidate.lastPathComponent, sample: sample, samples: samples) else {
                return nil
            }
            return (candidate, taxTriageBAMCandidateScore(filename: candidate.lastPathComponent, sample: sample))
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

    /// Whether the file name `name` fits `sample` by the extract scan's rule
    /// (``ClassifierReadResolver/taxTriageNameFits(_:sampleId:)``: case-sensitive, the id at the start followed by `.`,
    /// `_` or `-`, and the pipeline's `{X}.{X}.dwnld.references.bam` for sample X alone) and fits no longer sample id
    /// of the same result. A name that fits two ids, such as `S1_2.bam` for S1 and S1_2, belongs to the longer one, so
    /// S1 never takes S1_2's file and S1_2 keeps its own.
    static func taxTriageBAMNameFits(_ name: String, sample: String, samples: Set<String>) -> Bool {
        ClassifierReadResolver.taxTriageNameFits(name, sampleId: sample)
            && !samples.contains { $0.count > sample.count && ClassifierReadResolver.taxTriageNameFits(name, sampleId: $0) }
    }

    private func taxTriageBAMCandidateScore(filename: String, sample: String) -> Int {
        let name = filename.lowercased()
        let sample = sample.lowercased()

        if name == "\(sample).bam" { return 10 }
        if name.contains("downsample") || name.contains("minibam") { return 20 }
        if name.contains("dwnld.references") { return 30 }
        if name.contains("references") { return 40 }
        return 50
    }

    /// The samples of `rows` whose recorded BAM came from a fit of its name, a file that is neither `{S}.bam` nor
    /// `{S}.{S}.dwnld.references.bam`, the two names the pipeline gives a sample's own BAM, in byte order.
    static func taxTriageFittedBAMSamples(in rows: [TaxTriageTaxonomyRow]) -> [String] {
        var fitted = Set<String>()
        for row in rows {
            guard let bamPath = row.bamPath else { continue }
            let name = URL(fileURLWithPath: bamPath).lastPathComponent
            if name != "\(row.sample).bam", name != "\(row.sample).\(row.sample).dwnld.references.bam" {
                fitted.insert(row.sample)
            }
        }
        return fitted.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// One build line for each fitted sample of `rows`, naming the file that the database records for it.
    static func taxTriageFittedBAMLines(in rows: [TaxTriageTaxonomyRow]) -> [String] {
        taxTriageFittedBAMSamples(in: rows).compactMap { sample in
            guard let bamPath = rows.first(where: { $0.sample == sample })?.bamPath else { return nil }
            return "Sample \(sample)'s own BAM was not found, so Lungfish recorded \(bamPath), a file in the minimap2 "
                + "folder whose name fits it. If that file belongs to another sample, put \(sample)'s own BAM back, "
                + "delete taxtriage.sqlite and build the database again."
        }
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
