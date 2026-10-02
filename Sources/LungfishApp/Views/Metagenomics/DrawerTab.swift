// DrawerTab.swift - Which tab is active in the bottom drawer
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - DrawerTab

/// Which tab is active in the bottom drawer.
///
/// The drawer supports two tabs: Collections (taxa collection browser)
/// and BLAST Results (BLAST verification results). The tab is selected
/// via an ``NSSegmentedControl`` in the header bar.
enum DrawerTab: Int, CaseIterable {
    case collections = 0
    case blastResults = 1

    var title: String {
        switch self {
        case .collections: return "Collections"
        case .blastResults: return "BLAST Results"
        }
    }
}
