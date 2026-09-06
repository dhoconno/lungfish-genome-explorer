// ProjectLockResolutionDialog.swift - Resolve a shared-project lock before opening
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
enum ProjectLockResolutionDialog {
    enum Choice: Equatable, Sendable {
        case readOnly, cancel, recover
    }

    static func choose(for state: ProjectOpenWarningState, on window: NSWindow?) async -> Choice {
        await resolve(for: state) { alert in
            let presentation = AlertPresentation(alert: alert, window: window)
            return await withTaskCancellationHandler {
                await presentation.run()
            } onCancel: {
                Task { @MainActor in
                    presentation.cancel()
                }
            }
        }
    }

    /// Keeps the two-stage decision separate from AppKit's sheet lifetime.
    static func resolve(
        for state: ProjectOpenWarningState,
        present: (NSAlert) async -> NSApplication.ModalResponse
    ) async -> Choice {
        guard !Task.isCancelled else { return .cancel }
        let response = await present(makeAlert(for: state))
        guard !Task.isCancelled else { return .cancel }
        let selected = choice(for: response, state: state)
        guard selected == .recover, state.lockStatus != .stale else { return selected }
        let confirmation = await present(makeRecoveryConfirmation(for: state))
        guard !Task.isCancelled else { return .cancel }
        return recoveryChoice(for: confirmation)
    }

    static func makeAlert(for state: ProjectOpenWarningState) -> NSAlert {
        let alert = NSAlert()
        if let project = state.projectURL {
            alert.messageText = "“\(project.deletingPathExtension().lastPathComponent)” may already be open"
        } else {
            alert.messageText = "This project may already be open"
        }
        switch state.lockStatus {
        case .active:
            alert.informativeText = "Another session is using this project. You can open it read-only to inspect it. Close the other session and try again to make changes."
        case .corrupted:
            alert.informativeText = "The project's lock information is damaged, so Lungfish cannot tell whether another session is using it. Open it read-only, or recover the lock after confirming the project is closed everywhere else."
        case .stale:
            alert.informativeText = "A previous session appears to have ended, but its lock remains. Open the project read-only, or recover the lock to resume editing."
        case .unknown, nil:
            if state.lockRecord != nil {
                alert.informativeText = "Lungfish could not confirm whether a previous session is still using this project. Open it read-only, or recover the lock after confirming the project is closed everywhere else."
            } else {
                alert.informativeText = "Lungfish could not read the project's lock information. You can open it read-only. Check that the project storage is available, then try again to make changes."
            }
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Read-Only").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if canRecover(state) {
            alert.addButton(withTitle: "Recover and Open").keyEquivalent = ""
        }
        alert.accessoryView = ownerDetails(for: state)
        alert.applyLungfishBranding()
        return alert
    }

    static func choice(for response: NSApplication.ModalResponse, state: ProjectOpenWarningState) -> Choice {
        switch response {
        case .alertFirstButtonReturn: return .readOnly
        case .alertThirdButtonReturn where canRecover(state): return .recover
        default: return .cancel
        }
    }

    static func makeRecoveryConfirmation(for state: ProjectOpenWarningState) -> NSAlert {
        let alert = NSAlert()
        let name = state.projectURL?.deletingPathExtension().lastPathComponent ?? "this project"
        alert.messageText = "Recover access to “\(name)”?"
        alert.informativeText = "Before continuing, ensure this project is closed in other Lungfish versions, in the CLI, and on other computers. Recovering a lock while another session is writing can damage the project. Lungfish will retain an archive of the existing lock for review."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Recover and Open").keyEquivalent = ""
        alert.applyLungfishBranding()
        return alert
    }

    static func recoveryChoice(for response: NSApplication.ModalResponse) -> Choice {
        response == .alertSecondButtonReturn ? .recover : .cancel
    }

    private static func canRecover(_ state: ProjectOpenWarningState) -> Bool {
        state.lockStatus != .active && (state.lockRecord != nil || state.lockStatus == .corrupted)
    }

    private static func ownerDetails(for state: ProjectOpenWarningState) -> NSTextField {
        var lines: [String] = []
        if let record = state.lockRecord {
            lines.append("Session: \(record.toolName) \(record.appVersion)")
            lines.append("Owner: \(record.user) on \(record.host) · Process \(record.pid)")
            lines.append("Lock created: \(record.createdAt.isEmpty ? "Unknown" : record.createdAt)")
        }
        if let project = state.projectURL { lines.append("Project: \(project.path)") }
        if let error = state.readErrorDescription, !error.isEmpty { lines.append("Details: \(error)") }
        let field = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        field.isSelectable = true
        field.isEditable = false
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 420
        field.setAccessibilityLabel("Project lock details")
        let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 420, height: 10_000)) ?? .zero
        field.frame = NSRect(x: 0, y: 0, width: 420, height: max(40, ceil(size.height)))
        return field
    }

    @MainActor
    private final class AlertPresentation {
        let alert: NSAlert
        weak var window: NSWindow?

        init(alert: NSAlert, window: NSWindow?) {
            self.alert = alert
            self.window = window
        }

        func run() async -> NSApplication.ModalResponse {
            guard !Task.isCancelled else { return .abort }
            if let window {
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response)
                    }
                }
            }
            return alert.runModal()
        }

        func cancel() {
            if let window, alert.window.sheetParent === window {
                window.endSheet(alert.window, returnCode: .abort)
            } else if NSApp.modalWindow === alert.window {
                NSApp.abortModal()
            }
        }
    }
}
