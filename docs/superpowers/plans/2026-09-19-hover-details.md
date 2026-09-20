# Readable, Pinnable Hover Details Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task in the current authorized workflow. Steps use checkbox syntax. The coordinator assigns implementation and all compilation/tests to the user-requested lesser-model workers; this Astra investigation performs no compilation.

**Goal:** Every sequence-viewer hover fits its available space, exposes its complete content, and can be clicked to keep it open until explicitly dismissed.

**Architecture:** Retain the shared `HoverTooltipView` API, but present its content in a document-owned child `NSPanel`, independent of the sequence viewer's clipping bounds. A selectable, read-only `NSTextView` wraps and measures the same attributed string it displays, inside an `NSScrollView`; a small persistent header provides pin state, Copy, and Close. Pinned cards are immutable snapshots while the current document remains open.

**Tech Stack:** Swift, AppKit, TextKit, XCTest. No third-party dependencies.

**Spec:** User request dated 2026-09-19, item 2, and first supplied screenshot. This plan records the concrete UX specification below; no additional approval is needed under the existing authorization.

## Global Constraints

- Preserve all existing uncommitted changes; do not revert, reset, clean, or commit unrelated work.
- All compiler, test, and build invocations go through the coordinator's Sol Medium worker.
- Do not change variant values, INFO/FORMAT semantics, track identities, or scientific coordinate conventions.
- Plain-text content stays shared with existing context-menu copy actions. Formatting must never truncate scientific content.
- This is display/clipboard UI, not creation of a scientific output file or bundle. Do not introduce export provenance machinery here; the independently planned file exports must supply it.
- Keep existing `AppSettings.shared.tooltipDelay`; no appearance delay restart on every mouse-move event over the same target.

## Investigation and UX Decisions

`Sources/LungfishApp/Views/Viewer/HoverTooltipView.swift` currently clamps width to 320 after measuring an `NSTextField`; its wrapping cell can report an unsuitable natural size, and content is displayed inside a viewer subview. `repositionNear` adjusts origin but never caps height. A card larger than the viewer cannot fit regardless of its origin. `hitTest` always returns nil, making click-to-pin impossible. Delayed hide animation completion can also hide a newly shown card.

All instances of this shared class are owned by `SequenceViewerView.hoverTooltip` in `SequenceViewerView.swift`. Callers in `SequenceViewerView+Tooltips.swift` cover sample names, genotype cells, variant summary bars, reads, coverage, and annotations. No other view instantiates `HoverTooltipView`. `TaxonomyTooltipView` is a separate component and not implicated by the screenshot; avoid unrelated changes.

Use these behavior rules:

1. Short hovers shrink to their content. Normal readable width is up to 520 points, limited by the available document-window/screen intersection minus an 8-point margin. A 240-point preferred minimum is allowed only when that space exists. Height grows to content, capped at 70% of the available height; overflow scrolls vertically. Very small windows use all available space without enforcing a minimum larger than the window.
2. Anchor beside the originating pointer, try the opposite side if necessary, then clamp on both axes. Work entirely in screen coordinates after `parentView.convert(point, to: nil)` and `window.convertPoint(toScreen:)`. Never mix flipped viewer Y coordinates with screen coordinates. Select the screen containing the anchor, falling back to the document window's screen. Bound the panel to the intersection of that screen's `visibleFrame` and the document's screen-space content rectangle.
3. A transient card stays still once visible for the same text. Pointer motion must not make the card chase the pointer. Delayed show tracks the latest anchor until it appears. When content changes on a genuinely different target, replace the unpinned card.
4. Moving from the target to its hover is possible. Keep the transient card while the pointer is inside the panel, or in a narrow corridor from the original anchor to the nearest point of the panel rectangle. On leaving both, allow a 300 ms grace period. Cancel that pending hide when the pointer reaches the card. Do not restart an already pending hide indefinitely.
5. Clicking any card content or its Pin control pins it before ordinary text/button processing. The header changes from “Click to keep open” to “Pinned details”. Hovering other features does not replace pinned text. Normal viewer navigation can continue while the card remains a clearly labeled snapshot.
6. Always expose Copy and Close. Copy copies the full current plain text, not only visible or truncated content. Text selection and Command-C work in the content view after clicking. Escape closes the visible card when focus is in either its parent document or the card; it must not consume Escape in unrelated windows. Close/Escape leave the source hover suppressed until the pointer leaves it, avoiding instant reopening.
7. Explicit document/source replacement, source invalidation, parent window close, and viewer detach dismiss pinned and transient cards and clean timers/observers/monitors. A transient card disappears on application deactivation. Pinned cards may be ordered out during deactivation and restored with their parent, or dismissed; never float over other applications. The simplest consistent option is dismiss on deactivation.
8. First line is a semibold title. Colon-prefixed field names are semibold; values remain regular. Sample blocks get spacing and a semibold sample heading. Existing blank lines between overlapping variant records remain visible. Use label/secondary-label colors, a system font at least 12 pt, adequate line spacing, and native material. Do not infer new scientific groupings from arbitrary field names.
9. Long IDs, alleles, consequence strings, CIGAR strings, and URLs must character-wrap if no word break exists. Never clip or add an ellipsis. Full read CIGAR should be available rather than the current 40-character prefix.

