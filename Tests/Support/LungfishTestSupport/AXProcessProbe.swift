// AXProcessProbe.swift - Reads and performs actions through the real AX server, as another process would
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import XCTest

/// Drives the test process's own windows through `AXUIElementCreateApplication`,
/// `AXUIElementCopyActionNames` and `AXUIElementPerformAction`, the public
/// calls an AX client such as VoiceOver or axdrive makes.
///
/// The Swift getters (`accessibilityCustomActions()` and friends) skip the AX
/// server's own mapping, which is exactly where AppKit has surprised us: a
/// button reaches the server as its cell, a table cell as a private proxy,
/// and custom actions are served under encoded names. A passing check here
/// means an out-of-process client sees and can run the action.
///
/// A request to the process's own pid is answered on the calling thread, so
/// the calls run on the main thread. The process must be trusted for accessibility (`isAvailable`);
/// tests skip rather than fake a result when it is not. Windows must be
/// ordered front to appear in the application's window list.
@MainActor
public enum AXProcessProbe {
    public static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Matches an element by role and by any of its title, description,
    /// identifier or help text.
    public struct Query: Sendable {
        public var role: String?
        public var text: String?
        public var nth: Int
        public init(role: String? = nil, text: String? = nil, nth: Int = 1) {
            self.role = role
            self.text = text
            self.nth = nth
        }
    }

    private static var finished = false

    /// Makes the test process look like an application an AX client can
    /// attach to. Without `finishLaunching` the AX server answers every
    /// request with "not implemented".
    public static func prepare() {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular { app.setActivationPolicy(.regular) }
        if !finished { finished = true; app.finishLaunching() }
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    // MARK: - Public checks

    /// The custom action names of the element `query` finds, decoded from the
    /// server's encoded form, or nil when no element matches.
    public static func customActionNames(_ query: Query) -> [String]? {
        offMain {
            guard let element = find(query) else { return nil }
            return decodedNames(of: element)
        }
    }

    /// The value of the `AXCustomActions` attribute of the element `query`
    /// finds, as a description, or nil when the attribute is absent. Clients
    /// that read the attribute rather than the action list see this.
    public static func customActionsAttribute(_ query: Query) -> String? {
        offMain {
            guard let element = find(query), let value = attribute(element, "AXCustomActions") else { return nil }
            return String(describing: value)
        }
    }

    /// Presses the element `query` finds with the standard `AXPress` action.
    @discardableResult
    public static func press(_ query: Query) -> Bool {
        offMain {
            guard let element = find(query) else { return false }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }

    /// The `AXValue` of the element `query` finds, as a string.
    public static func value(_ query: Query) -> String? {
        offMain {
            guard let element = find(query), let value = attribute(element, kAXValueAttribute) else { return nil }
            return String(describing: value)
        }
    }

    /// The `AXFocused` flag of the element `query` finds.
    public static func isFocused(_ query: Query) -> Bool? {
        offMain {
            guard let element = find(query) else { return nil }
            return (attribute(element, kAXFocusedAttribute) as? NSNumber)?.boolValue
        }
    }

    /// Performs the custom action `name` on the element `query` finds.
    /// Returns false when there is no such element or action, or the server
    /// reports a failure.
    @discardableResult
    public static func perform(_ name: String, on query: Query) -> Bool {
        offMain {
            guard let element = find(query) else { return false }
            return performDecoded(name, on: element)
        }
    }

    /// The custom action names of the first cell of row `row` of the `nth`
    /// table or outline, as the server lists them.
    public static func rowCellActionNames(table nth: Int = 1, row: Int) -> [String]? {
        offMain {
            guard let cell = rowCell(table: nth, row: row) else { return nil }
            return decodedNames(of: cell)
        }
    }

    /// Performs custom action `name` on the first cell of row `row`.
    @discardableResult
    public static func performRowCellAction(_ name: String, table nth: Int = 1, row: Int) -> Bool {
        offMain {
            guard let cell = rowCell(table: nth, row: row) else { return false }
            return performDecoded(name, on: cell)
        }
    }

    /// Selects the rows through the server's `AXSelectedRows`, as VoiceOver does.
    @discardableResult
    public static func selectRow(table nth: Int = 1, row: Int) -> Bool {
        offMain {
            guard let table = findTable(nth),
                  let rows = attribute(table, kAXRowsAttribute) as? [AXUIElement], rows.indices.contains(row)
            else { return false }
            return AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [rows[row]] as CFArray) == .success
        }
    }

    /// A readable dump of the windows' AX tree (role, title, description,
    /// identifier and raw action names), for failure messages.
    public static func treeDescription(depth: Int = 8) -> String {
        offMain {
            var out = ""
            @MainActor func walk(_ element: AXUIElement, _ level: Int) {
                guard level < depth else { return }
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].map { string(element, $0) ?? "" }
                let actions = rawNames(of: element).map { decode($0) ?? $0 }
                out += String(repeating: "  ", count: level) + (string(element, kAXRoleAttribute) ?? "?")
                    + " [" + labels.joined(separator: "|") + "] " + (actions.isEmpty ? "" : "\(actions)") + "\n"
                let role = string(element, kAXRoleAttribute)
                if role == "AXTable" || role == "AXOutline" { return }
                for child in children(element) { walk(child, level + 1) }
            }
            for window in windows() { walk(window, 0) }
            return out
        }
    }

