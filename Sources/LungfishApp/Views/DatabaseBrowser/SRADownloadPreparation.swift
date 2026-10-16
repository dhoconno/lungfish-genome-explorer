// SRADownloadPreparation.swift - Cancellable metadata and import settings before the SRA CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

extension DatabaseBrowserViewModel {
    func prepareSRADownload(records: [SearchResultRecord], operationID: UUID) {
        // Resolve ownership before dismissing the browser. An explicit route must
        // never fall through to another project's key window.
        let window: NSWindow?
        if let routeContext {
            window = AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?.window
        } else {
            let key = NSApp.keyWindow
            window = downloadPresentationWindow ?? key?.sheetParent ?? NSApp.mainWindow ?? key
        }
        SRADownloadPreparation(model: self, records: records, operationID: operationID, window: window).start()
    }

    /// The operation-history line for a lookup that could not detect the import settings, in three
    /// sentences with no colon. The reason is the error's own text, so it is cut to end in exactly
    /// one period whether the error ended in one, in several or in none. A reason that ends in `?`
    /// or `!` keeps its mark, and an empty one leaves its sentence out.
    static func sraOutageLine(reason: String) -> String {
        var sentence = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = sentence.last, last == "." || last.isWhitespace { sentence.removeLast() }
        if let last = sentence.last, last != "?", last != "!" { sentence += "." }
        return ["Could not detect SRA import settings.", sentence, "Choose the settings manually."]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
private final class SRADownloadPreparation {
    let model: DatabaseBrowserViewModel
    let records: [SearchResultRecord]
    let operationID: UUID
    let window: NSWindow?
    var lookupTask: Task<Void, Never>?
    var sheet: NSWindow?
    var closeObserver: NSObjectProtocol?
    var finished = false

    init(model: DatabaseBrowserViewModel, records: [SearchResultRecord], operationID: UUID, window: NSWindow?) {
        self.model = model
        self.records = records
        self.operationID = operationID
        self.window = window
    }

    func start() {
        report("Looking up SRA run metadata...")
        let task = Task { await prepare() }
        lookupTask = task
        OperationCenter.shared.setCancelCallback(for: operationID) {
            task.cancel()
            performOnMainRunLoop { self.cancel() }
        }
        if let window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                performOnMainRunLoop { self?.cancel() }
            }
        }
    }

    private var canContinue: Bool {
        !finished && !Task.isCancelled
            && OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running
    }

    private func prepare() async {
        guard canContinue else { cancel(); return }
        guard let window else {
            finish()
            OperationCenter.shared.fail(
                id: operationID,
                detail: "Cannot show SRA import settings because the download window is unavailable. Open the database browser again and retry.")
            return
        }
        var platform: LungfishIO.SequencingPlatform = .unknown
        var paired = false
        var bytes: Int64?
        do {
            let outcome = try await SRARunMetadataLookup(ena: model.enaService, ncbi: model.ncbiService)
                .lookUpRuns([records[0].accession])
            guard canContinue else { cancel(); return }
            if let notice = outcome.notice {
                OperationCenter.shared.log(id: operationID, level: .info, message: notice)
            }
            if let read = outcome.runs.first?.enaRecord {
                platform = LungfishIO.SequencingPlatform(vendor: read.instrumentPlatform ?? "")
                paired = read.libraryLayout?.uppercased() == "PAIRED"
                bytes = read.totalFileSizeBytes.map { Int64($0) }
            } else if let run = outcome.runs.first?.ncbiRun {
                platform = LungfishIO.SequencingPlatform(vendor: run.platform ?? "")
                paired = run.libraryLayout?.uppercased() == "PAIRED"
                bytes = run.size.map { Int64($0) * 1_000_000 }
            }
        } catch {
            guard canContinue, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { cancel(); return }
            // Metadata is optional. Keep the existing manual settings fallback,
            // but make its reason visible in the operation history.
            OperationCenter.shared.log(
                id: operationID, level: .info,
                message: DatabaseBrowserViewModel.sraOutageLine(reason: error.localizedDescription))
        }
        guard canContinue else { cancel(); return }
        let pairs = records.map {
            FASTQFilePair(r1: URL(fileURLWithPath: "/\($0.accession)_1.fastq.gz"),
                          r2: paired ? URL(fileURLWithPath: "/\($0.accession)_2.fastq.gz") : nil)
        }
        let detectedPlatform = platform
        let controller = FASTQImportConfigSheet(
            pairs: pairs, detectedPlatform: platform,
            summaryOverride: FASTQImportConfigSheet.downloadSummary(
                pairs: pairs, knownDownloadBytes: records.count == 1 ? bytes : nil),
            onImport: { [self] config in
                guard canContinue else { cancel(); return }
                finish()
                model.startSRADownloadTask(
                    records: records, importConfig: config.namingArchivePlatform(detectedPlatform),
                    downloadCenterTaskID: operationID, totalCount: records.count)
            },
            onCancel: { [self] in cancel() })
        let settings = NSWindow(contentViewController: controller)
        settings.title = "Import FASTQ"
        settings.styleMask = [.titled, .closable]
        settings.isReleasedWhenClosed = false
        sheet = settings
        report("Waiting for SRA import settings...")
        model.onDownloadStarted?()
        guard canContinue else { cancel(); return }
        window.beginSheet(settings) { [self] _ in
            // Also covers a sheet closed without pressing one of its buttons.
            cancel()
        }
    }

    private func report(_ message: String) {
        OperationCenter.shared.update(id: operationID, progress: 0, detail: message)
        OperationCenter.shared.log(id: operationID, level: .info, message: message)
    }

    private func cancel() {
        guard !finished else { return }
        lookupTask?.cancel()
        let settings = sheet
        finish()
        if let settings, let parent = settings.sheetParent { parent.endSheet(settings) }
        OperationCenter.shared.acknowledgeCancellation(id: operationID)
    }

    private func finish() {
        finished = true
        model.isDownloading = false
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        sheet = nil
        lookupTask = nil
    }
}
