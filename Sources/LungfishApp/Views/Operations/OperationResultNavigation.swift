// OperationResultNavigation.swift - Route completed operation results to their project viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// Selects a completed operation's persisted result in the originating project window.
///
/// Operation targets and loose exported files are deliberately excluded. `bundleURLs`
/// is the OperationCenter contract for final results. Some older producers publish a
/// native result package through `outputURLs`, so those URLs qualify only when the
/// sidebar's shared package classifier recognizes them. `targetBundleURL` may only
/// identify the source being locked during an in-place operation.
@MainActor
enum OperationResultNavigation {
    static func resultURL(
        for item: OperationCenter.Item,
        fileManager: FileManager = .default
    ) -> URL? {
        guard item.state == .completed else { return nil }
        let nativeOutputBundles = item.outputURLs.filter(SidebarProjectScanner.isNativePackage)
        return (item.bundleURLs + nativeOutputBundles).lazy
            .map(\.standardizedFileURL)
            .first { url in
                guard fileManager.fileExists(atPath: url.path) else { return false }
                guard let projectURL = item.routeContext?.projectURL else { return true }
                return isURL(url, inside: projectURL)
            }
    }

    static func canNavigate(to item: OperationCenter.Item) -> Bool {
        resultURL(for: item) != nil
    }

    /// Resolves the exact originating window first. If that window has since
    /// closed, an explicit Results click may use another open window for the
    /// same project. A projectless stale route never falls back globally.
    static func targetController(
        for item: OperationCenter.Item,
        appDelegate: AppDelegate? = .shared
    ) -> MainWindowController? {
        guard let appDelegate else { return nil }
        if let exact = appDelegate.targetMainWindowController(routeContext: item.routeContext) {
            return exact
        }
        guard let projectURL = item.routeContext?.projectURL else { return nil }
        let projectRoute = OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        return appDelegate.targetMainWindowController(routeContext: projectRoute)
    }

    /// Reloads the existing project sidebar, selects the result, and raises that window.
    /// No import or document-open path is used, so this cannot create duplicate project data.
    @discardableResult
    static func navigate(to item: OperationCenter.Item) async -> Bool {
        guard let resultURL = resultURL(for: item),
              let controller = targetController(for: item),
              let sidebar = controller.mainSplitViewController?.sidebarController else {
            return false
        }

        await sidebar.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: true)?.value
        guard sidebar.selectItem(forURL: resultURL) else { return false }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }
}
