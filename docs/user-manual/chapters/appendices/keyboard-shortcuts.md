---
title: Keyboard Shortcuts
chapter_id: appendices/keyboard-shortcuts
audience: bench-scientist
prereqs: []
estimated_reading_min: 4
task: Look up the keyboard shortcut for any common Lungfish operation.
tags: [reference, shortcuts, productivity, macos]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A reference of every keyboard shortcut available in Lungfish on macOS. Shortcuts follow Apple Human Interface Guidelines so most chords match the conventions used elsewhere on the Mac. Use this appendix as a quick lookup or print it for the bench.

All shortcuts use standard Mac modifier keys: Cmd (command), Opt (option, also labeled Alt), Shift, and Ctrl (control).

## Project window

Project-level commands for creating, opening, and closing project bundles.

| Action | Shortcut |
|---|---|
| New Project | Cmd-N |
| Open Project | Cmd-O |
| Save Project | Cmd-S |
| Close Window | Cmd-W |
| Quit Lungfish | Cmd-Q |
| Hide Lungfish | Cmd-H |
| Minimize Window | Cmd-M |

## View

The four panels that frame the main viewport. The sidebar lists project items, the Inspector shows metadata for the current selection, the Operations Panel surfaces every running and completed pipeline, and the Document Inspector exposes manifest-level metadata for the active bundle.

| Action | Shortcut |
|---|---|
| Show or Hide Sidebar | Cmd-Shift-S |
| Show or Hide Inspector | Cmd-Opt-I |
| Operations Panel | Cmd-Shift-P |
| Document Inspector | Cmd-Opt-D |
| AI Assistant Panel | Cmd-Shift-A |
| Enter Full Screen | Cmd-Ctrl-F |

## Import and tools

Bring data into a project and reach Lungfish-wide tooling.

| Action | Shortcut |
|---|---|
| Import Center | Cmd-Shift-I |
| Plugin Manager | Cmd-Shift-B |
| Settings | Cmd-, |

## Navigation

Move the viewport to a coordinate or named feature. Both work in any sequence-aware view.

| Action | Shortcut |
|---|---|
| Go to Location | Cmd-L |
| Go to Gene | Cmd-Shift-G |

`Go to Location` accepts numeric coordinates or `chr:start-end` style ranges. `Go to Gene` matches gene names from the active GFF or GenBank annotation.

## Sequence operations

Act on the region currently visible in the sequence viewport. Lungfish writes outputs of Extract operations into the project's `Reference Sequences/` folder; Copy operations place FASTA text on the system clipboard.

| Action | Shortcut |
|---|---|
| Extract Visible Region | Cmd-Shift-E |
| Copy Visible Region as FASTA | Cmd-Shift-C |
| Translate | Cmd-Shift-T |
| Reverse Complement | Cmd-Shift-R |

`Translate` and `Reverse Complement` open the standard FASTQ/FASTA Operations dialog for the selected range. If no range is selected, the active visible sequence is used.

## Editing

Standard Mac editing shortcuts work in every text field, table, and viewport selection.

| Action | Shortcut |
|---|---|
| Undo | Cmd-Z |
| Redo | Cmd-Shift-Z |
| Cut | Cmd-X |
| Copy | Cmd-C |
| Paste | Cmd-V |
| Select All | Cmd-A |
| Find | Cmd-F |

`Cmd-Shift-G` is overloaded: in a sequence viewport it triggers `Go to Gene`; in a text-find context it steps to the previous match. Lungfish dispatches based on which view has focus.

## Help

| Action | Shortcut |
|---|---|
| Lungfish Help | Cmd-? |

`Cmd-?` opens this user manual in the default browser, scoped to the chapter that matches the current viewport when possible.

## Mouse and trackpad

Shortcuts are not the only way to drive Lungfish. The viewport responds to standard Mac gestures: scroll vertically to pan along the sequence, pinch on a trackpad to zoom in or out, and right-click any item in the sidebar for a context menu of operations.

## Memorizing chords

A few patterns repeat across the menu structure. `Cmd-Shift-letter` usually opens or toggles a panel (Sidebar, Operations, AI Assistant, Plugin Manager, Import Center). On a sequence verb, `Cmd-Shift-letter` performs an action on the visible region (Extract, Copy, Translate, Reverse Complement). `Cmd-Opt-letter` targets inspectors (Inspector, Document Inspector). When in doubt, click the menu bar entry; the chord appears on the right side of the row.

## Customizing shortcuts

Any Lungfish menu item can be remapped from System Settings. Open System Settings, click Keyboard, then Keyboard Shortcuts, then App Shortcuts. Click the plus button, choose Lungfish, and enter the exact menu title (for example, `Reverse Complement`). Press the new chord and click Add. System Settings overrides the built-in chord on next launch. To restore defaults, delete the custom entry from the same panel.

## Accessibility

VoiceOver reads every menu item and shortcut. To hear the full menu bar, press `Ctrl-Opt-M`. Full Keyboard Access (System Settings, Keyboard, Keyboard Navigation) lets the reader reach every control without a pointer; Tab moves between regions and Space activates the focused control.

## Next

See [CLI Reference](cli-reference.md) for the equivalent command-line surface, or [Troubleshooting](troubleshooting.md) when a shortcut does not appear to work.
