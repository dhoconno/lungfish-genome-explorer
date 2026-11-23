import AppKit
import LungfishCore
import LungfishKit
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

        // The Mode picker's model, which the surface keeps, and the host's store for the reference view inside (VS-MAP).
        let state = MHCReferenceBundleViewportState(mode: model.preferredMode)
        state.viewMemoryStore = surfaceHost.viewMemoryStore
        let controller = NSHostingController(
            rootView: MHCReferenceBundleViewport(
                model: model,
                onEditHaplotypes: onEditHaplotypes,
                state: state
            )
        )
        _ = try showSurface(.bundle(.mhcReference), input: controller, as: MHCReferenceBundleSurface.self)
        // showSurface hides the genomics viewer. The annotation drawer is this kind's own line.
        annotationDrawerView?.isHidden = true
    }
}
