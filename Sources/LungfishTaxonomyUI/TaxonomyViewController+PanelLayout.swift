// TaxonomyViewController+PanelLayout.swift - The panel layout the Kraken2 viewer builds, and where it reads it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

extension TaxonomyViewController {
    /// The panel layout this viewer builds now. It reads `layoutDefaults` on every use, so a viewer a test gave a suite
    /// of its own never reads the account's defaults (VS-LEAK).
    func currentPanelLayout() -> MetagenomicsPanelLayout {
        MetagenomicsPanelLayout.current(defaults: layoutDefaults)
    }

    /// The minimum pane extents of the layout the viewer builds now.
    func currentMinimumExtents() -> (leading: CGFloat, trailing: CGFloat) {
        minimumExtents(for: currentPanelLayout())
    }

    /// The first divider fraction of the layout the viewer builds now.
    func currentDefaultLeadingFraction() -> CGFloat {
        defaultLeadingFraction(for: currentPanelLayout())
    }

    func defaultLeadingFraction(for layout: MetagenomicsPanelLayout) -> CGFloat {
        switch layout {
        case .detailLeading:
            return 0.6
        case .listLeading, .stacked:
            return 0.4
        }
    }

    func minimumExtents(for layout: MetagenomicsPanelLayout) -> (leading: CGFloat, trailing: CGFloat) {
        switch layout {
        case .detailLeading:
            return (300, 260)
        case .listLeading, .stacked:
            return (260, 300)
        }
    }
}
