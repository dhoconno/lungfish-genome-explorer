// OperationResultNavigation.swift - Route completed operation results to their project viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
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
        let nativeOutputBundles = item.outputURLs.filter { url in
            SidebarProjectScanner.isNativePackage(url) || isBlastResultFolder(url, fileManager: fileManager)
        }
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
        guard let controller = targetController(for: item),
              let sidebar = controller.mainSplitViewController?.sidebarController,
              await selectResult(of: item, in: sidebar) else {
            return false
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Reloads `sidebar` and selects the item's result, or the nearest folder above it that the sidebar lists. The walk
    /// stops at the route's project. A test calls this with a real sidebar, since `navigate(to:)` reaches its window only
    /// through `AppDelegate.shared`.
    static func selectResult(of item: OperationCenter.Item, in sidebar: SidebarViewController) async -> Bool {
        guard let resultURL = resultURL(for: item) else { return false }
        await sidebar.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: true)?.value
        return selectNearestListedCandidate(from: resultURL, upTo: item.routeContext?.projectURL) {
            sidebar.selectItem(forURL: $0, explicit: true)
        }
    }

    /// Asks `select` for the result's own row, then for each folder above it below the project, and stops at the
    /// first the sidebar lists (OPS-RESULTS-BLAST-ANCESTOR). The closure stands for the sidebar in tests.
    static func selectNearestListedCandidate(
        from resultURL: URL,
        upTo projectURL: URL?,
        select: (URL) -> Bool
    ) -> Bool {
        selectionCandidates(from: resultURL, upTo: projectURL).contains(where: select)
    }

    /// The result's own URL, then each parent folder below the project, nearest first. A route with no project, or a
    /// result outside the project, yields the result alone, so the walk never climbs into another project's folders.
    static func selectionCandidates(from resultURL: URL, upTo projectURL: URL?) -> [URL] {
        let result = resultURL.standardizedFileURL
        guard let projectURL else { return [result] }
        let insideProject = projectURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var candidates = [result]
        var current = result
        while true {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.resolvingSymlinksInPath().path.hasPrefix(insideProject) else { break }
            candidates.append(parent)
            current = parent
        }
        return candidates
    }

    /// The folder of a BLAST search that collected its record (`blast submit` writes `blast-result.json` last). A BLAST
    /// row completes with this folder, the result the viewer's own BLAST Results button reads (OPS-RESULTS-BUTTON).
    private static func isBlastResultFolder(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(BlastSubmissionRecord.recordFileName).path)
    }

    private static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }
}
