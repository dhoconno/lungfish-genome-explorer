// AppDelegate+ReferenceBundleResolution.swift - Which reference bundle the menu actions act on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension AppDelegate {
    /// Order of preference: what the viewer actually displays (either display
    /// route, then a mapping result's reference copy), then a single sidebar
    /// candidate. Several sidebar candidates are ambiguous and resolve to `nil`.
    /// The candidates are read only when the viewer displays no bundle.
    static func resolveReferenceBundleURL(
        currentReferenceBundleURL: URL?,
        currentBundleURL: URL?,
        referenceViewportRenderedBundleURL: URL?,
        mappingResultRenderedBundleURL: URL?,
        selectedBundleURLs: @autoclosure () -> [URL] = []
    ) -> URL? {
        let displayed = currentReferenceBundleURL
            ?? currentBundleURL
            ?? referenceViewportRenderedBundleURL
            ?? mappingResultRenderedBundleURL
        if let displayed, displayed.pathExtension.lowercased() == "lungfishref" {
            return displayed
        }
        var unique: [URL] = []
        for url in selectedBundleURLs().map(\.standardizedFileURL) where !unique.contains(url) {
            unique.append(url)
        }
        return unique.count == 1 ? unique[0] : nil
    }

    /// The displayed (or selected) reference bundle with its manifest, for
    /// callers that need a `ReferenceBundle` rather than a URL (the Call
    /// Variants dialog). A bundle the viewer already holds is used as it is.
    /// Otherwise the manifest is decoded, seconds for a large reference, so
    /// menu validation calls `heldReferenceBundle(in:)` instead. `nil` when
    /// nothing resolves or the manifest cannot be read.
    func currentReferenceBundle(in controller: MainWindowController?) -> ReferenceBundle? {
        guard let bundleURL = currentReferenceBundleURL(in: controller) else { return nil }
        return heldReferenceBundle(in: controller) ?? Self.loadReferenceBundle(at: bundleURL)
    }

    /// The bundle the window's viewer already holds for its current reference
    /// bundle, so menu validation never decodes a manifest. `nil` while the
    /// viewer has not opened that bundle.
    func heldReferenceBundle(in controller: MainWindowController?) -> ReferenceBundle? {
        guard let viewer = controller?.mainSplitViewController?.viewerController,
              let bundleURL = currentReferenceBundleURL(in: controller)?.standardizedFileURL
        else { return nil }
        let held = [
            viewer.currentReferenceBundle,
            viewer.referenceBundleViewportController?.activeSequenceViewerController.currentReferenceBundle,
            viewer.mappingResultController?.activeSequenceViewerController.currentReferenceBundle,
        ]
        return held.lazy.compactMap { $0 }.first { $0.url.standardizedFileURL == bundleURL }
    }

    /// The reference bundles a sidebar selection stands for: a selected
    /// `.lungfishref` itself, or a selected mapping result's reference copy.
    /// The copy is the result folder's one `.lungfishref` child, found by a
    /// listing, because decoding `mapping-result.json` reads every reference
    /// sequence. Anything else contributes nothing.
    static func referenceBundleCandidates(inSidebarSelection urls: [URL]) -> [URL] {
        urls.compactMap { url in
            if url.pathExtension.lowercased() == "lungfishref" {
                return url
            }
            guard MappingResult.savedResultModificationDate(in: url) != nil,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                  )
            else { return nil }
            let copies = children.filter { $0.pathExtension.lowercased() == "lungfishref" }
            return copies.count == 1 ? copies[0] : nil
        }
    }

    static func loadReferenceBundle(at bundleURL: URL) -> ReferenceBundle? {
        guard let manifest = try? BundleManifest.load(from: bundleURL) else { return nil }
        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }
}
