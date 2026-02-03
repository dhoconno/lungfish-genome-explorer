// MultiSequenceSupport.swift - Multi-sequence stacking for the viewer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Extends SequenceViewerView to support displaying multiple sequences stacked vertically,
// such as FASTQ reads, multi-FASTA files, or multiple selected sequences.

import AppKit
import LungfishCore
import os.log

/// Logger for multi-sequence operations
private let multiSeqLogger = Logger(subsystem: "com.lungfish.browser", category: "MultiSequence")

// MARK: - StackedSequenceInfo

/// Information about a single sequence in the stacked display.
///
/// Contains layout information, selection state, and associated annotations
/// for each sequence track.
public struct StackedSequenceInfo: Identifiable {
    /// Unique identifier for this stacked sequence
    public let id: UUID

    /// The sequence data
    public let sequence: Sequence

    /// The track index (0 = reference, 1+ = additional sequences)
    public let trackIndex: Int

    /// Y offset where this track starts (includes space for annotations of previous sequences)
    public var yOffset: CGFloat

    /// Height of the sequence portion of this track
    public var sequenceHeight: CGFloat

    /// Height of the annotation portion of this track
    public var annotationHeight: CGFloat

    /// Total height of this track including sequence and annotations
    public var height: CGFloat {
        sequenceHeight + annotationHeight
    }

    /// Whether this sequence is the reference (longest/first)
    public var isReference: Bool

    /// Whether this track is currently active/selected
    public var isActive: Bool

    /// Alignment offset in base pairs (0 = left-aligned)
    public var alignmentOffset: Int

    /// Annotations that belong to this sequence
    public var annotations: [SequenceAnnotation]

    public init(
        sequence: Sequence,
        trackIndex: Int,
        yOffset: CGFloat = 0,
        sequenceHeight: CGFloat = 28,
        annotationHeight: CGFloat = 0,
        isReference: Bool = false,
        isActive: Bool = false,
        alignmentOffset: Int = 0,
        annotations: [SequenceAnnotation] = []
    ) {
        self.id = sequence.id
        self.sequence = sequence
        self.trackIndex = trackIndex
        self.yOffset = yOffset
        self.sequenceHeight = sequenceHeight
        self.annotationHeight = annotationHeight
        self.isReference = isReference
        self.isActive = isActive
        self.alignmentOffset = alignmentOffset
        self.annotations = annotations
    }
}

// MARK: - SequenceStackLayout

/// Manages layout calculations for stacked sequences.
///
/// Calculates Y offsets, track heights, and total content height
/// based on the number of sequences and current settings.
public struct SequenceStackLayout {

    /// Default height for each sequence track
    public static let defaultTrackHeight: CGFloat = 28  // Reduced for more compact display

    /// Default height for annotation rows
    public static let defaultAnnotationRowHeight: CGFloat = 18

    /// Spacing between annotation rows within a track
    public static let annotationRowSpacing: CGFloat = 2

    /// Spacing between sequence tracks
    public static let trackSpacing: CGFloat = 4

    /// Height of the track label area
    public static let labelHeight: CGFloat = 16

    /// Total height for a single track including spacing (without annotations)
    public static var totalTrackHeight: CGFloat {
        defaultTrackHeight + trackSpacing
    }

    /// Starting Y offset for the first track
    public var startY: CGFloat

    /// Individual track height for sequence display
    public var trackHeight: CGFloat

    /// Height per annotation row
    public var annotationRowHeight: CGFloat

    /// Spacing between tracks
    public var spacing: CGFloat

    /// Maximum number of tracks to display before scrolling
    public var maxVisibleTracks: Int

    public init(
        startY: CGFloat = 20,
        trackHeight: CGFloat = defaultTrackHeight,
        annotationRowHeight: CGFloat = defaultAnnotationRowHeight,
        spacing: CGFloat = trackSpacing,
        maxVisibleTracks: Int = 20
    ) {
        self.startY = startY
        self.trackHeight = trackHeight
        self.annotationRowHeight = annotationRowHeight
        self.spacing = spacing
        self.maxVisibleTracks = maxVisibleTracks
    }

    /// Calculates the Y offset for a track at the given index (without annotations).
    /// For actual offsets with annotations, use the StackedSequenceInfo.yOffset property.
    public func yOffset(forTrack index: Int) -> CGFloat {
        startY + CGFloat(index) * (trackHeight + spacing)
    }

    /// Calculates the total content height for the given number of sequences (without annotations).
    public func totalHeight(forSequenceCount count: Int) -> CGFloat {
        guard count > 0 else { return startY }
        return yOffset(forTrack: count - 1) + trackHeight + spacing
    }

    /// Calculates the annotation track height based on number of annotation rows needed.
    public func annotationHeight(forRowCount rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * (annotationRowHeight + SequenceStackLayout.annotationRowSpacing) + spacing
    }

