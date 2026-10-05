// AppDelegate+TreeInference.swift - Tools > Alignment & Phylogenetics > Build Tree with IQ-TREE…
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension AppDelegate {
    /// The tooltip the Build Tree item shows while it is disabled.
    static let treeInferenceDisabledToolTip = "Open or select an alignment to build a tree."

    /// The alignment bundle the Build Tree item acts on: the .lungfishmsa shown in the
    /// viewport, else exactly one .lungfishmsa selected in the sidebar, else `nil`.
    ///
    /// The menu validation and the action both go through this, so the item is enabled
    /// for the bundle it will open the dialog on.
    static func resolveTreeInferenceBundleURL(
        displayedBundleURL: URL?,
        sidebarSelection: [URL]
    ) -> URL? {
        if let displayedBundleURL, displayedBundleURL.pathExtension.lowercased() == "lungfishmsa" {
            return displayedBundleURL
        }
        var unique: [URL] = []
        for url in sidebarSelection where url.pathExtension.lowercased() == "lungfishmsa" {
            let standardized = url.standardizedFileURL
            if !unique.contains(standardized) { unique.append(standardized) }
        }
        return unique.count == 1 ? unique[0] : nil
    }

    /// The tree-inference request for the active window. A displayed alignment passes its
    /// current row and column selection, the same request its context menu builds. A
    /// sidebar-only selection builds a whole-alignment request.
    func treeInferenceRequest(in controller: MainWindowController?) -> MultipleSequenceAlignmentTreeInferenceRequest? {
        guard let split = controller?.mainSplitViewController else { return nil }
        let displayed = split.viewerController?.multipleSequenceAlignmentViewController
        let selection = split.sidebarController?.selectedFileURLs() ?? []
        guard let bundleURL = Self.resolveTreeInferenceBundleURL(
            displayedBundleURL: displayed?.bundleURL,
            sidebarSelection: selection
        ) else { return nil }
        if let displayed, displayed.bundleURL == bundleURL, let request = displayed.treeInferenceRequest() {
            return request
        }
        let name = bundleURL.deletingPathExtension().lastPathComponent
        return MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: bundleURL,
            rows: nil,
            columns: nil,
            suggestedName: "\(name).lungfishtree",
            displayName: name
        )
    }

    @objc func showIQTreeInference(_ sender: Any?) {
        let controller = activeMainWindowController(sender: sender)
        guard let viewer = controller?.mainSplitViewController?.viewerController,
              let request = treeInferenceRequest(in: controller) else {
            NSSound.beep()
            return
        }
        viewer.inferTreeFromMSAViaCLI(request)
    }
}
