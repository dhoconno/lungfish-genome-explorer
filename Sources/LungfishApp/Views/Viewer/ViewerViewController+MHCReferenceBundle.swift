import AppKit
import LungfishCore
import SwiftUI

extension ViewerViewController {
    /// Shows the MHC amplicon reference bundle through the surface host in place of the sequence
    /// viewer, or throws the reason it is not shown. The route says so in words.
    func displayMHCReferenceBundle(
        _ model: MHCReferenceBundleViewportModel,
        onEditHaplotypes: @escaping () -> Void
    ) throws {
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
        _ = try showSurface(.bundle(.mhcReference), input: controller, as: MHCReferenceBundleSurface.self)
        // showSurface hides the genomics viewer. These two drawers are this kind's own lines.
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true
    }

    /// Hides the MHC reference viewer, a shim that other display routes call until the hide list
    /// goes in Phase 3.2.
    func hideMHCReferenceBundleView() {
        clearSurface(ifShowing: .bundle(.mhcReference))
    }
}
