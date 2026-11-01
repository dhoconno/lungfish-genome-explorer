// CzIdResultViewController.swift - CZ-ID imported taxonomy result wrapper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import SwiftUI
import LungfishKit

@MainActor
public final class CzIdResultViewController: NSViewController, NSPopoverDelegate {
    /// The embedded Kraken2 taxonomy view, whose drawer ``CzIdSurface`` answers for.
    let taxonomyViewController = TaxonomyViewController()
    private var manifest: CzIdImportManifest?
    private var bundleURL: URL?
    private var provenancePopover: NSPopover?
    private var didEmbedTaxonomy = false

    public var taxonomyViewControllerForTesting: TaxonomyViewController? {
        taxonomyViewController
    }

    /// Hands the embedded taxonomy view's Extract Reads request to the host that shows the dialog (layering rule 1).
    public var onExtractionRequested: (@MainActor (ClassifierExtractionRequest) -> Void)? {
        get { taxonomyViewController.onExtractionRequested }
        set { taxonomyViewController.onExtractionRequested = newValue }
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
        // Gate both the action bar and the table's own context menu
        // (Extract Reads…, Verify with BLAST…) on the same capability
        // flag, since CZ-ID imports have no per-read source IDs for either.
        // Set it before naming the import: changing it refreshes the action
        // bar, which would replace the name with the no-selection prompt.
        // The reason goes first (UX-3E-LABELS R8). The refresh that follows the flag puts it on both greyed
        // buttons, and every later refresh keeps it.
        taxonomyViewController.readLevelActionsUnavailableReason = ClassifierActionWords.czIdHasNoReadIDs
        taxonomyViewController.readLevelActionsAvailable = false
        // With no read IDs CZ-ID cannot run BLAST, so the BLAST Results button would open a pane that never fills.
        taxonomyViewController.resultActions.blastResultsButton.isHidden = true
        taxonomyViewController.actionBar.updateInfoText(
            "Imported CZ-ID result · \(manifest.sampleName) · \(manifest.rowCount) taxa"
        )
        taxonomyViewController.actionBar.onProvenance = { [weak self] sender in
            self?.showProvenance(relativeTo: sender)
        }
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