    // MARK: - Off-main execution

    /// Runs `work` on the calling (main) thread. A request to the process's
    /// own pid is answered on the calling thread by the same AX server entry
    /// points an external client reaches, so the main-actor checks inside
    /// AppKit and the app's swizzles hold; sending it from another thread
    /// would run them off the main actor. The messaging timeout bounds the
    /// wait should the server not answer.
    private static func offMain<T>(_ work: @MainActor () -> T) -> T {
        prepare()
        return work()
    }

    // MARK: - AX walking (background thread only)

    private static func application() -> AXUIElement {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 5)
        return app
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func matches(_ element: AXUIElement, _ query: Query) -> Bool {
        if let role = query.role, string(element, kAXRoleAttribute) != role { return false }
        guard let text = query.text else { return true }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute]
            .contains { string(element, $0) == text }
    }

    private static func windows() -> [AXUIElement] {
        (attribute(application(), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Breadth-first search of every window. Tables and outlines are not
    /// descended into, since they can hold thousands of rows.
    private static func find(_ query: Query) -> AXUIElement? {
        var seen = 0
        var queue = windows()
        var depthLimit = 4000
        while !queue.isEmpty, depthLimit > 0 {
            depthLimit -= 1
            let element = queue.removeFirst()
            if matches(element, query) {
                seen += 1
                if seen == query.nth { return element }
            }
            let role = string(element, kAXRoleAttribute)
            if role != "AXTable", role != "AXOutline" { queue.append(contentsOf: children(element)) }
        }
        return nil
    }

    private static func findTable(_ nth: Int) -> AXUIElement? {
        var seen = 0
        var queue = windows()
        var budget = 4000
        while !queue.isEmpty, budget > 0 {
            budget -= 1
            let element = queue.removeFirst()
            let role = string(element, kAXRoleAttribute)
            if role == "AXTable" || role == "AXOutline" {
                seen += 1
                if seen == nth { return element }
                continue
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }

    private static func rowCell(table nth: Int, row: Int) -> AXUIElement? {
        guard let table = findTable(nth),
              let rows = attribute(table, kAXRowsAttribute) as? [AXUIElement], rows.indices.contains(row)
        else { return nil }
        return children(rows[row]).first ?? rows[row]
    }

    // MARK: - Encoded action names

    /// A custom action reaches the client as "Name:<name>\nTarget:0x0\nSelector:(null)".
    private static func decode(_ raw: String) -> String? {
        for line in raw.split(separator: "\n") where line.hasPrefix("Name:") {
            return String(line.dropFirst("Name:".count))
        }
        return nil
    }

    private static func rawNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String]) ?? []
    }

    private static func decodedNames(of element: AXUIElement) -> [String] {
        rawNames(of: element).compactMap(decode)
    }

    private static func performDecoded(_ name: String, on element: AXUIElement) -> Bool {
        guard let raw = rawNames(of: element).first(where: { decode($0) == name }) else { return false }
        return AXUIElementPerformAction(element, raw as CFString) == .success
    }
}
