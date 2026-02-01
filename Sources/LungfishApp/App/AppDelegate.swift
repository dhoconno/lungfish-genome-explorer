// AppDelegate.swift - Application lifecycle management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// Main application delegate handling app lifecycle and global state.
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {

    /// The shared application delegate instance
    public static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// Main window controller for the application
    private var mainWindowController: MainWindowController?

    // MARK: - Application Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Create and show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Configure application appearance
        configureAppearance()

        // Register for system notifications
        registerNotifications()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Save application state
        saveApplicationState()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even when all windows are closed (standard macOS behavior)
        return false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon is clicked
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    // MARK: - File Handling

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Handle opening files via Finder or drag-drop to dock
        let url = URL(fileURLWithPath: filename)
        return openDocument(at: url)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Handle opening multiple files
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            _ = openDocument(at: url)
        }
    }

    // MARK: - Private Methods

    private func configureAppearance() {
        // Use system appearance (respects Dark Mode)
        // No custom appearance overrides - follow HIG
    }

    private func registerNotifications() {
        // Register for relevant system notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // Handle window close events
    }

    private func saveApplicationState() {
        // Persist user preferences and window state
        UserDefaults.standard.synchronize()
    }

    private func openDocument(at url: URL) -> Bool {
        // TODO: Implement document opening
        // For now, just return true to indicate we handled it
        print("Opening document: \(url.path)")
        return true
    }

    // MARK: - Menu Actions

    @IBAction func newDocument(_ sender: Any?) {
        // Create new project/document
        mainWindowController?.showWindow(nil)
    }

    @IBAction func openDocument(_ sender: Any?) {
        // Show open panel
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "fa")!,
            .init(filenameExtension: "fasta")!,
            .init(filenameExtension: "fna")!,
            .init(filenameExtension: "gb")!,
            .init(filenameExtension: "gbk")!,
            .init(filenameExtension: "gff")!,
            .init(filenameExtension: "gff3")!,
        ]

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    _ = self.openDocument(at: url)
                }
            }
        }
    }

    @IBAction func showPreferences(_ sender: Any?) {
        // Show preferences window (will be SwiftUI Settings scene)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
