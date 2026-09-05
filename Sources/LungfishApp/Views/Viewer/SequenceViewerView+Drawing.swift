// SequenceViewerView+Drawing.swift - Multi-sequence drawing integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Provides the main drawing entry point for multi-sequence mode that
// integrates with the existing draw() method.

import AppKit
import LungfishCore
import LungfishWorkflow
import os.log

/// Logger for multi-sequence drawing operations
private let drawLogger = Logger(subsystem: LogSubsystem.app, category: "MultiSeqDraw")

// MARK: - SequenceViewerView Drawing Integration

extension SequenceViewerView {

    // MARK: - Main Multi-Sequence Drawing Entry Point

    /// Draws all stacked sequences if in multi-sequence mode.
    ///
    /// This method should be called from draw() when `shouldDrawMultiSequence` is true.
    /// It replaces the single-sequence drawing with multi-sequence stacking.
    /// Each sequence is drawn with its associated annotations directly below it.
    ///
    /// - Parameters:
    ///   - frame: The reference frame for coordinate mapping
    ///   - context: The graphics context
    /// - Returns: True if multi-sequence drawing was performed, false otherwise
    @discardableResult
    public func drawMultiSequenceContent(frame: ReferenceFrame, context: CGContext) -> Bool {
        guard shouldDrawMultiSequence,
              let state = multiSequenceState else {
            return false
        }

        drawLogger.debug("drawMultiSequenceContent: Drawing \(state.stackedSequences.count) sequences with grouped annotations")

        // Draw each stacked sequence with its annotations
        drawStackedSequences(state.stackedSequences, frame: frame, context: context)

        // Draw selection highlight (on active sequence)
        drawMultiSequenceSelection(frame: frame, context: context)

        // Draw sequence stack summary info
        drawStackSummary(state: state, context: context)

        return true
    }

    // MARK: - Selection Drawing

    /// Draws selection highlight on the active sequence track.
    private func drawMultiSequenceSelection(frame: ReferenceFrame, context: CGContext) {
        guard let range = selectionRange,
              let state = multiSequenceState,
              state.activeSequenceIndex < state.stackedSequences.count else {
            return
        }

        let activeInfo = state.stackedSequences[state.activeSequenceIndex]
        let visibleBases = frame.end - frame.start
        let pixelsPerBase = bounds.width / CGFloat(max(1, visibleBases))

        // Calculate selection rect within the active track (sequence portion only)
        let startX = CGFloat(range.lowerBound - Int(frame.start)) * pixelsPerBase
        let endX = CGFloat(range.upperBound - Int(frame.start)) * pixelsPerBase
        let selectionRect = CGRect(
            x: max(0, startX),
            y: activeInfo.yOffset,
            width: min(bounds.width - startX, endX - startX),
            height: activeInfo.sequenceHeight  // Only highlight the sequence portion
        )

        // Draw selection highlight
        context.saveGState()
        context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).cgColor)
        context.fill(selectionRect)

        context.setStrokeColor(NSColor.selectedTextBackgroundColor.cgColor)
        context.setLineWidth(2)
        context.stroke(selectionRect)
        context.restoreGState()
    }

    /// Draws a summary of the sequence stack.
    private func drawStackSummary(state: MultiSequenceState, context: CGContext) {
        // Use the actual content height which accounts for annotations
        let totalHeight = state.totalContentHeight

        // Draw summary line below all tracks
        let summaryY = totalHeight + 4

        // Count total annotations across all sequences
        let totalAnnotations = state.stackedSequences.reduce(0) { $0 + $1.annotations.count }

        var summaryText = "\(state.sequenceCount) sequences | Active: \(state.activeSequenceIndex + 1)"
        if totalAnnotations > 0 {
            summaryText += " | \(totalAnnotations) annotations"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        (summaryText as NSString).draw(
            at: CGPoint(x: 8, y: summaryY),
            withAttributes: attributes
        )
    }

    // MARK: - Mouse Event Handling for Multi-Sequence

    /// Handles mouse down for multi-sequence selection.
    ///
    /// Returns true if the event was handled (clicked on a sequence track),
    /// false if it should fall through to other handlers.
    public func handleMultiSequenceMouseDown(at location: NSPoint, frame: ReferenceFrame) -> Bool {
        guard shouldDrawMultiSequence,
              let state = multiSequenceState else {
            return false
        }

        // Check if click is on a sequence track
        if let clickedInfo = state.sequenceInfo(atY: location.y) {
            drawLogger.info("handleMultiSequenceMouseDown: Clicked on sequence '\(clickedInfo.sequence.name, privacy: .public)' at index \(clickedInfo.trackIndex)")

            // Make this sequence active
            if clickedInfo.trackIndex != state.activeSequenceIndex {
                state.setActiveSequence(index: clickedInfo.trackIndex)
                needsDisplay = true

                // Update view controller
                viewController?.setActiveSequence(index: clickedInfo.trackIndex)
            }

            return true
        }

        return false
    }

    /// Gets the base position for the active sequence at a given point.
    public func basePositionForActiveSequence(at location: NSPoint, frame: ReferenceFrame) -> Int? {
        guard let state = multiSequenceState,
              state.activeSequenceIndex < state.stackedSequences.count else {
            return nil
        }

        let activeInfo = state.stackedSequences[state.activeSequenceIndex]
        return basePosition(atPoint: location, forSequence: activeInfo, frame: frame)
    }

    // MARK: - Scroll and Zoom Support

    /// Returns the visible sequences in the current scroll position.
    public func visibleSequenceIndices(in visibleRect: CGRect) -> Range<Int> {
        guard let state = multiSequenceState else {
            return 0..<1
        }

        let layout = state.layout
        let firstVisible = max(0, layout.trackIndex(atY: visibleRect.minY, sequences: state.stackedSequences) ?? 0)
        let lastVisible = min(state.sequenceCount - 1, layout.trackIndex(atY: visibleRect.maxY, sequences: state.stackedSequences) ?? state.sequenceCount - 1)

        return firstVisible..<(lastVisible + 1)
    }
}

