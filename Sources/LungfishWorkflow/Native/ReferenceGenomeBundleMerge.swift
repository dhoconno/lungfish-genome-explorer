// ReferenceGenomeBundleMerge.swift - Adds a built genome and its annotations to an existing bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Adds the genome and annotations of a built reference bundle to an existing `.lungfishref`
/// bundle, such as a variant-only bundle imported from a VCF with no reference, as the app's
/// `mergeGenomeIntoBundle` does (`MainSplitViewController+GenomicsDisplay.swift`). It serves
/// `lungfish-cli fetch genome --into-bundle` (Phase 2.10 lane A44, census g17).
///
/// The source's `genome/` folder replaces the target's, and its `annotations/` folder replaces the
/// target's, which is removed when the source has none. The target's manifest gains the genome and
/// the annotation tracks and keeps every other field (`BundleManifest.mergingGenomeAndAnnotations`).
/// Each folder is copied in under a hidden name first and swapped in only once every copy is
/// complete, and the manifest is written last (SWIFT 4), so a failure leaves the target's old
/// manifest in place.
public enum ReferenceGenomeBundleMerge {
    public static func merge(sourceBundleURL: URL, into targetBundleURL: URL) throws {
        let fileManager = FileManager.default
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)
        let targetManifest = try BundleManifest.load(from: targetBundleURL)
        let token = UUID().uuidString
        var incoming: [(staged: URL?, final: URL)] = []
        defer {
            for entry in incoming {
                if let staged = entry.staged { try? fileManager.removeItem(at: staged) }
            }
        }
        for folder in ["genome", "annotations"] {
            let source = sourceBundleURL.appendingPathComponent(folder, isDirectory: true)
            let final = targetBundleURL.appendingPathComponent(folder, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else {
                incoming.append((nil, final))
                continue
            }
            let staged = targetBundleURL.appendingPathComponent(".\(folder).incoming-\(token)", isDirectory: true)
            try fileManager.copyItem(at: source, to: staged)
            incoming.append((staged, final))
        }
        try Task.checkCancellation()
        for (index, entry) in incoming.enumerated() {
            if fileManager.fileExists(atPath: entry.final.path) {
                try fileManager.removeItem(at: entry.final)
            }
            if let staged = entry.staged {
                try fileManager.moveItem(at: staged, to: entry.final)
                incoming[index].staged = nil
            }
        }
        let merged = targetManifest.mergingGenomeAndAnnotations(from: sourceManifest, preferredName: sourceManifest.name)
        try merged.save(to: targetBundleURL)
    }
}
