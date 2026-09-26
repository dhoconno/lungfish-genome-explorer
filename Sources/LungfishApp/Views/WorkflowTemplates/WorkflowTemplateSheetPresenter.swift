// WorkflowTemplateSheetPresenter.swift - Presents the save and run workflow template sheets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import LungfishWorkflow
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "WorkflowTemplateSheetPresenter")

/// Presents the workflow template sheets on a main window, the same way
/// `AssemblySheetPresenter` and the NAO-MGS import sheet do: an `NSPanel`
/// hosting a SwiftUI view, attached with `beginSheet`, never `runModal`.
@MainActor
enum WorkflowTemplateSheetPresenter {

    /// Shows "Save as Workflow Template…" for a Kraken2 analysis folder.
    ///
    /// Extraction refusals become a "Can't Save a Workflow Template" alert
    /// naming the reason; the sheet only appears when the template can be
    /// built.
    static func presentSave(
        from window: NSWindow,
        analysisURL: URL,
        projectURL: URL?,
        sourceTitle: String,
        routeContext: OperationRouteContext?,
        service: WorkflowTemplateRunService = WorkflowTemplateRunService()
    ) {
        let extraction: AnalysisTemplateExtractor.Extraction
        do {
            extraction = try service.extract(analysisURL: analysisURL, projectURL: projectURL)
        } catch {
            logger.error("presentSave: cannot build a template from \(analysisURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Can't Save a Workflow Template"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return
        }

        let panel = makePanel(title: "Save as Workflow Template")
        var sheet = SaveWorkflowTemplateSheet(extraction: extraction, sourceTitle: sourceTitle)
        sheet.onCancel = {
            window.endSheet(panel)
        }
        sheet.onSave = { name in
            window.endSheet(panel)
            var template = extraction.template
            template.name = name
            do {
                let saved = try service.saveTemplate(template, sourceAnalysisURL: analysisURL, routeContext: routeContext)
                logger.info("presentSave: saved template to \(saved.fileURL.path, privacy: .public)")
            } catch {
                let alert = NSAlert()
                alert.messageText = "Workflow Template Not Saved"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        }
        panel.contentViewController = NSHostingController(rootView: sheet)
        panel.setContentSize(NSSize(width: 560, height: 540))
        window.beginSheet(panel)
    }

    /// Shows "Run Workflow Template…" for the open project.
    static func presentRun(
        from window: NSWindow,
        projectURL: URL,
        routeContext: OperationRouteContext?,
        preselectedTemplateURL: URL? = nil,
        service: WorkflowTemplateRunService = WorkflowTemplateRunService()
    ) {
        let entries = service.templateLibrary.list()
        let model = RunWorkflowTemplateSheetModel(
            entries: entries,
            projectURL: projectURL,
            preselectedEntryID: preselectedTemplateURL?.standardizedFileURL.path,
            preflight: { request in await service.preflight(request) }
        )

        let panel = makePanel(title: "Run Workflow Template")
        var sheet = RunWorkflowTemplateSheet(model: model)
        sheet.onCancel = {
            window.endSheet(panel)
        }
        sheet.onRun = { request in
            window.endSheet(panel)
            Task { @MainActor in
                do {
                    _ = try await service.run(request, routeContext: routeContext)
                } catch AnalysisTemplateRunError.preflightFailed(let issues) {
                    let alert = NSAlert()
                    alert.messageText = "Workflow Template Can't Run"
                    alert.informativeText = issues.joined(separator: "\n")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: window) { _ in }
                } catch {
                    // Step failures are already reported on the Operations panel row.
                    logger.error("presentRun: template run failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        panel.contentViewController = NSHostingController(rootView: sheet)
        panel.setContentSize(NSSize(width: 600, height: 620))
        window.beginSheet(panel)
    }

    private static func makePanel(title: String) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = title
        panel.isReleasedWhenClosed = false
        return panel
    }
}
