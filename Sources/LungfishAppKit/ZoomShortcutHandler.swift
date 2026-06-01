// ZoomShortcutHandler.swift - Shared command-key zoom shortcut handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
public final class ZoomShortcutHandler {
    public typealias ZoomAction = () -> Void

    private let zoomInAction: ZoomAction
    private let zoomOutAction: ZoomAction
    private let zoomToFitAction: ZoomAction

    public init(
        zoomIn: @escaping ZoomAction,
        zoomOut: @escaping ZoomAction,
        zoomToFit: @escaping ZoomAction
    ) {
        self.zoomInAction = zoomIn
        self.zoomOutAction = zoomOut
        self.zoomToFitAction = zoomToFit
    }

    @discardableResult
    public func handleZoomShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }

        let disallowed: NSEvent.ModifierFlags = [.control, .option, .function]
        guard modifiers.intersection(disallowed).isEmpty else { return false }

        switch event.keyCode {
        case 24, 69:
            zoomInAction()
            return true
        case 27, 78:
            zoomOutAction()
            return true
        case 29, 82:
            zoomToFitAction()
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case "+", "=":
            zoomInAction()
            return true
        case "-", "_":
            zoomOutAction()
            return true
        case "0":
            zoomToFitAction()
            return true
        default:
            return false
        }
    }

    public static func shouldHandleLocalZoomShortcut(
        _ event: NSEvent,
        window: NSWindow?,
        rootView: NSView,
        responder: NSResponder?
    ) -> Bool {
        guard let window else { return false }
        guard window == event.window, window.isKeyWindow else { return false }
        guard isVisibleInHierarchy(rootView) else { return false }
        return responderIsWithinView(responder, rootView: rootView)
    }

    private static func isVisibleInHierarchy(_ rootView: NSView) -> Bool {
        guard rootView.window != nil else { return false }
        var node: NSView? = rootView
        while let current = node {
            if current.isHidden || current.alphaValue <= 0.01 {
                return false
            }
            node = current.superview
        }
        return true
    }

    private static func responderIsWithinView(_ responder: NSResponder?, rootView: NSView) -> Bool {
        var current: NSResponder? = responder
        while let next = current {
            if let view = next as? NSView, view.isDescendant(of: rootView) {
                return true
            }
            current = next.nextResponder
        }
        return false
    }
}
