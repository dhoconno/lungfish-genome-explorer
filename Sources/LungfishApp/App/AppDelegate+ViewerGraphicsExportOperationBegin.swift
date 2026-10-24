// AppDelegate+ViewerGraphicsExportOperationBegin.swift - The Operations row of the viewer image export of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishKit
import LungfishOperations
import LungfishWorkflow

/// What the pane shows, as File > Export > Image reads it (UX ruling Q-G2 items 2 and 3).
enum ViewerGraphicsExportContent: Equatable {
    /// The sequence viewer shows this reference bundle, so the export runs `bundle export-graphic` behind a row.
    case referenceBundle(URL)
    /// The sequence viewer shows a document that is not a bundle, which keeps its captures (O18, V1-3).
    case document
    /// Any other view or an empty pane, which keeps the capture of the whole pane alone (O18).
    case other
}

/// The state of the pane that decides its content, read from the viewer when the panel opens.
struct ViewerGraphicsExportPaneState: Equatable {
    /// The bundle the pane draws, from `ViewerViewController.drawnReferenceBundle`, which reads the display route.
    var bundleURL: URL?
    /// The content mode of the viewer that draws, a reference viewport's embedded viewer or the pane's own viewer.
    var contentMode: ViewportContentMode
    /// False when another view hides the viewer that draws, such as an MSA, a tree or a classifier result.
    var sequenceViewShown: Bool
    /// True while the VCF dataset or FASTA collection view of a document fills the pane.
    var documentDashboardShown: Bool
    /// True when the sequence viewer holds a loaded document.
    var hasDocument: Bool
}

/// The words of an alert of the image export, as a value a test reads (UX ruling Q-G2 items 4 and 5).
struct ViewerGraphicsExportAlert: Equatable {
    let title: String
    let message: String
    let isFailure: Bool

    /// The kept capture's success alert, word for word as before.
    static func captured(fileName: String) -> Self {
        Self(title: "Export Successful", message: "Successfully exported 1 graphic to \(fileName).", isFailure: false)
    }

    /// A failed capture or a failed leaf run, where `message` is the error's or the runner failure's message.
    static func failed(_ message: String) -> Self {
        Self(title: "Export Failed", message: "Failed to export viewer graphics: \(message)", isFailure: true)
    }

    /// Selected Region of a bundle with no selection inside the visible window when Save is pressed.
    static let noSelectedRegion = Self(
        title: "Export Failed", message: "No selected region is available for export.", isFailure: true
    )
}

/// The title and details of the export's row (UX ruling Q-G2 item 1).
struct ViewerGraphicsExportRowWords: Equatable {
    let title: String
    let detail: String
    let completionDetail: String
}

/// Selected Region was chosen with no user selection left inside the visible window.
struct ViewerGraphicsExportNoSelection: Error, Equatable {}

/// File > Export > Image (PNG) and Image (PDF) of a reference bundle run `lungfish-cli bundle export-graphic` behind an
/// Operations row (Phase 2.13 lane 13.30, owner rows O17 and O18). Other content keeps its capture of the screen,
/// which runs no leaf, begins no row and writes no record (O18, V1-3). This file holds the content check, the scope
/// list, the settings the app passes, the row and the alert words, since AppDelegate+ImportCenter.swift may not grow.
extension AppDelegate {
    /// What the pane shows. A bundle is shown when the display route draws one in a sequence viewer that fills the
    /// pane, since `contentMode` alone cannot tell (ARCH condition 1, UX item 2, 2.14 obs-11).
    static func viewerGraphicsExportContent(of state: ViewerGraphicsExportPaneState) -> ViewerGraphicsExportContent {
        if state.documentDashboardShown { return .document }
        guard state.contentMode == .genomics, state.sequenceViewShown else { return .other }
        if let bundleURL = state.bundleURL { return .referenceBundle(bundleURL) }
        return state.hasDocument ? .document : .other
    }

