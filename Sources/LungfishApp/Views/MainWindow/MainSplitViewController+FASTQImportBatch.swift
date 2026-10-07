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
            // The bundles this sheet's samples wrote. The duplicate dialog
            // never offers to replace one, so no sample of the sheet takes the
            // place of another's bundle, the rule `import fastq` keeps
            // whatever --force says.
            var written = FASTQBatchImporter.BundlesWrittenByThisImport()
            for (index, pair) in effectivePairs.enumerated() {
                let bundleURL = await self.importFASTQPair(
                    pair: pair, index: index, totalPairs: effectivePairs.count,
                    config: config, projectDirectory: projectDirectory,
                    viewerController: viewerController, requestID: requestID,
                    bundlesWrittenByThisBatch: written
                )
                if let bundleURL { written.insert(bundleURL) }
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
    ///
    /// A bundle in `bundlesWrittenByThisBatch` came from an earlier sample of
    /// the same sheet, so its dialog offers Keep Both and Skip, never Replace.
    /// Returns the bundle the import wrote, or nil.
    @discardableResult
    func importFASTQPair(
        pair: FASTQFilePair, index: Int, totalPairs: Int,
        config: FASTQImportConfiguration, projectDirectory: URL,
        viewerController: ViewerViewController, requestID: String?,
        bundlesWrittenByThisBatch: FASTQBatchImporter.BundlesWrittenByThisImport = .init()
    ) async -> URL? {
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
            let resolution = await showDuplicateFileDialog(
                filename: bundleURL.lastPathComponent,
                offeringReplace: !bundlesWrittenByThisBatch.contains(bundleURL)
            )
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
                postSidebarFileDropCompleted(requestID: requestID, sample: pair, success: true, error: nil)
                return nil
            }
        }

        let progressMessage = totalPairs > 1
            ? "Importing \(index + 1) of \(totalPairs): \(pair.r1.lastPathComponent)\u{2026}"
            : "Importing \(pair.r1.lastPathComponent)\u{2026}"
        viewerController.showProgress(progressMessage)

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            FASTQIngestionService.ingestAndBundle(
                pair: pair,
                projectDirectory: projectDirectory,
                bundleName: effectiveBundleName,
                importConfig: config,
                forceReplace: forceReplace,
                routeContext: operationRouteContext
            ) { [weak self, weak viewerController] result in
                defer { continuation.resume(returning: try? result.get()) }
                switch result {
                case .success(let bundleURL):
                    viewerController?.hideProgress()
                    self?.sidebarController.requestReloadFromFilesystem()
                    self?.displayGenomicsFile(url: bundleURL)
                    self?.postSidebarFileDropCompleted(requestID: requestID, sample: pair, success: true, error: nil)
                case .failure(let error):
                    viewerController?.hideProgress()
                    mainSplitLogger.error("importFASTQBatch: \(error)")
                    self?.postSidebarFileDropCompleted(
                        requestID: requestID, sample: pair, success: false, error: error.localizedDescription
                    )
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

    /// Posts the drop completion of every file of a sample. A request that
    /// tracks each dropped file, such as File > Import, finishes only when
    /// each file has one, and posting it for R1 alone left a pair's request,
    /// and its activity indicator, open after the import ended.
    func postSidebarFileDropCompleted(requestID: String?, sample: FASTQFilePair, success: Bool, error: String?) {
        for url in Self.sidebarDropCompletionURLs(of: sample) {
            postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: success, error: error)
        }
    }

    /// The dropped files one sample's import completes.
    nonisolated static func sidebarDropCompletionURLs(of sample: FASTQFilePair) -> [URL] {
        sample.inputFiles
    }

    /// Shows a dialog asking the user how to handle a duplicate file.
    /// Without `offeringReplace` the bundle came from an earlier sample of
    /// the same import, and the dialog offers Keep Both and Skip only.
    func showDuplicateFileDialog(filename: String, offeringReplace: Bool = true) async -> DuplicateResolution {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = offeringReplace
            ? "A file named \"\(filename)\" already exists in this location. What would you like to do?"
            : "An earlier sample of this import created \"\(filename)\". Keep both, or skip this sample?"
        alert.alertStyle = .warning
        let choices = Self.duplicateFileChoices(offeringReplace: offeringReplace)
        for choice in choices {
            alert.addButton(withTitle: choice.title)
        }

        alert.applyLungfishBranding()

        guard let window = self.view.window ?? NSApp.keyWindow else { return .skip }
        let response = await alert.beginSheetModal(for: window)
        // Buttons answer from alertFirstButtonReturn on, in order. Cancel skips.
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index].resolution : .skip
    }

    /// The duplicate dialog's buttons, in order. Replace is offered only
    /// for a bundle from another import, never for one an earlier sample of
    /// the same import wrote.
    nonisolated static func duplicateFileChoices(
        offeringReplace: Bool
    ) -> [(title: String, resolution: DuplicateResolution)] {
        (offeringReplace ? [("Replace", DuplicateResolution.replace)] : [])
            + [("Keep Both", .keepBoth), ("Skip", .skip)]
    }
}
