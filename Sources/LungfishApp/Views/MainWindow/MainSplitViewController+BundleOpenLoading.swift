// MainSplitViewController+BundleOpenLoading.swift - One off-main decode per reference or mapping open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// What a reference open reads from disk, built once and off the main actor: the
/// bundle's manifest and the bundle made from it, with its chromosome name index
/// and sequence reader already built. The embedded viewer shows this bundle, so it
/// decodes no manifest and builds no index on the main actor.
struct ReferenceBundleOpenPayload: Sendable {
    let manifest: BundleManifest
    let bundle: ReferenceBundle
}

/// What a mapping open reads from disk, decoded once and off the main actor,
/// then shared by every consumer of the open: the route, the Inspector, the
/// embedded viewer, the BAM metadata context and the mapping row refresh.
struct MappingAnalysisOpenPayload: Sendable {
    let result: MappingResult
    let provenance: MappingProvenance?
    /// The viewer bundle, made from its decoded manifest with its chromosome name
    /// index and sequence reader already built, as for a reference open. The
    /// embedded viewer shows it, so it builds neither on the main actor. `nil`
    /// when the viewer bundle cannot be read, which stays a valid legacy mapping
    /// route with no track-derived rows.
    let viewerBundle: ReferenceBundle?
    let resultModificationDate: Date?

    /// The manifest the viewer bundle was made from.
    var viewerBundleManifest: BundleManifest? { viewerBundle?.manifest }
}

extension MainSplitViewController {
    /// Decodes a bundle manifest on a background thread, then builds the bundle and
    /// its chromosome name index and sequence reader there. The manifest of a large
    /// reference is hundreds of megabytes and takes seconds to decode, and its
    /// indexes take a second more. A large one waits for ``BundleDecodeLane``, and
    /// the indexes are built in the same turn, so a 16 GB Mac holds one large open
    /// at a time.
    nonisolated static func loadReferenceBundleOffMain(
        at url: URL
    ) async -> Result<ReferenceBundleOpenPayload, Error> {
        await BundleDecodeLane.offMain {
            try await BundleDecodeLane.decode(reading: [url.appendingPathComponent(BundleManifest.filename)]) {
                let bundle = try decodeIndexedBundle(at: url, withBrowserSummary: true)
                return ReferenceBundleOpenPayload(manifest: bundle.manifest, bundle: bundle)
            }
        }
    }

    /// Decodes a mapping result, its provenance and its viewer bundle on a
    /// background thread, each once. The viewer bundle's manifest is decoded and
    /// its indexes built in the same turn, as for a reference open. A large
    /// result or manifest waits for ``BundleDecodeLane``.
    nonisolated static func loadMappingAnalysisOffMain(
        at url: URL
    ) async -> Result<MappingAnalysisOpenPayload, Error> {
        await BundleDecodeLane.offMain { () async throws -> MappingAnalysisOpenPayload in
            // Read before the decode, so a rewrite during it makes the next compare unequal.
            let stamp = MappingResult.savedResultModificationDate(in: url)
            let result = try await BundleDecodeLane.decode(reading: savedMappingResultFiles(in: url)) {
                try MappingResult.load(from: url)
            }
            let provenance = MappingProvenance.load(from: url)
            var viewerBundle: ReferenceBundle?
            if let viewerURL = result.viewerBundleURL {
                viewerBundle = try? await BundleDecodeLane.decode(
                    reading: [viewerURL.appendingPathComponent(BundleManifest.filename)]
                ) { try decodeIndexedBundle(at: viewerURL) }
            }
            return MappingAnalysisOpenPayload(
                result: result,
                provenance: provenance,
                viewerBundle: viewerBundle,
                resultModificationDate: stamp
            )
        }
    }

    /// Decodes the manifest of the bundle at `url` and makes the bundle from it, with
    /// its chromosome name index and sequence reader built. It runs inside a
    /// ``BundleDecodeLane`` turn, so a large reference's decode and index builds are
    /// one large open. With `withBrowserSummary`, a manifest that stores no browser summary gets the one synthesized
    /// from it, in memory and in the same turn, so the direct open's rows build none on the main actor and write
    /// no mirror (lane 12.37, PF10 note a). A mapping open shows no such rows and builds none.
    nonisolated private static func decodeIndexedBundle(
        at url: URL, withBrowserSummary: Bool = false
    ) throws -> ReferenceBundle {
        let decoded = try BundleManifest.load(from: url)
        // A cancelled open cannot stop its decode, but it can skip the summary and index builds, which would hold the lane for seconds more.
        try Task.checkCancellation()
        let manifest = withBrowserSummary ? decoded.withSynthesizedBrowserSummaryIfNeeded() : decoded
        let bundle = ReferenceBundle(url: url.standardizedFileURL, manifest: manifest)
        // A genome that cannot be read is reported by the first fetch, as before the indexes were built here.
        try? bundle.prepareSequenceAccess()
        return bundle
    }

    /// The saved result files of a mapping folder, in the order
    /// `MappingResult.load(from:)` reads them.
    nonisolated private static func savedMappingResultFiles(in directory: URL) -> [URL] {
        ["mapping-result.json", "alignment-result.json"].map { directory.appendingPathComponent($0) }
    }

    /// Shows the reference viewport's loading state while an open decodes its
    /// files, unless the viewer already shows that document. A document on
    /// screen keeps its live viewport, and the open's identity check decides
    /// whether anything changed.
    func showBundleOpenLoading(at url: URL, kind: ReferenceBundleViewportInput.Kind) {
        let target = url.standardizedFileURL
        guard !viewerShowsDocument(at: target, kind: kind) else { return }
        viewerController.displayReferenceBundleViewportLoading(
            title: kind == .directBundle
                ? target.deletingPathExtension().lastPathComponent
                : target.lastPathComponent,
            documentURL: target
        )
    }

    /// Whether the decoded files of the open of `url` may reach the panes: the
    /// viewer still shows that open's loading state, or the document it
    /// re-announces. Content shown since then by any route wins, including a
    /// route that starts no display request.
    func viewerAwaitsBundleOpen(at url: URL, kind: ReferenceBundleViewportInput.Kind) -> Bool {
        let target = url.standardizedFileURL
        if viewerController.contentMode == .mapping,
           viewerController.referenceBundleViewportController?.isAwaitingOpen(of: target) == true {
            return true
        }
        return viewerShowsDocument(at: target, kind: kind)
    }

    private func viewerShowsDocument(at target: URL, kind: ReferenceBundleViewportInput.Kind) -> Bool {
        guard viewerController.contentMode == .mapping,
              let input = viewerController.referenceBundleViewportController?.currentInput,
              input.kind == kind
        else { return false }
        return (kind == .directBundle ? input.renderedBundleURL : input.mappingResultDirectoryURL) == target
    }
}
