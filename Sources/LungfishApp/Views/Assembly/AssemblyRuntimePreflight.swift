// AssemblyRuntimePreflight.swift - Run-click validation for managed assembly tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

@MainActor
enum AssemblyRuntimePreflight {
    enum PresentationMode: Equatable {
        case sheet
        case applicationErrorPresentation
    }

    static func warningTitle(for tool: AssemblyTool) -> String {
        "Cannot Run \(tool.displayName)"
    }

    static func warningMessage(
        for request: AssemblyRunRequest,
        statusProvider: PluginPackStatusProviding = PluginPackStatusService.shared
    ) async -> String? {
        do {
            _ = try ManagedAssemblyPipeline.buildCommand(for: request)
        } catch {
            return error.localizedDescription
        }

        guard let packStatus = await statusProvider.status(forPackID: "assembly"),
              let toolStatus = packStatus.toolStatuses.first(where: { $0.requirement.id == request.tool.rawValue }) else {
            return nil
        }

        if toolStatus.storageUnavailablePath != nil {
            return "Managed assembly storage is unavailable for \(request.tool.displayName)."
        }
        if !toolStatus.environmentExists {
            return "Install the Genome Assembly pack to enable \(request.tool.displayName)."
        }
        if !toolStatus.missingExecutables.isEmpty {
            return "Reinstall the Genome Assembly pack to restore \(request.tool.displayName)."
        }
        if let smokeTestFailure = toolStatus.smokeTestFailure,
           !smokeTestFailure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return smokeTestFailure
        }

        return nil
    }

    static func presentWarning(
        message: String,
        for tool: AssemblyTool,
        on window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = warningTitle(for: tool)
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.applyLungfishBranding()

        if presentationMode(hasWindow: window != nil) == .sheet, let window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(PreflightWarning(title: alert.messageText, message: alert.informativeText))
        }
    }

    static func presentationMode(hasWindow: Bool) -> PresentationMode {
        hasWindow ? .sheet : .applicationErrorPresentation
    }

    static func presentationModeForTest(hasWindow: Bool) -> PresentationMode {
        presentationMode(hasWindow: hasWindow)
    }

    private struct PreflightWarning: LocalizedError {
        let title: String
        let message: String

        var errorDescription: String? { title }
        var recoverySuggestion: String? { message }
    }
}
