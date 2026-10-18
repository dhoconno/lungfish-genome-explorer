// MainSplitViewController+BundleOpenLoading.swift - One off-main decode per reference or mapping open
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow

/// What a mapping open reads from disk, decoded once and off the main actor,
/// then shared by every consumer of the open: the route, the Inspector, the
/// embedded viewer, the BAM metadata context and the mapping row refresh.
struct MappingAnalysisOpenPayload: Sendable {
    let result: MappingResult
    let provenance: MappingProvenance?
    /// `nil` when the viewer bundle cannot be read, which stays a valid
    /// legacy mapping route with no track-derived rows.
    let viewerBundleManifest: BundleManifest?
    let resultModificationDate: Date?
}

extension MainSplitViewController {
    /// Decodes a bundle manifest on a background thread. The manifest of a
    /// large reference is hundreds of megabytes and takes seconds to decode.
    nonisolated static func loadReferenceManifestOffMain(at url: URL) async -> Result<BundleManifest, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try BundleManifest.load(from: url) }
        }.value
    }

    /// Decodes a mapping result, its provenance and its viewer bundle's
    /// manifest on a background thread, each once.
    nonisolated static func loadMappingAnalysisOffMain(
        at url: URL
    ) async -> Result<MappingAnalysisOpenPayload, Error> {
        await Task.detached(priority: .userInitiated) {
            Result {
                // Read before the decode, so a rewrite during it makes the next compare unequal.
                let stamp = MappingResult.savedResultModificationDate(in: url)
                let result = try MappingResult.load(from: url)
                return MappingAnalysisOpenPayload(
                    result: result,
                    provenance: MappingProvenance.load(from: url),
                    viewerBundleManifest: result.viewerBundleURL.flatMap { try? BundleManifest.load(from: $0) },
                    resultModificationDate: stamp
                )
            }
        }.value
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
