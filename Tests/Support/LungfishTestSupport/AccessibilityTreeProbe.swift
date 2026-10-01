// AccessibilityTreeProbe.swift - Walks a hosted SwiftUI view's NSAccessibility tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Hosts a SwiftUI view in a window and reads its accessibility tree the
/// way VoiceOver and AX-driven automation do.
///
/// SwiftUI builds its accessibility nodes only once an assistive client is
/// attached, which ``host(_:size:)`` announces through the app-level
/// `AXEnhancedUserInterface` attribute. The nodes are not `NSView`s and only
/// speak the informal NSAccessibility protocol, hence the selector calls.
/// Waits run on a clock deadline and return as soon as the condition holds.
@MainActor
public enum AccessibilityTreeProbe {

    /// Hosts `content` in an ordered-front window and returns the window,
    /// the root of the tree to walk. The caller keeps the window alive and
    /// orders it out afterwards.
    public static func host<Content: View>(_ content: Content, size: CGSize = CGSize(width: 460, height: 720)) -> NSWindow {
        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        return window
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes,
    /// returning as soon as it does.
    public static func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    public static func children(of element: NSObject) -> [NSObject] {
        let modern = ((element as AnyObject).accessibilityChildren?() ?? nil) ?? []
        if !modern.isEmpty { return modern.compactMap { $0 as? NSObject } }
        return ((element.accessibilityAttributeValue(.children) as? [Any]) ?? []).compactMap { $0 as? NSObject }
    }

    public static func all(in root: NSObject) -> [NSObject] {
        [root] + children(of: root).flatMap { all(in: $0) }
    }

    public static func element(in root: NSObject, identifier: String) -> NSObject? {
        all(in: root).first { self.identifier($0) == identifier }
    }

    public static func elements(in root: NSObject, labelled label: String) -> [NSObject] {
        all(in: root).filter { self.label($0) == label }
    }

    public static func identifier(_ element: NSObject) -> String? {
        (element as AnyObject).accessibilityIdentifier?() ?? nil
    }

    public static func label(_ element: NSObject) -> String? {
        (element as AnyObject).accessibilityLabel?() ?? nil
    }

    public static func role(_ element: NSObject) -> String? {
        ((element as AnyObject).accessibilityRole?() ?? nil)?.rawValue
    }

    public static func subrole(_ element: NSObject) -> String? {
        ((element as AnyObject).accessibilitySubrole?() ?? nil)?.rawValue
    }

    /// The value through the modern protocol, which is what VoiceOver and
    /// the AX API read. The legacy `.value` attribute of a SwiftUI text node
    /// echoes its text instead of a value set with `.accessibilityValue`.
    public static func value(_ element: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        if element.responds(to: selector),
           let value = element.perform(selector)?.takeUnretainedValue() as? String {
            return value
        }
        return element.accessibilityAttributeValue(.value) as? String
    }

    public static func help(_ element: NSObject) -> String? {
        (element as AnyObject).accessibilityHelp?() ?? nil
    }

    /// The custom actions the element offers, which is how a SwiftUI
    /// `.accessibilityAction(named:)` reaches an AX client.
    public static func customActions(_ element: NSObject) -> [NSAccessibilityCustomAction] {
        let selector = NSSelectorFromString("accessibilityCustomActions")
        guard element.responds(to: selector),
              let array = element.perform(selector)?.takeUnretainedValue() as? NSArray
        else { return [] }
        return (0..<array.count).compactMap { array.object(at: $0) as? NSAccessibilityCustomAction }
    }

    public static func customActionNames(_ element: NSObject) -> [String] {
        customActions(element).map(\.name)
    }

    /// Runs the named custom action on `element`.
    public static func performCustomAction(named name: String, on element: NSObject) -> Bool {
        guard let action = customActions(element).first(where: { $0.name == name }) else { return false }
        return action.handler?() ?? false
    }

    public static func press(_ element: NSObject) -> Bool {
        (element as AnyObject).accessibilityPerformPress?() ?? false
    }

    /// The first element whose custom actions include `name`.
    public static func element(in root: NSObject, offering name: String) -> NSObject? {
        all(in: root).first { customActionNames($0).contains(name) }
    }

    public static func dump(_ root: NSObject, depth: Int = 0) -> String {
        let line = String(repeating: "  ", count: depth)
            + "\(role(root) ?? "?")\(subrole(root).map { "/\($0)" } ?? "") | \(label(root) ?? "") | \(identifier(root) ?? "")"
            + (customActionNames(root).isEmpty ? "" : " | actions: \(customActionNames(root))")
        return ([line] + children(of: root).map { dump($0, depth: depth + 1) }).joined(separator: "\n")
    }
}
