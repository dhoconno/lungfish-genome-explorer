// ScopedEventFilter.swift - Window or application scope for every app notification
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore

/// The one rule that decides whether a project window reacts to a notification
/// (finding R9 in the 2026-10-02 architecture review).
///
/// Every `Notification.Name` the app declares is classified here as a window
/// event or an application event.
///
/// - A window event changes the state of one project window, such as a
///   selection, an Inspector request or a viewer display setting. Its poster
///   attaches the window's `WindowStateScope` under
///   `NotificationUserInfoKey.windowStateScope`, and an observer that belongs
///   to a window accepts it only when that scope is its own. A window event
///   without a scope is dropped. The filter fails closed.
/// - An application event concerns the whole app, such as a preference, a
///   managed resource change or an operation finishing. Every observer accepts
///   it, with or without a scope.
///
/// A name missing from ``classifications`` is treated as a window event, and
/// `ScopedEventClassificationTests` fails until the name is classified.
public enum ScopedEventFilter {

    /// Whether a notification concerns one project window or the whole app.
    public enum Classification: String, Sendable, CaseIterable {
        case window
        case application
    }

    /// The classification of every notification name declared under Sources.
    ///
    /// Names declared in LungfishCore and LungfishKit are written by symbol.
    /// Names declared in LungfishApp and the leaf modules are written by raw
    /// value, because LungfishKit cannot import those modules.
    /// `ScopedEventClassificationTests` checks that this table and the
    /// declarations under Sources hold exactly the same names.
    public static let classifications: [Notification.Name: Classification] = [
        // LungfishCore, Models/Notifications.swift
        .annotationSelected: .window,
        .annotationUpdated: .window,
        .annotationDeleted: .window,
        .annotationColorAppliedToType: .window,
        .appearanceChanged: .application,
        .contentTextSizeDidChange: .application,
        .appSettingsChanged: .application,
        .annotationSettingsChanged: .window,
        .annotationFilterChanged: .window,
        .variantFilterChanged: .window,
        .sampleDisplayStateChanged: .window,
        .variantColorThemeDidChange: .application,
        .viewerCoordinatesChanged: .window,
        .bundleDidLoad: .window,
        .viewportVariantsUpdated: .window,
        .bundleViewStateResetRequested: .window,
        // Every window showing the bundle drops the deleted tracks. Observers
        // match on the bundle URL.
        .bundleVariantTracksDeleted: .application,
        .readSelected: .window,
        .readDisplaySettingsChanged: .window,
        .readSortPositionChosen: .window,
        .msaDiscriminatingSitesHighlightChanged: .window,
        .msaFocusAlignmentColumnRequested: .window,
        .viewportContentModeDidChange: .window,
        .showInspectorRequested: .window,
        .chromosomeInspectorRequested: .window,
        .showCDSTranslationRequested: .window,
        .extractSequenceRequested: .window,
        .copyAnnotationAsFASTARequested: .window,
        .copyTranslationAsFASTARequested: .window,
        .zoomToAnnotationRequested: .window,
        .variantSelected: .window,
        .variantSelectionChanged: .window,
        .copyAnnotationSequenceRequested: .window,
        .copyAnnotationReverseComplementRequested: .window,
        .runFASTAOperationOnAnnotationRequested: .window,
        .operationStateChanged: .application,
        .analysisRunOutputsCompleted: .application,
        .fastqDatasetLoaded: .window,
        .vcfDatasetLoaded: .window,
        .databaseStorageLocationChanged: .application,
        .managedResourcesDidChange: .application,

        // LungfishKit, MetagenomicsLayoutPreference.swift
        .metagenomicsLayoutSwapRequested: .application,
        .metagenomicsSampleSelectionChanged: .window,
        .metagenomicsMetadataImportRequested: .window,

        // LungfishApp, App/DocumentManager.swift. The split view controller
        // also matches the session ID on the two window events.
        Notification.Name("DocumentManagerDocumentLoaded"): .window,
        Notification.Name("DocumentManagerActiveDocumentChanged"): .application,
        Notification.Name("DocumentManagerProjectOpened"): .window,
        Notification.Name("DocumentManagerProjectLoaded"): .application,

        // LungfishApp, Services/DependencyReconciliationActivity.swift and
        // Views/Dependencies/UpdateToolsSheetController.swift
        Notification.Name("com.lungfish.dependencyReconciliationDidStart"): .application,
        Notification.Name("com.lungfish.dependencyReconciliationDidEnd"): .application,
        Notification.Name("com.lungfish.dependencyReconciliationDidFinish"): .application,

        // LungfishApp, Services/WorkflowLibrary.swift
        Notification.Name("com.lungfish.workflowLibraryEnablementChanged"): .application,
        Notification.Name("workflowLibraryEnablementDidChange"): .application,
        Notification.Name("com.lungfish.workflowLibraryPackagesChanged"): .application,

        // LungfishApp, Views/AI/AIAssistantPanel.swift
        Notification.Name("showAIAssistantRequested"): .window,

        // LungfishApp, Views/Sidebar. Saved folder metadata is a disk change
        // that any window showing the folder may refresh.
        Notification.Name("sampleMetadataDidChange"): .application,
        Notification.Name("SidebarSelectionChanged"): .window,
        Notification.Name("SidebarFileDropped"): .window,
        // An import finishing. The import tracker matches the request ID.
        Notification.Name("SidebarFileDropCompleted"): .application,
        Notification.Name("SidebarPreferredWidthRecommended"): .window,
        Notification.Name("SidebarItemsDeleted"): .window,
        Notification.Name("NavigateToSidebarItem"): .window,

        // LungfishApp, Views/Viewer
        Notification.Name("com.lungfish.activeSequenceChanged"): .window,
        Notification.Name("com.lungfish.sequenceStackChanged"): .window,
        Notification.Name("com.lungfish.annotationVisibilityChanged"): .window,
        Notification.Name("com.lungfish.mappingLayoutSwapRequested"): .application,
        Notification.Name("com.lungfish.batchManifestCached"): .window,
        Notification.Name("com.lungfish.referenceBundleScrollDirectionChanged"): .application,
        // Posted inline by SequenceViewerView+Interaction.swift.
        Notification.Name("createAnnotationFromSelection"): .window,

        // LungfishAssemblyUI, AssemblyLayoutPreference.swift
        Notification.Name("com.lungfish.assemblyLayoutSwapRequested"): .application,

        // LungfishGenotypeUI, GenotypeNotifications.swift and GenotypeOutlineView.swift
        Notification.Name("com.lungfish.genotypeResultViewModeChanged"): .window,
        Notification.Name("com.lungfish.genotypeResultOpenHaplotypeDefinitions"): .window,
        Notification.Name("com.lungfish.genotypeResultSmartCohortApplied"): .window,
        Notification.Name("com.lungfish.genotypeResultSmartCohortSaveRequested"): .window,
        Notification.Name("com.lungfish.genotypeResultSmartCohortDeleteRequested"): .window,
        Notification.Name("com.lungfish.genotypeResultExcelExportRequested"): .window,
        Notification.Name("com.lungfish.genotypeResultRequestSampleDetailSheet"): .window,
        Notification.Name("com.lungfish.genotypeResultShowsAncillaryLociChanged"): .window,
        Notification.Name("com.lungfish.genotypeResultIncludedLociChanged"): .window,
        // The haplotype row density is a saved preference.
        Notification.Name("genotypeHaplotypeDensityDidChange"): .application,
    ]

