// DemoProjectsSheetController.swift - Presents Help > Demo Projects…
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DemoProjects")

/// Presents the Demo Projects sheet on the frontmost window, or as a small
/// window of its own when no window is open. Never a modal session.
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
        if let key = NSApp.keyWindow, key.isVisible, key.attachedSheet == nil, !(key is NSPanel) {
            return key
        }
        if let main = NSApp.mainWindow, main.isVisible, main.attachedSheet == nil {
            return main
        }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.attachedSheet == nil && !($0 is NSPanel) }
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
