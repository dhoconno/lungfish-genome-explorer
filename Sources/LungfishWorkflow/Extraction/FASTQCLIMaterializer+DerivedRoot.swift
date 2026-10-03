// FASTQCLIMaterializer+DerivedRoot.swift - A virtual derivative of a paired or mixed bundle reads that bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQCLIMaterializer {

    /// The root records a virtual derivative's recipe applies to, and the
    /// scratch folder to delete once the recipe has run.
    struct VirtualRootRead {
        let urls: [URL]
        /// The paired or mixed bundle the reads come from, when they come from one.
        let pairedOrMixedSource: URL?
        let scratchDirectory: URL?

        func cleanup() {
            if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        }
    }

    /// The root files of the virtual derivative at `bundleURL`.
    ///
    /// When its reads come from a deinterleaved or mixed bundle, its recorded
    /// root or, for a child written before lane A7, its nearest paired or
    /// mixed ancestor (``FASTQDerivedPayloadRoot/pairedOrMixedSource(of:recordedRoot:)``),
    /// that bundle is materialized into a scratch folder, its pairs
    /// interleaved, then its merged reads, then its single reads, and the
    /// recipe reads that one file. Those are the records, in that order, its
    /// read-ID list, trim table and orientation map were made from. Otherwise
    /// it is the recorded root's files (`FASTQBundle.rootSequenceURLs`), as
    /// before (D1, Phase 1.5 lane A7).
    func virtualRootRead(
        of bundleURL: URL,
        manifest: FASTQDerivedBundleManifest,
        recordedRoot rootBundleURL: URL,
        tempDirectory: URL
    ) async throws -> VirtualRootRead {
        guard let source = FASTQDerivedPayloadRoot.pairedOrMixedSource(of: bundleURL, recordedRoot: rootBundleURL) else {
            return VirtualRootRead(
                urls: try rootSequenceURLs(manifest.rootFASTQFilename, in: rootBundleURL),
                pairedOrMixedSource: nil,
                scratchDirectory: nil
            )
        }
        let scratch = tempDirectory.appendingPathComponent("derived-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let materialized = try await materialize(bundleURL: source, tempDirectory: scratch)
            return VirtualRootRead(urls: [materialized], pairedOrMixedSource: source, scratchDirectory: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }
}