    /// The pane state of `viewer` at this moment. The bundle, the mode and the shown sequence view are those of the
    /// viewer that draws, which for a `.lungfishref` or a mapping result from the sidebar is the reference viewport's
    /// embedded viewer, while `viewer` keeps `.mapping` with its own sequence view hidden (2.14 lane OBS11).
    static func viewerGraphicsExportPaneState(of viewer: ViewerViewController) -> ViewerGraphicsExportPaneState {
        let drawn = viewer.drawnReferenceBundle
        let drawing = drawn?.viewer ?? viewer
        return ViewerGraphicsExportPaneState(
            bundleURL: drawn?.url,
            contentMode: drawing.contentMode,
            sequenceViewShown: !drawing.viewerView.isHidden,
            documentDashboardShown: viewer.children.contains {
                $0 is VCFDatasetViewController || $0 is FASTACollectionViewController
            },
            hasDocument: viewer.currentDocument != nil
        )
    }

    /// The Scope menu for what `viewer` shows, the one function that gives the list for a bundle, a document and
    /// other content (UX items 2 and 3). A bundle's selection is read from the viewer that draws it.
    static func viewerGraphicsExportScopes(
        viewerController viewer: ViewerViewController
    ) -> (content: ViewerGraphicsExportContent, scopes: [ViewerExportScope]) {
        let content = viewerGraphicsExportContent(of: viewerGraphicsExportPaneState(of: viewer))
        let view = (viewer.drawnReferenceBundle?.viewer ?? viewer).viewerView!
        let scopes = viewerGraphicsExportScopes(
            for: content, hasSelection: view.selectionRange?.isEmpty == false,
            isUserSelection: view.isUserColumnSelection
        )
        return (content, scopes)
    }

    /// The list for one content. A bundle offers Selected Region only for a selection the user made, since the
    /// viewport also sets `selectionRange` (BIO ruling Q-G3 section 4). A document keeps today's rule.
    static func viewerGraphicsExportScopes(
        for content: ViewerGraphicsExportContent, hasSelection: Bool, isUserSelection: Bool
    ) -> [ViewerExportScope] {
        switch content {
        case .referenceBundle:
            return [.tracks, .rulerAndTracks] + (hasSelection && isUserSelection ? [.selectedRegion] : [])
        case .document:
            return [.tracks, .fullViewer] + (hasSelection ? [.selectedRegion] : [])
        case .other:
            return [.fullViewer]
        }
    }

    /// The theme the app passes, the theme on screen (UX item 6).
    static func viewerGraphicsExportTheme(for appearance: NSAppearance) -> ViewerGraphicExport.Theme {
        ViewerFigureTheme.resolved(for: appearance) == .dark ? .dark : .light
    }

    /// A 0-based window as the 1-based closed `--region` value, `<Int(start) + 1>-<ceil(end)>` with no commas, the
    /// end kept within the contig.
    static func viewerGraphicsExportRegion(contig: String, start: Double, end: Double, length: Int) -> String {
        let last = min(Int(end.rounded(.up)), length)
        return "\(contig):\(Int(max(0, start)) + 1)-\(last)"
    }

    /// The leaf's settings for one scope (BIO ruling Q-G3 items 2, 3 and 6, UX item 6). Tracks and Ruler and Tracks
    /// pass the visible window at the view's width. Selected Region passes the user's selection clipped to that
    /// window at its width at the current zoom, as the capture clipped its rect, and throws
    /// ``ViewerGraphicsExportNoSelection`` when none is left.
    static func viewerGraphicsExportSettings(
        scope: ViewerExportScope,
        format: ViewerGraphicFormat,
        bitmapScale: CGFloat,
        frame: ReferenceFrame,
        boundsWidth: CGFloat,
        userSelection: Range<Int>?,
        appearance: NSAppearance,
        alignment: (excludeFlags: UInt16, coverageScale: CoverageScaleMode)?
    ) throws -> ViewerGraphicExport.Settings {
        let figureFormat: ViewerFigureFormat
        switch format {
        case .png: figureFormat = .png
        case .jpeg: figureFormat = .jpeg
        case .tiff: figureFormat = .tiff
        case .pdf: figureFormat = .pdf
        }
        var settings = ViewerGraphicExport.Settings(
            format: figureFormat,
            scale: format.isVector ? nil : Int(bitmapScale),
            theme: viewerGraphicsExportTheme(for: appearance),
            excludeFlags: alignment?.excludeFlags,
            coverageScale: alignment?.coverageScale
        )
        guard scope == .selectedRegion else {
            settings.region = viewerGraphicsExportRegion(
                contig: frame.chromosome, start: frame.start, end: frame.end, length: frame.sequenceLength
            )
            settings.width = Double(boundsWidth)
            settings.includeRuler = scope == .rulerAndTracks
            return settings
        }
        guard let selection = userSelection, !selection.isEmpty else { throw ViewerGraphicsExportNoSelection() }
        let lower = max(Double(selection.lowerBound), frame.start)
        let upper = min(Double(selection.upperBound), frame.end)
        guard upper > lower else { throw ViewerGraphicsExportNoSelection() }
        let rawStartX = frame.screenPosition(for: Double(selection.lowerBound))
        let rawEndX = frame.screenPosition(for: Double(selection.upperBound))
        let minX = max(frame.leadingInset, min(rawStartX, rawEndX))
        let maxX = min(max(frame.leadingInset, boundsWidth - frame.trailingInset), max(rawStartX, rawEndX))
        settings.region = viewerGraphicsExportRegion(
            contig: frame.chromosome, start: lower, end: upper, length: frame.sequenceLength
        )
        settings.width = Double(max(1, maxX - minX))
        return settings
    }

