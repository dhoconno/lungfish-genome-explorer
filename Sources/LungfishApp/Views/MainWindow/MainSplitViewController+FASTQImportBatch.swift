// MainSplitViewController+FASTQImportBatch.swift - Imports the samples of one Import FASTQ sheet in turn
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

extension MainSplitViewController {
    /// Imports multiple FASTQ file pairs using the same user-configured settings.
    func importFASTQBatchWithConfig(
        pairs: [FASTQFilePair],
        config: FASTQImportConfiguration,
        projectDirectory: URL,
        requestID: String?
    ) {
        guard let viewerController = self.viewerController else { return }

        // The sheet's Pairing popup decides whether a detected R1/R2 pair is
        // one sample or two; before 2026-09-24 the choice was stored and
        // never read, so Single-end still imported the pair.
        let effectivePairs = FASTQFilePair.applying(pairingMode: config.pairingMode, to: pairs)

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, pair) in effectivePairs.enumerated() {
                await self.importFASTQPair(
                    pair: pair, index: index, totalPairs: effectivePairs.count,
                    config: config, projectDirectory: projectDirectory,
                    viewerController: viewerController, requestID: requestID
                )
            }
        }
    }

    /// Imports a single FASTQ pair, resolving duplicates via sheet if needed.
    ///
    /// The duplicate check targets the CLI's real output location
    /// (`FASTQBatchImporter.bundleOutputURL`, i.e. `<project>/Imports/<name>.lungfishfastq`),
    /// not `<projectDirectory>/<name>.lungfishfastq` directly — `projectDirectory`
    /// here is the project root, and checking the root never saw the bundle the
    /// CLI actually wrote, so a second same-named import silently replaced the
    /// first bundle and its derivatives with `--force`.
    func importFASTQPair(
        pair: FASTQFilePair, index: Int, totalPairs: Int,
        config: FASTQImportConfiguration, projectDirectory: URL,
        viewerController: ViewerViewController, requestID: String?
    ) async {
        let baseName = pair.sampleName
        var effectiveBundleName = baseName
        var forceReplace = false

        func destinationURL(forName name: String) -> URL {
            FASTQBatchImporter.bundleOutputURL(
                for: SamplePair(sampleName: name, r1: pair.r1, r2: pair.r2),
                in: projectDirectory
            )
        }

        var bundleURL = destinationURL(forName: effectiveBundleName)

        // Check for an existing bundle at the CLI's real destination.
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            let resolution = await showDuplicateFileDialog(filename: bundleURL.lastPathComponent)
            switch resolution {
            case .replace:
                // Pass --force only after the user explicitly chose Replace.
                // The CLI (not this code) performs the actual replacement, so
                // an existing bundle is never deleted here ahead of time.
                forceReplace = true
            case .keepBoth:
                var counter = 2
                var uniqueName = "\(baseName) \(counter)"
                while FileManager.default.fileExists(atPath: destinationURL(forName: uniqueName).path) {
                    counter += 1
                    uniqueName = "\(baseName) \(counter)"
                }
                effectiveBundleName = uniqueName
                bundleURL = destinationURL(forName: effectiveBundleName)
            case .skip:
                displayGenomicsFile(url: bundleURL)
                postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: true, error: nil)
                return
            }
        }

        let progressMessage = totalPairs > 1
            ? "Importing \(index + 1) of \(totalPairs): \(pair.r1.lastPathComponent)\u{2026}"
            : "Importing \(pair.r1.lastPathComponent)\u{2026}"
        viewerController.showProgress(progressMessage)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            FASTQIngestionService.ingestAndBundle(
                pair: pair,
                projectDirectory: projectDirectory,
                bundleName: effectiveBundleName,
                importConfig: config,
                forceReplace: forceReplace,
                routeContext: operationRouteContext
            ) { [weak self, weak viewerController] result in
                defer { continuation.resume() }
                switch result {
                case .success(let bundleURL):
                    viewerController?.hideProgress()
                    self?.sidebarController.requestReloadFromFilesystem()
                    self?.displayGenomicsFile(url: bundleURL)
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: true, error: nil)
                case .failure(let error):
                    viewerController?.hideProgress()
                    mainSplitLogger.error("importFASTQBatch: \(error)")
                    self?.postSidebarFileDropCompleted(requestID: requestID, sourceURL: pair.r1, success: false, error: error.localizedDescription)
                    guard !(error is CancellationError) else { return }
                    let alert = NSAlert()
                    alert.messageText = "Failed to Import FASTQ"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.applyLungfishBranding()
                    if let window = self?.view.window ?? NSApp.keyWindow {
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    // MARK: - Duplicate File Handling

    /// Shows a dialog asking the user how to handle a duplicate file
    func showDuplicateFileDialog(filename: String) async -> DuplicateResolution {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "A file named \"\(filename)\" already exists in this location. What would you like to do?"
        alert.alertStyle = .warning

        alert.addButton(withTitle: "Replace")    // First button = index 1000
        alert.addButton(withTitle: "Keep Both")  // Second button = index 1001
        alert.addButton(withTitle: "Skip")       // Third button = index 1002

        alert.applyLungfishBranding()

        guard let window = self.view.window ?? NSApp.keyWindow else { return .skip }
        let response = await alert.beginSheetModal(for: window)

        switch response {
        case .alertFirstButtonReturn:  // Replace
            return .replace
        case .alertSecondButtonReturn: // Keep Both
            return .keepBoth
        default:                       // Skip or Cancel
            return .skip
        }
    }
}
