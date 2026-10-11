// BundleViewState.swift - Per-bundle visual state persistence
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import os.log

/// Logger for view state persistence operations.
private let logger = Logger(subsystem: LogSubsystem.core, category: "BundleViewState")

/// Persisted visual state for a `.lungfishref` bundle.
///
/// Saved as `.viewstate.json` inside the bundle directory. Travels with
/// the bundle when shared and is auto-restored on bundle load.
///
/// ## File Location
/// ```
/// MyGenome.lungfishref/
/// ├── manifest.json
/// ├── .viewstate.json   ← this file
/// ├── genome/
/// ├── annotations/
/// └── ...
/// ```
///
/// ## App state
/// The file is declared app state (plan row S11). It sits inside the bundle but outside every
/// checksum and provenance record, because its name is hidden. The viewer writes it only after a
/// user change, so showing a bundle with no input writes nothing. `markRestored()` and
/// `saveUnlessRestored(to:)` tell a user change from the programmatic restore of the same values.
/// A `.lungfishmsa` or `.lungfishtree` bundle keeps a `.viewstate.json` that its creation wrote and
/// its manifest checksums, so nothing here writes into those bundles.
public struct BundleViewState: Codable, Sendable, Equatable {

    // MARK: - Annotation Display

    /// Per-type color overrides (user-customized). Only non-default colors are stored.
    public var typeColorOverrides: [AnnotationType: AnnotationColor]

    /// Per-annotation color overrides (user-customized via "This Only" mode).
    /// Keyed by stable annotation identifier: `"chrom:start-end:name"`.
    public var annotationColorOverrides: [String: AnnotationColor]

    /// Height of each annotation box in pixels.
    public var annotationHeight: Double

    /// Vertical spacing between annotation rows.
    public var annotationSpacing: Double

    /// Whether annotations are visible.
    public var showAnnotations: Bool

    /// Set of visible annotation types (nil = show all).
    public var visibleAnnotationTypes: Set<AnnotationType>?

    /// Search text applied to annotations.
    public var annotationFilterText: String

    // MARK: - Variant Display

    /// Whether variants are visible.
    public var showVariants: Bool

    /// Set of visible variant types (nil = show all).
    public var visibleVariantTypes: Set<String>?

    /// Search or query text applied to variants.
    public var variantFilterText: String

    /// Stable IDs of variant tracks hidden across the Calls table, genotypes, and viewport.
    public var hiddenVariantTrackIDs: Set<String>

    /// Sample row ordering, filtering, and display settings for genotype tracks.
    public var sampleDisplayState: SampleDisplayState?

    // MARK: - Translation

    /// The amino acid color scheme.
    public var translationColorScheme: AminoAcidColorScheme

    /// Whether RNA mode is active (U instead of T).
    public var isRNAMode: Bool

    // MARK: - Navigation State

    /// Last viewed chromosome name.
    public var lastChromosome: String?

    /// Last scroll origin (genomic start position).
    public var lastOrigin: Double?

    /// Last zoom scale (bp/pixel).
    public var lastScale: Double?

    // MARK: - Session Bookkeeping

    /// The state the viewer last restored or wrote, held in memory only (plan row S11).
    ///
    /// It is not saved, and `==` ignores it. A save that a programmatic restore asked for carries the
    /// values that were just restored, so it equals this state and writes nothing. A user change makes the
    /// two differ.
    fileprivate var restored = RestoredState()

    /// A snapshot of a `BundleViewState`, kept apart from the values so a state can carry the one it restored.
    fileprivate struct RestoredState: Sendable, Equatable {
        var snapshot: Snapshot?

        /// Every `RestoredState` is equal, so a snapshot never changes whether two states are equal.
        static func == (lhs: RestoredState, rhs: RestoredState) -> Bool { true }
    }

    fileprivate final class Snapshot: Sendable {
        let state: BundleViewState
        init(_ state: BundleViewState) { self.state = state }
    }

    /// The keys of the saved file. The session bookkeeping above is not one of them.
    private enum CodingKeys: String, CodingKey {
        case typeColorOverrides, annotationColorOverrides, annotationHeight, annotationSpacing
        case showAnnotations, visibleAnnotationTypes, annotationFilterText
        case showVariants, visibleVariantTypes, variantFilterText, hiddenVariantTrackIDs, sampleDisplayState
        case translationColorScheme, isRNAMode
        case lastChromosome, lastOrigin, lastScale
    }

    // MARK: - Defaults

    public static let `default` = BundleViewState(
        typeColorOverrides: [:],
        annotationColorOverrides: [:],
        annotationHeight: 16,
        annotationSpacing: 2,
        showAnnotations: true,
        visibleAnnotationTypes: nil,
        annotationFilterText: "",
        showVariants: true,
        visibleVariantTypes: nil,
        variantFilterText: "",
        hiddenVariantTrackIDs: [],
        sampleDisplayState: nil,
        translationColorScheme: .zappo,
        isRNAMode: false,
        lastChromosome: nil,
        lastOrigin: nil,
        lastScale: nil
    )

    // MARK: - Initialization