## Review Focus

- A many-sample iVar call with long allele/consequence strings remains fully readable and copyable; height is bounded and bottom rows can be scrolled into view.
- Moving diagonally from the glyph to its card does not dismiss or replace the card, and clicking selects text without affecting the underlying viewer selection.
- A queued show/hide from an old target cannot resurrect or hide a new/pinned/dismissed card.
- Narrow windows and secondary displays with negative screen coordinates keep all controls inside the visible document/screen bounds.
- Closing or replacing a document removes its child panel and local event monitor without affecting another document's hover.

## File Ownership

- Replace internals of `Sources/LungfishApp/Views/Viewer/HoverTooltipView.swift`: shared facade, child-panel presentation, state, events, text view, header controls.
- Create `Sources/LungfishApp/Views/Viewer/HoverTooltipLayout.swift`: pure screen-coordinate layout and pointer-transit calculations, and attributed-string decoration if keeping those helpers here stays small.
- Modify `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Tooltips.swift`: pointer-transit early return, request-hide call sites, remove obsolete right-click instruction text, full read CIGAR.
- Modify only focused portions of `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`: hover construction and explicit dismissal on source invalidation/replacement/clear.
- Create `Tests/LungfishAppTests/HoverTooltipViewTests.swift` and `Tests/LungfishAppTests/HoverTooltipLayoutTests.swift`.
- Existing regression coverage: `VariantHoverDetailsTests`, `SequenceViewerReadVisibilityTests`, and `VariantInspectorParityTests`.
- Avoid modifying `SequenceViewerView+VariantDetails.swift` unless a formatting bug actually requires it; its exact plain-text tests should continue passing.

### Task 1: Content Measurement and Bounded Placement

**Interfaces:**

```swift
enum HoverTooltipLayout {
    static func panelFrame(contentSize: NSSize, anchor: NSPoint, available: NSRect) -> NSRect
    static func containsTransitPoint(_ point: NSPoint, anchor: NSPoint, panel: NSRect) -> Bool
}
```

- [ ] Write geometry tests covering bottom-right anchors, negative screen origins, a document smaller than the preferred minimum, and content taller/wider than the available rectangle. For nonempty bounds, assert containment and finite positive dimensions:

```swift
let available = NSRect(x: -1200, y: 40, width: 320, height: 210)
let frame = HoverTooltipLayout.panelFrame(
    contentSize: NSSize(width: 900, height: 2000),
    anchor: NSPoint(x: -890, y: 50), available: available)
XCTAssertTrue(available.contains(frame))
XCTAssertLessThanOrEqual(frame.width, available.width)
XCTAssertLessThanOrEqual(frame.height, available.height)
```

