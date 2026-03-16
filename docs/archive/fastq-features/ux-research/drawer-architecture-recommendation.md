# Bottom Drawer as Universal Operations Configuration Surface
## Architectural Design Recommendation

**Date:** 2026-03-10
**Status:** Proposal
**Scope:** FASTQDatasetViewController bottom drawer behavior

---

## 1. Executive Summary

**Recommendation: YES, adopt the bottom drawer as the universal configuration surface, but with a tiered hybrid approach -- not a blanket "everything in the drawer" policy.**

The current architecture already has the right instincts. The parameter bar (horizontal NSStackView above the preview canvas) handles inline controls well for simple operations. The FASTQMetadataDrawerView handles complex demux configuration with tabs. The problem is that these two systems are disconnected: the drawer is hardwired to demux metadata, and complex future operations (assembly, mapping) would need either their own drawers or disruptive modal sheets.

The recommended approach unifies these into a single adaptive drawer that responds to the selected operation in the sidebar, while preserving the parameter bar for quick-access controls.

---

## 2. Precedent Analysis

### IGV (Integrative Genomics Viewer)
- Uses modal dialogs for most configuration (File > Load, Tools > Run igvtools)
- No persistent configuration surface; parameters are set-and-forget
- Weakness: loses spatial context when configuring; user cannot see data while adjusting parameters
- Strength: simple mental model -- configure, then view

### Geneious Prime
- Bottom panel is the primary detail/configuration surface (exactly the pattern proposed here)
- Panel content changes based on selection in the document table or operation tree
- Annotations, sequences, chromatograms all share the same bottom panel real estate
- Uses a drag handle for vertical resize
- **Most relevant precedent for Lungfish -- the app already cites Geneious as inspiration**

### Galaxy
- Right-hand panel serves as the configuration surface for each workflow step
- Parameters appear contextually when a tool node is selected
- Scrollable form with collapsible sections for advanced parameters
- Run button lives at the bottom of the configuration panel, not in a global toolbar
- Weakness: panel can become very long for tools with many parameters

### CLC Genomics Workbench
- Wizard-style modal dialogs for complex operations (assembly, mapping)
- Step-by-step configuration with Back/Next navigation
- Weakness: completely loses data context; user cannot reference reads while configuring
- Strength: guided flow prevents misconfiguration for novices

### Key Takeaway
Geneious and Galaxy both demonstrate that **contextual, in-place configuration panels outperform modal dialogs** for scientific applications where users need to reference their data while configuring parameters. CLC's wizard approach is pedagogically sound but disruptive. IGV's modal approach is the weakest for parameter-heavy operations.

---

## 3. Tiered Hybrid Architecture

### Tier Classification

| Tier | Parameter Count | Configuration Surface | Drawer Behavior | Examples |
|------|----------------|----------------------|-----------------|----------|
| **Tier 1** | 1-3 params | Parameter bar only | Drawer optional (stays on previous state or collapses) | Quality trim, fixed trim, subsample, length filter, deduplicate |
| **Tier 2** | 4-8 params | Parameter bar (essentials) + drawer (advanced) | Drawer auto-opens to "Advanced" tab if closed, shows operation-specific content | Adapter removal, contaminant filter, error correction, primer removal |
| **Tier 3** | Complex / multi-step | Drawer-primary | Drawer auto-opens with full configuration tabs; parameter bar shows summary only | Demultiplexing, SPAdes assembly, read mapping, paired-end merge/repair |

### Tier Assignment for Current Operations

