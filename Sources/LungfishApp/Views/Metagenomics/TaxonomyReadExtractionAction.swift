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
    /// Short filename-safe UTC timestamp with a random disambiguator.
    /// Produces e.g. `20260409T144521-k7q2` (20 chars).
    ///
    /// Used by the `.bundle` destination path to disambiguate back-to-back
    /// extractions when the user left the name at the default value. See
    /// the Phase 2 review-2 forwarded bundle-clobber defense.
    ///
    /// The 4-char random base36 suffix is required because the timestamp
    /// alone is second-resolution: two back-to-back Create-Bundle clicks
    /// inside the same wall-clock second would otherwise produce identical
    /// suffixes and the second extraction would silently clobber the first
    /// via `ReadExtractionService.createBundle`'s removeItem + moveItem
    /// (Phase 4 review-1 critical #1).
    static func shortStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date)
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let random = String((0..<4).map { _ in alphabet.randomElement()! })
        return "\(stamp)-\(random)"
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
        #if DEBUG
        // Phase 7 Task 7.2: when `testingCaptureOnly` is set, record the
        // context and return immediately without presenting the real dialog.
        // This short-circuit is BEFORE the re-entrancy guard so tests observe
        // the context even if a prior test left a sheet attached (defense
        // against cross-test pollution).
        if testingCaptureOnly {
            testingCapture.presentCount += 1
            testingCapture.lastContext = context
            return
        }
        #endif

        // Re-entrancy guard (Phase 4 review-1 significant #4). AppKit only
        // supports one sheet per window at a time, so if the host already has
        // a sheet attached, drop this request silently. The user can retry
        // once the current dialog closes.
        if hostWindow.attachedSheet != nil {
            logger.info("Dropping present() — host window already has an attached sheet")
            return
        }

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

        // Box that holds both the in-flight initial-estimate task and the
        // extraction task so the Cancel button can tear down whichever is
        // currently running — the estimate issues up to 2N samtools spawns
        // for BAM tools and the extraction itself runs a full samtools
        // pipeline, neither of which should outlive the dialog (Phase 4
        // review-1 significant #5 + Phase 4 review-2 critical #1).
        let taskBox = TaskBox()

        let dialog = ClassifierExtractionDialog(
            model: model,
            onCancel: { [weak hostWindow, weak sheetWindow, weak model, taskBox] in
                // Surface a visible "Cancelling…" state while the cancel is
                // in flight — the extraction task's progress updates stop
                // immediately on cancellation and the sheet will close from
                // the CancellationError catch branch in startExtraction.
                if let model, model.isRunning {
                    model.progressMessage = "Cancelling..."
                }
                taskBox.estimateTask?.cancel()
                taskBox.extractionTask?.cancel()
                // If no extraction is running (user clicked Cancel before
                // pressing Create Bundle), dismiss the sheet immediately.
                // Otherwise wait for the extraction's catch-CancellationError
                // branch to flip model.isRunning and dismiss the sheet from
                // there — this keeps the dialog on screen until the detached
                // task has actually honored the cancel, so the user doesn't
                // see a stale bundle appear after dismissal.
                if let model, !model.isRunning,
                   let hostWindow, let sheetWindow,
                   hostWindow.attachedSheet === sheetWindow {
                    hostWindow.endSheet(sheetWindow)
                }
            },
            onPrimary: { [weak self, weak hostWindow, weak sheetWindow, taskBox] in
                guard let self, let hostWindow else { return }
                self.startExtraction(
                    context: context,
                    model: model,
                    hostWindow: hostWindow,
                    sheetWindow: sheetWindow,
                    taskBox: taskBox
                )
            }
        )

        sheetWindow.contentViewController = NSHostingController(rootView: dialog)
        hostWindow.beginSheet(sheetWindow)

        // Kick off the initial pre-flight estimate and hold its handle so the
        // dialog's Cancel button can cancel it.
        taskBox.estimateTask = runInitialEstimate(context: context, model: model)
    }

    // MARK: - Pre-flight estimation

    /// Spawns the detached pre-flight estimate task and returns its handle so
    /// the caller can cancel it when the dialog is dismissed
    /// (Phase 4 review-1 significant #5).
    ///
    /// `Context` is `Sendable` (deviation #7), so the struct is captured
    /// directly by the detached closure without a local copy.
    @discardableResult
    private func runInitialEstimate(
        context: Context,
        model: ClassifierExtractionDialogViewModel
    ) -> Task<Void, Never> {
        let resolverFactory = self.resolverFactory
        return Task.detached { [weak model] in
            let resolver = resolverFactory()
            do {
                let base = try await resolver.estimateReadCount(
                    tool: context.tool,
                    resultPath: context.resultPath,
                    selections: context.selections,
                    options: ExtractionOptions(includeUnmappedMates: false)
                )
                let withMates: Int
                if context.tool.usesBAMDispatch {
                    withMates = try await resolver.estimateReadCount(
                        tool: context.tool,
                        resultPath: context.resultPath,
                        selections: context.selections,
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
            } catch is CancellationError {
                // Dialog dismissed before the estimate finished — drop silently.
                return
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
        sheetWindow: NSPanel?,
        taskBox: TaskBox
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

                // `Context` is Sendable (deviation #7), so the outer variable
                // is captured directly by the detached closure — no local copy.
                let task = Task.detached { [weak self] in
                    let resolver = resolverFactory()
                    do {
                        let outcome = try await resolver.resolveAndExtract(
                            tool: context.tool,
                            resultPath: context.resultPath,
                            selections: context.selections,
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
                                    context: context,
                                    hostWindow: hostWindow,
                                    sheetWindow: sheetWindow
                                )
                            }
                        }
                    } catch is CancellationError {
                        DispatchQueue.main.async { [weak model, weak hostWindow, weak sheetWindow] in
                            MainActor.assumeIsolated {
                                OperationCenter.shared.fail(
                                    id: opID,
                                    detail: "Cancelled by user",
                                    errorMessage: "Cancelled by user"
                                )
                                model?.isRunning = false
                                model?.errorMessage = "Cancelled"
                                // Dismiss the sheet now that the detached
                                // task has honored the cancel — the dialog's
                                // onCancel closure deferred dismissal to this
                                // branch so the user doesn't see a stale
                                // bundle appear after clicking Cancel
                                // (Phase 4 review-2 critical #1).
                                if let hostWindow, let sheetWindow,
                                   hostWindow.attachedSheet === sheetWindow {
                                    hostWindow.endSheet(sheetWindow)
                                }
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
                                OperationCenter.shared.fail(
                                    id: opID,
                                    detail: errorDesc,
                                    errorMessage: errorDesc
                                )
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
                // Store the task handle on the shared box so the dialog's
                // Cancel button can cancel it (Phase 4 review-2 critical #1),
                // and register the same cancellation with the Operations
                // Panel row.
                taskBox.extractionTask = task
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
            // Present the sharing service picker, anchored to the sheet's
            // content view when possible, falling back to the host window's
            // content view when the sheet has already been torn down. Logging
            // a warning in the nil-nil case ensures we never silently no-op
            // the user's Share click (Phase 4 review-1 significant #2).
            let anchor: NSView? = sheetWindow?.contentView ?? hostWindow.contentView
            if let anchor {
                self.sharingServicePresenter.present(items: [url], relativeTo: anchor, preferredEdge: .maxY)
            } else {
                logger.warning("Cannot present share picker — no content view anchor available")
            }
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
    /// shell-copy-pasteable.
    ///
    /// **Note on bundle names** (Phase 4 review-2 significant #3): when the
    /// user left the bundle name at the default `suggestedName`, the
    /// orchestrator appended a collision-safe random suffix
    /// (`-yyyyMMddTHHmmss-XXXX`) via `ISO8601DateFormatter.shortStamp` before
    /// passing the destination here. That suffix is then embedded in the
    /// `--bundle-name` arg of the reconstructed command. A user who copies
    /// the command and re-runs it later will get a bundle named with
    /// yesterday's timestamp, because the CLI itself has no default-name
    /// disambiguator. That's intentional: the copy-pasteable command is a
    /// faithful record of what the GUI did, not a recipe for reproducing
    /// the default-name behavior. If you want a recipe, pass
    /// `--bundle-name` explicitly yourself.
    ///
    /// Used by `OperationCenter.start(cliCommand:)`.
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

    // MARK: - Test-only seams

    #if DEBUG
    /// Test-only access to `resolveDestination` for exercising the bundle
    /// disambiguator without going through the full dialog lifecycle.
    /// Used by `ClassifierExtractionDialogTests` to pin the
    /// "user-rename-to-collision" branch behavior.
    func resolveDestinationForTesting(
        model: ClassifierExtractionDialogViewModel,
        context: Context
    ) async throws -> ExtractionDestination {
        // Create a throwaway host window. For the `.bundle` branch the save
        // panel is never invoked, so this is only a structural placeholder.
        let fakeHost = NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        return try await resolveDestination(
            model: model,
            context: context,
            savePanel: self.savePanelPresenter,
            hostWindow: fakeHost
        )
    }

    /// Test-only capture struct for observing `present()` calls without
    /// actually presenting a dialog. Used by `ClassifierExtractionMenuWiringTests`
    /// to assert the VC → menu → orchestrator Context propagation.
    public struct TestingCapture {
        public var lastContext: Context?
        public var presentCount: Int = 0

        public init() {}
    }

    /// Test-only: records the most recent `present()` call's context when
    /// `testingCaptureOnly` is set.
    public var testingCapture: TestingCapture = TestingCapture()

    /// Test-only: when `true`, `present()` records the context and returns
    /// immediately WITHOUT presenting the real dialog. The test is responsible
    /// for resetting this in `tearDown`.
    public var testingCaptureOnly: Bool = false
    #endif
}

// MARK: - TaskBox

extension TaxonomyReadExtractionAction {

    /// Main-actor-isolated holder for the in-flight pre-flight estimate and
    /// main extraction task handles.
    ///
    /// Used by `TaxonomyReadExtractionAction.present` to hand both task handles
    /// to the dialog's Cancel closure so either the pre-flight work or the
    /// full extraction can be torn down when the user dismisses the dialog.
    ///
    /// **Why both?** Phase 4 review-1 significant #5 only caught the estimate
    /// case and added a single-task holder. Phase 4 review-2 critical #1
    /// caught the larger problem: the `Task.detached` inside `startExtraction`
    /// is ALSO detached from the dialog, so the dialog's Cancel during
    /// `isRunning == true` needs to cancel that task too — otherwise the
    /// extraction continues in the background and produces an orphaned bundle
    /// via `handleSuccess`. The spec explicitly requires this at design doc
    /// line 278: "Cancel stays enabled and routes to the underlying Task's
    /// cancellation."
    ///
    /// **Lifetime**: the box is created in `present()` and captured by value
    /// (reference) by the dialog's `onCancel` closure and the `onPrimary`
    /// closure. When the sheet closes and the dialog view hierarchy releases
    /// its closures, the box is released with the closures — no explicit
    /// clear needed under ARC.
    @MainActor
    final class TaskBox {
        var estimateTask: Task<Void, Never>?
        var extractionTask: Task<Void, Never>?
    }
}
