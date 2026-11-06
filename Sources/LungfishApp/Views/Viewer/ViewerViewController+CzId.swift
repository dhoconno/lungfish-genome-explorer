// ViewerViewController+CzId.swift - CZ-ID imported result display extension
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTaxonomyUI

extension ViewerViewController {
    /// What a person reads when a CZ-ID result does not open, because its files could not be read or its viewer
    /// was not shown. It says what did not open and what to try, with no kind id and no raw error text.
    static let czIdNotShownWords = "Unable to open the CZ-ID result. Select it again, or import it again if it still does not open."

    /// Shows `controller` through the surface host in place of the normal sequence viewer and returns once it is
    /// installed, or throws the reason it is not. The caller configures the controller before the show.
    public func displayCzIdResult(_ controller: CzIdResultViewController) throws {
        // The Extract Reads dialog is an App sheet, so the view hands its request up and the App presents it.
        controller.onExtractionRequested = { [weak controller] request in
            controller?.presentClassifierExtractionDialog(request)
        }
        clearSurfaceForNewContent()
        contentMode = .metagenomics

        _ = try showSurface(.analysis(.czId), input: controller, as: CzIdSurface.self)
        // showSurface hides the genomics viewer. The annotation drawer is this kind's own line.
        annotationDrawerView?.isHidden = true
    }
}
