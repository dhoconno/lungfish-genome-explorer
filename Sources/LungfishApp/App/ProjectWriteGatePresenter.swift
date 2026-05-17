// ProjectWriteGatePresenter.swift - AppKit presentation for read-only project write gates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
enum ProjectWriteGatePresenter {
    enum PresentationMode: Equatable {
        case sheet
        case applicationErrorPresentation
    }

    struct Warning: LocalizedError, Equatable {
        let title: String
        let message: String

        var errorDescription: String? { title }
        var recoverySuggestion: String? { message }
    }

    static let title = "Project Is Open Read Only"

    static func presentBlockedWrite(
        workflowName: String,
        on presentingWindow: NSWindow?
    ) {
        let alert = makeAlert(workflowName: workflowName)
        let window = presentingWindow ?? NSApp.keyWindow

        if presentationMode(hasPresentationWindow: window != nil) == .sheet, let window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(warning(workflowName: workflowName))
        }
    }

    static func makeAlert(workflowName: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message(workflowName: workflowName)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.applyLungfishBranding()
        return alert
    }

    static func presentationMode(hasPresentationWindow: Bool) -> PresentationMode {
        hasPresentationWindow ? .sheet : .applicationErrorPresentation
    }

    static func message(workflowName: String) -> String {
        "\(workflowName) writes files into the project. Close the other writer or reopen the project after the lock is released before running this workflow."
    }

    static func warning(workflowName: String) -> Warning {
        Warning(title: title, message: message(workflowName: workflowName))
    }

    static func makeAlertForTest(workflowName: String) -> NSAlert {
        makeAlert(workflowName: workflowName)
    }

    static func presentationModeForTest(hasPresentationWindow: Bool) -> PresentationMode {
        presentationMode(hasPresentationWindow: hasPresentationWindow)
    }

    static func noWindowWarningForTest(workflowName: String) -> Warning {
        warning(workflowName: workflowName)
    }
}
