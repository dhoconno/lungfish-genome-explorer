# Design Specification: Enhanced BP Ruler Component

**Document ID**: DESIGN-002
**Component**: EnhancedCoordinateRulerView
**Owner**: UI/UX Lead (Role 02)
**Status**: Implementation Complete
**Date**: 2024-01-15

---

## 1. Overview

The Enhanced BP Ruler component provides comprehensive genomic position awareness and navigation for the Lungfish Genome Browser. It combines three integrated visual elements:

1. **Info Bar**: Displays current visible range and total sequence context
2. **Mini-Map**: Interactive visual representation of view position within full sequence
3. **Coordinate Ruler**: Traditional tick-mark ruler with base pair labels

### Design Goals

- Provide instant awareness of viewing position within the full sequence
- Enable rapid navigation via click and drag interactions
- Support keyboard shortcuts for power users (Cmd+0, Cmd+1)
- Maintain visual consistency with macOS design language
- Ensure accessibility compliance (WCAG 2.1 AA)

---

## 2. Visual Design

### Layout Structure (56px total height)

```
+---------------------------------------------------------------------------------+
|  45,000 - 55,000 bp        of 500,000 bp total              [Fit] [100%]       |  <- 20px
+---------------------------------------------------------------------------------+
|  [=============================|////|=================================]         |  <- 16px
+---------------------------------------------------------------------------------+
|  |   45K   |   46K   |   47K   |   48K   |   49K   |   50K   |   51K   |        |  <- 20px
+---------------------------------------------------------------------------------+
```

### Component Breakdown

#### Info Bar (20px)
- **Range Display**: Monospaced font, "45,000 - 55,000 bp" format
- **Total Length**: Secondary text, "of 500,000 bp total"
- **Zoom Buttons**: Right-aligned, rounded rectangle buttons
  - [Fit] - Zoom to show entire sequence
  - [100%] - Current zoom level / reset button

#### Mini-Map (16px)
- **Track Background**: Tertiary system fill, rounded corners
- **Sequence Region**: Gray fill representing full sequence extent
- **Visible Window Thumb**: Accent color highlight, draggable
  - Minimum width: 8px (ensures clickable even when zoomed out)
  - Includes grip lines when wide enough (>20px)

#### Coordinate Ruler (20px)
- **Major Ticks**: Every calculated interval (adapts to zoom)
- **Minor Ticks**: 5x more frequent than major ticks
- **Labels**: Formatted with K/M suffixes (45K, 1.5M)

---

## 3. Color Specification

| Element | Light Mode | Dark Mode | Variable |
|---------|------------|-----------|----------|
| Background | windowBackgroundColor | windowBackgroundColor | System |
| Primary Text | labelColor | labelColor | System |
| Secondary Text | secondaryLabelColor | secondaryLabelColor | System |
| Track Background | tertiarySystemFill | tertiarySystemFill | System |
| Sequence Region | systemGray @ 40% | systemGray @ 40% | Custom |
| Thumb Fill | controlAccentColor @ 70% | controlAccentColor @ 70% | Custom |
| Thumb Border | controlAccentColor | controlAccentColor | System |
| Button Background | quaternarySystemFill | quaternarySystemFill | System |
| Button Hover | tertiarySystemFill | tertiarySystemFill | System |

---

## 4. Interaction Design

### Mini-Map Interactions

#### Click to Navigate
- **Action**: Single click on mini-map (outside thumb)
- **Result**: View centers on clicked position
- **Animation**: Immediate (no transition)

#### Drag to Pan
- **Action**: Click and drag on thumb
- **Cursor**: Open hand (hover) -> Closed hand (dragging)
- **Result**: View pans proportionally as thumb moves
- **Bounds**: Clamped to sequence extent

### Button Interactions

#### Zoom to Fit [Fit]
- **Trigger**: Click button OR Cmd+0
- **Result**: Adjust view to show entire sequence
- **Visual Feedback**: Button highlight on hover