    /// Returns the track index at the given Y coordinate, or nil if outside tracks.
    /// This method works with sequences that have variable heights due to annotations.
    public func trackIndex(atY y: CGFloat, sequences: [StackedSequenceInfo]) -> Int? {
        guard y >= startY else { return nil }

        for (index, info) in sequences.enumerated() {
            if y >= info.yOffset && y < info.yOffset + info.height {
                return index
            }
        }

        return nil
    }

    /// Returns the rect for a track at the given index.
    public func trackRect(forIndex index: Int, width: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: yOffset(forTrack: index),
            width: width,
            height: trackHeight
        )
    }
}

// MARK: - MultiSequenceState

/// Manages state for multi-sequence display.
///
/// Tracks which sequences are loaded, which is active, and handles
/// selection across multiple sequences.
@MainActor
public class MultiSequenceState: ObservableObject {

    /// All loaded sequences with their stacking info
    @Published public private(set) var stackedSequences: [StackedSequenceInfo] = []

    /// The reference sequence (longest or first)
    @Published public private(set) var referenceSequence: Sequence?

    /// Index of the currently active sequence
    @Published public var activeSequenceIndex: Int = 0

    /// All annotations (used to associate with sequences)
    private var allAnnotations: [SequenceAnnotation] = []

    /// Layout configuration
    public var layout: SequenceStackLayout

    /// Whether multiple sequences are loaded
    public var hasMultipleSequences: Bool {
        stackedSequences.count > 1
    }

    /// The currently active sequence
    public var activeSequence: Sequence? {
        guard activeSequenceIndex >= 0 && activeSequenceIndex < stackedSequences.count else {
            return nil
        }
        return stackedSequences[activeSequenceIndex].sequence
    }

    /// Total number of sequences
    public var sequenceCount: Int {
        stackedSequences.count
    }

    /// Maximum sequence length across all loaded sequences
    public var maxSequenceLength: Int {
        stackedSequences.map { $0.sequence.length }.max() ?? 0
    }

    public init(layout: SequenceStackLayout = SequenceStackLayout()) {
        self.layout = layout
    }

    /// Sets the sequences to display, determining reference and calculating layout.
    ///
    /// - Parameter sequences: Array of sequences to display
    /// - Parameter useFirstAsReference: If true, uses first sequence as reference;
    ///   otherwise uses longest
    public func setSequences(_ sequences: [Sequence], useFirstAsReference: Bool = true) {
        multiSeqLogger.info("setSequences: Setting \(sequences.count) sequences")

        guard !sequences.isEmpty else {
            stackedSequences = []
            referenceSequence = nil
            activeSequenceIndex = 0
            return
        }

        // Determine reference sequence
        if useFirstAsReference {
            referenceSequence = sequences.first
        } else {
            referenceSequence = sequences.max(by: { $0.length < $1.length })
        }

        multiSeqLogger.info("setSequences: Reference sequence is '\(self.referenceSequence?.name ?? "none", privacy: .public)' with length \(self.referenceSequence?.length ?? 0)")

        // Create stacked sequence info for each sequence with annotations
        rebuildStackedSequences(sequences: sequences)

        activeSequenceIndex = 0
        multiSeqLogger.info("setSequences: Created \(self.stackedSequences.count) stacked sequence entries")
    }

    /// Sets the annotations and updates the stacked sequences to include them.
    ///
    /// - Parameter annotations: Array of annotations to associate with sequences
    public func setAnnotations(_ annotations: [SequenceAnnotation]) {
        multiSeqLogger.info("setAnnotations: Setting \(annotations.count) annotations")
        self.allAnnotations = annotations

        // Rebuild layout with new annotations
        let sequences = stackedSequences.map { $0.sequence }
        if !sequences.isEmpty {
            rebuildStackedSequences(sequences: sequences)
        }
    }

    /// Rebuilds the stacked sequence info array with proper layout calculations.
    private func rebuildStackedSequences(sequences: [Sequence]) {
        var currentY = layout.startY
        var newStackedSequences: [StackedSequenceInfo] = []

        for (index, seq) in sequences.enumerated() {
            // Find annotations belonging to this sequence
            let seqAnnotations = allAnnotations.filter { annotation in
                annotation.belongsToSequence(named: seq.name)
            }

            // Calculate annotation height based on number of overlapping rows needed
            let annotationRowCount = calculateAnnotationRows(seqAnnotations)
            let annotationHeight = layout.annotationHeight(forRowCount: annotationRowCount)

            let info = StackedSequenceInfo(
                sequence: seq,
                trackIndex: index,
                yOffset: currentY,
                sequenceHeight: layout.trackHeight,
                annotationHeight: annotationHeight,
                isReference: seq.id == referenceSequence?.id,
                isActive: index == 0,
                alignmentOffset: 0,
                annotations: seqAnnotations
            )
            newStackedSequences.append(info)

            // Move to next track position
            currentY += info.height + layout.spacing
        }

        stackedSequences = newStackedSequences
    }

