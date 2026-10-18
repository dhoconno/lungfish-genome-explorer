// BundleLoadProbe.swift - Test seam that observes decodes of large bundle files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Observes each decode of a bundle manifest or a mapping result.
///
/// A reference with hundreds of thousands of sequences has a manifest of
/// hundreds of megabytes, and its mapping result lists every sequence again.
/// Each decode takes seconds and gigabytes, so opening one must decode each
/// file once and never on the main thread. Tests install an observer here to
/// count the decodes and check the thread they run on. Release builds compile
/// the hook to nothing.
public enum BundleLoadProbe {
    /// The file a loader is about to decode.
    public enum Kind: Sendable, Equatable {
        case bundleManifest
        case mappingResult
    }

    /// Called on the decoding thread with the kind and the bundle or result folder.
    public typealias Observer = @Sendable (Kind, URL) -> Void

    #if DEBUG
    private static let observer = OSAllocatedUnfairLock<Observer?>(initialState: nil)

    /// Installs `newObserver` for every later decode, or removes it with `nil`.
    public static func install(_ newObserver: Observer?) {
        observer.withLock { $0 = newObserver }
    }
    #endif

    /// Called by `BundleManifest.load(from:)` and `MappingResult.load(from:)` before they decode.
    @inline(__always)
    public static func willDecode(_ kind: Kind, at url: URL) {
        #if DEBUG
        observer.withLock { $0 }?(kind, url)
        #endif
    }
}
