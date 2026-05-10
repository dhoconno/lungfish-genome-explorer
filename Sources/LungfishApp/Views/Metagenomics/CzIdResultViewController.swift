// CzIdResultViewController.swift - CZ-ID imported taxonomy result wrapper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import SwiftUI

@MainActor
public final class CzIdResultViewController: NSViewController, NSPopoverDelegate {
    private let taxonomyViewController = TaxonomyViewController()
    private var manifest: CzIdImportManifest?
    private var bundleURL: URL?
    private var provenancePopover: NSPopover?
    private var didEmbedTaxonomy = false

    public var taxonomyViewControllerForTesting: TaxonomyViewController? {
        taxonomyViewController
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier("czid-result-view")
        self.view = container
    }

    public func configure(
        result: ClassificationResult,
        manifest: CzIdImportManifest,
        bundleURL: URL
    ) {
        self.manifest = manifest
        self.bundleURL = bundleURL

        if !isViewLoaded {
            loadView()
        }
        embedTaxonomyIfNeeded()
        taxonomyViewController.configure(result: result)
        taxonomyViewController.actionBar.updateInfoText(
            "Imported CZ-ID result · \(manifest.sampleName) · \(manifest.rowCount) taxa"
        )
        taxonomyViewController.actionBar.onProvenance = { [weak self] sender in
            self?.showProvenance(relativeTo: sender)
        }
        taxonomyViewController.actionBar.setExtractEnabled(false)
        taxonomyViewController.actionBar.extractButton.toolTip =
            "CZ-ID imports do not include per-read source IDs for FASTQ extraction."
    }

    private func embedTaxonomyIfNeeded() {
        guard !didEmbedTaxonomy else { return }
        addChild(taxonomyViewController)
        let taxonomyView = taxonomyViewController.view
        taxonomyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(taxonomyView)
        NSLayoutConstraint.activate([
            taxonomyView.topAnchor.constraint(equalTo: view.topAnchor),
            taxonomyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            taxonomyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            taxonomyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        didEmbedTaxonomy = true
    }

    private func showProvenance(relativeTo button: NSButton) {
        guard let manifest else { return }
        provenancePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: CzIdProvenanceView(
            manifest: manifest,
            bundleURL: bundleURL
        ))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        provenancePopover = popover
    }

    public func popoverDidClose(_ notification: Notification) {
        provenancePopover = nil
    }
}