// MARK: - Tooltip Support

extension SequenceViewerView {

    /// Returns tooltip text for multi-sequence mode at the given point.
    public func multiSequenceTooltip(at location: NSPoint, frame: ReferenceFrame) -> String? {
        guard shouldDrawMultiSequence,
              let state = multiSequenceState,
              let seqInfo = state.sequenceInfo(atY: location.y) else {
            return nil
        }

        let seq = seqInfo.sequence
        let basePos = basePosition(atPoint: location, forSequence: seqInfo, frame: frame)

        guard basePos >= 0 && basePos < seq.length else { return nil }

        let base = seq[basePos]
        var tooltip = """
        Sequence: \(seq.name)
        Position: \(basePos + 1)
        Base: \(base)
        """

        // Add quality score if available
        if let quality = seq.qualityScores, basePos < quality.count {
            let q = quality[basePos]
            tooltip += "\nQuality: Q\(q)"
        }

        // Add track info
        if seqInfo.isReference {
            tooltip += "\n(Reference sequence)"
        }
        tooltip += "\nTrack \(seqInfo.trackIndex + 1) of \(state.sequenceCount)"

        // Add annotation count
        if !seqInfo.annotations.isEmpty {
            tooltip += "\nAnnotations: \(seqInfo.annotations.count)"
        }

        return tooltip
    }
}

// MARK: - Context Menu Support

extension SequenceViewerView {

