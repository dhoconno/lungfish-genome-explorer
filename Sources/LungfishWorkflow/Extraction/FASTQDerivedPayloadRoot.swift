// FASTQDerivedPayloadRoot.swift - Which bundle a virtual derivative's reads come from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Which bundle the reads of a virtual derivative (a subset, trim,
/// orientation map or demultiplexed reads) come from.
///
/// A deinterleaved bundle (`fullPaired`) and a PE merge or repair bundle
/// (`fullMixed`) hold reads as files of their own. Their manifests keep the
/// raw import as their root, and a virtual child of one used to take that
/// root as its own. The child's read-ID list names merged fragments, which the
/// raw import holds as two mates, so the child materialized raw mates instead
/// of the merged or repaired reads (D1, Phase 1.5 lane A7). A child of a
/// physical derivative now roots at that derivative, and a child written
/// before reads from its nearest paired or mixed ancestor.
public enum FASTQDerivedPayloadRoot {

    /// Whether `bundleURL` is a derived bundle whose payload is paired or
    /// mixed read files.
    public static func holdsPairedOrMixedPayload(_ bundleURL: URL) -> Bool {
        switch FASTQBundle.loadDerivedManifest(in: bundleURL)?.payload {
        case .fullPaired, .fullMixed: return true
        default: return false
        }
    }

    /// The root a new virtual child of `sourceBundleURL` records, the bundle
    /// and the file `rootFASTQFilename` names.
    ///
    /// A derived source that holds its reads as files (`full`, `fullFASTA`,
    /// `fullPaired`, `fullMixed`) is the root itself, with its first payload
    /// file recorded. A virtual source passes on its own root. Nil for a
    /// source with no derived manifest, whose caller keeps its own rule.
    public static func childRoot(
        ofSource sourceBundleURL: URL,
        manifest: FASTQDerivedBundleManifest?
    ) -> (bundleURL: URL, rootFASTQFilename: String)? {
        guard let manifest else { return nil }
        switch manifest.payload {
        case .full(let filename), .fullFASTA(let filename):
            return (sourceBundleURL, filename)
        case .fullPaired(let r1Filename, _):
            return (sourceBundleURL, r1Filename)
        case .fullMixed(let classification):
            let order: [ReadClassification.FileRole] = [.pairedR1, .merged, .unpaired, .pairedR2]
            let first = order.lazy.compactMap { role in
                classification.files.first { $0.role == role }?.filename
            }.first
            return (sourceBundleURL, first ?? manifest.rootFASTQFilename)
        case .subset, .trim, .demuxedVirtual, .orientMap, .demuxGroup:
            return (
                FASTQBundle.resolveBundle(relativePath: manifest.rootBundleRelativePath, from: sourceBundleURL),
                manifest.rootFASTQFilename
            )
        }
    }

    /// The paired or mixed bundle the reads of `bundleURL` come from, or nil
    /// when they come from the recorded root `rootBundleURL` as recorded.
    ///
    /// The walk starts at `bundleURL` itself, then follows parent links
    /// through virtual derivatives. It stops at the first bundle that holds
    /// its reads as files: a paired or mixed one is the answer, and a plain
    /// root, a `full` or `fullFASTA` derivative, or the recorded root ends
    /// the walk with nil. A broken parent link also ends it with nil, the
    /// recorded root, as before.
    public static func pairedOrMixedSource(
        of bundleURL: URL,
        recordedRoot rootBundleURL: URL
    ) -> URL? {
        let rootPath = rootBundleURL.standardizedFileURL.path
        var current = bundleURL.standardizedFileURL
        var visited: Set<String> = []
        while visited.insert(current.path).inserted, visited.count <= 64 {
            if holdsPairedOrMixedPayload(current) { return current }
            if current.path == rootPath { return nil }
            guard let manifest = FASTQBundle.loadDerivedManifest(in: current) else { return nil }
            switch manifest.payload {
            case .subset, .trim, .demuxedVirtual, .orientMap:
                let parent = FASTQBundle.resolveBundle(
                    relativePath: manifest.parentBundleRelativePath,
                    from: current
                ).standardizedFileURL
                guard FASTQBundle.isBundleURL(parent) else { return nil }
                current = parent
            case .full, .fullFASTA, .fullPaired, .fullMixed, .demuxGroup:
                return nil
            }
        }
        return nil
    }
}
