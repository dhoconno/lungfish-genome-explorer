# Multi-Sequence Stacking Integration Guide

This document describes the changes needed to integrate multi-sequence stacking into the existing ViewerViewController.swift.

## Files Created

1. **MultiSequenceSupport.swift** - Core data structures:
   - `StackedSequenceInfo` - Information about each stacked sequence
   - `SequenceStackLayout` - Layout calculations
   - `MultiSequenceState` - State management for multi-sequence display

2. **SequenceViewerView+Properties.swift** - Property extensions:
   - `multiSequenceState` - State storage using associated objects
   - `isMultiSequenceMode` - Mode flag
   - `setSequences()`, `addSequence()`, etc.

3. **SequenceViewerView+MultiSequence.swift** - Drawing logic:
   - `drawStackedSequences()` - Renders multiple sequences
   - `drawSequenceTrack()` - Renders individual tracks
   - Hit testing helpers

4. **SequenceViewerView+Drawing.swift** - Drawing integration:
   - `drawMultiSequenceContent()` - Main entry point
   - Mouse handling
   - Context menus

5. **ViewerViewController+MultiSequence.swift** - Controller integration:
   - `displayDocumentWithMultipleSequences()`
   - Status bar updates

## Required Changes to ViewerViewController.swift

### 1. Update draw() method in SequenceViewerView (line ~893)

Replace the existing draw implementation with:

```swift
public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let context = NSGraphicsContext.current?.cgContext else {
        logger.warning("SequenceViewerView.draw: No graphics context available")
        return
    }

    // Background
    if isDragActive {
        context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor)
    } else {
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
    }
    context.fill(bounds)

    // Draw drag border if active
    if isDragActive {
        context.setStrokeColor(NSColor.selectedContentBackgroundColor.cgColor)
        context.setLineWidth(3)
        context.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
    }

    // Check for multi-sequence mode first
    if let frame = viewController?.referenceFrame {
        if shouldDrawMultiSequence {
            // Multi-sequence mode: draw stacked sequences
            logger.debug("SequenceViewerView.draw: Drawing \(sequenceCount) stacked sequences")
            drawMultiSequenceContent(frame: frame, context: context)

            // Draw annotations below all sequence tracks
            if showAnnotations && !annotations.isEmpty {
                drawAnnotationsForMultiSequence(frame: frame, context: context)
            }
        } else if let seq = sequence {
            // Single sequence mode (original behavior)
            logger.debug("SequenceViewerView.draw: Drawing sequence '\(seq.name, privacy: .public)'")
            drawSequence(seq, frame: frame, context: context)
        } else {
            drawPlaceholder(context: context)
        }
    } else {
        drawPlaceholder(context: context)
    }
}
```

### 2. Add annotation drawing for multi-sequence mode

Add this method to SequenceViewerView:

```swift
/// Draws annotations adjusted for multi-sequence layout
private func drawAnnotationsForMultiSequence(frame: ReferenceFrame, context: CGContext) {
    // Temporarily adjust annotationTrackY for multi-sequence layout
    let originalTrackY = trackY

    // Move annotations below all sequence tracks
    if let state = multiSequenceState {
        let sequenceHeight = state.layout.totalHeight(forSequenceCount: state.sequenceCount)
        // Draw annotations starting below all sequences
        drawAnnotationsAt(y: sequenceHeight + 10, frame: frame, context: context)
    }
}
```

### 3. Update mouseDown in SequenceViewerView (line ~1649)

Add multi-sequence handling at the start:

```swift
public override func mouseDown(with event: NSEvent) {
    guard let frame = viewController?.referenceFrame else { return }

    let location = convert(event.locationInWindow, from: nil)

    // Handle multi-sequence click first
    if shouldDrawMultiSequence {
        if handleMultiSequenceMouseDown(at: location, frame: frame) {
            // Continue with selection on the active sequence
            let basePosition = basePositionForActiveSequence(at: location, frame: frame) ?? 0
            selectionStartBase = basePosition
            selectionRange = basePosition..<(basePosition + 1)
            isSelecting = true
            setNeedsDisplay(bounds)
            updateSelectionStatus()
            return
        }
    }

    // Original single-sequence handling continues below...
    // (existing code for annotation clicks, etc.)
```

