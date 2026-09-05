// AppDelegate+SequenceMenu.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3
import os
import LungfishKit

extension AppDelegate {
    // MARK: - SequenceMenuActions

    @objc func reverseComplement(_ sender: Any?) {
        guard let viewerView = activeMainWindowController(sender: sender)?
            .mainSplitViewController?
            .activeFullSequenceViewerController?
            .viewerView else {
            showAlert(title: "No Viewer", message: "Open a sequence to use Reverse Complement.")
            return
        }
        viewerView.runSelectedSequenceFASTAOperation(toolID: .reverseComplement)
    }

    @objc func translate(_ sender: Any?) {
        guard let viewerView = activeMainWindowController(sender: sender)?
            .mainSplitViewController?
            .activeFullSequenceViewerController?
            .viewerView else {
            showAlert(title: "No Viewer", message: "Open a sequence to use Translate.")
            return
        }
        viewerView.runSelectedSequenceFASTAOperation(toolID: .translate)
    }


    @objc func goToPosition(_ sender: Any?) {
        // Ensure we have a viewer controller
        guard let originController = activeMainWindowController(sender: sender),
              let viewerController = originController.mainSplitViewController?.activeFullSequenceViewerController else {
            showAlert(title: "No Viewer", message: "No sequence viewer is available.")
            return
        }
        // Ensure a sequence is loaded
        guard viewerController.referenceFrame != nil else {
            showAlert(title: "No Sequence", message: "Please load a sequence before navigating to a position.")
            return
        }

#if DEBUG
        if let input = goToPositionInputForTesting {
            let result = parseAndNavigate(input: input, viewerController: viewerController)
            if !result.success {
                showAlert(
                    title: "Navigation Error",
                    message: result.errorMessage ?? "Failed to navigate to the specified position."
                )
            }
            return
        }
#endif

        // Show go-to-position dialog
        let alert = NSAlert()
        alert.messageText = "Go to Location"
        alert.informativeText = "Enter a genomic position or region.\n\nSupported formats:\n  1000 (position)\n  chr1:1000 (chromosome:position)\n  chr1:1000-2000 (range with hyphen)\n  chr1:1000..2000 (range with dots)"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.placeholderString = "e.g., 1000 or chr1:1000-2000"
        alert.accessoryView = textField

        // Make the text field first responder
        alert.window.initialFirstResponder = textField

        guard let window = originController.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                let input = textField.stringValue.trimmingCharacters(in: .whitespaces)

                guard !input.isEmpty else {
                    showAlert(title: "Invalid Input", message: "Please enter a position or range.")
                    return
                }

                // Parse the input and navigate
                let result = parseAndNavigate(input: input, viewerController: viewerController)
                if !result.success {
                    showAlert(title: "Navigation Error", message: result.errorMessage ?? "Failed to navigate to the specified position.")
                }
            }
        }
    }

    @objc func goToGene(_ sender: Any?) {
        // Ensure we have a viewer controller with annotations loaded
        guard let originController = activeMainWindowController(sender: sender),
              let viewerController = originController.mainSplitViewController?.activeFullSequenceViewerController else {
            showAlert(title: "No Viewer", message: "No sequence viewer is available.")
            return
        }
        guard viewerController.referenceFrame != nil else {
            showAlert(title: "No Sequence", message: "Please load a sequence before searching for genes.")
            return
        }

        guard let searchIndex = viewerController.annotationSearchIndex else {
            showAlert(title: "No Annotations", message: "No annotation data is loaded. Import a genome bundle with annotations first.")
            return
        }

        // Show go-to-gene dialog
        let alert = NSAlert()
        alert.messageText = "Go to Gene"
        alert.informativeText = "Enter a gene name or symbol to navigate to its location."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.placeholderString = "e.g., BRCA1 or TP53"
        alert.accessoryView = textField

        // Make the text field first responder
        alert.window.initialFirstResponder = textField

        guard let window = originController.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                let query = textField.stringValue.trimmingCharacters(in: .whitespaces)

                guard !query.isEmpty else {
                    showAlert(title: "Invalid Input", message: "Please enter a gene name.")
                    return
                }

                let results = await searchIndex.searchOffMain(query: query, limit: 50)
                guard let match = preferredGeneSearchResult(
                    from: results,
                    query: query,
                    currentChromosome: viewerController.referenceFrame?.chromosome
                        ?? viewerController.viewerView.activeSequence?.name
                        ?? viewerController.viewerView.sequence?.name
                ) else {
                    showAlert(title: "Gene Not Found", message: "No annotation matching \"\(query)\" was found in the current dataset.")
                    return
                }

                let success = navigateSequenceViewer(
                    viewerController,
                    chromosome: match.chromosome,
                    start: match.start,
                    end: match.end
                )

                if success {
                    debugLog("goToGene: Navigated to \(match.name) at \(match.chromosome):\(match.start)-\(match.end)")
                } else {
                    showAlert(title: "Navigation Error", message: "Could not navigate to \(match.name) at \(match.chromosome):\(match.start)-\(match.end).")
                }
            }
        }
    }

    func preferredGeneSearchResult(
        from results: [AnnotationSearchIndex.SearchResult],
        query: String,
        currentChromosome: String?
    ) -> AnnotationSearchIndex.SearchResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactMatches = results.filter { result in
            isExactGeneSearchMatch(result, query: trimmedQuery)
        }
        if let match = bestGeneSearchResult(from: exactMatches, currentChromosome: currentChromosome) {
            return match
        }
        if let match = bestGeneSearchResult(from: results, currentChromosome: currentChromosome) {
            return match
        }
        return results.first
    }

    private func bestGeneSearchResult(
        from results: [AnnotationSearchIndex.SearchResult],
        currentChromosome: String?
    ) -> AnnotationSearchIndex.SearchResult? {
        if let currentChromosome,
           let currentGeneMatch = results.first(where: {
               !$0.isVariant
                   && $0.type.caseInsensitiveCompare("gene") == .orderedSame
                   && chromosomesMatchForSequenceMenu($0.chromosome, currentChromosome)
           }) {
            return currentGeneMatch
        }
        if let geneMatch = results.first(where: {
            !$0.isVariant && $0.type.caseInsensitiveCompare("gene") == .orderedSame
        }) {
            return geneMatch
        }
        if let currentChromosome,
           let currentMatch = results.first(where: {
               !$0.isVariant && chromosomesMatchForSequenceMenu($0.chromosome, currentChromosome)
           }) {
            return currentMatch
        }
        return results.first { !$0.isVariant } ?? results.first
    }

    private func isExactGeneSearchMatch(
        _ result: AnnotationSearchIndex.SearchResult,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return false }
        let candidates = [
            result.name,
            result.attributes?["gene"],
            result.attributes?["gene_name"],
            result.attributes?["gene_id"],
            result.attributes?["Name"],
        ].compactMap { $0 }
        return candidates.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    private func chromosomesMatchForSequenceMenu(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || canonicalSequenceMenuChromosomeName(lhs) == canonicalSequenceMenuChromosomeName(rhs)
    }

    private func canonicalSequenceMenuChromosomeName(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("chr") {
            value = String(value.dropFirst(3))
        }
        if let dot = value.firstIndex(of: ".") {
            value = String(value[..<dot])
        }
        return value
    }

    /// Parses genomic location input and navigates the viewer.
    ///
    /// Supported formats:
    /// - "1000" - single position
    /// - "chr1:1000" - chromosome:position
    /// - "chr1:1000-2000" or "chr1:1000..2000" - range
    ///
    /// - Parameters:
    ///   - input: The user-provided position string
    ///   - viewerController: The viewer controller to navigate
    /// - Returns: A tuple with success status and optional error message
    private func parseAndNavigate(input: String, viewerController: ViewerViewController) -> (success: Bool, errorMessage: String?) {
        var chromosome: String? = nil
        var startPosition: Int? = nil
        var endPosition: Int? = nil

        // Check if input contains a chromosome prefix (contains ":")
        if input.contains(":") {
            // Format: chromosome:position or chromosome:start-end
            let colonParts = input.split(separator: ":", maxSplits: 1)
            guard colonParts.count == 2 else {
                return (false, "Invalid format. Expected 'chromosome:position' or 'chromosome:start-end'.")
            }

            chromosome = String(colonParts[0])
            let positionPart = String(colonParts[1])

            // Check for range separator (either "-" or "..")
            if positionPart.contains("..") {
                // Format: start..end
                let rangeParts = positionPart.split(separator: ".", omittingEmptySubsequences: true)
                guard rangeParts.count == 2,
                      let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) else {
                    return (false, "Invalid range format. Expected 'start..end' with numeric values.")
                }
                startPosition = start
                endPosition = end
            } else if positionPart.contains("-") {
                // Format: start-end (but need to handle negative numbers)
                // Find the last hyphen that's preceded by a digit (to distinguish range separator from negative sign)
                if let rangeHyphenIndex = positionPart.lastIndex(of: "-"),
                   rangeHyphenIndex > positionPart.startIndex {
                    let beforeHyphen = String(positionPart[positionPart.startIndex..<rangeHyphenIndex])
                    let afterHyphen = String(positionPart[positionPart.index(after: rangeHyphenIndex)...])

                    if let start = Int(beforeHyphen.trimmingCharacters(in: .whitespaces)),
                       let end = Int(afterHyphen.trimmingCharacters(in: .whitespaces)) {
                        startPosition = start
                        endPosition = end
                    } else {
                        // Try parsing the whole thing as a single position
                        if let pos = Int(positionPart.trimmingCharacters(in: .whitespaces)) {
                            startPosition = pos
                        } else {
                            return (false, "Invalid position format. Expected numeric value.")
                        }
                    }
                } else {
                    // Single position
                    if let pos = Int(positionPart.trimmingCharacters(in: .whitespaces)) {
                        startPosition = pos
                    } else {
                        return (false, "Invalid position format. Expected numeric value.")
                    }
                }
            } else {
                // Single position
                if let pos = Int(positionPart.trimmingCharacters(in: .whitespaces)) {
                    startPosition = pos
                } else {
                    return (false, "Invalid position format. Expected numeric value.")
                }
            }
        } else {
            // No chromosome prefix - just a position or range
            if input.contains("..") {
                // Range with ".."
                let rangeParts = input.split(separator: ".", omittingEmptySubsequences: true)
                guard rangeParts.count == 2,
                      let start = Int(String(rangeParts[0]).trimmingCharacters(in: .whitespaces)),
                      let end = Int(String(rangeParts[1]).trimmingCharacters(in: .whitespaces)) else {
                    return (false, "Invalid range format. Expected 'start..end' with numeric values.")
                }
                startPosition = start
                endPosition = end
            } else if input.contains("-") && input.first != "-" {
                // Range with "-" (not starting with negative sign)
                let rangeParts = input.split(separator: "-")
                if rangeParts.count == 2,
                   let start = Int(String(rangeParts[0]).trimmingCharacters(in: .whitespaces)),
                   let end = Int(String(rangeParts[1]).trimmingCharacters(in: .whitespaces)) {
                    startPosition = start
                    endPosition = end
                } else if let pos = Int(input.trimmingCharacters(in: .whitespaces)) {
                    startPosition = pos
                } else {
                    return (false, "Invalid format. Expected position number or 'start-end' range.")
                }
            } else {
                // Simple position number
                if let pos = Int(input.trimmingCharacters(in: .whitespaces)) {
                    startPosition = pos
                } else {
                    return (false, "Invalid position. Please enter a numeric value.")
                }
            }
        }

        // Validate we have at least a start position
        guard let start = startPosition else {
            return (false, "Could not parse the position value.")
        }

        // Convert from 1-based user input to 0-based internal coordinates
        // Users typically think in 1-based coordinates for genomic positions
        let zeroBasedStart = max(0, start - 1)
        let zeroBasedEnd: Int? = endPosition.map { max(zeroBasedStart + 1, $0) }

        // Navigate using the helper method
        let success = navigateSequenceViewer(
            viewerController,
            chromosome: chromosome,
            start: zeroBasedStart,
            end: zeroBasedEnd
        )

        if success {
            debugLog("goToPosition: Navigated to \(chromosome ?? "current"):\(zeroBasedStart)-\(zeroBasedEnd ?? zeroBasedStart)")
            return (true, nil)
        } else {
            return (false, "Position is outside the sequence bounds.")
        }
    }

    private func navigateSequenceViewer(
        _ viewerController: ViewerViewController,
        chromosome: String?,
        start: Int,
        end: Int?
    ) -> Bool {
        let targetChromosome = chromosome
            ?? viewerController.referenceFrame?.chromosome
            ?? viewerController.currentBundleDataProvider?.chromosomes.first?.name

        if let targetChromosome,
           let chromosomeInfo = viewerController.currentBundleDataProvider?.chromosomeInfo(named: targetChromosome) {
            let chromosomeLength = Int(chromosomeInfo.length)
            guard start >= 0 && start < chromosomeLength else { return false }

            let rangeStart: Int
            let rangeEnd: Int
            if let end {
                guard end > start && end <= chromosomeLength else { return false }
                rangeStart = start
                rangeEnd = end
            } else {
                let defaultWindow = min(1000, chromosomeLength)
                let halfWindow = defaultWindow / 2
                var windowStart = max(0, start - halfWindow)
                var windowEnd = min(chromosomeLength, start + halfWindow)
                if windowStart == 0 {
                    windowEnd = min(chromosomeLength, defaultWindow)
                }
                if windowEnd == chromosomeLength {
                    windowStart = max(0, chromosomeLength - defaultWindow)
                }
                rangeStart = windowStart
                rangeEnd = max(windowStart + 1, windowEnd)
            }

            viewerController.navigateToChromosomeAndPosition(
                chromosome: chromosomeInfo.name,
                chromosomeLength: chromosomeLength,
                start: rangeStart,
                end: rangeEnd
            )
            return true
        }

        return viewerController.navigateToPosition(
            chromosome: chromosome,
            start: start,
            end: end
        )
    }

    @objc func copySelectionFASTA(_ sender: Any?) {
        guard let viewerView = activeMainWindowController(sender: sender)?
            .mainSplitViewController?
            .activeFullSequenceViewerController?
            .viewerView else {
            NSSound.beep()
            return
        }
        viewerView.copySelectionAsFASTA(sender)
    }

    @objc func extractSelection(_ sender: Any?) {
        guard let viewerView = activeMainWindowController(sender: sender)?
            .mainSplitViewController?
            .activeFullSequenceViewerController?
            .viewerView else {
            NSSound.beep()
            return
        }
        viewerView.extractSelectionSequence(sender)
    }

    @objc func addAnnotation(_ sender: Any?) {
        // Get the current selection from the viewer
        guard let originController = activeMainWindowController(sender: sender),
              let viewerController = originController.mainSplitViewController?.viewerController else {
            showAlert(title: "No Viewer", message: "No sequence viewer available.")
            return
        }
        let routeContext = currentOperationRouteContext(for: originController)

        if let alignmentController = viewerController.multipleSequenceAlignmentViewController {
            alignmentController.presentAddAnnotationDialog(window: originController.window ?? NSApp.keyWindow)
            return
        }

        // Access the active sequence viewport to get the explicit user selection range.
        guard let selectionContext = viewerController.currentSequenceAnnotationDraftContext() else {
            showAlert(title: "No Selection", message: "Please select a region of the sequence first.")
            return
        }
        let selectionRange = selectionContext.range

        // Show the annotation dialog
        let alert = NSAlert()
        alert.messageText = "Add Annotation"
        alert.informativeText = "Add an annotation for \(selectionContext.chromosome):\(selectionRange.lowerBound + 1)-\(selectionRange.upperBound)"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        // Create accessory view with form fields
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))

        // Name field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 90, width: 60, height: 20)
        accessoryView.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 70, y: 88, width: 220, height: 24))
        nameField.placeholderString = "Annotation name"
        accessoryView.addSubview(nameField)

        // Type popup
        let typeLabel = NSTextField(labelWithString: "Type:")
        typeLabel.frame = NSRect(x: 0, y: 55, width: 60, height: 20)
        accessoryView.addSubview(typeLabel)

        let typePopup = NSPopUpButton(frame: NSRect(x: 70, y: 53, width: 220, height: 24))
        typePopup.addItems(withTitles: [
            "gene", "CDS", "exon", "mRNA", "region", "misc_feature",
            "promoter", "primer", "restriction_site"
        ])
        accessoryView.addSubview(typePopup)

        // Strand popup
        let strandLabel = NSTextField(labelWithString: "Strand:")
        strandLabel.frame = NSRect(x: 0, y: 20, width: 60, height: 20)
        accessoryView.addSubview(strandLabel)

        let strandPopup = NSPopUpButton(frame: NSRect(x: 70, y: 18, width: 100, height: 24))
        strandPopup.addItems(withTitles: ["+", "-", "none"])
        accessoryView.addSubview(strandPopup)

        alert.accessoryView = accessoryView

        guard let window = originController.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                let name = nameField.stringValue.isEmpty ? "New Annotation" : nameField.stringValue
                let typeString = typePopup.selectedItem?.title ?? "region"
                let strandString = strandPopup.selectedItem?.title ?? "none"

                // Create the annotation
                let annotationType = AnnotationType(rawValue: typeString) ?? .region
                let strand: Strand = strandString == "+" ? .forward : (strandString == "-" ? .reverse : .unknown)

                let annotation = SequenceAnnotation(
                    type: annotationType,
                    name: name,
                    chromosome: selectionContext.chromosome,
                    intervals: [AnnotationInterval(start: selectionRange.lowerBound, end: selectionRange.upperBound)],
                    strand: strand
                )

                if let bundleURL = selectionContext.bundleURL {
                    await self.persistManualReferenceAnnotation(
                        annotation,
                        bundleURL: bundleURL,
                        viewerController: viewerController,
                        routeContext: routeContext
                    )
                } else if let document = viewerController.currentDocument {
                    document.annotations.append(annotation)

                    // Refresh the viewer to show the new annotation
                    viewerController.displayDocument(document)

                    debugLog("Added annotation: \(name) (\(typeString)) at \(selectionRange)")
                }
            }
        }
    }

    private func persistManualReferenceAnnotation(
        _ annotation: SequenceAnnotation,
        bundleURL: URL,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext?
    ) async {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Add annotation",
            presentingWindow: targetMainWindowController(routeContext: routeContext)?.window ?? viewerController.view.window
        ) else { return }
        let opID = OperationCenter.shared.start(
            title: "Add Annotation",
            detail: "Adding \(annotation.name)...",
            operationType: .bundleBuild,
            cliCommand: nil,
            routeContext: routeContext
        )

        do {
            let result = try await ReferenceBundleManualAnnotationService().addAnnotation(
                annotation,
                toBundleAt: bundleURL
            )
            guard OperationCenter.shared.complete(
                id: opID,
                detail: "Added annotation to \(result.track.name)"
            ) else { return }
            let targetController = targetMainWindowController(routeContext: routeContext)
            let targetViewerController = targetController?.mainSplitViewController?.viewerController ?? viewerController
            if let sidebarController = targetController?.mainSplitViewController?.sidebarController {
                sidebarController.reloadFromFilesystem()
                _ = sidebarController.selectItem(forURL: bundleURL)
            }

            if let referenceViewport = targetViewerController.referenceBundleViewportController,
               referenceViewport.currentInput?.renderedBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                try referenceViewport.reloadViewerBundleForInspectorChanges()
                targetController?.mainSplitViewController?.wireDirectReferenceViewportInspectorUpdates()
            } else if targetViewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                try targetViewerController.displayBundle(at: bundleURL)
            }
        } catch {
            guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
            showAlert(title: "Add Annotation Failed", message: error.localizedDescription)
        }
    }

    @objc func applyAlignmentAnnotationToSelection(_ sender: Any?) {
        let controller = activeMainWindowController(sender: sender)
        guard let viewerController = controller?.mainSplitViewController?.viewerController,
              let alignmentController = viewerController.multipleSequenceAlignmentViewController else {
            showAlert(
                title: "No Alignment Viewer",
                message: "Open a multiple sequence alignment before applying annotations.",
                presentingWindow: controller?.window
            )
            return
        }
        do {
            let projected = try alignmentController.applySelectedAnnotationsToSelectedRows()
            if projected.isEmpty {
                showAlert(
                    title: "No Annotation to Apply",
                    message: "Select an annotated alignment range and at least one additional target row.",
                    presentingWindow: controller?.window
                )
            }
        } catch {
            showAlert(title: "Apply Annotation Failed", message: error.localizedDescription, presentingWindow: controller?.window)
        }
    }

    internal func showAlert(title: String, message: String, presentingWindow: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = presentingWindow ?? mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    private func presentFindORFsOperation(sender: Any?) {
        guard let originController = activeMainWindowController(sender: sender),
              let viewerController = originController.mainSplitViewController?.activeFullSequenceViewerController else {
            showAlert(title: "No Viewer", message: "Open a reference sequence bundle before running Find ORFs.")
            return
        }
        guard let context = viewerController.currentSequenceAnnotationOperationContext(),
              let bundleURL = context.bundleURL else {
            showAlert(
                title: "No Reference Bundle",
                message: "Find ORFs writes a new annotation track and requires an active `.lungfishref` bundle.",
                presentingWindow: originController.window
            )
            return
        }
        guard OperationCenter.shared.canStartOperation(on: context.bundleURL) else {
            let active = OperationCenter.shared.activeLockHolder(for: context.bundleURL)
            let detail = active.map { "\($0.title) is already running on this bundle." }
                ?? "Another operation is already running on this bundle."
            showAlert(
                title: "Bundle Busy",
                message: detail,
                presentingWindow: originController.window
            )
            return
        }

        let routeContext = currentOperationRouteContext(for: originController)
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: SequenceAnnotationOperationKind.orf.displayName,
            presentingWindow: originController.window
        ) else { return }

        let sequenceName = sequenceAnnotationOperationSequenceName(
            for: context,
            viewerController: viewerController
        )
        let range = context.range
        let defaultTrackName = "\(sequenceName) ORFs"
        let defaultTrackID = defaultSequenceAnnotationTrackID(
            prefix: "orfs",
            chromosome: sequenceName
        )

        guard let window = originController.window ?? NSApp.keyWindow else { return }
        let state = SequenceORFOperationDialogState(
            bundleURL: bundleURL,
            sequenceName: sequenceName,
            range: range,
            defaultTrackName: defaultTrackName,
            defaultTrackID: defaultTrackID
        )
        SequenceORFOperationDialogPresenter.present(
            from: window,
            state: state,
            onRun: { [weak self, weak viewerController] request in
                guard let self, let viewerController else { return }
                self.runSequenceAnnotationOperation(
                    request,
                    viewerController: viewerController,
                    routeContext: routeContext
                )
            },
            onCancel: nil
        )
    }

    func sequenceAnnotationOperationSequenceName(
        for context: SequenceAnnotationDraftContext,
        viewerController: ViewerViewController
    ) -> String {
        if let chromosomeName = viewerController.currentBundleDataProvider?
            .chromosomeInfo(named: context.chromosome)?
            .name {
            return chromosomeName
        }
        if let chromosomeName = viewerController.viewerView.currentReferenceBundle?
            .chromosome(named: context.chromosome)?
            .name {
            return chromosomeName
        }
        return context.chromosome
    }

    private func defaultSequenceAnnotationTrackID(prefix: String, chromosome: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let raw = "\(prefix)_\(chromosome)"
        let mapped = raw.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(Character(scalar)).lowercased() : "_"
        }
        return mapped.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func runSequenceAnnotationOperation(
        _ request: SequenceAnnotationOperationRequest,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?
    ) {
        guard OperationCenter.shared.canStartOperation(on: request.bundleURL) else {
            showAlert(
                title: "Bundle Busy",
                message: "Another operation is already modifying this reference bundle. Wait for it to finish before running \(request.operation.displayName).",
                presentingWindow: targetMainWindowController(routeContext: routeContext)?.window
                    ?? viewerController.view.window
            )
            return
        }

        let opID = OperationCenter.shared.start(
            title: request.operation.displayName,
            detail: "Running \(request.operation.displayName)...",
            operationType: .bundleBuild,
            targetBundleURL: request.bundleURL,
            cliCommand: SequenceAnnotationOperationRunner.displayCommand(for: request),
            routeContext: routeContext
        )

        let cliCancellation = LungfishCLIRunner.CancellationHandle()
        let task = Task.detached { [weak self] in
            do {
                let output = try SequenceAnnotationOperationRunner.run(
                    request,
                    cancellation: cliCancellation
                )
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OperationCenter.shared.log(id: opID, level: .info, message: output.stdout)
                    }
                    if !output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OperationCenter.shared.log(id: opID, level: .warning, message: output.stderr)
                    }
                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Created annotation track in \(request.bundleURL.lastPathComponent)"
                    ) else { return }
                    self?.refreshReferenceBundleAfterSequenceAnnotation(
                        bundleURL: request.bundleURL,
                        viewerController: viewerController,
                        routeContext: routeContext
                    )
                }}
            } catch LungfishCLIRunner.RunError.cancelled {
                // The runner has exited and drained; acknowledge worker cancellation.
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    OperationCenter.shared.log(id: opID, level: .info, message: "\(request.operation.displayName) cancelled")
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                }}
            } catch is CancellationError {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    OperationCenter.shared.log(id: opID, level: .info, message: "\(request.operation.displayName) cancelled")
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                }}
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard OperationCenter.shared.fail(
                        id: opID,
                        detail: "\(request.operation.displayName) failed",
                        errorMessage: error.localizedDescription
                    ) else { return }
                    self?.showAlert(
                        title: "\(request.operation.displayName) Failed",
                        message: error.localizedDescription,
                        presentingWindow: self?.targetMainWindowController(routeContext: routeContext)?.window
                            ?? viewerController.view.window
                    )
                }}
            }
        }
        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
            cliCancellation.cancel()
        }
    }

    private func refreshReferenceBundleAfterSequenceAnnotation(
        bundleURL: URL,
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext?
    ) {
        let targetController = targetMainWindowController(routeContext: routeContext)
        let targetViewerController = targetController?.mainSplitViewController?.viewerController ?? viewerController
        if let sidebarController = targetController?.mainSplitViewController?.sidebarController {
            sidebarController.reloadFromFilesystem()
            _ = sidebarController.selectItem(forURL: bundleURL)
        }

        do {
            let activeSequenceViewer = targetViewerController.activeSequenceViewerController
            let activeSequenceMatches = (activeSequenceViewer.currentBundleURL ?? activeSequenceViewer.viewerView.currentReferenceBundle?.url)?
                .standardizedFileURL == bundleURL.standardizedFileURL
            if activeSequenceMatches {
                try activeSequenceViewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundleURL)
            } else if let referenceViewport = targetViewerController.referenceBundleViewportController,
               referenceViewport.currentInput?.renderedBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                try referenceViewport.reloadViewerBundleForInspectorChanges()
                targetController?.mainSplitViewController?.wireDirectReferenceViewportInspectorUpdates()
            } else if targetViewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                try targetViewerController.displayBundle(at: bundleURL)
            }
        } catch {
            showAlert(title: "Reload Failed", message: error.localizedDescription, presentingWindow: targetController?.window)
        }
    }

    @objc func findORFs(_ sender: Any?) {
        presentFindORFsOperation(sender: sender)
    }
}
