// TableCellProxyActionFix.swift - Stops AppKit listing every cell custom action twice
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ObjectiveC

/// Makes AppKit's private table cell proxy report each custom action once.
///
/// `NSTableView` hands the AX server one `NSTableViewCellMockElement` per
/// cell. The proxy forwards the cell view's `accessibilityCustomActions`
/// through the modern route, as every `NSView` does, and also through the
/// legacy route: its `accessibilityActionNames` lists the same custom actions
/// again as opaque strings, with `accessibilityActionDescription:` mapping
/// each string back to the action's name. The AX server unions both routes,
/// so `AXUIElementCopyActionNames` on a cell returns every custom action
/// twice and VoiceOver reads each one twice (verified on macOS 26 with a
/// cross-process harness; neutralising either route alone lists each action
/// once and performing still works).
///
/// A real `NSView` keeps its legacy list empty and serves custom actions
/// through the modern route only, so the proxy is brought in line with that:
/// its legacy list keeps every standard `AX…` action and drops the entries
/// that describe one of its own custom actions. Nothing else in the proxy is
/// touched. When the private class or method is absent the fix is a no-op,
/// and ``AccessibilityRowProbe``'s served-names check catches a duplicate
/// should AppKit's behaviour change.
@MainActor
enum TableCellProxyActionFix {
    private static var installed = false
    private typealias LegacyActionNamesIMP = @convention(c) (AnyObject, Selector) -> NSArray?

    /// Installs the fix once per process. Called from
    /// ``AccessibilityCellActions/install(_:on:)``.
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        guard let proxyClass = NSClassFromString("NSTableViewCellMockElement") else { return }
        let legacySelector = NSSelectorFromString("accessibilityActionNames")
        guard let method = class_getInstanceMethod(proxyClass, legacySelector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: LegacyActionNamesIMP.self)
        let block: @convention(block) (AnyObject) -> NSArray? = { proxy in
            guard let names = original(proxy, legacySelector) as? [AnyObject] else { return nil }
            return legacyNamesWithoutCustomActions(names, on: proxy) as NSArray
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// `names` without the entries that stand for one of `proxy`'s modern
    /// custom actions. Standard actions (`AXPress`, `AXShowMenu`, ...) are
    /// always kept.
    static func legacyNamesWithoutCustomActions(_ names: [AnyObject], on proxy: AnyObject) -> [AnyObject] {
        let customNames = Set(customActionNames(of: proxy))
        guard !customNames.isEmpty else { return names }
        let describeSelector = NSSelectorFromString("accessibilityActionDescription:")
        return names.filter { entry in
            guard let name = entry as? String, !name.hasPrefix("AX") else { return true }
            let description = proxy.perform(describeSelector, with: name as NSString)?
                .takeUnretainedValue() as? String
            return !(description.map(customNames.contains) ?? false)
        }
    }

    private static func customActionNames(of proxy: AnyObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityCustomActions")
        guard proxy.responds(to: selector),
              let actions = proxy.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction]
        else { return [] }
        return actions.map(\.name)
    }
}
