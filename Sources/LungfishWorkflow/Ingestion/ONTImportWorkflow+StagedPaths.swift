// ONTImportWorkflow+StagedPaths.swift - The one spelling an ONT import keys its tool steps by, and their move to the bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension ONTImportWorkflow {
    /// The spelling the import keys each bundle's tool steps by and records its paths in. It is the same before a path
    /// exists, while it exists and after it is gone.
    ///
    /// `resolvingSymlinksInPath()` resolves a path only while the path exists, and drops `/private` only then. The
    /// import keys a staged bundle's steps while the bundle sits in the staging folder and looks them up after the
    /// publish has removed that folder. So an output spelled `/private/tmp/...` or reached through a link keyed the
    /// steps under one spelling and looked under another, and the bundle's record lost every tool step (lane
    /// C2-PROVPATH). This resolves the deepest folder that exists and appends the rest, so an existing path keeps the
    /// spelling `resolvingSymlinksInPath()` gives it.
    static func stableCanonicalURL(_ url: URL) -> URL {
        CrossProjectItemCopier.resolvedThroughExistingAncestor(url)
    }

    /// The tool steps of each staged bundle, keyed by its published bundle, with every path moved there.
    func remapOptimizationStepsByBundle(
        _ stepsByStagedBundle: [String: [ProvenanceStep]],
        from stagedBundleURLs: [URL],
        to finalBundleURLs: [URL]
    ) -> [String: [ProvenanceStep]] {
        var remapped: [String: [ProvenanceStep]] = [:]
        for (stagedBundleURL, finalBundleURL) in zip(stagedBundleURLs, finalBundleURLs) {
            let stagedKey = Self.stableCanonicalURL(stagedBundleURL).path
            let finalKey = Self.stableCanonicalURL(finalBundleURL).path
            remapped[finalKey] = (stepsByStagedBundle[stagedKey] ?? []).map {
                remapOptimizationStep($0, from: stagedBundleURL, to: finalBundleURL)
            }
        }
        return remapped
    }

    /// `step` with each spelling of the staged bundle's folder replaced by the published bundle's, in its argument
    /// vectors, its command, its files and its options. The published bundle is named by its stable spelling, the one
    /// the record holds its other paths in. ``StagedBundlePlace`` owns the spellings.
    func remapOptimizationStep(
        _ step: ProvenanceStep,
        from stagedBundleURL: URL,
        to finalBundleURL: URL
    ) -> ProvenanceStep {
        let place = StagedBundlePlace(staged: stagedBundleURL, final: Self.stableCanonicalURL(finalBundleURL))
        return step.with { copy in
            copy.argv = step.argv.map(place.relocating)
            copy.durableReplayArgv = step.durableReplayArgv?.map(place.relocating)
            copy.reproducibleCommand = place.relocating(step.reproducibleCommand)
            copy.inputs = step.inputs.map(place.relocating)
            copy.outputs = step.outputs.map(place.relocating)
            copy.resolvedOptions = place.relocating(step.resolvedOptions)
        }
    }
}
