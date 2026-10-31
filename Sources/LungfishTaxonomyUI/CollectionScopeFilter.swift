// CollectionScopeFilter.swift - The active scope filter for the collections list
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - CollectionScopeFilter

/// The active scope filter for the collections list.
enum CollectionScopeFilter: Int, CaseIterable {
    case all = 0
    case builtIn = 1
    case appWide = 2
    case project = 3

    var title: String {
        switch self {
        case .all: return "All"
        case .builtIn: return "Built-in"
        case .appWide: return "App"
        case .project: return "Project"
        }
    }

    /// Whether a given collection tier matches this filter.
    func matches(_ tier: CollectionTier) -> Bool {
        switch self {
        case .all: return true
        case .builtIn: return tier == .builtin
        case .appWide: return tier == .appWide
        case .project: return tier == .project
        }
    }
}