    /// The row's words. `<region>` is the `--region` value of the row's own arguments, character for character.
    static func viewerGraphicsExportRowWords(
        arguments: [String], bundleName: String, outputURL: URL
    ) -> ViewerGraphicsExportRowWords {
        let flag = arguments.firstIndex(of: ViewerGraphicExport.Option.region.flag)
        let region = flag.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ""
        let file = outputURL.lastPathComponent
        return ViewerGraphicsExportRowWords(
            title: "Export Image",
            detail: "Writing \(file) from \(bundleName), \(region)",
            completionDetail: "Exported \(file)"
        )
    }

    /// The alert a finished leaf run shows. The completed row is the end, so a completed or cancelled run shows none
    /// (UX item 5).
    static func viewerGraphicsExportEndAlert(_ outcome: CLIViewerExportRunner.Outcome) -> ViewerGraphicsExportAlert? {
        guard case .failed(let failure) = outcome else { return nil }
        return .failed(failure.message)
    }

    /// Begins the Operations row of one image export and runs `lungfish-cli bundle export-graphic` for it on the
    /// shared viewer export runner (ARCH ruling 1.5, rules 3 and 4).
    ///
    /// The row records the command the runner runs, both built from `invocation`, so the row and the leaf's record
    /// name one command. The row takes no lock. The leaf writes the image and its record, and the app writes no byte
    /// after it exits. A failure fails the row and reaches `onFailure`. A cancel reads Cancelled and shows nothing.
    ///
    /// - Parameters:
    ///   - invocation: The leaf's invocation, from ``ViewerGraphicExport/invocation(bundleURL:settings:outputURL:force:emitsEvents:)``.
    ///   - bundleName: The bundle's name, which the row's detail shows.
    ///   - runner: The runner the leaf runs on. The row's cancel callback is its `cancel()`.
    ///   - reporter: Where the row begins.
    ///   - environmentAdditions: Variables for the leaf's environment, for tests. No production caller passes any.
    ///   - onFailure: Called on the main actor when the leaf failed.
    /// - Returns: The row's id and the task that runs the leaf and settles the row, or nil when the row did not start.
    @discardableResult
    static func beginViewerGraphicsExportOperation(
        invocation: ViewerExportInvocation,
        bundleName: String,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared,
        environmentAdditions: [String: String] = [:],
        onFailure: @escaping @MainActor @Sendable (CLIViewerExportRunner.Failure) -> Void
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let arguments = invocation.arguments()
        let outputURL = URL(fileURLWithPath: invocation.output)
        let words = viewerGraphicsExportRowWords(arguments: arguments, bundleName: bundleName, outputURL: outputURL)
        let start = reporter.begin(
            title: words.title,
            detail: words.detail,
            operationType: .export,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: invocation.commandPath.joined(separator: " "),
                args: Array(arguments.dropFirst(invocation.commandPath.count))
            ),
            onCancel: { runner.cancel() }
        )
        guard case .started(let operationID) = start else { return nil }
        return (operationID, Task { @MainActor in
            let outcome = await runner.run(
                arguments: arguments,
                outputURL: outputURL,
                operationID: operationID,
                completionDetail: words.completionDetail,
                environmentAdditions: environmentAdditions
            )
            if case .failed(let failure) = outcome {
                onFailure(failure)
            }
            return outcome
        })
    }

    /// The panel's Save. A bundle runs the leaf behind its row, and other content keeps its capture with today's
    /// words, which begins no row (UX item 4). A test passes `presentAlert`, `runner` and `reporter`.
    @discardableResult
    func finishViewerGraphicsExport(
        viewerController: ViewerViewController,
        content: ViewerGraphicsExportContent,
        scope: ViewerExportScope,
        format: ViewerGraphicFormat,
        bitmapScale: CGFloat,
        outputURL: URL,
        presentAlert: (@MainActor @Sendable (ViewerGraphicsExportAlert) -> Void)? = nil,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let present: @MainActor @Sendable (ViewerGraphicsExportAlert) -> Void = presentAlert ?? { [weak self] alert in
            self?.showViewerGraphicsExportAlert(alert)
        }
        guard case .referenceBundle(let bundleURL) = content else {
            let alert: ViewerGraphicsExportAlert
            do {
                let data = try viewerExportData(
                    viewerController: viewerController, scope: scope, format: format, bitmapScale: bitmapScale
                )
                try data.write(to: outputURL, options: .atomic)
                alert = .captured(fileName: outputURL.lastPathComponent)
            } catch {
                alert = .failed(error.localizedDescription)
            }
            present(alert)
            return nil
        }
        return Self.startViewerGraphicsExport(
            viewerController: viewerController, bundleURL: bundleURL, scope: scope, format: format,
            bitmapScale: bitmapScale, outputURL: outputURL, present: present, runner: runner, reporter: reporter
        )
    }

    /// Builds the leaf's invocation from the view of the viewer that draws the bundle, writes `view-state.json` and
    /// begins the row. The window, the selection and the read settings are that viewer's (2.14 lane OBS11).
    private static func startViewerGraphicsExport(
        viewerController: ViewerViewController,
        bundleURL: URL,
        scope: ViewerExportScope,
        format: ViewerGraphicFormat,
        bitmapScale: CGFloat,
        outputURL: URL,
        present: @escaping @MainActor @Sendable (ViewerGraphicsExportAlert) -> Void,
        runner: CLIViewerExportRunner,
        reporter: any OperationReporting
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        let drawing = viewerController.drawnReferenceBundle?.viewer ?? viewerController
        let view = drawing.viewerView!
        guard let frame = drawing.referenceFrame else {
            present(.failed("No viewer is currently available for export."))
            return nil
        }
        let drawsAlignment = drawing.currentReferenceBundle?.manifest.alignments.isEmpty == false
        let invocation: ViewerExportInvocation
        do {
            var settings = try Self.viewerGraphicsExportSettings(
                scope: scope, format: format, bitmapScale: bitmapScale, frame: frame,
                boundsWidth: view.bounds.width,
                userSelection: view.isUserColumnSelection ? view.selectionRange : nil,
                appearance: view.effectiveAppearance,
                alignment: drawsAlignment ? (view.excludeFlagsSetting, view.coverageScaleModeSetting) : nil
            )
            settings.viewState = try ViewerGraphicViewState(sampleDisplay: view.sampleDisplayState)
                .write(besideOutput: outputURL).path
            invocation = ViewerGraphicExport.invocation(
                bundleURL: bundleURL, settings: settings, outputURL: outputURL,
                force: FileManager.default.fileExists(atPath: outputURL.path)
            )
        } catch is ViewerGraphicsExportNoSelection {
            present(.noSelectedRegion)
            return nil
        } catch {
            present(.failed(error.localizedDescription))
            return nil
        }
        return beginViewerGraphicsExportOperation(
            invocation: invocation,
            bundleName: drawing.currentBundleDisplayName ?? bundleURL.deletingPathExtension().lastPathComponent,
            runner: runner,
            reporter: reporter,
            onFailure: { failure in
                if let alert = viewerGraphicsExportEndAlert(.failed(failure)) {
                    present(alert)
                }
            }
        )
    }

    /// Shows an alert of the image export on the main window.
    func showViewerGraphicsExportAlert(_ words: ViewerGraphicsExportAlert) {
        let alert = NSAlert()
        alert.messageText = words.title
        alert.informativeText = words.message
        alert.alertStyle = words.isFailure ? .warning : .informational
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }
}
