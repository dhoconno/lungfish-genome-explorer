# Sequence-Range Context Menu Design

## Goal

Make the complete sequence-range context menu available from every target inside
`SequenceViewerView` whenever a sequence range is selected. A right-click on an
alignment track, individual read, variant, annotation, sequence track, or empty
viewer space must not hide the actions that operate on the selected range.

The zoom action will be named **Zoom to Selected Region**. Existing specialized
actions, including **Show BAM in Finder** and read-, variant-, or
annotation-specific commands, remain available.

## Root Cause

`SequenceViewerView.rightMouseDown(with:)` currently treats its hit targets as
mutually exclusive menu paths. In particular, a click in the alignment coverage
or read-display area builds the two-item alignment menu and returns before the
selection-aware path can add copy, extraction, centering, and zoom actions. At
coverage zoom, individual-read hit testing is intentionally unavailable, so the
broad alignment-track branch consistently wins.

The same structural issue can affect other specialized targets: their menus
replace rather than compose with the actions for the active sequence range.

## Scope

This change is local to the main sequence-range viewer and its existing context
menu actions. It applies anywhere `SequenceViewerView.selectionRange` represents
an actionable range, including BAM-backed mapping views and the other sequence
viewer modes that share this component.

The change does not alter selection creation, hit testing, read selection,
scientific data, extraction implementation, mapping behavior, or provenance.
The compact `MiniBAMViewController` is a separate viewer without the same
sequence-range selection model and is outside this change.

## Menu Composition

`rightMouseDown(with:)` will continue to resolve the most specific target using
the existing precedence:

1. individual read;
2. variant;
3. annotation;
4. alignment track;
5. sequence/background.

Instead of each target presenting and returning its own complete menu, a local
composer will build one menu in two parts:

1. **Target actions.** Preserve the commands specific to the resolved target,
   such as **Show BAM in Finder**, read copy/extraction, or annotation actions.
2. **Shared range actions.** When `selectionRange` is non-`nil`, append the
   existing range commands: copy, FASTA copy, extraction, **Center View Here**,
   and **Zoom to Selected Region**.

The composer will add shared commands only once. Specialized menus that already
contain a shared navigation command will use the common section instead, avoiding
duplicate separators or duplicate **Center View Here** and zoom entries.

When no range is available, the viewer retains the existing general commands,
including **Select All**, **Center View Here**, **Zoom to Fit**, translation
toggles where applicable, and **Show in Inspector**. Target-specific actions are
still composed ahead of those general commands where relevant.

`rightMouseDown(with:)` will perform one popup after target resolution and menu
composition. No app-wide command framework or responder-chain redesign is
introduced.

## Labels

The existing **Zoom to Visible Region** context-menu label will become
**Zoom to Selected Region** wherever it invokes `zoomToSelectionAction(_:)`.
Other existing range-action labels remain unchanged unless they already use the
zoom wording.

## Error and State Handling

The existing action selectors, represented objects, enabled states, and guards
remain authoritative. Menu composition introduces no new I/O or failure mode.
If no selection exists, selection-only commands are omitted. If no alignment
file resolves, no reveal command is added. A click position continues to be
clamped and stored before menu construction so **Center View Here** behaves as it
does today.

## Testing

Add a non-presenting internal test seam that returns the real `NSMenu` produced
for an explicit context target. Tests will assert both visible commands and their
selectors/targets rather than synthesizing an `NSEvent` or opening a popup.

Focused regression coverage will verify:

- an alignment target with a selected range contains **Show BAM in Finder** and
  every shared range action, including **Zoom to Selected Region**;
- an individual-read target retains its read commands and also contains the
  shared range actions;
- variant and annotation targets retain their specialized commands while common
  navigation entries occur exactly once;
- sequence/background targets with a range expose the same shared range section;
- a target without a range uses the existing general commands and omits
  selection-only actions;
- action selectors and represented objects still point to the existing behavior.

Existing tests for alignment-file resolution, read selection, copy/extraction,
and zoom behavior remain in place. Focused tests will run first, followed by the
broader app test suite and an independent review.

## Alternatives Considered

### Patch only the alignment menu

Appending range actions only to `alignmentFileContextMenu` would fix the supplied
screenshot but leave individual reads and other specialized targets capable of
hiding range actions. This does not satisfy the requirement that the behavior
apply anywhere a sequence range can be selected.

### Move alignment handling below selection handling

This is mechanically smaller, but reference-bundle rendering normally maintains
a `selectionRange`. The selection branch would therefore make **Show BAM in
Finder** effectively unreachable.

### App-wide menu command registry

A generalized registry could compose commands across the application, but this
bug is confined to one viewer and already has working selectors and builders.
That abstraction would add unnecessary scope and migration risk.

The local composer is the smallest design that preserves specialized commands
and guarantees consistent sequence-range actions.