```
TIER 1 (Parameter Bar Only)
  - Compute Quality Report       [0 params -- just Run]
  - Subsample by Proportion      [1 param: proportion]
  - Subsample by Count           [1 param: count]
  - Filter by Read Length         [2 params: min, max]
  - Find by ID/Description       [2 params: query, field + checkboxes]
  - Find by Sequence Motif        [2 params: pattern + checkboxes]
  - Remove Duplicates             [1 param: mode popup]
  - Quality Trim                  [3 params: threshold, window, direction]
  - Fixed Trim (5'/3')            [2 params: 5' bases, 3' bases]

TIER 2 (Parameter Bar + Advanced Drawer)
  - Adapter Removal               [Essential: mode | Advanced: custom sequences, overlap, error rate]
  - Contaminant Filter            [Essential: mode | Advanced: reference DB, sensitivity, output]
  - Error Correction              [Essential: k-mer size | Advanced: algorithm, coverage, confidence]
  - Custom Primer Removal         [Essential: source | Advanced: primer list, mismatch tolerance]

TIER 3 (Drawer-Primary)
  - Demultiplex (Barcodes)        [Kit, location, symmetry, error rate, trim, sample map, scout]
  - SPAdes Assembly               [Mode, k-mers, coverage, memory, threads, paired-end, presets]
  - Read Mapping                  [Reference, algorithm, sensitivity, output format, SAM flags]
  - Merge Overlapping Pairs       [Strictness, overlap, quality handling, interleave direction]
  - Repair Paired Reads           [Pairing strategy, orphan handling, sort order]
```

---

## 4. Drawer Content Design per Operation

### 4.1 Drawer Tab Structure

The drawer should present **operation-specific tabs** that replace the current fixed Samples/Demux Setup/Barcode Kits tabs. The tab set changes when the user selects a different operation in the sidebar.

**Universal tabs** (always available regardless of operation):
- None. Every tab should be contextual. A "Samples" tab only makes sense for demux. Forcing universal tabs creates dead space.

**Per-operation tab sets:**

| Operation | Tab 1 | Tab 2 | Tab 3 |
|-----------|-------|-------|-------|
| Demultiplex | Demux Setup | Sample Map | Barcode Kits |
| SPAdes Assembly | Assembly Config | Resource Limits | Output Options |
| Read Mapping | Reference & Algorithm | SAM/BAM Options | -- |
| Adapter Removal | Advanced Settings | Custom Adapters | -- |
| Merge Pairs | Merge Settings | Quality Handling | -- |
| Contaminant Filter | Advanced Settings | Reference Database | -- |

### 4.2 Transition Behavior When Switching Operations

When the user selects a different operation in the sidebar:

1. **Tier 1 selected:** Drawer does NOT auto-close if already open (jarring). Drawer content shows a contextual help/preview panel: operation description, expected input/output, typical use cases. This turns the drawer into useful documentation rather than dead space.

2. **Tier 2 selected:** If drawer is closed, a subtle "Advanced..." disclosure button appears in the parameter bar. Clicking it opens the drawer to the advanced tab. If drawer is already open, content transitions immediately.

3. **Tier 3 selected:** If drawer is closed, it auto-opens with a smooth animation (matching the existing 0.2s ease-in-ease-out from `toggleFASTQMetadataDrawer`). Parameter bar shows a compact summary (e.g., "SPAdes -- Bacterial Isolate preset, 8 GB RAM") with an "Edit in drawer" indicator.

**State preservation:** Each operation's drawer state (scroll position, tab selection, field values) should be preserved when switching away and restored when switching back. Use a dictionary keyed by `OperationKind`.

### 4.3 Animation and Height

```
Operation switched:
  1. Cross-fade drawer content (0.15s)
  2. If height change needed, animate height constraint (0.2s, ease-in-ease-out)
  3. Tab bar updates immediately (no animation -- tabs should feel instant)
```

**Default heights by tier:**

| Tier | Default Height | Min Height | Max Height |
|------|---------------|------------|------------|
| Tier 1 (help panel) | 160 pt | 120 pt | 300 pt |
| Tier 2 (advanced) | 200 pt | 150 pt | 400 pt |
| Tier 3 (full config) | 280 pt | 200 pt | 500 pt |

Heights are persisted per-operation via UserDefaults (extending the existing `fastqMetadataDrawerHeight` pattern).

---

## 5. Drawer Resize Handle