### 4. Update displayDocument() in ViewerViewController (line ~234)

Modify to handle multiple sequences:

```swift
public func displayDocument(_ document: LoadedDocument) {
    logger.info("displayDocument: Starting to display '\(document.name, privacy: .public)'")
    logger.info("displayDocument: Document has \(document.sequences.count) sequences")

    currentDocument = document

    // Check if we have multiple sequences
    if document.sequences.count > 1 {
        // Use multi-sequence display
        displayDocumentWithMultipleSequences(document)
        return
    }

    // Single sequence handling (original code)
    if let firstSequence = document.sequences.first {
        // ... rest of existing implementation
    }
}
```

### 5. Update TrackHeaderView to support multiple tracks (line ~2068)

Modify the draw method to handle multiple sequence tracks:

```swift
public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Background
    if trackNames.isEmpty {
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
    } else {
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
    }
    context.fill(bounds)

    // Draw border and labels
    if !trackNames.isEmpty {
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0))
        context.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        context.strokePath()

        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.labelColor,
        ]

        // Calculate spacing based on multi-sequence layout
        let effectiveTrackHeight = trackHeight + 4  // Match SequenceStackLayout.trackSpacing

        for (index, label) in trackNames.enumerated() {
            let rowY = trackY + CGFloat(index) * effectiveTrackHeight
            let labelSize = (label as NSString).size(withAttributes: attributes)
            let labelY = rowY + (trackHeight - labelSize.height) / 2

            let maxWidth = bounds.width - 16
            let truncatedLabel = truncateLabel(label, maxWidth: maxWidth, attributes: attributes)

            (truncatedLabel as NSString).draw(at: CGPoint(x: 8, y: labelY), withAttributes: attributes)
        }
    }
}
```

### 6. Update zoomToFit() in ViewerViewController (line ~323)

Handle multi-sequence:

```swift
public func zoomToFit() {
    // Use max sequence length for multi-sequence mode
    let seqLength: Int
    if viewerView.isMultiSequenceMode {
        seqLength = viewerView.maxSequenceLength
    } else {
        guard let sequence = viewerView.sequence else { return }
        seqLength = sequence.length
    }

    referenceFrame?.start = 0
    referenceFrame?.end = Double(seqLength)
    referenceFrame?.sequenceLength = seqLength
    viewerView.setNeedsDisplay(viewerView.bounds)
    rulerView.setNeedsDisplay(rulerView.bounds)
    updateStatusBar()
}
```

## Usage Example

```swift
// Loading a multi-FASTA file automatically triggers stacking:
let document = try await DocumentManager.shared.loadDocument(at: multiFastaURL)
viewerController.displayDocument(document)  // Will detect multiple sequences

// Programmatically adding sequences:
viewerController.viewerView.setSequences([seq1, seq2, seq3])

// Adding a sequence to existing display:
viewerController.viewerView.addSequence(newSequence)

// Switching active sequence:
viewerController.setActiveSequence(index: 2)

// Getting info about current state:
let count = viewerController.viewerView.sequenceCount
let active = viewerController.viewerView.activeSequence
```

## Testing Checklist

- [ ] Load multi-FASTA file - sequences stack correctly
- [ ] Load FASTQ file with multiple reads - reads stack
- [ ] Click on different sequence tracks - activates that track
- [ ] Selection works on active track
- [ ] Ruler shows coordinates for reference (longest) sequence
- [ ] Shorter sequences show length indicators
- [ ] Context menu works for each track
- [ ] Copy/export works for individual sequences
- [ ] Remove sequence from stack works
- [ ] Set as reference reorders correctly
- [ ] Zoom to fit shows all sequences
- [ ] Annotations appear below all sequence tracks
