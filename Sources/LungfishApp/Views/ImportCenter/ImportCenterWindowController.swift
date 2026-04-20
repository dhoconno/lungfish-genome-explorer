// ImportCenterWindowController.swift - Import Center window for data import workflows
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import os.log

/// Logger for the Import Center window.
private let logger = Logger(subsystem: LogSubsystem.app, category: "ImportCenter")

/// NSWindowController that hosts the Import Center SwiftUI view.
///
/// Provides a singleton window for importing sequencing data, alignments,
/// variants, classification results, reference sequences, and metadata into the
/// current project. Follows the same lazy singleton pattern used by
/// ``PluginManagerWindowController``.
///
/// The content area is a SwiftUI ``ImportCenterView`` wrapped in an
/// ``NSHostingView`` and uses in-window sidebar navigation instead of
/// titlebar controls.
///
/// ## Usage
///
/// ```swift
/// ImportCenterWindowController.show()
/// ImportCenterWindowController.show(tab: .classificationResults)
/// ```
@MainActor
public final class ImportCenterWindowController: NSWindowController {

    /// Shared singleton instance. Created on first call to ``show()``.
    private static var shared: ImportCenterWindowController?

    /// The SwiftUI view model, retained for toolbar-to-view binding.
    private let viewModel = ImportCenterViewModel()

    // MARK: - Singleton Access

    /// Shows the Import Center window, creating it if needed.
    ///
    /// Reuses the singleton window if it already exists. Centers the
    /// window on first display.
    public static func show() {
        showWindow(tab: nil)
    }

    /// Shows the Import Center window and switches to the specified tab.
    ///
    /// - Parameter tab: The tab to display. Pass `.classificationResults`
    ///   to navigate directly to the classification import view.
    static func show(tab: ImportCenterViewModel.Tab) {
        showWindow(tab: tab)
    }

    /// Closes the Import Center window if it is visible.
    static func close() {
        shared?.window?.close()
    }

    /// Internal implementation shared by both `show()` overloads.
    private static func showWindow(tab: ImportCenterViewModel.Tab?) {
        if shared == nil {
            shared = ImportCenterWindowController()
        }
        if let tab {
            shared?.viewModel.selectedTab = tab
        }
        shared?.showWindow(nil)
    }

    // MARK: - Initialization

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Import Center"
        window.identifier = NSUserInterfaceItemIdentifier(ImportCenterAccessibilityID.window)
        window.minSize = NSSize(width: 640, height: 400)
        window.setFrameAutosaveName("ImportCenterWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false

        super.init(window: window)

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupContent() {
        guard let window else { return }
        let hostingView = NSHostingView(rootView: ImportCenterView(viewModel: viewModel))
        window.contentView = hostingView
    }

    // MARK: - Window Lifecycle

    override public func showWindow(_ sender: Any?) {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        logger.info("Import Center window shown")
    }
}
