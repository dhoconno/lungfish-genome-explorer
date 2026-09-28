// DemoProjectsSheetController.swift - Presents Help > Demo Projects…
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DemoProjects")

/// Presents the Demo Projects sheet on the key (or main) window, or as a small
/// window of its own when no window is key. Never a modal session.
@MainActor
enum DemoProjectsSheetController {
    private static var panel: NSPanel?
    private static var hostWindow: NSWindow?

    static func present(
        openProject: @escaping (URL) -> Void,
        isProjectOpen: @escaping (URL) -> Bool
    ) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let environment = DemoProjectsEnvironment(
            loadManifest: { try DemoProjectManifest.loadBundled() },
            installer: DemoProjectInstaller(),
            locationStore: DemoProjectLocationStore(defaults: .standard),
            operations: OperationCenterDemoProjectReporter(),
            openProject: openProject,
            revealInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            openURL: { url in NSWorkspace.shared.open(url) },
            isProjectOpen: isProjectOpen
        )
        let viewModel = DemoProjectsViewModel(environment: environment)

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        newPanel.title = "Demo Projects"
        newPanel.isReleasedWhenClosed = false
        newPanel.setAccessibilityIdentifier(DemoProjectsAccessibilityID.sheet)

        // Bring the app forward first so the sheet (or the standalone window)
        // is shown where the user is looking.
        NSApp.activate()
        let host = Self.frontWindow()
        viewModel.onDismiss = { dismiss() }
        viewModel.onChooseFolder = { [weak viewModel] in
            guard let viewModel else { return }
            chooseFolder(for: viewModel, from: newPanel)
        }

        let view = DemoProjectsView(viewModel: viewModel, onDone: { dismiss() })
        newPanel.contentViewController = NSHostingController(rootView: view)
        newPanel.setContentSize(NSSize(width: 760, height: 600))
        panel = newPanel

        if let host {
            hostWindow = host
            host.beginSheet(newPanel) { _ in
                MainActor.assumeIsolated {
                    panel = nil
                    hostWindow = nil
                }
            }
        } else {
            // No window to hang a sheet on (all windows closed): show it on its own.
            newPanel.styleMask.insert(.miniaturizable)
            newPanel.center()
            newPanel.makeKeyAndOrderFront(nil)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: newPanel,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    panel = nil
                    hostWindow = nil
                }
            }
        }
        logger.info("Presented Demo Projects (\(viewModel.projects.count) projects)")
    }

    static func dismiss() {
        guard let panel else { return }
        if let hostWindow {
            hostWindow.endSheet(panel)
        } else {
            panel.close()
        }
        self.panel = nil
        self.hostWindow = nil
    }

    private static func frontWindow() -> NSWindow? {
        hostWindow(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    /// The window the sheet attaches to: the key window, else the main
    /// window, else none, and the sheet then opens as a window of its own.
    ///
    /// There used to be a last fallback to the first visible window in
    /// `NSApp.windows`. With the app in the background there is no key or main
    /// window, so that fallback hung the sheet on whichever project window
    /// happened to be first in the list, often not the one the user was
    /// looking at.
    static func hostWindow(keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
        if let keyWindow, isEligibleHost(keyWindow) {
            return keyWindow
        }
        if let mainWindow, isEligibleHost(mainWindow) {
            return mainWindow
        }
        return nil
    }

    private static func isEligibleHost(_ window: NSWindow) -> Bool {
        window.isVisible && window.attachedSheet == nil && !(window is NSPanel)
    }

    private static func chooseFolder(for viewModel: DemoProjectsViewModel, from window: NSWindow) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Demo Projects Folder"
        openPanel.message = "Choose the folder where demo projects are saved."
        openPanel.prompt = "Choose"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = viewModel.installDirectory.deletingLastPathComponent()
        openPanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = openPanel.url else { return }
            MainActor.assumeIsolated {
                viewModel.setInstallDirectory(url)
            }
        }
    }
}