The existing `DrawerDividerView` in AnnotationTableDrawerView.swift already implements the correct pattern:
- Grip indicator (three subtle horizontal lines at the divider center)
- `resizeUpDown` cursor rect
- `mouseDown`/`mouseDragged`/`mouseUp` tracking with delta reporting to delegate

**Recommendation:** Extract `DrawerDividerView` into a shared component (or keep it as-is and replicate the pattern in the FASTQ drawer). The FASTQ drawer should adopt the same 8pt drag handle at its top edge.

**Constraints during drag:**
- Minimum height: tier-dependent (see table above)
- Maximum height: `superview.bounds.height - 150` (preserve at least 150pt for the preview canvas above)
- Snap-to-close: if dragged below minimum, collapse the drawer entirely with a spring animation
- Double-click divider: toggle between user's last height and the tier default

---

## 6. Run/Cancel Button Placement

**Current state:** `runButton` and `cancelButton` live in a `runBar` at the bottom of the preview pane (inside the middle split view). This is correct for Tier 1 operations.

**Recommendation for Tier 3:**

When the drawer becomes the primary configuration surface, the Run button should appear in **two places**:

1. **Primary:** Bottom-right of the drawer content area (following Galaxy's pattern). This is where the user's eyes land after configuring parameters.

2. **Mirror:** The existing `runBar` position in the preview pane. Keep it there too. Having two Run buttons is not redundant -- it matches where the user's attention is depending on whether they are looking at the preview (Tier 1) or the drawer (Tier 3).

**Button state synchronization:** Both buttons share the same action and disabled state. When an operation is running, both show "Cancel" with the same progress indicator.

**Layout for drawer Run bar:**
```
[Status label ........... ] [Output estimate] [Cancel] [Run]
                                                        ^^^
                                                    Accent color,
                                                    prominent style
```

---

## 7. Progress Display

**Current pattern:** `progressIndicator` (NSProgressIndicator) and `statusLabel` in the run bar.

**Recommendation:**

- **Tier 1/2:** Progress stays in the existing run bar above the preview canvas. The preview canvas itself can animate to show progress (the OperationPreviewView already does schematic animations).

- **Tier 3:** Progress should appear in BOTH locations:
  - Run bar: determinate progress bar + percentage
  - Drawer header bar: compact progress indicator (spinning or determinate) next to the tab control
  - This ensures progress is visible whether the user is looking at the preview or the drawer

- **Long-running operations (assembly, mapping):** Add a "Background" button that minimizes the drawer but keeps a progress pill in the parameter bar area (similar to Safari's download progress). The user can continue browsing other operations or reads while assembly runs.

---

## 8. Implementation Architecture

### 8.1 Protocol-Based Drawer Content

Replace the monolithic `FASTQMetadataDrawerView` with a protocol-based system:

```swift
@MainActor
protocol OperationDrawerContent: NSView {
    /// The tabs this content provides
    var tabTitles: [String] { get }

    /// Currently selected tab index
    var selectedTabIndex: Int { get set }

    /// Preferred initial height for this content
    var preferredHeight: CGFloat { get }

    /// Minimum resize height
    var minimumHeight: CGFloat { get }

    /// The operation's current parameter state (for preservation)
    var parameterState: [String: Any] { get set }

    /// Called when the drawer is about to appear
    func drawerWillAppear()

    /// Called when the drawer is about to disappear
    func drawerWillDisappear()

    /// Build the run request from current configuration
    func buildRunRequest() -> FASTQDerivativeRequest?
}
```

### 8.2 Concrete Implementations

```
OperationDrawerContent (protocol)
  |-- DemuxDrawerContent          (migrated from FASTQMetadataDrawerView)
  |-- AssemblyDrawerContent       (migrated from AssemblyConfigurationView)
  |-- MappingDrawerContent        (new)
  |-- AdapterAdvancedContent      (new)
  |-- OperationHelpContent        (generic, for Tier 1 operations)
```

### 8.3 Drawer Container

A new `OperationDrawerContainer` replaces `FASTQMetadataDrawerView` as the actual NSView added to the view hierarchy. It manages:
- The divider/resize handle at the top
- The tab bar (NSSegmentedControl)
- Content swapping when the operation changes
- Height animation
- State preservation dictionary

```swift
@MainActor
final class OperationDrawerContainer: NSView {
    private var currentContent: (any OperationDrawerContent)?
    private var contentStateCache: [OperationKind: [String: Any]] = [:]

    func setContent(for operation: OperationKind) {
        // 1. Save current content state
        // 2. Remove current content
        // 3. Instantiate or retrieve cached content for new operation
        // 4. Restore saved state
        // 5. Animate height transition
        // 6. Update tab bar
    }
}
```

### 8.4 Migration Path

**Phase 1 (minimal disruption):**
- Extract `DrawerDividerView` resize handle to the FASTQ drawer
- Add `OperationDrawerContainer` wrapper around existing `FASTQMetadataDrawerView`
- Wire sidebar selection to update drawer content
- For non-demux operations, show `OperationHelpContent` (description + tips)

**Phase 2 (Tier 2 operations):**
- Create `AdapterAdvancedContent`, `ContaminantAdvancedContent`
- Add "Advanced..." disclosure button to parameter bar
- Implement state preservation

**Phase 3 (Tier 3 operations):**
- Migrate `AssemblyConfigurationView` from modal sheet to `AssemblyDrawerContent`
- Create `MappingDrawerContent`
- Implement dual Run button pattern
- Add background operation support

---

## 9. Risk Analysis and Mitigations

### Risk 1: Cognitive Overload from Drawer Content Churning
**Severity:** Medium
**Description:** If the drawer content changes every time the user clicks a different operation in the sidebar, it creates visual instability. Users may feel disoriented.
**Mitigation:**
- Use cross-fade transitions (not instant swaps) to signal that content is changing
- Preserve scroll position and tab selection per operation
- For Tier 1, show stable help content rather than nothing -- emptying the drawer is worse than showing something useful
- Add a subtle header in the drawer: "Quality Trim -- Advanced Settings" so the user always knows what they are looking at

### Risk 2: Vertical Space Competition
**Severity:** High
**Description:** The FASTQ viewer already has: summary bar (48pt) + sparklines (52pt) + tab control (28pt) + parameter bar (~40pt) + preview canvas (remaining) + run bar (~36pt). Adding a 280pt drawer for Tier 3 operations leaves very little for the preview canvas on a 1080p display.
**Mitigation:**
- When the drawer opens for Tier 3, collapse the sparkline strip (it is not needed during configuration)
- Allow the preview canvas to shrink to 120pt minimum -- the schematic preview is useful but not critical during configuration
- On small displays (<900pt vertical), auto-collapse the summary bar to a single-line compact mode
- The resize handle gives the user full control to find their preferred balance

### Risk 3: Two Run Buttons Cause Confusion
**Severity:** Low
**Description:** Users may not realize both Run buttons do the same thing, or may wonder which one is "correct."
**Mitigation:**
- Both buttons are visually identical (accent color, same label)
- When one is clicked, both animate simultaneously
- Consider: for Tier 3 operations, HIDE the run bar's Run button and only show it in the drawer. This avoids the dual-button question entirely. The run bar can show status/progress only.

### Risk 4: State Preservation Complexity
**Severity:** Medium
**Description:** Preserving parameter state across operation switches adds engineering complexity and potential for stale state bugs.
**Mitigation:**
- Use value-type state structs per operation (not reference types)
- Clear cached state when the FASTQ dataset changes (new file loaded)
- Unit test state round-tripping for each operation type

### Risk 5: Drawer Interferes with Keyboard Navigation
**Severity:** Low
**Description:** If the drawer captures focus, keyboard shortcuts for the preview canvas or sidebar may stop working.
**Mitigation:**
- Drawer content should not become first responder on appearance
- Respect the existing responder chain -- Tab key should cycle sidebar > parameter bar > drawer
- Escape key closes the drawer (matching the annotation drawer behavior)

### Risk 6: Assembly Configuration Regression
**Severity:** Medium
**Description:** AssemblyConfigurationView is currently a SwiftUI view presented as a modal sheet. Migrating it to a drawer means re-implementing it in AppKit (the drawer system is AppKit-native) or hosting SwiftUI inside the AppKit drawer via NSHostingView.
**Mitigation:**
- Use NSHostingView to embed the existing SwiftUI AssemblyConfigurationView inside an `AssemblyDrawerContent` wrapper. This avoids rewriting the form.
- The SwiftUI view's fixed frame (550x560) needs to become flexible. Change to `minWidth`/`maxWidth` and remove the fixed height.
- Test that the SwiftUI form scrolls correctly inside the drawer's constrained height.

---

## 10. Interaction Specification

### Scenario: User Selects Demultiplex Operation

1. User clicks "Demultiplex (Barcodes)" in the operations sidebar
2. Parameter bar updates to show: Kit popup, Location popup, "Configure in drawer..." link
3. If drawer is closed: drawer slides up with 0.2s animation to 280pt default height
4. Drawer shows three tabs: "Demux Setup" | "Sample Map" | "Barcode Kits"
5. First tab is selected by default showing step list + detail panel
6. User configures steps, assigns samples
7. Run button at bottom-right of drawer is enabled
8. User clicks Run -- progress appears in both drawer header and run bar
9. On completion, status label updates, drawer remains open for review

### Scenario: User Switches from Demultiplex to Quality Trim

1. User clicks "Quality Trim" in sidebar
2. Parameter bar updates to show: Threshold slider, Window size, Direction popup
3. Drawer content cross-fades to Tier 1 help content: "Quality Trim removes low-quality bases from read ends using a sliding window algorithm."
4. Drawer height animates from 280pt to 160pt
5. Demux state is preserved in `contentStateCache[.demultiplex]`
6. Run button is in the run bar (above preview), not in the drawer
7. User adjusts threshold, clicks Run in the run bar

### Scenario: User Switches Back to Demultiplex

1. User clicks "Demultiplex (Barcodes)" in sidebar
2. Drawer content cross-fades back, height animates to 280pt
3. All demux configuration is restored: selected step, kit, error rate, sample assignments
4. User can immediately click Run without re-configuring

---

## 11. Accessibility Considerations

- Drawer divider must be keyboard-accessible: add an accessibility action "Resize Drawer" that cycles through small/medium/large heights
- Tab control must support VoiceOver: each tab should announce its label and position ("Demux Setup, tab 1 of 3")
- When drawer auto-opens for Tier 3, VoiceOver should announce: "Configuration drawer opened for [operation name]"
- All form controls in drawer content must have accessibility labels (existing parameter bar controls already do)
- Drawer close: Escape key, or a dedicated close button with accessibility label "Close configuration drawer"

---

## 12. Summary of Recommendations

1. **Adopt the tiered hybrid approach.** Do not force all operations into the drawer. Let Tier 1 operations live in the parameter bar. Use the drawer for Tier 2 advanced settings and Tier 3 full configuration.

2. **Make the drawer operation-aware.** Replace the fixed Samples/Demux/Kits tabs with operation-specific tab sets. Use a protocol-based content system for extensibility.

3. **Add a vertical resize handle.** Port the existing `DrawerDividerView` pattern from the annotation drawer. Persist heights per operation.

4. **Keep Run buttons contextual.** For Tier 1-2, Run lives in the run bar. For Tier 3, Run lives in the drawer. Do not show both simultaneously -- it creates unnecessary cognitive load.

5. **Preserve state across operation switches.** Cache parameter values per operation so users can switch freely without losing configuration.

6. **Migrate assembly configuration from modal sheet to drawer.** Use NSHostingView to embed the existing SwiftUI form. This eliminates the context-loss problem of modal sheets.

7. **Implement in three phases.** Start with the container and help content (low risk), then Tier 2 advanced panels, then Tier 3 full migration. Each phase is independently shippable.
