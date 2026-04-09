// TaxonomyReadExtractionAction.swift — MainActor orchestrator for unified classifier extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

private let logger = Logger(
    subsystem: "com.lungfish.app",
    category: "TaxonomyReadExtractionAction"
)

// MARK: - Test-seam protocols

/// Test seam for presenting `NSAlert` on a window.
@MainActor
public protocol AlertPresenting {
    func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse
}

/// Test seam for presenting an `NSSavePanel`.
@MainActor
public protocol SavePanelPresenting {
    func present(suggestedName: String, on window: NSWindow) async -> URL?
}

/// Test seam for presenting an `NSSharingServicePicker`.
@MainActor
public protocol SharingServicePresenting {
    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge)
}

/// Test seam for writing strings to `NSPasteboard`.
@MainActor
public protocol PasteboardWriting {
    func setString(_ string: String)
}

// MARK: - Default implementations

@MainActor
struct DefaultAlertPresenter: AlertPresenting {
    func present(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
        // macOS 26 rule: use beginSheetModal, never runModal.
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}

@MainActor
struct DefaultSavePanelPresenter: SavePanelPresenting {
    func present(suggestedName: String, on window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

@MainActor
struct DefaultSharingServicePresenter: SharingServicePresenting {
    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge) {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
    }
}

@MainActor
struct DefaultPasteboard: PasteboardWriting {
    func setString(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Filename-safe timestamp helper

internal extension ISO8601DateFormatter {
    /// Short filename-safe UTC timestamp. Produces e.g. `20260409T144521`.
    ///
    /// Used by the `.bundle` destination path to disambiguate back-to-back
    /// extractions when the user left the name at the default value. See
    /// the Phase 2 review-2 forwarded bundle-clobber defense.
    static func shortStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - TaxonomyReadExtractionAction

/// Singleton that presents the unified classifier extraction dialog and
/// orchestrates the resolver → destination → feedback flow.
///
/// Every classifier view controller calls into this class to open the
/// extraction dialog; the dialog's behavior is driven by the `Context` struct
/// and the tool's dispatch class.
@MainActor
public final class TaxonomyReadExtractionAction {

    public static let shared = TaxonomyReadExtractionAction()

    /// Soft cap beyond which the clipboard destination is disabled.
    public static let clipboardReadCap = 10_000

    // MARK: - Context

    public struct Context {
        public let tool: ClassifierTool
        public let resultPath: URL
        public let selections: [ClassifierRowSelector]
        public let suggestedName: String

        public init(
            tool: ClassifierTool,
            resultPath: URL,
            selections: [ClassifierRowSelector],
            suggestedName: String
        ) {
            self.tool = tool
            self.resultPath = resultPath
            self.selections = selections
            self.suggestedName = suggestedName
        }
    }

    // MARK: - Test seams

    var alertPresenter: AlertPresenting = DefaultAlertPresenter()
    var savePanelPresenter: SavePanelPresenting = DefaultSavePanelPresenter()
    var sharingServicePresenter: SharingServicePresenting = DefaultSharingServicePresenter()
    var pasteboard: PasteboardWriting = DefaultPasteboard()
    var resolverFactory: @Sendable () -> ClassifierReadResolver = { ClassifierReadResolver() }

    // MARK: - Initialization

    private init() {}

    // MARK: - Entry point

    /// Opens the unified extraction dialog for the given context.
    ///
    /// Synchronous and non-throwing — all async work happens inside a detached
    /// Task. Errors surface via `NSAlert.beginSheetModal` on `hostWindow`.
    public func present(context: Context, hostWindow: NSWindow) {
        // Implementation in Task 4.3; stub logs so the method is reachable from
        // tests but does nothing visible.
        logger.info("TaxonomyReadExtractionAction.present called for tool=\(context.tool.rawValue, privacy: .public) with \(context.selections.count) selections")
        // Placeholder: Task 4.3 wires up the actual dialog presentation.
    }
}
