// ViewerViewController+Assembly.swift - Assembly result display for ViewerViewController
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow
import os.log

private let assemblyDisplayLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerAssembly")

extension ViewerViewController {
    /// Displays an assembly result viewport in place of the normal sequence viewer.
    public func displayAssemblyResult(_ result: AssemblyResult) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideAssemblyView()
        clearBundleDisplay()
        hideCollectionBackButton()
        contentMode = .genomics

        let controller = AssemblyResultViewController()
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let assemblyView = controller.view
        controller.configure(result: result)
        assemblyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(assemblyView)

        NSLayoutConstraint.activate([
            assemblyView.topAnchor.constraint(equalTo: view.topAnchor),
            assemblyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            assemblyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            assemblyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        assemblyResultController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        assemblyDisplayLogger.info(
            "displayAssemblyResult: Showing \(result.tool.displayName, privacy: .public) result"
        )
    }

    /// Removes the assembly result viewport and restores the normal viewer components.
    public func hideAssemblyView() {
        guard let controller = assemblyResultController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        assemblyResultController = nil

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
    }
}
