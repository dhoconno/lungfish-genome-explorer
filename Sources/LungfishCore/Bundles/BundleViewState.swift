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

    // MARK: - Variant Display

    /// Whether variants are visible.
    public var showVariants: Bool

    /// Set of visible variant types (nil = show all).
    public var visibleVariantTypes: Set<String>?

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

    // MARK: - Defaults

    public static let `default` = BundleViewState(
        typeColorOverrides: [:],
        annotationColorOverrides: [:],
        annotationHeight: 16,
        annotationSpacing: 2,
        showAnnotations: true,
        visibleAnnotationTypes: nil,
        showVariants: true,
        visibleVariantTypes: nil,
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
        showVariants: Bool = true,
        visibleVariantTypes: Set<String>? = nil,
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
        self.showVariants = showVariants
        self.visibleVariantTypes = visibleVariantTypes
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
        visibleAnnotationTypes = try container.decodeIfPresent(Set<AnnotationType>.self, forKey: .visibleAnnotationTypes)
        showVariants = try container.decode(Bool.self, forKey: .showVariants)
        visibleVariantTypes = try container.decodeIfPresent(Set<String>.self, forKey: .visibleVariantTypes)
        translationColorScheme = try container.decode(AminoAcidColorScheme.self, forKey: .translationColorScheme)
        isRNAMode = try container.decode(Bool.self, forKey: .isRNAMode)
        lastChromosome = try container.decodeIfPresent(String.self, forKey: .lastChromosome)
        lastOrigin = try container.decodeIfPresent(Double.self, forKey: .lastOrigin)
        lastScale = try container.decodeIfPresent(Double.self, forKey: .lastScale)
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
        let fileURL = bundleURL.appendingPathComponent(Self.filename)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.warning("Failed to save to \(fileURL.path): \(error)")
        }
    }

    /// Deletes the view state file from a bundle directory. Silently fails.
    public static func delete(from bundleURL: URL) {
        let fileURL = bundleURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
