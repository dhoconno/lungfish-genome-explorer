// AssemblyRuntimePreflight.swift - Run-click validation for managed assembly tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

@MainActor
enum AssemblyRuntimePreflight {
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

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            // runModal-legacy-allowed because preflight can be invoked before a presenter window exists.
            alert.runModal()
        }
    }
}
