// BundleManifest+StoredForm.swift - The manifest as `save` writes it, and its browser summary in memory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Observes each build of a browser summary from a manifest's chromosomes and tracks.
///
/// A reference with hundreds of thousands of sequences builds a summary of as many rows, so an open builds it
/// once and never on the main thread. Tests install an observer here to count the builds and check the thread
/// they run on. Release builds compile the hook to nothing.
public enum BrowserSummarySynthesisProbe {
    /// Called on the building thread with the identifier of the manifest whose summary is built.
    public typealias Observer = @Sendable (String) -> Void

    #if DEBUG
    private static let observer = OSAllocatedUnfairLock<Observer?>(initialState: nil)

    /// Installs `newObserver` for every later build, or removes it with `nil`.
    public static func install(_ newObserver: Observer?) {
        observer.withLock { $0 = newObserver }
    }
    #endif

    /// Called by ``BundleManifest/withSynthesizedBrowserSummaryIfNeeded()`` before it builds a summary.
    @inline(__always)
    static func willSynthesize(_ identifier: String) {
        #if DEBUG
        observer.withLock { $0 }?(identifier)
        #endif
    }
}

extension BundleManifest {
    /// The manifest as ``save(to:)`` writes it (lane 12.37, F5a). A stored browser summary that equals the one
    /// synthesized from `genome` and the track lists, compared on every field with the aggregate and the metrics,
    /// is left out, since a reader builds the same summary in memory. A stored summary that differs, such as one
    /// with measured metrics or one written by an older build for other tracks, is kept as it is. A manifest
    /// without a stored summary is written without one. `==` treats both forms as equal.
    public var storedForm: BundleManifest {
        guard let browserSummary, browserSummary == synthesizedBrowserSummary() else { return self }
        return copy(browserSummary: .some(nil))
    }

    /// The manifest with its browser summary in memory: the stored one, or, for a manifest with a genome and
    /// none stored, the one synthesized from `genome` and the track lists. It keeps `modifiedDate` and writes
    /// nothing, so a reader may call it. Opening a reference calls it once, off the main actor.
    public func withSynthesizedBrowserSummaryIfNeeded() -> BundleManifest {
        guard browserSummary == nil, genome != nil else { return self }
        BrowserSummarySynthesisProbe.willSynthesize(identifier)
        guard let synthesized = synthesizedBrowserSummary() else { return self }
        return copy(browserSummary: .some(synthesized))
    }
}