    public init(
        typeColorOverrides: [AnnotationType: AnnotationColor] = [:],
        annotationColorOverrides: [String: AnnotationColor] = [:],
        annotationHeight: Double = 16,
        annotationSpacing: Double = 2,
        showAnnotations: Bool = true,
        visibleAnnotationTypes: Set<AnnotationType>? = nil,
        annotationFilterText: String = "",
        showVariants: Bool = true,
        visibleVariantTypes: Set<String>? = nil,
        variantFilterText: String = "",
        hiddenVariantTrackIDs: Set<String> = [],
        sampleDisplayState: SampleDisplayState? = nil,
        translationColorScheme: AminoAcidColorScheme = .zappo,
        isRNAMode: Bool = false,
        lastChromosome: String? = nil,
        lastOrigin: Double? = nil,
        lastScale: Double? = nil
    ) {
        self.typeColorOverrides = typeColorOverrides
        self.annotationColorOverrides = annotationColorOverrides
        self.annotationHeight = annotationHeight
        self.annotationSpacing = annotationSpacing
        self.showAnnotations = showAnnotations
        self.visibleAnnotationTypes = visibleAnnotationTypes
        self.annotationFilterText = annotationFilterText
        self.showVariants = showVariants
        self.visibleVariantTypes = visibleVariantTypes
        self.variantFilterText = variantFilterText
        self.hiddenVariantTrackIDs = hiddenVariantTrackIDs
        self.sampleDisplayState = sampleDisplayState
        self.translationColorScheme = translationColorScheme
        self.isRNAMode = isRNAMode
        self.lastChromosome = lastChromosome
        self.lastOrigin = lastOrigin
        self.lastScale = lastScale
    }
    // MARK: - Codable (backward-compatible decoding)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typeColorOverrides = try container.decode([AnnotationType: AnnotationColor].self, forKey: .typeColorOverrides)
        annotationColorOverrides = try container.decodeIfPresent([String: AnnotationColor].self, forKey: .annotationColorOverrides) ?? [:]
        annotationHeight = try container.decode(Double.self, forKey: .annotationHeight)
        annotationSpacing = try container.decode(Double.self, forKey: .annotationSpacing)
        showAnnotations = try container.decode(Bool.self, forKey: .showAnnotations)
        visibleAnnotationTypes = Self.migrateVisibleAnnotationTypes(
            try container.decodeIfPresent(Set<AnnotationType>.self, forKey: .visibleAnnotationTypes)
        )
        annotationFilterText = try container.decodeIfPresent(String.self, forKey: .annotationFilterText) ?? ""
        showVariants = try container.decode(Bool.self, forKey: .showVariants)
        visibleVariantTypes = try container.decodeIfPresent(Set<String>.self, forKey: .visibleVariantTypes)
        variantFilterText = try container.decodeIfPresent(String.self, forKey: .variantFilterText) ?? ""
        hiddenVariantTrackIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenVariantTrackIDs) ?? []
        sampleDisplayState = try container.decodeIfPresent(SampleDisplayState.self, forKey: .sampleDisplayState)
        translationColorScheme = try container.decode(AminoAcidColorScheme.self, forKey: .translationColorScheme)
        isRNAMode = try container.decode(Bool.self, forKey: .isRNAMode)
        lastChromosome = try container.decodeIfPresent(String.self, forKey: .lastChromosome)
        lastOrigin = try container.decodeIfPresent(Double.self, forKey: .lastOrigin)
        lastScale = try container.decodeIfPresent(Double.self, forKey: .lastScale)
    }

    private static func migrateVisibleAnnotationTypes(_ types: Set<AnnotationType>?) -> Set<AnnotationType>? {
        guard var types else { return nil }

        let legacyAllVisibleBeforeSequenceAnnotations = Set(AnnotationType.allCases)
            .subtracting([.orf, .translation])
        if legacyAllVisibleBeforeSequenceAnnotations.isSubset(of: types) {
            types.insert(.orf)
            types.insert(.translation)
        }

        return types
    }
}

// MARK: - Persistence

extension BundleViewState {

    /// Standard filename inside the bundle directory.
    public static let filename = ".viewstate.json"

    /// Loads view state from a bundle directory, returning `.default` on any failure.
    ///
    /// Gracefully handles missing files, corrupted JSON, and read-only volumes.
    public static func load(from bundleURL: URL) -> BundleViewState {
        let fileURL = bundleURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            return .default
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(BundleViewState.self, from: data)
        } catch {
            logger.warning("Failed to decode \(fileURL.path): \(error)")
            return .default
        }
    }

    /// Saves view state to a bundle directory. Silently fails if the bundle is read-only.
    public func save(to bundleURL: URL) {
        _ = write(to: bundleURL)
    }

    /// Records this state as what the viewer restored or wrote, in memory only.
    public mutating func markRestored() {
        var snapshot = self
        snapshot.restored = RestoredState()
        restored.snapshot = Snapshot(snapshot)
    }

    /// Whether the viewer restored or wrote a state and this one carries the same values.
    public var matchesRestoredState: Bool {
        restored.snapshot.map { $0.state == self } ?? false
    }

    /// Saves the state unless it equals the one the viewer restored or last wrote, and records it as written.
    ///
    /// This is how the viewer keeps a programmatic restore from reaching the file. With no restored state on
    /// record the state is saved.
    ///
    /// - Returns: Whether the file was written.
    @discardableResult
    public mutating func saveUnlessRestored(to bundleURL: URL) -> Bool {
        guard !matchesRestoredState, write(to: bundleURL) else { return false }
        markRestored()
        return true
    }

    private func write(to bundleURL: URL) -> Bool {
        let fileURL = bundleURL.appendingPathComponent(Self.filename)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            logger.warning("Failed to save to \(fileURL.path): \(error)")
            return false
        }
    }

    /// Deletes the view state file from a bundle directory. Silently fails.
    public static func delete(from bundleURL: URL) {
        let fileURL = bundleURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
