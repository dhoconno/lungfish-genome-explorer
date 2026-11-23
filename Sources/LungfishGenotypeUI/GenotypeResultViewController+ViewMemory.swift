// GenotypeResultViewController+ViewMemory.swift - The genotype result viewer keeps its view in the view memory store
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Seam: the store the route hands the viewer and the visit's entry points, with no behaviour yet (VS-GENO).

import AppKit
import LungfishIO
import LungfishKit
import ObjectiveC

@MainActor private var genotypeViewMemoryStoreKey: UInt8 = 0

/// The view the genotype result viewer keeps for one result.
struct GenotypeViewMemory: ViewMemoryState {
    static var kind: String { SurfaceKind.bundle(.genotypeResult).description }
    static var schemaVersion: Int { 1 }

    var summaryViewMode: String
    var layout: String
}

/// What an open reads off the main actor.
struct GenotypeViewMemoryRead: Sendable {
    let olderFile: GenotypeResultViewState?

    static func read(bundleURL: URL, store: ViewMemoryStore) -> GenotypeViewMemoryRead {
        GenotypeViewMemoryRead(olderFile: GenotypeResultViewState.load(fromBundleAt: bundleURL))
    }
}

extension GenotypeResultViewController {
    /// The store the route hands the viewer, the window's surface host's store in the app and a test's own store in a
    /// test. Nil keeps nothing.
    public var viewMemoryStore: ViewMemoryStore? {
        get { objc_getAssociatedObject(self, &genotypeViewMemoryStoreKey) as? ViewMemoryStore }
        set { objc_setAssociatedObject(self, &genotypeViewMemoryStoreKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Whether the open's restore has run, for a test to wait on.
    var viewMemoryIsSettled: Bool { true }

    /// The view the open shows before the store's view lands: the sidecar's choice, else the result's default.
    func initialSummaryViewMode(for result: ONTGenotypeResultBundleData) -> GenotypeSummaryViewMode {
        if let rawValue = annotationStore?.startingViewState.preferredSummaryViewMode,
           let mode = GenotypeSummaryViewMode(rawValue: rawValue) {
            return normalizedDisplayState(GenotypeResultDisplayState(viewportLens: .summary, summaryViewMode: mode))
                .summaryViewMode
        }
        return defaultSummaryViewMode(for: result)
    }

    func visitSummaryViewMode(for result: ONTGenotypeResultBundleData) -> GenotypeSummaryViewMode? { nil }

    func beginViewMemoryVisit(for result: ONTGenotypeResultBundleData) {}

    func leaveViewMemory() {}

    /// Reset View for the result on show.
    func resetViewMemory() {}
}