- [ ] Ask the compilation worker to run the focused tests, recording the expected initial missing-symbol failure.
- [ ] Implement clamping after choosing preferred/opposite anchor placement. Inset bounds by 8 only if doing so leaves positive dimensions; return `.zero` for empty bounds and suppress presentation. Use `min(max(value, lowerBound), upperBound)` only after capping dimensions, so upper bounds cannot precede lower bounds.
- [ ] Implement pointer transit by the distance from the pointer to the line segment between `anchor` and the nearest point on the panel rectangle. Include the panel rectangle expanded by 4 points. A 12-point segment radius is enough; do not use the entire bounding rectangle between anchor and panel, which could swallow unrelated targets. Tests assert an on-segment point is retained and a point 50 points sideways is not.
- [ ] Create a read-only selectable `NSTextView`: `isEditable = false`, `isSelectable = true`, `isRichText = false`, `drawsBackground = false`, `isHorizontallyResizable = false`, `isVerticallyResizable = true`, and `textContainer?.widthTracksTextView = true`. Disable automatic links/data detection to keep scientific identifiers unchanged.
- [ ] Measure with the exact attributed string and TextKit container width used for display, calling `ensureLayout(for:)` before reading `usedRect(for:)`. Set unlimited text-container height and `.byCharWrapping` paragraph behavior for unbroken tokens. Add text insets, fixed header height, and border/padding exactly once. Use native `NSScrollView.contentSize`/`frameSize` conversion if the scroller consumes width, then remeasure for the actual content width.
- [ ] Assert long text increases document height while the panel stays bounded; verify the last field is present in text storage. Keep a short-text shrink test. Ask compilation worker to rerun focused tests.

### Task 2: Shared Panel, Pinning, and Lifecycle

**Interfaces:** Preserve `show(text:near:in:)`, `hide()`, `currentText`, and the existing `isHidden` test access. Add these explicit methods/properties:

```swift
private(set) var isPinned: Bool = false
func requestHide() // ordinary pointer leave: delayed; no-op when pinned
func dismiss()     // immediate unconditional cleanup and state reset
func pin()         // snapshot currently visible content
func retainsHover(at point: NSPoint, in parentView: NSView) -> Bool
```

Keep `hide()` as an unconditional alias for `dismiss()` for source invalidation compatibility. Update only pointer-leave call sites to `requestHide()`. Do not globally change `hide()` to ignore pinned state.

- [ ] Write state tests for visible→pinned, pinned + `show(otherText)` preserving original text, pinned + `requestHide()` remaining visible, and `dismiss()` clearing text and pin state. Inject the show/hide scheduling delay or provide a small internal deterministic scheduling seam; tests must not sleep wall-clock seconds.
- [ ] Create a child `NSPanel` owned by the originating document window using `addChildWindow(_:ordered:)`. Use a panel subclass that can become key for text selection on click; transient display does not call `makeKeyAndOrderFront`. A nonactivating borderless panel is suitable, provided controls and selection work when explicitly clicked. Keep the panel at normal document-child ordering rather than a global floating level.
- [ ] Remove `addSubview(tip)` from the viewer's lazy property. Keep the facade alive through that property, with a separate panel content view. Preserve `isHidden` as presentation state for existing test hooks; detached-view tests may populate the text state without ordering any window onscreen.
- [ ] Replace the nil `hitTest` policy with ordinary native content hit-testing. Pin before dispatching mouse-down to a text view or button, using the panel's event handling or one panel-scoped mouse-down monitor; do not swallow selection/scroll/button events.
- [ ] Add visible Pin, Copy, and Close controls, with accessibility identifiers `hover-details-pin`, `hover-details-copy`, `hover-details-close`, and selectable text identifier `hover-details-text`. Copy uses an injectable `NSPasteboard` helper and includes all content. Supply accessibility labels and help for the pin state and dismissal.
- [ ] Add one local Escape monitor only while a card is presented. Handle only events whose window is the parent or panel. Return the event unchanged for unrelated windows. Close/Escape restore the parent's prior first responder only if the panel had taken keyboard focus; do not steal focus from an unrelated document.
- [ ] Guard all deferred show/hide callbacks with a monotonically increasing generation and matching target text/identity. Cancel both timers on dismissal and pin. Remove animated asynchronous hide completion or apply the same generation guard to it. Repeated `show` for the pending target must not reset its delay.
- [ ] Use weak references in callbacks and remove event monitors/notification tokens in dismissal/deinit. Observe parent close/move/resize and app deactivation. Recalculate bounded geometry on move/resize; hide when no visible bounds remain. Add lifecycle tests asserting no child window after dismissal and no stale scheduled callback changes state.
- [ ] Ask compilation worker to run `HoverTooltipViewTests|HoverTooltipLayoutTests|SequenceViewerReadVisibilityTests`.