    /// Creates context menu for multi-sequence operations.
    public func multiSequenceContextMenu(at location: NSPoint, frame: ReferenceFrame) -> NSMenu? {
        guard shouldDrawMultiSequence,
              let state = multiSequenceState,
              let seqInfo = state.sequenceInfo(atY: location.y) else {
            return nil
        }

        let menu = NSMenu(title: "Sequence Track")

        // Sequence info header
        let headerItem = NSMenuItem(title: seqInfo.sequence.name, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // Make Reference
        if !seqInfo.isReference {
            let refItem = NSMenuItem(
                title: "Set as Reference",
                action: #selector(setSequenceAsReference(_:)),
                keyEquivalent: ""
            )
            refItem.target = self
            refItem.representedObject = seqInfo.trackIndex
            menu.addItem(refItem)
        }

        // Remove from stack
        let removeItem = NSMenuItem(
            title: "Remove from View",
            action: #selector(removeSequenceFromStack(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        removeItem.representedObject = seqInfo.trackIndex
        menu.addItem(removeItem)

        menu.addItem(NSMenuItem.separator())

        // Copy sequence
        let copyItem = NSMenuItem(
            title: "Copy Sequence",
            action: #selector(copySequenceToClipboard(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.representedObject = seqInfo
        menu.addItem(copyItem)

        // Export sequence
        let exportItem = NSMenuItem(
            title: "Export as FASTA...",
            action: #selector(exportSequenceAsFASTA(_:)),
            keyEquivalent: ""
        )
        exportItem.target = self
        exportItem.representedObject = seqInfo
        menu.addItem(exportItem)

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func setSequenceAsReference(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              let state = multiSequenceState,
              index < state.stackedSequences.count else {
            return
        }

        // Reorder sequences to put the selected one first
        let sourceURLsByID = Dictionary(
            uniqueKeysWithValues: state.stackedSequences.compactMap { info in
                info.sourceURL.map { (info.sequence.id, $0) }
            }
        )
        var sequences = state.stackedSequences.map { $0.sequence }
        let selected = sequences.remove(at: index)
        sequences.insert(selected, at: 0)

        setSequences(sequences, sourceURLsByID: sourceURLsByID)

        drawLogger.info("setSequenceAsReference: Set '\(selected.name, privacy: .public)' as reference")
    }

    @objc private func removeSequenceFromStack(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else {
            return
        }

        removeSequence(at: index)
        drawLogger.info("removeSequenceFromStack: Removed sequence at index \(index)")
    }

    @objc private func copySequenceToClipboard(_ sender: NSMenuItem) {
        guard let seqInfo = sender.representedObject as? StackedSequenceInfo else {
            return
        }

        let seq = seqInfo.sequence
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(seq.asString(), forType: .string)

        drawLogger.info("copySequenceToClipboard: Copied \(seq.length) bases from '\(seq.name, privacy: .public)'")
    }

    @objc private func exportSequenceAsFASTA(_ sender: NSMenuItem) {
        guard let seqInfo = sender.representedObject as? StackedSequenceInfo else {
            return
        }

        let seq = seqInfo.sequence

        let savePanel = ViewerFilePanelFactory.sequenceFastaExportPanel(
            suggestedName: "\(seq.name).fasta"
        )

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            let startedAt = Date()
            let sourceURLs = self.sequenceFASTAExportSourceURLs(for: seqInfo)
            do {
                try Self.writeSequenceFASTAExport(seq, sourceURLs: sourceURLs, to: url, startedAt: startedAt)
                drawLogger.info("exportSequenceAsFASTA: Exported '\(seq.name, privacy: .public)' to \(url.path, privacy: .public)")
            } catch {
                drawLogger.error("exportSequenceAsFASTA: Failed to export: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    static func writeSequenceFASTAExport(
        _ sequence: Sequence,
        sourceURLs: [URL],
        to outputURL: URL,
        startedAt: Date = Date()
    ) throws -> URL {
        let fasta = sequenceFASTAText(sequence)
        var explicitOptions: [String: ParameterValue] = [
            "sourcePaths": .array(sourceURLs.map { .file($0) }),
            "outputPath": .file(outputURL),
            "sequenceName": .string(sequence.name),
        ]
        if let description = sequence.description {
            explicitOptions["sequenceDescription"] = .string(description)
        }

        do {
            return try ScientificFileExportProvenance.writeAtomically(.init(
                workflowName: "lungfish app sequence fasta export",
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: .fasta,
                argv: sequenceFASTAExportArgv(sourceURLs: sourceURLs, outputURL: outputURL, sequenceName: sequence.name),
                explicitOptions: explicitOptions,
                defaults: [
                    "lineWidth": .integer(80),
                    "outputFormat": .string("fasta"),
                ],
                resolved: [
                    "sequenceLength": .integer(sequence.length),
                    "outputByteCount": .integer(fasta.utf8.count),
                    "sourceCount": .integer(sourceURLs.count),
                ],
                startedAt: startedAt,
                completedAt: Date()
            )) { staged in
                try fasta.write(to: staged, atomically: true, encoding: .utf8)
            }
        } catch {
            throw error
        }
    }

    private static func sequenceFASTAText(_ sequence: Sequence) -> String {
        var fasta = ">\(sequence.name)"
        if let desc = sequence.description {
            fasta += " \(desc)"
        }
        fasta += "\n"

        let bases = sequence.asString()
        for i in stride(from: 0, to: bases.count, by: 80) {
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(80, bases.count - i))
            fasta += String(bases[start..<end]) + "\n"
        }
        return fasta
    }

    private static func sequenceFASTAExportArgv(
        sourceURLs: [URL],
        outputURL: URL,
        sequenceName: String
    ) -> [String] {
        var argv = ["Lungfish Genome Explorer", "export-sequence-fasta"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        argv.append(contentsOf: ["--sequence", sequenceName, "--output", outputURL.path])
        return argv
    }

    func sequenceFASTAExportSourceURLs(for seqInfo: StackedSequenceInfo) -> [URL] {
        if let sourceURL = seqInfo.sourceURL,
           let existing = Self.existingUniqueURLs([sourceURL]).first {
            return [existing]
        }

        if let document = viewController?.currentDocument,
           let state = multiSequenceState {
            let visibleSequenceIDs = Set(state.stackedSequences.map { $0.sequence.id })
            let documentSequenceIDs = Set(document.sequences.map(\.id))
            if !visibleSequenceIDs.isEmpty,
               visibleSequenceIDs.isSubset(of: documentSequenceIDs),
               let url = Self.existingUniqueURLs([document.url]).first {
                return [url]
            }
        } else if let document = viewController?.currentDocument,
                  document.sequences.contains(where: { $0.id == seqInfo.sequence.id }),
                  let url = Self.existingUniqueURLs([document.url]).first {
            return [url]
        }

        let candidates = [
            viewController?.currentBundleURL,
            currentReferenceBundle?.url,
            viewController?.multipleSequenceAlignmentViewController?.bundleURL,
            viewController?.phylogeneticTreeViewController?.bundleURL,
        ]
        let existing = Self.existingUniqueURLs(candidates)
        return existing.count == 1 ? existing : []
    }

    private static func existingUniqueURLs(_ candidates: [URL?]) -> [URL] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let url = candidate?.standardizedFileURL else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return seen.insert(url.path).inserted ? url : nil
        }
    }
}
