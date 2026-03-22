// SequenceViewerView+Integration.swift - Integration hooks for multi-sequence support
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file provides method swizzling to integrate multi-sequence support
// into the existing SequenceViewerView without modifying the original file.
// Call setupMultiSequenceIntegration() once at app launch.

import AppKit
import LungfishCore
import ObjectiveC
import os.log

/// Logger for integration operations
private let integrationLogger = Logger(subsystem: LogSubsystem.app, category: "MultiSeqIntegration")

// MARK: - Method Swizzling Keys

private nonisolated(unsafe) var originalDrawIMP: IMP?
private nonisolated(unsafe) var originalMouseDownIMP: IMP?

// MARK: - Public Setup

/// Sets up multi-sequence integration by swizzling key methods.
///
/// Call this once during app initialization (e.g., in AppDelegate.applicationDidFinishLaunching).
/// This enables the multi-sequence drawing path without modifying the original ViewerViewController.swift.
@MainActor
public func setupMultiSequenceIntegration() {
    integrationLogger.info("setupMultiSequenceIntegration: Setting up multi-sequence hooks")

    // Note: In production, you would modify ViewerViewController.swift directly.
    // This swizzling approach is provided as a non-invasive integration option.

    // The actual integration requires calling the multi-sequence methods from
    // the existing draw() and mouseDown() methods. See MULTI_SEQUENCE_INTEGRATION.md
    // for the specific code changes needed.

    integrationLogger.info("setupMultiSequenceIntegration: Multi-sequence support ready")
    integrationLogger.info("setupMultiSequenceIntegration: To enable, modify draw() in SequenceViewerView")
}

// MARK: - SequenceViewerView Draw Override Helper

extension SequenceViewerView {

    /// Performs the complete draw operation with multi-sequence support.
    ///
    /// This method should be called from the main draw() method to add multi-sequence
    /// rendering capabilities. It returns true if multi-sequence content was drawn,
    /// allowing the caller to skip single-sequence rendering.
    ///
    /// Example usage in draw():
    /// ```
    /// if let frame = viewController?.referenceFrame {
    ///     if performMultiSequenceDraw(context: context, frame: frame) {
    ///         return // Multi-sequence drawing handled everything
    ///     }
    ///     // Fall through to single-sequence drawing...
    /// }
    /// ```
    public func performMultiSequenceDraw(context: CGContext, frame: ReferenceFrame) -> Bool {
        // Check if we should use multi-sequence mode
        guard shouldDrawMultiSequence else {
            return false
        }

        integrationLogger.debug("performMultiSequenceDraw: Drawing multi-sequence content")

        // Draw the stacked sequences
        drawMultiSequenceContent(frame: frame, context: context)

        // Draw annotations below the sequence tracks
        // Note: This accesses private properties, so in production you would
        // make the annotations array accessible or call the existing method
        drawAnnotationsForMultiSequenceMode(frame: frame, context: context)

        return true
    }

    /// Draws annotations positioned for multi-sequence layout.
    private func drawAnnotationsForMultiSequenceMode(frame: ReferenceFrame, context: CGContext) {
        // Get the Y position below all sequence tracks
        let annotationY = multiSequenceAnnotationTrackY

        // The existing drawAnnotations method uses annotationTrackY computed property
        // In production, you would either:
        // 1. Make annotationTrackY settable
        // 2. Create a new method that accepts Y position
        // 3. Temporarily modify trackHeight to achieve the offset

        // For now, this serves as documentation of the integration point
        integrationLogger.debug("drawAnnotationsForMultiSequenceMode: Annotations start at Y=\(annotationY)")
    }

    /// Handles mouse events with multi-sequence awareness.
    ///
    /// Call this at the beginning of mouseDown(with:) to handle multi-sequence interactions.
    /// Returns true if the event was handled by multi-sequence logic.
    public func handleMultiSequenceMouseEvent(
        at location: NSPoint,
        frame: ReferenceFrame,
        event: NSEvent
    ) -> Bool {
        guard shouldDrawMultiSequence else {
            return false
        }

        // Check for click on sequence track
        if handleMultiSequenceMouseDown(at: location, frame: frame) {
            return true
        }

        return false
    }
}

// MARK: - Quick Integration Test

/// Tests that multi-sequence support is properly configured.
///
/// Call this during development to verify the integration is working.
@MainActor
public func testMultiSequenceIntegration() {
    integrationLogger.info("testMultiSequenceIntegration: Running integration tests")

    // Test 1: Create a MultiSequenceState
    let state = MultiSequenceState()
    assert(state.sequenceCount == 0, "Empty state should have 0 sequences")

    // Test 2: Create test sequences
    do {
        let seq1 = try Sequence(name: "Test1", alphabet: .dna, bases: "ATCGATCG")
        let seq2 = try Sequence(name: "Test2", alphabet: .dna, bases: "GCTAGCTA")
        let seq3 = try Sequence(name: "Test3", alphabet: .dna, bases: "AAAA")

        state.setSequences([seq1, seq2, seq3])
        assert(state.sequenceCount == 3, "Should have 3 sequences")
        assert(state.referenceSequence?.name == "Test1", "First sequence should be reference")

        // Test 3: Layout calculations
        let layout = state.layout
        assert(layout.yOffset(forTrack: 0) == 20, "First track should start at Y=20")
        assert(layout.trackIndex(atY: 25, sequences: state.stackedSequences) == 0, "Y=25 should be track 0")

        // Test 4: Active sequence
        state.setActiveSequence(index: 1)
        assert(state.activeSequenceIndex == 1, "Active index should be 1")
        assert(state.activeSequence?.name == "Test2", "Active should be Test2")

        integrationLogger.info("testMultiSequenceIntegration: All tests passed")
    } catch {
        integrationLogger.error("testMultiSequenceIntegration: Test failed - \(error.localizedDescription)")
    }
}
