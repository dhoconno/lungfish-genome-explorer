// MonospacedSystemFontLookups.swift - Records the SF Mono lookups a block of drawing code makes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ObjectiveC
import os

/// Runs `body` with `+[NSFont monospacedSystemFontOfSize:weight:]` swizzled, and returns the
/// point size of every lookup at `weight` made on the main thread while `body` ran. Each call
/// still reaches AppKit and returns its font, so `body` draws exactly as it would without the
/// recorder. Call it from the main thread.
///
/// That lookup is annotated non-null but returned nil under load, and a nil font in a string
/// drawing attribute dictionary makes CoreText raise. A view keeps its SF Mono fonts instead,
/// from `DrawingFont.keptMonospaced(ofSize:weight:)`, and a test proves it by drawing the view
/// inside this function and expecting no lookups.
///
/// The function is not main-actor isolated, so the swizzled block is not either, and AppKit
/// may call it from any thread.
public func monospacedSystemFontLookups(
    weight: NSFont.Weight,
    during body: () throws -> Void
) rethrows -> [CGFloat] {
    typealias Factory = @convention(c) (AnyClass, Selector, CGFloat, CGFloat) -> Unmanaged<NSFont>?

    let selector = NSSelectorFromString("monospacedSystemFontOfSize:weight:")
    guard let method = class_getClassMethod(NSFont.self, selector) else {
        preconditionFailure("NSFont no longer answers +monospacedSystemFontOfSize:weight:")
    }
    let original = method_getImplementation(method)
    let callOriginal = unsafeBitCast(original, to: Factory.self)
    let recordedWeight = weight.rawValue
    let sizes = OSAllocatedUnfairLock(initialState: [CGFloat]())
    // The font passes through unmanaged, so the recorder adds no retain or release.
    let recorder: @convention(block) (AnyClass, CGFloat, CGFloat) -> Unmanaged<NSFont>? = { fontClass, size, weight in
        if weight == recordedWeight, Thread.isMainThread {
            sizes.withLock { $0.append(size) }
        }
        return callOriginal(fontClass, selector, size, weight)
    }
    method_setImplementation(method, imp_implementationWithBlock(recorder))
    defer { method_setImplementation(method, original) }
    try body()
    return sizes.withLock { $0 }
}
