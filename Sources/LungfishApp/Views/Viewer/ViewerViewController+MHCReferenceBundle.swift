import AppKit
import LungfishCore
import SwiftUI

extension ViewerViewController {
    func displayMHCReferenceBundle(
        _ model: MHCReferenceBundleViewportModel,
        onEditHaplotypes: @escaping () -> Void
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
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
        hideTwelveSAmpliconResultView()
        hideAlignmentTreeBundleViews()
        clearBundleDisplay()
        hideCollectionBackButton()
        hideBundleBackNavigationButton()
        hideProgress()
        contentMode = .genomics

        let controller = NSHostingController(
            rootView: MHCReferenceBundleViewport(
                model: model,
                onEditHaplotypes: onEditHaplotypes
            )
        )
        addChild(controller)

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let mhcView = controller.view
        mhcView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mhcView)

        NSLayoutConstraint.activate([
            mhcView.topAnchor.constraint(equalTo: view.topAnchor),
            mhcView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mhcView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mhcView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        mhcReferenceBundleViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true
    }

    func hideMHCReferenceBundleView() {
        guard let controller = mhcReferenceBundleViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        mhcReferenceBundleViewController = nil

        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = (geneTabBarView?.selectedGeneRegion == nil)
        revealAnnotationDrawerUnlessNativeBundleInstalled()
        fastqMetadataDrawerView?.isHidden = false
    }
}
