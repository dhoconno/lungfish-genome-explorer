// SequenceViewerView+Properties.swift - Multi-sequence properties and integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Adds multi-sequence storage properties to SequenceViewerView using
// associated objects pattern for extension-safe property storage.

import AppKit
import LungfishCore
import ObjectiveC
import os.log

/// Logger for multi-sequence property operations
private let propLogger = Logger(subsystem: "com.lungfish.browser", category: "MultiSeqProps")

// MARK: - Associated Object Keys

private nonisolated(unsafe) var multiSequenceStateKey: UInt8 = 0
private nonisolated(unsafe) var isMultiSequenceModeKey: UInt8 = 1

// MARK: - SequenceViewerView Multi-Sequence Properties

extension SequenceViewerView {

    // MARK: - Multi-Sequence State Property

    /// State manager for multi-sequence display.
    ///
    /// When set, enables multi-sequence stacking mode. When nil, the viewer
    /// operates in single-sequence mode (default behavior).
    internal var multiSequenceState: MultiSequenceState? {
        get {
            objc_getAssociatedObject(self, &multiSequenceStateKey) as? MultiSequenceState
        }
        set {
            objc_setAssociatedObject(
                self,
                &multiSequenceStateKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Whether multi-sequence mode is active.
    public var isMultiSequenceMode: Bool {
        get {
            (objc_getAssociatedObject(self, &isMultiSequenceModeKey) as? Bool) ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &isMultiSequenceModeKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    // MARK: - Computed Properties

    /// Number of sequences currently loaded.
    public var sequenceCount: Int {
        multiSequenceState?.sequenceCount ?? (sequence != nil ? 1 : 0)
    }

    /// Index of the currently active sequence.
    public var activeSequenceIndex: Int {
        get {
            multiSequenceState?.activeSequenceIndex ?? 0
        }
        set {
            multiSequenceState?.setActiveSequence(index: newValue)
            needsDisplay = true
        }
    }

    /// Maximum sequence length across all loaded sequences.
    public var maxSequenceLength: Int {
        multiSequenceState?.maxSequenceLength ?? (sequence?.length ?? 0)
    }

    /// The currently active sequence.
    public var activeSequence: Sequence? {
        if isMultiSequenceMode {
            return multiSequenceState?.activeSequence
        } else {
            return sequence
        }
    }

    /// All loaded sequences.
    public var allSequences: [Sequence] {
        if isMultiSequenceMode {
            return multiSequenceState?.stackedSequences.map { $0.sequence } ?? []
        } else if let seq = sequence {
            return [seq]
        } else {
            return []
        }
    }

    // MARK: - Multi-Sequence Initialization

    /// Initializes multi-sequence state if not already present.
    public func initializeMultiSequenceState() {
        if multiSequenceState == nil {
            multiSequenceState = MultiSequenceState()
            propLogger.info("initializeMultiSequenceState: Created new MultiSequenceState")
        }
    }

    // MARK: - Sequence Management

    /// Sets multiple sequences for stacked display.
    ///
    /// - Parameter sequences: Array of sequences to display
    public func setSequences(_ sequences: [Sequence]) {
        propLogger.info("setSequences: Setting \(sequences.count) sequences")

        if sequences.count <= 1 {
            // Use single-sequence mode for 0 or 1 sequence
            isMultiSequenceMode = false
            if let first = sequences.first {
                setSequence(first)
            }
            multiSequenceState?.clear()
            propLogger.info("setSequences: Using single-sequence mode")
        } else {
            // Use multi-sequence mode
            isMultiSequenceMode = true
            initializeMultiSequenceState()
            multiSequenceState?.setSequences(sequences)

            // Also set the primary sequence for backward compatibility
            if let refSeq = multiSequenceState?.referenceSequence {
                setSequence(refSeq)
            }

            propLogger.info("setSequences: Using multi-sequence mode with \(sequences.count) sequences")
        }

        needsDisplay = true
    }

    /// Adds a sequence to the stack.
    ///
    /// If this is the second sequence being added, switches to multi-sequence mode.
    ///
    /// - Parameter seq: The sequence to add
    public func addSequence(_ seq: Sequence) {
        propLogger.info("addSequence: Adding sequence '\(seq.name, privacy: .public)'")

        if !isMultiSequenceMode && sequence != nil {
            // Transitioning from single to multi mode
            initializeMultiSequenceState()
            if let existing = sequence {
                multiSequenceState?.setSequences([existing, seq])
            }
            isMultiSequenceMode = true
        } else if isMultiSequenceMode {
            multiSequenceState?.addSequence(seq)
        } else {
            // First sequence - use single mode
            setSequence(seq)
        }

        needsDisplay = true
    }

    /// Removes a sequence at the given index.
    ///
    /// - Parameter index: Index of sequence to remove
    public func removeSequence(at index: Int) {
        guard isMultiSequenceMode, let state = multiSequenceState else {
            if index == 0 {
                // Cannot clear sequence from extension - use clearSequences via controller
                needsDisplay = true
            }
            return
        }

        propLogger.info("removeSequence: Removing sequence at index \(index)")
        state.removeSequence(at: index)

        // Check if we should switch back to single mode
        if state.sequenceCount <= 1 {
            isMultiSequenceMode = false
            if let remaining = state.stackedSequences.first?.sequence {
                setSequence(remaining)
            }
            propLogger.info("removeSequence: Switched back to single-sequence mode")
        }

        needsDisplay = true
    }

    /// Clears all sequences.
    public func clearSequences() {
        propLogger.info("clearSequences: Clearing all sequences")
        multiSequenceState?.clear()
        isMultiSequenceMode = false
        needsDisplay = true
    }

    /// Sets the active sequence by index.
    ///
    /// - Parameter index: Index of sequence to make active
    public func setActiveSequenceIndex(_ index: Int) {
        guard isMultiSequenceMode else { return }
        multiSequenceState?.setActiveSequence(index: index)
        needsDisplay = true

        propLogger.info("setActiveSequenceIndex: Active sequence is now index \(index)")

        // Notify of change
        NotificationCenter.default.post(
            name: .activeSequenceChanged,
            object: self,
            userInfo: [NotificationUserInfoKey.activeSequenceIndex: index]
        )
    }

    // MARK: - Annotation Management for Multi-Sequence

    /// Updates annotations in multi-sequence mode to associate them with their sequences.
    ///
    /// This method should be called after setAnnotations when in multi-sequence mode
    /// to ensure annotations are properly grouped with their parent sequences.
    internal func updateMultiSequenceAnnotations(_ annotations: [SequenceAnnotation]) {
        guard isMultiSequenceMode, let state = multiSequenceState else { return }
        state.setAnnotations(annotations)
        propLogger.info("updateMultiSequenceAnnotations: Updated \(annotations.count) annotations in multi-sequence state")
    }

    // MARK: - Drawing Integration

    /// Determines if multi-sequence drawing should be used.
    ///
    /// Call this from draw() to decide which rendering path to use.
    internal var shouldDrawMultiSequence: Bool {
        isMultiSequenceMode && (multiSequenceState?.stackedSequences.count ?? 0) > 1
    }

    /// Returns the calculated annotation track Y position for multi-sequence mode.
    ///
    /// When multiple sequences are displayed, annotations appear below all sequence tracks.
    /// Note: This is deprecated - annotations are now drawn within each sequence's track area.
    internal var multiSequenceAnnotationTrackY: CGFloat {
        guard let state = multiSequenceState else {
            return trackY + trackHeight + 30
        }
        return state.totalContentHeight + 20
    }

    // MARK: - Layout Calculations

    /// Updates track height for all sequences.
    ///
    /// - Parameter height: New track height
    public func updateMultiSequenceTrackHeight(_ height: CGFloat) {
        multiSequenceState?.updateTrackHeight(height)
        needsDisplay = true
    }

    /// Returns the total content height needed for all sequences and annotations.
    public var totalContentHeight: CGFloat {
        if isMultiSequenceMode, let state = multiSequenceState {
            return state.totalContentHeight
        } else {
            return trackY + trackHeight + 200
        }
    }
}
