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
        clearSurfaceForNewContent()
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
        // showSurface hides the genomics viewer. The annotation drawer is this kind's own line.
        annotationDrawerView?.isHidden = true
    }
}
