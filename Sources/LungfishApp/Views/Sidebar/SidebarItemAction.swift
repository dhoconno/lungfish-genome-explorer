// SidebarItemAction.swift - Commands that act on the selected sidebar items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// One command that acts on the sidebar's selected items.
///
/// The sidebar offers these from its context menu, from each row's
/// accessibility custom actions and from Selection > Sidebar Item in the menu
/// bar, which sends ``menuSelector`` to the first responder so the items are
/// enabled only while the sidebar outline has keyboard focus and
/// `SidebarViewController` validates them against its selection. The
/// context menu, the cell actions and the validation are the sidebar lane's
/// work; this enum is the single list of titles, selectors and chords they
/// all read, in the shape of ``OperationRowAction``.
///
/// "Move to" stays a submenu of destinations and is not a command here.
/// "Show in Inspector" shares the Selection menu's one top-level item with
/// every table, through ``ResultRowMenuActions``.
enum SidebarItemAction: String, CaseIterable, RowCommand, Sendable {
    case open
    case openBundle
    case showPackageContents
    case getBundleInfo
    case newFolder
    case rename
    case duplicate
    case moveToTrash
    case selectSiblings
    case showInFinder
    case copyPath
    case showInInspector
    case exportSequences
    case exportAlignment
    case exportAsFASTQ
    case mergeIntoNewBundle
    case reassemble
    case deleteVariantTracks
    case importSampleMetadata
    case cloneMetadataFrom
    case copyClassificationCommand
    case editFolderMetadata
    case exportFolderMetadata
    case importFolderMetadata
    case manageProjectStorage

    /// Menu title, as shown in the context menu and as the AX action name.
    var title: String {
        switch self {
        case .open: return "Open"
        case .openBundle: return "Open Bundle"
        case .showPackageContents: return "Show Package Contents"
        case .getBundleInfo: return "Get Bundle Info"
        case .newFolder: return "New Folder"
        case .rename: return "Rename\u{2026}"
        case .duplicate: return "Duplicate"
        case .moveToTrash: return "Move to Trash"
        case .selectSiblings: return "Select Siblings"
        case .showInFinder: return "Show in Finder"
        case .copyPath: return "Copy Path"
        case .showInInspector: return "Show in Inspector"
        case .exportSequences: return "Export Sequences\u{2026}"
        case .exportAlignment: return "Export Alignment\u{2026}"
        case .exportAsFASTQ: return "Export as FASTQ\u{2026}"
        case .mergeIntoNewBundle: return "Merge Into New Bundle\u{2026}"
        case .reassemble: return "Reassemble\u{2026}"
        case .deleteVariantTracks: return "Delete Variant Tracks\u{2026}"
        case .importSampleMetadata: return "Import Sample Metadata\u{2026}"
        case .cloneMetadataFrom: return "Clone Metadata From\u{2026}"
        case .copyClassificationCommand: return "Copy Classification Command"
        case .editFolderMetadata: return "Edit Folder Sample Metadata\u{2026}"
        case .exportFolderMetadata: return "Export Folder Sample Metadata (CSV)\u{2026}"
        case .importFolderMetadata: return "Import Folder Sample Metadata (CSV)\u{2026}"
        case .manageProjectStorage: return "Manage Project Storage\u{2026}"
        }
    }

    /// The context-menu title for a selection of `selectionCount` items.
    ///
    /// Finder counts the items it is about to trash, and the two bundle
    /// exports count the bundles they will write, so those three read
    /// "Move 3 Items to Trash", "Export 3 Sequences…" and "Export 3 as
    /// FASTQ…" for more than one item. Every other command keeps ``title``.
    func contextTitle(selectionCount: Int) -> String {
        guard selectionCount > 1 else { return title }
        switch self {
        case .moveToTrash: return "Move \(selectionCount) Items to Trash"
        case .exportSequences: return "Export \(selectionCount) Sequences\u{2026}"
        case .exportAsFASTQ: return "Export \(selectionCount) as FASTQ\u{2026}"
        default: return title
        }
    }

