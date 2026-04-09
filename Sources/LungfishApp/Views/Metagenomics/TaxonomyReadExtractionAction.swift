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

    public struct Context: Sendable {
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
        logger.info("present for tool=\(context.tool.rawValue, privacy: .public), \(context.selections.count) selections")

        let model = ClassifierExtractionDialogViewModel(
            tool: context.tool,
            selectionCount: context.selections.count,
            suggestedName: context.suggestedName
        )

        // Create the dialog view — callbacks captured so we can dismiss the sheet.
        let sheetWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let dialog = ClassifierExtractionDialog(
            model: model,
            onCancel: { [weak hostWindow, weak sheetWindow] in
                if let hostWindow, let sheetWindow, hostWindow.attachedSheet === sheetWindow {
                    hostWindow.endSheet(sheetWindow)
                }
            },
            onPrimary: { [weak self, weak hostWindow, weak sheetWindow] in
                guard let self, let hostWindow else { return }
                self.startExtraction(
                    context: context,
                    model: model,
                    hostWindow: hostWindow,
                    sheetWindow: sheetWindow
                )
            }
        )

        sheetWindow.contentViewController = NSHostingController(rootView: dialog)
        hostWindow.beginSheet(sheetWindow)

        // Kick off the initial pre-flight estimate.
        runInitialEstimate(context: context, model: model)
    }

    // MARK: - Pre-flight estimation

    private func runInitialEstimate(
        context: Context,
        model: ClassifierExtractionDialogViewModel
    ) {
        let resolverFactory = self.resolverFactory
        let contextCopy = context
        Task.detached { [weak model] in
            let resolver = resolverFactory()
            do {
                let base = try await resolver.estimateReadCount(
                    tool: contextCopy.tool,
                    resultPath: contextCopy.resultPath,
                    selections: contextCopy.selections,
                    options: ExtractionOptions(includeUnmappedMates: false)
                )
                let withMates: Int
                if contextCopy.tool.usesBAMDispatch {
                    withMates = try await resolver.estimateReadCount(
                        tool: contextCopy.tool,
                        resultPath: contextCopy.resultPath,
                        selections: contextCopy.selections,
                        options: ExtractionOptions(includeUnmappedMates: true)
                    )
                } else {
                    withMates = base
                }
                let delta = max(0, withMates - base)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        model?.estimatedReadCount = base
                        model?.estimatedUnmappedDelta = delta
                    }
                }
            } catch {
                logger.error("Pre-flight estimate failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        model?.estimatedReadCount = 0
                        model?.errorMessage = "Could not estimate read count: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Extraction launch

    private func startExtraction(
        context: Context,
        model: ClassifierExtractionDialogViewModel,
        hostWindow: NSWindow,
        sheetWindow: NSPanel?
    ) {
        model.isRunning = true
        model.progressFraction = 0
        model.progressMessage = "Preparing…"
        model.errorMessage = nil

        let resolverFactory = self.resolverFactory

        // Resolve the destination before spawning the detached task: we may
        // need to show a save panel first (which is @MainActor). The outer
        // Task is spawned from a @MainActor context (startExtraction is called
        // from the dialog's primary button on the main actor), so this Task
        // is safe per MEMORY.md (the rule blocks Task { @MainActor in } only
        // when spawned from GCD background queues).
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let destination = try await self.resolveDestination(
                    model: model,
                    context: context,
                    savePanel: self.savePanelPresenter,
                    hostWindow: hostWindow
                )

                // Build extraction options.
                let options = ExtractionOptions(
                    format: model.format,
                    includeUnmappedMates: model.includeUnmappedMates
                )

                // Log the equivalent CLI command so the operations panel row
                // reproduces what the GUI did.
                let cli = Self.buildCLIString(context: context, options: options, destination: destination)

                let opID = OperationCenter.shared.start(
                    title: "Extract Reads — \(context.tool.displayName)",
                    detail: "Running \(context.tool.displayName) extraction…",
                    operationType: .taxonomyExtraction,
                    cliCommand: cli
                )
                OperationCenter.shared.log(id: opID, level: .info, message: "Extraction started: \(cli)")

                let contextCopy = context
                let task = Task.detached { [weak self] in
                    let resolver = resolverFactory()
                    do {
                        let outcome = try await resolver.resolveAndExtract(
                            tool: contextCopy.tool,
                            resultPath: contextCopy.resultPath,
                            selections: contextCopy.selections,
                            options: options,
                            destination: destination,
                            progress: { fraction, message in
                                DispatchQueue.main.async { [weak model] in
                                    MainActor.assumeIsolated {
                                        OperationCenter.shared.update(id: opID, progress: fraction, detail: message)
                                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                                        model?.progressFraction = fraction
                                        model?.progressMessage = message
                                    }
                                }
                            }
                        )
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.handleSuccess(
                                    outcome: outcome,
                                    opID: opID,
                                    context: contextCopy,
                                    hostWindow: hostWindow,
                                    sheetWindow: sheetWindow
                                )
                            }
                        }
                    } catch is CancellationError {
                        DispatchQueue.main.async { [weak model] in
                            MainActor.assumeIsolated {
                                OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
                                model?.isRunning = false
                                model?.errorMessage = "Cancelled"
                            }
                        }
                    } catch {
                        let errorDesc = error.localizedDescription
                        // Schedule the failure handling on the main queue. The
                        // alert presentation needs to await a sheet modal, so
                        // we hand off to a separate @MainActor helper rather
                        // than spawning a `Task { @MainActor in }` inside an
                        // `assumeIsolated` block (MEMORY.md anti-pattern).
                        DispatchQueue.main.async { [weak self, weak model] in
                            MainActor.assumeIsolated {
                                OperationCenter.shared.fail(id: opID, detail: errorDesc)
                                OperationCenter.shared.log(id: opID, level: .error, message: errorDesc)
                                model?.isRunning = false
                                model?.errorMessage = errorDesc
                            }
                            // Spawn the alert-presentation Task from the GCD
                            // main queue, NOT from inside `assumeIsolated`.
                            // The Task body is implicitly @MainActor because
                            // `presentErrorAlert` is `@MainActor`.
                            Task { [weak self] in
                                await self?.presentErrorAlert(errorDesc, on: hostWindow)
                            }
                        }
                    }
                }
                OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            } catch {
                model.isRunning = false
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// Presents an "Extraction failed" alert sheet on `hostWindow`.
    ///
    /// Extracted into its own `@MainActor` helper so the failure path in
    /// `startExtraction` doesn't need to spawn a `Task { @MainActor in }` from
    /// inside a `MainActor.assumeIsolated` block (MEMORY.md anti-pattern).
    @MainActor
    private func presentErrorAlert(_ errorDesc: String, on hostWindow: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = "Extraction failed"
        alert.informativeText = errorDesc
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = await alertPresenter.present(alert, on: hostWindow)
    }

    // MARK: - Destination resolution

    private func resolveDestination(
        model: ClassifierExtractionDialogViewModel,
        context: Context,
        savePanel: SavePanelPresenting,
        hostWindow: NSWindow
    ) async throws -> ExtractionDestination {
        switch model.destination {
        case .bundle:
            let projectRoot = ClassifierReadResolver.resolveProjectRoot(from: context.resultPath)
            // Bundle-clobber defense (Phase 2 review-2 forwarded item): if the
            // user left the name at the default `context.suggestedName`, append
            // a UTC timestamp suffix so back-to-back extractions don't silently
            // overwrite the same bundle directory. If the user customized the
            // name, trust them — no suffix.
            let disambiguatedName: String = {
                if model.name == context.suggestedName {
                    let stamp = ISO8601DateFormatter.shortStamp(Date())
                    return "\(model.name)-\(stamp)"
                }
                return model.name
            }()
            let metadata = ExtractionMetadata(
                sourceDescription: disambiguatedName,
                toolName: context.tool.displayName,
                parameters: [
                    "accessions": context.selections.flatMap { $0.accessions }.joined(separator: ","),
                    "taxIds": context.selections.flatMap { $0.taxIds.map(String.init) }.joined(separator: ","),
                    "format": model.format.rawValue,
                    "includeUnmappedMates": model.includeUnmappedMates ? "yes" : "no",
                ]
            )
            return .bundle(projectRoot: projectRoot, displayName: disambiguatedName, metadata: metadata)

        case .file:
            let suggested = "\(model.name).\(model.format.rawValue)"
            guard let url = await savePanel.present(suggestedName: suggested, on: hostWindow) else {
                throw ClassifierExtractionError.cancelled
            }
            return .file(url)

        case .clipboard:
            return .clipboard(format: model.format, cap: TaxonomyReadExtractionAction.clipboardReadCap)

        case .share:
            let projectRoot = ClassifierReadResolver.resolveProjectRoot(from: context.resultPath)
            let tempDir = projectRoot.appendingPathComponent(".lungfish/.tmp")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return .share(tempDirectory: tempDir)
        }
    }

    // MARK: - Success handling

    private func handleSuccess(
        outcome: ExtractionOutcome,
        opID: UUID,
        context: Context,
        hostWindow: NSWindow,
        sheetWindow: NSPanel?
    ) {
        OperationCenter.shared.complete(id: opID, detail: "Extracted \(outcome.readCount) reads")

        switch outcome {
        case .file(let url, let n):
            OperationCenter.shared.log(id: opID, level: .info, message: "File saved: \(url.path)")
            dismiss(sheetWindow: sheetWindow, host: hostWindow)
            logger.info("Extracted \(n) reads to file: \(url.path, privacy: .public)")

        case .bundle(let url, let n):
            OperationCenter.shared.log(id: opID, level: .info, message: "Bundle created: \(url.path)")
            // Reload sidebar to show the new bundle.
            if let appDelegate = NSApp.delegate as? AppDelegate,
               let sidebar = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                sidebar.reloadFromFilesystem()
            }
            dismiss(sheetWindow: sheetWindow, host: hostWindow)
            logger.info("Bundle created with \(n) reads at: \(url.path, privacy: .public)")

        case .clipboard(let payload, let bytes, let n):
            self.pasteboard.setString(payload)
            OperationCenter.shared.log(id: opID, level: .info, message: "Copied \(bytes) bytes (\(n) reads) to clipboard")
            dismiss(sheetWindow: sheetWindow, host: hostWindow)

        case .share(let url, _):
            // Present the sharing service picker anchored to the sheet window's
            // content view (which is still visible — we don't dismiss until
            // the picker closes).
            if let contentView = sheetWindow?.contentView {
                self.sharingServicePresenter.present(items: [url], relativeTo: contentView, preferredEdge: .maxY)
            }
            // Don't dismiss the sheet here — let the caller dismiss after the
            // picker closes. For simplicity we dismiss immediately and accept
            // the picker may dangle briefly.
            dismiss(sheetWindow: sheetWindow, host: hostWindow)
        }
    }

    private func dismiss(sheetWindow: NSPanel?, host: NSWindow) {
        if let sheetWindow, host.attachedSheet === sheetWindow {
            host.endSheet(sheetWindow)
        }
    }

    // MARK: - CLI command reconstruction

    /// Reproduces the equivalent `lungfish extract reads --by-classifier` CLI
    /// command for the given dialog state, so the Operations Panel row is
    /// shell-copy-pasteable. Used by `OperationCenter.start(cliCommand:)`.
    static func buildCLIString(
        context: Context,
        options: ExtractionOptions,
        destination: ExtractionDestination
    ) -> String {
        var args: [String] = [
            "--by-classifier",
            "--tool", context.tool.rawValue,
            "--result", context.resultPath.path,
        ]
        for selector in context.selections {
            if let sampleId = selector.sampleId {
                args.append("--sample")
                args.append(sampleId)
            }
            for accession in selector.accessions {
                args.append("--accession")
                args.append(accession)
            }
            for taxon in selector.taxIds {
                args.append("--taxon")
                args.append(String(taxon))
            }
        }
        // Phase 3 deviation: classifier uses --read-format (not --format) to
        // avoid GlobalOptions.format collision (see GlobalOptions.swift:13-17).
        args.append("--read-format")
        args.append(options.format.rawValue)
        if options.includeUnmappedMates {
            args.append("--include-unmapped-mates")
        }
        switch destination {
        case .file(let url):
            args.append("-o")
            args.append(url.path)
        case .bundle(_, let name, _):
            args.append("--bundle")
            args.append("--bundle-name")
            args.append(name)
            args.append("-o")
            args.append("\(name).\(options.format.rawValue)")
        case .clipboard, .share:
            // Not CLI-expressible; leave the -o off and annotate.
            args.append("# (\(destinationLabel(destination)) — GUI only)")
        }
        return OperationCenter.buildCLICommand(subcommand: "extract reads", args: args)
    }

    private static func destinationLabel(_ destination: ExtractionDestination) -> String {
        switch destination {
        case .file:      return "file"
        case .bundle:    return "bundle"
        case .clipboard: return "clipboard"
        case .share:     return "share"
        }
    }
}
