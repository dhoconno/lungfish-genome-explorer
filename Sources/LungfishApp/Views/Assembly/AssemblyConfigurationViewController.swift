// AssemblyConfigurationViewController.swift - NSViewController wrapper for SPAdes assembly
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import os.log

/// Logger for assembly configuration view controller operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "AssemblyConfigurationViewController")

// MARK: - AssemblyConfigurationViewController

/// NSViewController that hosts the SwiftUI AssemblyConfigurationView.
///
/// Input files and output directory are provided at init time by the caller.
@MainActor
public class AssemblyConfigurationViewController: NSViewController {

    // MARK: - Properties

    private let inputFiles: [URL]
    private let outputDirectory: URL?
    private var hostingView: NSHostingView<AssemblyConfigurationView>!
    private var viewModel: AssemblyConfigurationViewModel!

    /// Callback when user cancels configuration
    public var onCancel: (() -> Void)?

    // MARK: - Initialization

    /// Creates a new assembly configuration view controller.
    ///
    /// - Parameters:
    ///   - inputFiles: FASTQ file URLs to assemble
    ///   - outputDirectory: Directory for assembly output (e.g. project's Assemblies/)
    public init(inputFiles: [URL], outputDirectory: URL?) {
        self.inputFiles = inputFiles
        self.outputDirectory = outputDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        viewModel = AssemblyConfigurationViewModel(
            inputFiles: inputFiles,
            outputDirectory: outputDirectory
        )

        viewModel.onCancel = { [weak self] in
            self?.handleCancel()
        }

        viewModel.onDismiss = { [weak self] in
            self?.dismissSheet()
        }

        let configView = AssemblyConfigurationView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: configView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 550, height: 520)

        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("Assembly configuration view loaded with \(self.inputFiles.count) files")
    }

    // MARK: - Callback Handlers

    private func handleCancel() {
        logger.info("Assembly configuration cancelled")
        dismissSheet()
        onCancel?()
    }

    // MARK: - Sheet Management

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

/// Helper for presenting the SPAdes assembly configuration sheet.
@MainActor
public struct AssemblySheetPresenter {

    /// Presents the SPAdes assembly configuration sheet.
    ///
    /// Assembly progress is tracked via ``OperationCenter`` and survives
    /// sheet dismissal. Completed bundles are delivered through
    /// ``OperationCenter/onBundleReady``.
    ///
    /// - Parameters:
    ///   - window: The parent window to attach the sheet to
    ///   - inputFiles: FASTQ file URLs to assemble
    ///   - outputDirectory: Directory for assembly output
    ///   - onCancel: Called when user cancels
    public static func present(
        from window: NSWindow,
        inputFiles: [URL],
        outputDirectory: URL?,
        onCancel: (() -> Void)? = nil
    ) {
        let controller = AssemblyConfigurationViewController(
            inputFiles: inputFiles,
            outputDirectory: outputDirectory
        )

        controller.onCancel = {
            onCancel?()
        }

        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.title = "Assemble with SPAdes"
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.isReleasedWhenClosed = false

        window.beginSheet(sheetWindow) { response in
            logger.info("Assembly sheet dismissed with response: \(response.rawValue)")
        }
    }
}
