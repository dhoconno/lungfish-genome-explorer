// ViewerViewController+Genotype.swift - Native genotype result bundle display
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishGenotypeUI
import os.log

private let genotypeDisplayLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerGenotype")

extension ViewerViewController {
    /// Shows `result` through the surface host and returns its viewer for the route to wire, or throws the
    /// reason it is not installed. Removing this viewer is work as well as chrome, and that work runs in
    /// `GenotypeResultSurface.willDeactivate` on every removal.
    @discardableResult
    func displayGenotypeResult(_ result: ONTGenotypeResultBundleData) throws -> GenotypeResultViewController {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideMHCReferenceBundleView()
        hideGenotypeResultView()
        hideAlignmentTreeBundleViews()
        hideTwelveSAmpliconResultView()
        clearBundleDisplay()
        hideCollectionBackButton()
        hideBundleBackNavigationButton()
        hideProgress()
        contentMode = .genotype

        let controller = GenotypeResultViewController()
        controller.annotationAuthorProvider = { AppSettings.shared.resolvedAnalystIdentity() }
        controller.windowStateScope = windowStateScope
        controller.manualHaplotypeBandDisclosureStore =
            genotypeManualHaplotypeBandDisclosureStore

        let surface = try showSurface(.bundle(.genotypeResult), input: controller, as: GenotypeResultSurface.self)
        surface.onWillDeactivate = { [weak self] in self?.onGenotypeResultViewWillHide?($0) }
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true
        controller.configure(result: result)

        genotypeDisplayLogger.info(
            "displayGenotypeResult: Showing \(result.manifest.outputName, privacy: .public)"
        )

        return controller
    }

    /// Hides the genotype viewer, a shim that other display routes call until the
    /// hide list goes in Phase 3.2.
    func hideGenotypeResultView() {
        clearSurface(ifShowing: .bundle(.genotypeResult))
    }
}