    /// Stable identifier suffix shared by the menu bar item and the AX action.
    var identifierSlug: String {
        switch self {
        case .open: return "open"
        case .openBundle: return "open-bundle"
        case .showPackageContents: return "show-package-contents"
        case .getBundleInfo: return "get-bundle-info"
        case .newFolder: return "new-folder"
        case .rename: return "rename"
        case .duplicate: return "duplicate"
        case .moveToTrash: return "move-to-trash"
        case .selectSiblings: return "select-siblings"
        case .showInFinder: return "show-in-finder"
        case .copyPath: return "copy-path"
        case .showInInspector: return "show-in-inspector"
        case .exportSequences: return "export-sequences"
        case .exportAlignment: return "export-alignment"
        case .exportAsFASTQ: return "export-as-fastq"
        case .mergeIntoNewBundle: return "merge-into-new-bundle"
        case .reassemble: return "reassemble"
        case .deleteVariantTracks: return "delete-variant-tracks"
        case .importSampleMetadata: return "import-sample-metadata"
        case .cloneMetadataFrom: return "clone-metadata-from"
        case .copyClassificationCommand: return "copy-classification-command"
        case .editFolderMetadata: return "edit-folder-metadata"
        case .exportFolderMetadata: return "export-folder-metadata"
        case .importFolderMetadata: return "import-folder-metadata"
        case .manageProjectStorage: return "manage-project-storage"
        }
    }

    /// The hoisted sidebar chords (owner decision, 2026-09-30): the Finder
    /// meanings of Cmd-Shift-N, Cmd-Shift-D and Cmd-Delete, plus Cmd-Opt-S
    /// for Show in Inspector, the one new chord of this pass. Cmd-Shift-A
    /// stays with Select Siblings, which the sidebar handled in its own
    /// key monitor before it became a menu item (View > AI Assistant moved
    /// to Cmd-Opt-A for it).
    var keyEquivalent: RowCommandKeyEquivalent? {
        switch self {
        case .newFolder: return RowCommandKeyEquivalent("n", [.command, .shift])
        case .duplicate: return RowCommandKeyEquivalent("d", [.command, .shift])
        case .moveToTrash: return RowCommandKeyEquivalent("\u{8}", [.command])
        case .selectSiblings: return RowCommandKeyEquivalent("a", [.command, .shift])
        case .showInInspector: return RowCommandKeyEquivalent("s", [.command, .option])
        default: return nil
        }
    }

    /// The responder-chain selector the menu bar item sends.
    var menuSelector: Selector {
        switch self {
        case .open: return #selector(SidebarItemMenuActions.openSelectedSidebarItem(_:))
        case .openBundle: return #selector(SidebarItemMenuActions.openSelectedSidebarBundle(_:))
        case .showPackageContents: return #selector(SidebarItemMenuActions.showSelectedSidebarPackageContents(_:))
        case .getBundleInfo: return #selector(SidebarItemMenuActions.getSelectedSidebarBundleInfo(_:))
        case .newFolder: return #selector(SidebarItemMenuActions.newFolderInSidebar(_:))
        case .rename: return #selector(SidebarItemMenuActions.renameSelectedSidebarItem(_:))
        case .duplicate: return #selector(SidebarItemMenuActions.duplicateSelectedSidebarItems(_:))
        case .moveToTrash: return #selector(SidebarItemMenuActions.moveSelectedSidebarItemsToTrash(_:))
        case .selectSiblings: return #selector(SidebarItemMenuActions.selectSiblingSidebarItems(_:))
        case .showInFinder: return #selector(SidebarItemMenuActions.showSelectedSidebarItemInFinder(_:))
        case .copyPath: return #selector(SidebarItemMenuActions.copySelectedSidebarItemPath(_:))
        case .showInInspector: return #selector(ResultRowMenuActions.showSelectedRowInInspector(_:))
        case .exportSequences: return #selector(FileMenuActions.exportFASTA(_:))
        case .exportAlignment: return #selector(SidebarItemMenuActions.exportSelectedSidebarAlignment(_:))
        case .exportAsFASTQ: return #selector(SidebarItemMenuActions.exportSelectedSidebarItemsAsFASTQ(_:))
        case .mergeIntoNewBundle: return #selector(SidebarItemMenuActions.mergeSelectedSidebarItemsIntoNewBundle(_:))
        case .reassemble: return #selector(SidebarItemMenuActions.reassembleSelectedSidebarBundle(_:))
        case .deleteVariantTracks: return #selector(SidebarItemMenuActions.deleteSelectedSidebarVariantTracks(_:))
        case .importSampleMetadata: return #selector(SidebarItemMenuActions.importSampleMetadataForSelectedSidebarBundle(_:))
        case .cloneMetadataFrom: return #selector(SidebarItemMenuActions.cloneMetadataForSelectedSidebarBundle(_:))
        case .copyClassificationCommand: return #selector(SidebarItemMenuActions.copySelectedSidebarClassificationCommand(_:))
        case .editFolderMetadata: return #selector(SidebarItemMenuActions.editSelectedSidebarFolderMetadata(_:))
        case .exportFolderMetadata: return #selector(SidebarItemMenuActions.exportSelectedSidebarFolderMetadata(_:))
        case .importFolderMetadata: return #selector(SidebarItemMenuActions.importSelectedSidebarFolderMetadata(_:))
        case .manageProjectStorage: return #selector(AppDelegate.manageProjectStorage(_:))
        }
    }

