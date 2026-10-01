// AccessibilityRowProbe.swift - Reads table and outline row actions the way an AX client does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest

/// Reads a table or outline row's custom actions the way an accessibility
/// client does.
///
/// AppKit answers `accessibilityRows()` with private `NSTableRow` proxies
/// whose children (`AXChildren`) are cell proxies. Only the cell proxies
/// forward `AXCustomActions`, to the cell view they stand for. Walking this
/// path from inside the process exercises the same forwarding the AX server
/// uses, so a passing assertion here means an external AX client sees the
/// actions too. The proxies are not `NSView`s and only speak the legacy
/// attribute API, hence the selector calls.
///
/// `NSOutlineView` is an `NSTableView`, so the same walk applies to outline
/// rows through ``outlineRowProxies(of:)``. Collapsed children are not rows,
/// so expand the outline first when the test needs them.
@MainActor
public enum AccessibilityRowProbe {
    /// The AX row proxies of `table`, as AppKit hands them to the AX server.
    public static func rowProxies(of table: NSTableView) -> [AnyObject] {
        let rows = (table.accessibilityRows() as NSArray?) ?? NSArray()
        return (0..<rows.count).map { rows.object(at: $0) as AnyObject }
    }

    /// The AX row proxies of `outline`, one per expanded row in display order.
    public static func outlineRowProxies(of outline: NSOutlineView) -> [AnyObject] {
        rowProxies(of: outline)
    }

    /// The custom action names the row proxy itself reports.
    public static func rowActionNames(_ rowProxy: AnyObject) -> [String] {
        actionNames(of: rowProxy)
    }

    /// The custom action names of each cell proxy under the row, in order.
    public static func cellActionNames(_ rowProxy: AnyObject) -> [[String]] {
        cellProxies(of: rowProxy).map { actionNames(of: $0) }
    }

    /// The custom action names of the first cell of the row, which is what
    /// axdrive performs against. Empty when the row has no cells.
    public static func firstCellActionNames(_ rowProxy: AnyObject) -> [String] {
        cellActionNames(rowProxy).first ?? []
    }

    /// The action names of each cell as the AX server would list them: the
    /// union of the cell proxy's legacy `accessibilityActionNames`, each
    /// mapped through `accessibilityActionDescription:`, and its modern
    /// custom actions. AppKit's proxy serves custom actions over both routes,
    /// so without `TableCellProxyActionFix` every name appears twice here,
    /// exactly as `AXUIElementCopyActionNames` reports it to a client.
    public static func servedCellActionNames(_ rowProxy: AnyObject) -> [[String]] {
        cellProxies(of: rowProxy).map { cell in
            legacyActionDescriptions(of: cell) + actionNames(of: cell)
        }
    }

    /// The action names a button or other cell-backed control lists to an AX
    /// client. The server exposes an `NSControl` as its cell, so this reads
    /// the cell the way ``servedCellActionNames(_:)`` reads a table cell
    /// proxy: the legacy action names mapped through their descriptions plus
    /// the modern custom actions. A name listed twice here is listed twice
    /// to VoiceOver.
    public static func servedActionNames(ofControl control: NSControl) -> [String] {
        let element: AnyObject = control.cell ?? control
        return legacyActionDescriptions(of: element) + actionNames(of: element)
    }

    private static func legacyActionDescriptions(of element: AnyObject) -> [String] {
        let namesSelector = NSSelectorFromString("accessibilityActionNames")
        let describeSelector = NSSelectorFromString("accessibilityActionDescription:")
        guard element.responds(to: namesSelector),
              let names = element.perform(namesSelector)?.takeUnretainedValue() as? [AnyObject]
        else { return [] }
        return names.compactMap { entry in
            guard let name = entry as? String else { return nil }
            guard element.responds(to: describeSelector),
                  let description = element.perform(describeSelector, with: name as NSString)?
                    .takeUnretainedValue() as? String
            else { return name }
            return description
        }
    }

    /// Runs the named custom action on the first cell proxy that offers it.
    public static func performCellAction(named name: String, in rowProxy: AnyObject) -> Bool {
        for child in cellProxies(of: rowProxy) {
            if let action = actions(of: child).first(where: { $0.name == name }) {
                return action.handler?() ?? false
            }
        }
        return false
    }

    private static func cellProxies(of rowProxy: AnyObject) -> [AnyObject] {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard rowProxy.responds(to: selector),
              let children = rowProxy.perform(selector, with: "AXChildren" as NSString)?.takeUnretainedValue() as? NSArray
        else { return [] }
        return (0..<children.count).map { children.object(at: $0) as AnyObject }
    }

    private static func actions(of element: AnyObject) -> [NSAccessibilityCustomAction] {
        let selector = NSSelectorFromString("accessibilityCustomActions")
        guard element.responds(to: selector),
              let array = element.perform(selector)?.takeUnretainedValue() as? NSArray
        else { return [] }
        return (0..<array.count).compactMap { array.object(at: $0) as? NSAccessibilityCustomAction }
    }

    private static func actionNames(of element: AnyObject) -> [String] {
        actions(of: element).map(\.name)
    }
}