    /// The classification of `name`, or nil when the name is not in the table.
    public static func classification(of name: Notification.Name) -> Classification? {
        classifications[name]
    }

    /// Whether an observer in the window with `windowScope` should react to
    /// `notification`.
    ///
    /// An application event is always accepted. A window event, or a name
    /// missing from the table, is accepted only when it carries a scope equal
    /// to `windowScope`. An observer with no scope of its own accepts no window
    /// event.
    public static func accept(_ notification: Notification, for windowScope: WindowStateScope?) -> Bool {
        if classifications[notification.name] == .application {
            return true
        }
        guard let windowScope,
              let eventScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope
        else {
            return false
        }
        return eventScope == windowScope
    }

    /// `userInfo` with `windowScope` attached under
    /// `NotificationUserInfoKey.windowStateScope`. Every other key is kept.
    /// When `windowScope` is nil the dictionary is returned unchanged, and a
    /// window observer then drops the event.
    public static func scopedUserInfo(
        _ userInfo: [AnyHashable: Any]? = nil,
        scope windowScope: WindowStateScope?
    ) -> [AnyHashable: Any]? {
        guard let windowScope else { return userInfo }
        var scoped = userInfo ?? [:]
        scoped[NotificationUserInfoKey.windowStateScope] = windowScope
        return scoped
    }

    /// The scope of the project window that shows `view`.
    ///
    /// Follows a sheet or a child window to the window it belongs to, and
    /// returns the scope of the first window whose controller is a
    /// ``WindowStateScopeOwner``. Returns nil when the view is in no window or
    /// in a window that belongs to no project window. Views that a container
    /// embeds without handing them a scope, such as the viewer inside a
    /// reference bundle viewport, find their window's scope this way.
    @MainActor
    public static func hostingWindowScope(of view: NSView?) -> WindowStateScope? {
        var window = view?.window
        while let current = window {
            if let owner = current.windowController as? WindowStateScopeOwner {
                return owner.windowStateScope
            }
            window = current.sheetParent ?? current.parent
        }
        return nil
    }
}

/// A window controller that owns one project window's `WindowStateScope`.
///
/// `MainWindowController` in LungfishApp conforms.
/// ``ScopedEventFilter/hostingWindowScope(of:)`` uses it to find the scope of
/// the window that shows a view.
@MainActor
public protocol WindowStateScopeOwner: AnyObject {
    var windowStateScope: WindowStateScope { get }
}
