// AssemblyConfigurationViewController.swift - NSViewController wrapper for assembly configuration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import SwiftUI
import os.log

/// Logger for assembly configuration view controller operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "AssemblyConfigurationViewController")

// MARK: - AssemblyConfigurationViewController

/// NSViewController that hosts the SwiftUI AssemblyConfigurationView.
///
/// This controller serves as a bridge between AppKit's sheet presentation
/// and the SwiftUI assembly configuration interface.
///
/// ## Usage
///
/// ```swift
/// let controller = AssemblyConfigurationViewController(algorithm: .spades)
/// controller.onAssemblyComplete = { outputURL in
///     // Handle completed assembly
/// }
/// window.beginSheet(controller.window!)
/// ```
@MainActor
public class AssemblyConfigurationViewController: NSViewController {

    // MARK: - Properties

    /// The initial algorithm to pre-select (nil for auto)
    private let initialAlgorithm: AssemblyAlgorithm?

    /// The SwiftUI hosting view
    private var hostingView: NSHostingView<AssemblyConfigurationView>!

    /// View model for the assembly configuration
    private var viewModel: AssemblyConfigurationViewModel!

    /// Callback when assembly completes successfully
    public var onAssemblyComplete: ((URL) -> Void)?

    /// Callback when assembly fails
    public var onAssemblyFailed: ((String) -> Void)?

    /// Callback when user cancels configuration
    public var onCancel: (() -> Void)?

    // MARK: - Initialization

    /// Creates a new assembly configuration view controller.
    ///
    /// - Parameter algorithm: Optional initial algorithm to pre-select
    public init(algorithm: AssemblyAlgorithm? = nil) {
        self.initialAlgorithm = algorithm
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        viewModel = AssemblyConfigurationViewModel()

        // Set initial algorithm if specified
        if let algorithm = initialAlgorithm {
            viewModel.algorithm = algorithm
        }

        // Wire up callbacks
        viewModel.onAssemblyComplete = { [weak self] outputURL in
            self?.handleAssemblyComplete(outputURL)
        }

        viewModel.onAssemblyFailed = { [weak self] error in
            self?.handleAssemblyFailed(error)
        }

        viewModel.onCancel = { [weak self] in
            self?.handleCancel()
        }

        // Create the SwiftUI view
        let configView = AssemblyConfigurationView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: configView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 650, height: 600)

        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("Assembly configuration view loaded")
    }

    // MARK: - Callback Handlers

    private func handleAssemblyComplete(_ outputURL: URL) {
        logger.info("Assembly completed: \(outputURL.path, privacy: .public)")
        onAssemblyComplete?(outputURL)
    }

    private func handleAssemblyFailed(_ error: String) {
        logger.error("Assembly failed: \(error, privacy: .public)")
        onAssemblyFailed?(error)
    }

    private func handleCancel() {
        logger.info("Assembly configuration cancelled")

        // Dismiss the sheet
        dismissSheet()

        // Call the cancel callback
        onCancel?()
    }

    // MARK: - Sheet Management

    /// Dismisses the sheet if presented as one.
    private func dismissSheet() {
        guard let window = view.window else { return }

        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }
}

// MARK: - AssemblySheetPresenter

/// Helper for presenting assembly configuration sheets.
///
/// Provides a clean API for showing the assembly configuration
/// as a sheet from any window.
@MainActor
public struct AssemblySheetPresenter {

    /// Presents the assembly configuration sheet.
    ///
    /// - Parameters:
    ///   - window: The parent window to attach the sheet to
    ///   - algorithm: Optional pre-selected algorithm
    ///   - onComplete: Called when assembly completes
    ///   - onFailed: Called when assembly fails
    ///   - onCancel: Called when user cancels
    public static func present(
        from window: NSWindow,
        algorithm: AssemblyAlgorithm? = nil,
        onComplete: ((URL) -> Void)? = nil,
        onFailed: ((String) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let controller = AssemblyConfigurationViewController(algorithm: algorithm)

        controller.onAssemblyComplete = { outputURL in
            onComplete?(outputURL)
        }

        controller.onAssemblyFailed = { error in
            onFailed?(error)
        }

        controller.onCancel = {
            onCancel?()
        }

        // Create the sheet window
        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.title = "Sequence Assembly"
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.isReleasedWhenClosed = false

        // Present as sheet
        window.beginSheet(sheetWindow) { response in
            logger.info("Assembly sheet dismissed with response: \(response.rawValue)")
        }
    }
}
