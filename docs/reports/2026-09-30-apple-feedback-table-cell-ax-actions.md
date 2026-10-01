# Apple Feedback draft: NSTableView cell proxies list custom accessibility actions twice

File with Feedback Assistant (feedbackassistant.apple.com), area **macOS > AppKit**, type **Incorrect/Unexpected Behavior**.

## Title

NSTableView cell accessibility proxy reports each NSAccessibilityCustomAction twice

## Description

In a view-based NSTableView, custom actions set on an NSTableCellView (via `accessibilityCustomActions` / `setAccessibilityCustomActions(_:)`) are exposed to assistive technologies twice. The cell's accessibility element is AppKit's private `NSTableViewCellMockElement`. It serves the cell view's custom actions through the modern `accessibilityCustomActions` route and also lists the same actions again in its legacy `accessibilityActionNames` (opaque entries that `accessibilityActionDescription:` maps back to the action names). The accessibility server unions both, so `AXUIElementCopyActionNames` on the cell returns every custom action twice and VoiceOver's Actions rotor reads each action twice.

A plain NSView with the same custom actions lists each action once.

Related: custom actions set on the NSTableRowView are not exposed at all, because `accessibilityRows()` returns `NSTableRow` proxies whose `accessibilityCustomActions` never consult the row view. Developers are pushed to the cell view, where the duplication occurs.

## Steps to reproduce

1. Create a view-based NSTableView with one column and a few rows.
2. In `tableView(_:viewFor:row:)`, set `cellView.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Zoom") { true }, NSAccessibilityCustomAction(name: "Copy") { true }])`.
3. From another process, get the table's AXRows, take a row's first AXChildren element (the cell), and call `AXUIElementCopyActionNames`.
4. Or turn on VoiceOver, move to a cell and open the Actions rotor (VO-Command-Space).

## Expected

`["Name:Zoom…", "Name:Copy…"]` (plus standard actions), and VoiceOver lists Zoom and Copy once.

## Actual

`["Name:Zoom…", "Name:Copy…", "Name:Zoom…", "Name:Copy…"]`, and VoiceOver lists each action twice. Performing either entry works.

## Configuration

macOS 26.6.2 (25G…), Apple silicon, AppKit app built with Swift 6.2 (Xcode 26 toolchain). Reproduced in Lungfish Genome Explorer (open source, github.com/dhoconno/lungfish-genome-explorer), see `Sources/LungfishKit/Accessibility/TableCellProxyActionFix.swift` for the analysis and our guarded workaround.
