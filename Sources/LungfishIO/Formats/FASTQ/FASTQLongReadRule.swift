// FASTQLongReadRule.swift - Oxford Nanopore and PacBio reads are never paired, and the platform a FASTQ records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The long-read rule of the read-pairing contract (`docs/contracts/READ-PAIRING.md`). A FASTQ whose
/// recorded platform is Oxford Nanopore or PacBio is never paired, by file name or by content. Two records
/// with one id in such a file are a duplex parent and child, a split read or a repeated record, never the
/// two ends of one fragment.
///
/// The read set resolver of LungfishWorkflow and ``FASTQInputLayoutResolver`` both read the rule here, so
/// every consumer of a layout gives a long-read bundle the same answer (Phase 2.13 lane 13.42, BIO ruling).
public enum FASTQLongReadRule {

    /// Whether reads from `platform` are long reads, which are never paired.
    public static func isLongRead(_ platform: SequencingPlatform?) -> Bool {
        platform == .oxfordNanopore || platform == .pacbio
    }

    /// The sequencing platform a bundle records, from its primary file's
    /// sidecar, its own sidecar, or the bundle it derives from, nearest
    /// first. Given a FASTQ file, it reads that file's own sidecar.
    public static func recordedPlatform(of bundleURL: URL) -> SequencingPlatform? {
        for candidate in [bundleURL] + ancestors(of: bundleURL) {
            if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: candidate),
               let platform = FASTQMetadataStore.load(for: fastqURL)?.sequencingPlatform {
                return platform
            }
            if let platform = FASTQMetadataStore.load(for: candidate)?.sequencingPlatform {
                return platform
            }
        }
        return nil
    }

    /// The bundles a derivative derives from, nearest first, through each
    /// manifest's parent.
    public static func ancestors(of bundleURL: URL, limit: Int = 32) -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = [bundleURL.standardizedFileURL.path]
        var current = bundleURL.standardizedFileURL
        while result.count < limit, let manifest = FASTQBundle.loadDerivedManifest(in: current) {
            let parent = FASTQBundle.resolveBundle(relativePath: manifest.parentBundleRelativePath, from: current)
                .standardizedFileURL
            guard !seen.contains(parent.path), FASTQBundle.isBundleURL(parent),
                  FileManager.default.fileExists(atPath: parent.path) else { break }
            seen.insert(parent.path)
            result.append(parent)
            current = parent
        }
        return result
    }
}