#### Zoom Reset [100%]
- **Trigger**: Click button OR Cmd+1
- **Result**: Reset to 10,000 bp window, centered on current view
- **Visual Feedback**: Shows current zoom percentage

---

## 5. Keyboard Shortcuts

| Shortcut | Action | Description |
|----------|--------|-------------|
| Cmd+0 | Zoom to Fit | Show entire sequence in view |
| Cmd+1 | Zoom Reset | Reset to default 10,000 bp window |
| Cmd++ | Zoom In | Handled by existing ViewMenuActions |
| Cmd+- | Zoom Out | Handled by existing ViewMenuActions |

### Menu Integration

The shortcuts are already defined in `MainMenu.swift`:

```swift
// In createViewMenu()
viewMenu.addItem(
    withTitle: "Zoom to Fit",
    action: #selector(ViewMenuActions.zoomToFit(_:)),
    keyEquivalent: "0"
)
```

Add the zoom reset menu item:

```swift
viewMenu.addItem(
    withTitle: "Zoom Reset",
    action: #selector(ViewMenuActions.zoomReset(_:)),
    keyEquivalent: "1"
)
```

---

## 6. Accessibility

### VoiceOver Support
- Group role with label: "Coordinate ruler and navigation"
- Help text describes available keyboard shortcuts
- Buttons announce their function when focused

### Keyboard Navigation
- View accepts first responder
- Tab navigates between interactive elements
- Space/Enter activates focused button

### Visual Accessibility
- Minimum contrast ratios maintained (4.5:1 for text)
- Color is not sole indicator of state
- Minimum touch target size: 8px (thumb), 40x16px (buttons)

---

## 7. Implementation

### File Location
```
Sources/LungfishApp/Views/Viewer/EnhancedCoordinateRulerView.swift
```

### Class Hierarchy
```
NSView
  |
  +-- EnhancedCoordinateRulerView
        |
        +-- EnhancedCoordinateRulerDelegate (protocol)
```

### Key Properties

```swift
/// Reference frame for coordinate mapping
public var referenceFrame: ReferenceFrame?

/// Delegate for navigation callbacks
public weak var delegate: EnhancedCoordinateRulerDelegate?

/// Recommended view height
public static let recommendedHeight: CGFloat = 56
```

### Delegate Protocol

```swift
@MainActor
public protocol EnhancedCoordinateRulerDelegate: AnyObject {
    /// Navigation request from mini-map interaction
    func ruler(_ ruler: EnhancedCoordinateRulerView,
               didRequestNavigation start: Double, end: Double)

    /// Zoom to fit request (Cmd+0)
    func rulerDidRequestZoomToFit(_ ruler: EnhancedCoordinateRulerView)

    /// Zoom reset request (Cmd+1)
    func rulerDidRequestZoomReset(_ ruler: EnhancedCoordinateRulerView)
}
```

---

## 8. Integration Guide

### Step 1: Replace Existing Ruler

In `ViewerViewController.loadView()`, replace:

```swift
// OLD
rulerView = CoordinateRulerView()
rulerView.translatesAutoresizingMaskIntoConstraints = false
containerView.addSubview(rulerView)

// NEW
let enhancedRuler = EnhancedCoordinateRulerView()
enhancedRuler.translatesAutoresizingMaskIntoConstraints = false
enhancedRuler.delegate = self
containerView.addSubview(enhancedRuler)
rulerView = enhancedRuler  // If keeping backward compatibility
```

### Step 2: Update Layout Constraint

```swift
// OLD
rulerView.heightAnchor.constraint(equalToConstant: 28)

// NEW
rulerView.heightAnchor.constraint(equalToConstant: EnhancedCoordinateRulerView.recommendedHeight)
```

### Step 3: Conform to Delegate

The ViewerViewController extension is already provided in the component file:

