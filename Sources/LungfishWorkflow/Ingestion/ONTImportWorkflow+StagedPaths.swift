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
    /// vectors, its command, its files and its options.
    func remapOptimizationStep(
        _ step: ProvenanceStep,
        from stagedBundleURL: URL,
        to finalBundleURL: URL
    ) -> ProvenanceStep {
        let place = StagedBundlePlace(staged: stagedBundleURL, final: finalBundleURL)
        return step.with { copy in
            copy.argv = step.argv.map(place.relocating)
            copy.durableReplayArgv = step.durableReplayArgv?.map(place.relocating)
            copy.reproducibleCommand = place.relocating(step.reproducibleCommand)
            copy.inputs = step.inputs.map(place.relocating)
            copy.outputs = step.outputs.map(place.relocating)
            copy.resolvedOptions = step.resolvedOptions.mapValues { $0.rewritingPaths(place.relocating) }
        }
    }
}

/// The spellings of a staged bundle's folder that a tool step may name, and the published bundle's folder that
/// replaces them.
///
/// A step names its files the way the run spelled the staged bundle, and a tool may name them by their real path. So
/// the spelling given, the stable spelling and the real path (links resolved, `/private` kept) are each replaced, the
/// longest first, so `/private/var/x` goes whole before `/var/x` is looked for.
private struct StagedBundlePlace {
    let spellings: [String]
    let target: String

    init(staged: URL, final: URL) {
        let candidates: Set<String> = [
            staged.standardizedFileURL.path,
            ONTImportWorkflow.stableCanonicalURL(staged).path,
            CanonicalFilePath.path(for: staged),
        ]
        spellings = candidates
            .filter { !$0.isEmpty }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        target = ONTImportWorkflow.stableCanonicalURL(final).path
    }

    func relocating(_ text: String) -> String {
        spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: target) }
    }

    func relocating(_ descriptor: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: relocating(descriptor.path),
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath.map(relocating),
            sourceProvenancePath: descriptor.sourceProvenancePath.map(relocating)
        )
    }
}
