// ToolsMenuLayout.swift - Where every Tools menu entry sits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The declarative layout of the Tools menu.
///
/// A category submenu is generated from `FASTQOperationCategoryID`, so adding a
/// read tool stays a case in `FASTQOperationToolID` plus an entry in
/// `FASTQOperationDialogState.toolIDs(for:)`, and never a menu item. This file
/// only says which entries the menu holds, in which group and order, and which
/// fixed commands sit inside a category's submenu beside its generated tools.
///
/// Every category must appear exactly once. A test checks it, so a new
/// `FASTQOperationCategoryID` case cannot be left out of the menu.
enum ToolsMenuLayout {
    /// A command inside a category submenu that no tool catalog generates.
    enum FixedCommand: Equatable, Sendable {
        /// Opens the variant calling dialog on an eligible alignment track.
        case callVariants
        /// Opens the haplotype definitions window. Menu validation disables it
        /// while no enabled workflow uses haplotype definitions.
        case haplotypeDefinitions
        /// Opens the IQ-TREE dialog on the displayed or selected alignment.
        case buildTree
    }

    enum Entry: Equatable, Sendable {
        /// A generated category submenu with three sections, in this order.
        /// The leading commands and the generated tool items come first, the
        /// catalog workflows follow, and the trailing commands come last. A
        /// separator sits only between sections that are not empty.
        case category(FASTQOperationCategoryID, leading: [FixedCommand] = [], trailing: [FixedCommand] = [])
        /// The PCR Primer Design submenu, one item per engine.
        case primerDesign
        /// The Workflows submenu, one item per linked workflow package and
        /// then the Workflow Library.
        case workflows
        /// Plugin Manager…, which keeps its Shift-Command-B shortcut.
        case pluginManager
    }

    /// The groups of the Tools menu from top to bottom, with one separator
    /// between two groups.
    ///
    /// 1. Read preparation, the steps that make reads fit to analyze.
    /// 2. Read analysis, from mapping through genotyping.
    /// 3. Sequences and alignments, which work on sequences and not on reads.
    /// 4. Workflows and plug-ins.
    static let groups: [[Entry]] = [
        [
            .category(.qcReporting),
            .category(.demultiplexing),
            .category(.trimmingFiltering),
            .category(.decontamination),
            .category(.readProcessing),
            .category(.searchSubsetting),
        ],
        [
            .category(.mapping),
            .category(.variantCalling, leading: [.callVariants]),
            .category(.assembly),
            .category(.clustering),
            .category(.classification),
            .category(.genotyping, trailing: [.haplotypeDefinitions]),
        ],
        [
            .category(.alignment, trailing: [.buildTree]),
            .primerDesign,
        ],
        [
            .workflows,
            .pluginManager,
        ],
    ]

    /// Every category the layout lists, in menu order.
    static var categories: [FASTQOperationCategoryID] {
        groups.flatMap { $0 }.compactMap { entry in
            if case .category(let category, _, _) = entry { return category }
            return nil
        }
    }
}