    /// Calculates the number of annotation rows needed to avoid overlapping.
    private func calculateAnnotationRows(_ annotations: [SequenceAnnotation]) -> Int {
        guard !annotations.isEmpty else { return 0 }

        // Simple row assignment - track end positions for each row
        var rowEndPositions: [Int] = []

        // Sort annotations by start position
        let sortedAnnotations = annotations.sorted { $0.start < $1.start }

        for annotation in sortedAnnotations {
            // Find first row where this annotation fits
            var assignedRow = 0
            for (row, endPos) in rowEndPositions.enumerated() {
                if annotation.start >= endPos + 2 {  // 2bp gap for visual separation
                    assignedRow = row
                    break
                }
                assignedRow = row + 1
            }

            // Ensure row exists
            while rowEndPositions.count <= assignedRow {
                rowEndPositions.append(0)
            }

            // Update row end position
            rowEndPositions[assignedRow] = annotation.end
        }

        return rowEndPositions.count
    }

    /// Adds a single sequence to the stack.
    public func addSequence(_ sequence: Sequence) {
        let sequences = stackedSequences.map { $0.sequence } + [sequence]

        // Update reference if this is first sequence
        if stackedSequences.isEmpty {
            referenceSequence = sequence
        }

        rebuildStackedSequences(sequences: sequences)

        multiSeqLogger.info("addSequence: Added '\(sequence.name, privacy: .public)' at index \(self.stackedSequences.count - 1)")
    }

    /// Removes a sequence at the given index.
    public func removeSequence(at index: Int) {
        guard index >= 0 && index < stackedSequences.count else { return }

        let removed = stackedSequences[index]
        multiSeqLogger.info("removeSequence: Removed '\(removed.sequence.name, privacy: .public)'")

        var sequences = stackedSequences.map { $0.sequence }
        sequences.remove(at: index)

        // Update active index if needed
        if activeSequenceIndex >= sequences.count {
            activeSequenceIndex = max(0, sequences.count - 1)
        }

        // Update reference if removed
        if removed.isReference && !sequences.isEmpty {
            referenceSequence = sequences.first
        }

        rebuildStackedSequences(sequences: sequences)
    }

    /// Sets the active sequence by index.
    public func setActiveSequence(index: Int) {
        guard index >= 0 && index < stackedSequences.count else { return }

        // Update active flags
        for i in 0..<stackedSequences.count {
            stackedSequences[i].isActive = (i == index)
        }

        activeSequenceIndex = index
        multiSeqLogger.debug("setActiveSequence: Active sequence is now index \(index)")
    }

    /// Returns the stacked sequence info at the given Y coordinate.
    public func sequenceInfo(atY y: CGFloat) -> StackedSequenceInfo? {
        guard let index = layout.trackIndex(atY: y, sequences: stackedSequences) else {
            return nil
        }
        return stackedSequences[safe: index]
    }

    /// Updates the track height for all sequences and recalculates layout.
    ///
    /// - Parameter height: New track height
    public func updateTrackHeight(_ height: CGFloat) {
        layout.trackHeight = height

        // Rebuild layout with new height
        let sequences = stackedSequences.map { $0.sequence }
        rebuildStackedSequences(sequences: sequences)

        multiSeqLogger.debug("updateTrackHeight: Set track height to \(height)")
    }

    /// Clears all sequences.
    public func clear() {
        stackedSequences = []
        referenceSequence = nil
        activeSequenceIndex = 0
        allAnnotations = []
    }

    /// Returns the total content height for the current layout.
    public var totalContentHeight: CGFloat {
        guard let lastSequence = stackedSequences.last else {
            return layout.startY
        }
        return lastSequence.yOffset + lastSequence.height + layout.spacing
    }
}

// MARK: - Array Extension

extension Array {
    /// Safe subscript that returns nil for out-of-bounds indices.
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when the active sequence changes in a multi-sequence view
    static let activeSequenceChanged = Notification.Name("com.lungfish.activeSequenceChanged")

    /// Posted when sequences are added or removed from the stack
    static let sequenceStackChanged = Notification.Name("com.lungfish.sequenceStackChanged")
}

// MARK: - NotificationUserInfoKey Extensions

public extension NotificationUserInfoKey {
    /// Key for the active sequence index in notifications
    static let activeSequenceIndex = "activeSequenceIndex"

    /// Key for the stacked sequence info in notifications
    static let stackedSequenceInfo = "stackedSequenceInfo"
}
