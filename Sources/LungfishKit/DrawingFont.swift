// DrawingFont.swift - Nil-proof, finite-size system fonts for custom drawing code
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Why this exists: three unit-gate crash reports (2026-09-23 x2, 2026-09-25) abort inside
// `-[NSString sizeWithAttributes:]` / `-[NSAttributedString drawInRect:]` with
// "attempt to insert nil object from objects[0]" raised by
// `CoreText TAttributes::ApplyFont -> CFDictionaryCreateMutableCopy`. CoreText only takes
// that copy when it found NO usable font in the attribute dictionary, and the copy then
// meets a nil value: the `.font` slot of a Swift `[NSAttributedString.Key: Any]` literal held
// a nil `NSFont`. The two call sites involved (SequenceViewerView base letters, the MSA
// consensus row) use constant or clamped sizes, so the nil is not a NaN-size artifact
// (`max(6, .nan)` is 6 in Swift and AppKit maps a NaN size to the default size). The
// `+[NSFont *SystemFontOfSize:weight:]` factories are annotated nonnull, so Swift never
// checks their result. A nil returned under heavy parallel load (never reproduced in
// isolation) would flow straight into the attribute dictionary and abort the process.
//
// The factories here call the same AppKit class methods through a nullable C signature so
// a nil result is actually observable, fall back to a font that cannot be nil, and replace
// non-finite sizes with the system font size. For any finite size and a non-nil AppKit
// result they return exactly the font AppKit returns, so normal rendering is unchanged.

import AppKit
import CoreText
import ObjectiveC

public enum DrawingFont {
    /// Whether `size` is usable as a text point size for drawing (finite and positive).
    public static func isDrawableSize(_ size: CGFloat) -> Bool {
        size.isFinite && size > 0
    }

    /// Nil-proof `NSFont.monospacedSystemFont(ofSize:weight:)`.
    public static func monospaced(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        resolve(
            size: size,
            primary: { callSizeWeightFactory("monospacedSystemFontOfSize:weight:", $0, weight) },
            monospacedFallback: true
        )
    }

    /// Nil-proof `NSFont.monospacedDigitSystemFont(ofSize:weight:)`.
    public static func monospacedDigit(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        resolve(
            size: size,
            primary: { callSizeWeightFactory("monospacedDigitSystemFontOfSize:weight:", $0, weight) },
            monospacedFallback: false
        )
    }

    /// Nil-proof `NSFont.systemFont(ofSize:weight:)`.
    public static func system(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        resolve(
            size: size,
            primary: { callSizeWeightFactory("systemFontOfSize:weight:", $0, weight) },
            monospacedFallback: false
        )
    }

    /// Nil-proof `NSFont.systemFont(ofSize:)`.
    public static func system(ofSize size: CGFloat) -> NSFont {
        resolve(
            size: size,
            primary: { callSizeFactory("systemFontOfSize:", $0) },
            monospacedFallback: false
        )
    }

    // MARK: - Resolution (internal for tests)

    /// Sanitizes `size`, asks `primary` for the font, and falls back to a font that can
    /// never be nil when `primary` returns nil.
    static func resolve(
        size: CGFloat,
        primary: (CGFloat) -> NSFont?,
        monospacedFallback: Bool
    ) -> NSFont {
        let resolvedSize = size.isFinite ? size : NSFont.systemFontSize
        if let font = primary(resolvedSize) {
            return font
        }
        return fallbackFont(ofSize: resolvedSize, monospaced: monospacedFallback)
    }

    static func fallbackFont(ofSize size: CGFloat, monospaced: Bool) -> NSFont {
        let pointSize = isDrawableSize(size) ? size : NSFont.systemFontSize
        if monospaced, let font = NSFont.userFixedPitchFont(ofSize: pointSize) {
            return font
        }
        if !monospaced, let font = NSFont.userFont(ofSize: pointSize) {
            return font
        }
        if !monospaced, let ctFont = CTFontCreateUIFontForLanguage(.system, pointSize, nil) {
            return ctFont as NSFont
        }
        // CTFontCreateWithName always returns a font (LastResort at worst).
        let name = (monospaced ? "Menlo-Regular" : "Helvetica") as CFString
        return CTFontCreateWithName(name, pointSize, nil) as NSFont
    }

    // MARK: - Nullable AppKit calls

    private typealias SizeWeightFactory = @convention(c) (AnyClass, Selector, CGFloat, CGFloat) -> Unmanaged<NSFont>?
    private typealias SizeFactory = @convention(c) (AnyClass, Selector, CGFloat) -> Unmanaged<NSFont>?

    /// Calls an `NSFont` class factory taking `(CGFloat size, NSFontWeight weight)` through
    /// a signature whose result is nullable, so a nil from AppKit is seen instead of being
    /// laundered into a non-optional `NSFont`.
    private static func callSizeWeightFactory(_ selectorName: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(NSFont.self, selector) else { return nil }
        let factory = unsafeBitCast(method_getImplementation(method), to: SizeWeightFactory.self)
        return factory(NSFont.self, selector, size, weight.rawValue)?.takeUnretainedValue()
    }

    private static func callSizeFactory(_ selectorName: String, _ size: CGFloat) -> NSFont? {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(NSFont.self, selector) else { return nil }
        let factory = unsafeBitCast(method_getImplementation(method), to: SizeFactory.self)
        return factory(NSFont.self, selector, size)?.takeUnretainedValue()
    }
}