### Task 3: Viewer Integration and Readable Content

- [ ] At the start of `SequenceViewerView.mouseMoved`, convert the event to viewer coordinates and ask `hoverTooltip.retainsHover(at:in:)`; if true, return before changing hovered annotation/read/genotype state or running the viewer hit-test chain. This protects pointer transit. Pinned cards ignore replacement internally while normal viewer status updates can continue outside the card.
- [ ] Replace `hoverTooltip.hide()` with `requestHide()` only in `SequenceViewerView+Tooltips.swift` pointer-exit/no-hit paths. Keep invalidation paths unconditional. In `viewDidMoveToWindow`, dismiss when the prior parent changes or becomes nil, then establish the new window tracking as before.
- [ ] Add unconditional dismissal at the start of `setReferenceBundle` when changing bundle URL, and `clearReferenceBundle`; retain unconditional dismissal in `invalidateAlignmentFetchState`. Same-document pan/zoom must not be wired to unconditional dismissal merely because rendering updates.
- [ ] Remove `Right-click → Copy Variant Details` from both summary and genotype display strings. The card has its own Copy button, while the existing context-menu action stays intact. Keep the formatter and copy payload unchanged.
- [ ] Replace the read tooltip's `cigarStr.prefix(40)` and ellipsis with full `cigarStr` so long read details can wrap/scroll. Decorate displayed strings without changing `currentText`: first-line title and `Sample:` headings semibold, label prefixes semibold, sample blocks with modest paragraph spacing. Do not parse fields by unrestricted colon splitting; style only the first delimiter and keep the entire original string.
- [ ] Add assertions that raw content, attributed-string `.string`, and copied payload agree exactly, including a long unbroken allele and multiline note. Extend read tooltip coverage to verify the end of a CIGAR longer than 40 characters is present. Existing exact `formatVariantDetails` expectations should stay unchanged.
- [ ] Ask compilation worker to run:

```sh
swift test --skip-update --filter 'HoverTooltipViewTests|HoverTooltipLayoutTests|VariantHoverDetailsTests|SequenceViewerReadVisibilityTests|VariantInspectorParityTests'
```

### Task 4: Native UI Verification and Handoff

- [ ] In the final Debug app, open the user's existing variant document or the corresponding fixture. Hover the same iVar call beside the Inspector and near the bottom drawer: confirm complete wrapping, no parent clipping, and access to the last sample fields by scrolling.
- [ ] Move diagonally from the variant glyph into the card, click content to pin, move over another call, and verify the original text remains. Select a substring and Command-C; use Copy to obtain the entire text. Click Close and verify it stays closed until leaving/reentering the source. Repeat with Escape while focus is in both text and document.
- [ ] Repeat short hover checks for annotation, read, coverage, and sample name. Confirm underlying selection is unchanged when clicking a hover, no stuck pointer cursor, and no hover chase.
- [ ] Resize the window smaller with Inspector and drawer open; confirm header controls remain reachable and scroll overflow. Move the window to another display if available; verify negative screen origin behavior through the geometry tests otherwise.
- [ ] Open two documents. Pin a card in the first, use Escape in the second, and verify the first card is unaffected. Close the first document and verify its panel vanishes. Switch documents/source and deactivate the app to check lifecycle cleanup.
- [ ] Send coordinator exact changed files, focused test results, and any unperformed manual checks. The coordinator handles the combined Debug build; do not independently trigger builds or commit the shared dirty checkout.