```swift
extension ViewerViewController: EnhancedCoordinateRulerDelegate {
    public func ruler(_ ruler: EnhancedCoordinateRulerView,
                      didRequestNavigation start: Double, end: Double) {
        referenceFrame?.start = start
        referenceFrame?.end = end
        viewerView.setNeedsDisplay(viewerView.bounds)
        ruler.needsDisplay = true
        updateStatusBar()
    }

    public func rulerDidRequestZoomToFit(_ ruler: EnhancedCoordinateRulerView) {
        zoomToFit()
    }

    public func rulerDidRequestZoomReset(_ ruler: EnhancedCoordinateRulerView) {
        // Implementation provided in component file
    }
}
```

### Step 4: Update Menu Actions (Optional)

Add zoom reset to `ViewMenuActions` protocol:

```swift
@MainActor
@objc protocol ViewMenuActions {
    // ... existing methods ...
    func zoomReset(_ sender: Any?)
}
```

---

## 9. Performance Considerations

### Rendering Optimization
- Uses Core Graphics for all drawing (no layer-backed subviews)
- Tick interval calculation adapts to zoom level
- Minor ticks only drawn when visible range warrants

### Memory Efficiency
- No image assets required
- All colors use system semantic colors
- Single tracking area for mouse events

### Responsiveness
- Immediate visual feedback on drag
- No animation delays for navigation
- Efficient needsDisplay management

---

## 10. Testing Requirements

### Unit Tests
- [ ] Thumb position calculation at various zoom levels
- [ ] Tick interval calculation for different ranges
- [ ] Number formatting (bp, Kb, Mb)
- [ ] Bounds clamping during drag

### UI Tests
- [ ] Click-to-navigate functionality
- [ ] Drag-to-pan interaction
- [ ] Zoom button functionality
- [ ] Keyboard shortcut response

### Accessibility Tests
- [ ] VoiceOver navigation
- [ ] Keyboard-only operation
- [ ] Color contrast verification

---

## 11. Future Enhancements

### Planned
- [ ] Annotations preview in mini-map (colored regions)
- [ ] GC content overview track
- [ ] Bookmark indicators

### Under Consideration
- [ ] Smooth animated transitions
- [ ] Pinch-to-zoom gesture support
- [ ] Context menu for mini-map

---

## Appendix A: Complete Code Reference

The complete implementation is available at:
```
/Users/dho/Documents/lungfish-genome-browser/Sources/LungfishApp/Views/Viewer/EnhancedCoordinateRulerView.swift
```

Total lines: ~600
Key sections:
- Lines 1-50: Documentation and imports
- Lines 51-100: Constants and colors
- Lines 101-200: State and computed properties
- Lines 201-350: Drawing methods
- Lines 351-450: Utility methods
- Lines 451-550: Mouse event handling
- Lines 551-600: Delegate protocol and integration

---

## Appendix B: Visual Reference

### State: Default (Zoomed In)
```
+-------------------------------------------------------------------------+
| 45,000 - 55,000 bp        of 500,000 bp total         [Fit]  [2%]      |
+-------------------------------------------------------------------------+
| [===============|##|================================================]  |
+-------------------------------------------------------------------------+
|  45K    46K    47K    48K    49K    50K    51K    52K    53K    54K    |
+-------------------------------------------------------------------------+
```

### State: Zoomed to Fit
```
+-------------------------------------------------------------------------+
| 1 - 500,000 bp            of 500,000 bp total         [Fit] [100%]     |
+-------------------------------------------------------------------------+
| [################################################################]     |
+-------------------------------------------------------------------------+
|    50K       100K      150K      200K      250K      300K      350K    |
+-------------------------------------------------------------------------+
```

### State: No Sequence Loaded
```
+-------------------------------------------------------------------------+
| No sequence loaded                                                      |
+-------------------------------------------------------------------------+
| [                                                                   ]   |
+-------------------------------------------------------------------------+
|     |         |         |         |         |         |         |      |
+-------------------------------------------------------------------------+
```