    /// Menu sections of Selection > Sidebar Item, in display order.
    ///
    /// Three commands are left out because the menu bar already carries them
    /// elsewhere: Show in Inspector (Selection, top level), Export
    /// Sequences (File > Export > Sequences) and Manage Project Storage
    /// (File). They stay in the enum so the context menu and the cell
    /// actions keep one source of titles.
    static let menuSections: [[SidebarItemAction]] = [
        [.open, .openBundle, .showPackageContents, .getBundleInfo],
        [.newFolder, .rename, .duplicate, .moveToTrash],
        [.selectSiblings],
        [.showInFinder, .copyPath],
        [.exportAlignment, .exportAsFASTQ, .mergeIntoNewBundle, .reassemble, .deleteVariantTracks],
        [.importSampleMetadata, .cloneMetadataFrom, .copyClassificationCommand],
        [.editFolderMetadata, .exportFolderMetadata, .importFolderMetadata],
    ]
}

/// Menu bar handlers for the sidebar's selected items.
///
/// The items in Selection > Sidebar Item send these to the first responder,
/// so they are enabled only while the sidebar outline has focus and
/// `SidebarViewController` validates them against `selectedItems()`. The
/// sidebar lane adopts this protocol; until then every item stays disabled.
@MainActor
@objc protocol SidebarItemMenuActions {
    func openSelectedSidebarItem(_ sender: Any?)
    func openSelectedSidebarBundle(_ sender: Any?)
    func showSelectedSidebarPackageContents(_ sender: Any?)
    func getSelectedSidebarBundleInfo(_ sender: Any?)
    func newFolderInSidebar(_ sender: Any?)
    func renameSelectedSidebarItem(_ sender: Any?)
    func duplicateSelectedSidebarItems(_ sender: Any?)
    func moveSelectedSidebarItemsToTrash(_ sender: Any?)
    func selectSiblingSidebarItems(_ sender: Any?)
    func showSelectedSidebarItemInFinder(_ sender: Any?)
    func copySelectedSidebarItemPath(_ sender: Any?)
    func exportSelectedSidebarAlignment(_ sender: Any?)
    func exportSelectedSidebarItemsAsFASTQ(_ sender: Any?)
    func mergeSelectedSidebarItemsIntoNewBundle(_ sender: Any?)
    func reassembleSelectedSidebarBundle(_ sender: Any?)
    func deleteSelectedSidebarVariantTracks(_ sender: Any?)
    func importSampleMetadataForSelectedSidebarBundle(_ sender: Any?)
    func cloneMetadataForSelectedSidebarBundle(_ sender: Any?)
    func copySelectedSidebarClassificationCommand(_ sender: Any?)
    func editSelectedSidebarFolderMetadata(_ sender: Any?)
    func exportSelectedSidebarFolderMetadata(_ sender: Any?)
    func importSelectedSidebarFolderMetadata(_ sender: Any?)
}
