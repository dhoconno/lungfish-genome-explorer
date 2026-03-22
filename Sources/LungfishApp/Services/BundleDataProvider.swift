// BundleDataProvider.swift - On-demand data provider for reference genome bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

/// Logger for bundle data provider operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "BundleDataProvider")

// MARK: - BundleDataProvider

/// Provides on-demand access to sequence and annotation data from a `.lungfishref` bundle.
///
/// `BundleDataProvider` wraps `BgzipIndexedFASTAReader` (via `ReferenceBundle`) and
/// `BigBedReader` to lazily fetch data for the currently visible genomic region. This
/// avoids loading the entire genome into memory, which is critical for large reference
/// genomes (e.g., 3 Gb human genome).
///
/// ## Thread Safety
///
/// This class is `@MainActor`-isolated because it is used directly by the viewer
/// to drive display updates. The underlying `ReferenceBundle` is `Sendable` and
/// its async methods use actor-isolated readers internally.
///
/// ## Example
///
/// ```swift
/// let provider = BundleDataProvider(bundleURL: url, manifest: manifest)
/// let bases = try await provider.fetchSequence(chromosome: "chr1", start: 0, end: 10000)
/// let annotations = try await provider.fetchAnnotations(chromosome: "chr1", start: 0, end: 10000)
/// ```
@MainActor
public final class BundleDataProvider {

    // MARK: - Properties

    /// URL of the `.lungfishref` bundle directory.
    private let bundleURL: URL

    /// The parsed bundle manifest.
    private let manifest: BundleManifest

    /// The reference bundle reader, created lazily on first data access.
    private var referenceBundle: ReferenceBundle?

    // MARK: - Initialization

    /// Creates a data provider for a reference genome bundle.
    ///
    /// The provider does not open any file handles at initialization time. Readers
    /// are created lazily on the first call to `fetchSequence` or `fetchAnnotations`.
    ///
    /// - Parameters:
    ///   - bundleURL: URL of the `.lungfishref` bundle directory
    ///   - manifest: The pre-loaded bundle manifest
    public init(bundleURL: URL, manifest: BundleManifest) {
        self.bundleURL = bundleURL
        self.manifest = manifest
        logger.info("BundleDataProvider: Initialized for '\(manifest.name, privacy: .public)' at \(bundleURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Public API

    /// Chromosomes from the bundle manifest.
    public var chromosomes: [ChromosomeInfo] {
        manifest.genome?.chromosomes ?? []
    }

    /// The bundle name from the manifest.
    public var name: String {
        manifest.name
    }

    /// The organism name from the manifest source.
    public var organism: String {
        manifest.source.organism
    }

    /// The assembly name from the manifest source.
    public var assembly: String {
        manifest.source.assembly
    }

    /// Available annotation track identifiers.
    public var annotationTrackIds: [String] {
        manifest.annotations.map { $0.id }
    }

    /// Returns information about a specific chromosome by name.
    ///
    /// - Parameter name: Chromosome name (e.g., "chr1")
    /// - Returns: The chromosome info, or `nil` if not found
    public func chromosomeInfo(named name: String) -> ChromosomeInfo? {
        manifest.genome?.chromosomes.first { $0.name == name || $0.aliases.contains(name) }
    }

    /// Fetches sequence bases for a genomic region.
    ///
    /// Uses the bundle's bgzip-compressed FASTA with `.fai` and `.gzi` indices
    /// for efficient random access. Only the blocks covering the requested region
    /// are decompressed.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based, inclusive)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: The sequence string for the region
    /// - Throws: `ReferenceBundleError` or `BgzipError` if the sequence cannot be fetched
    public func fetchSequence(chromosome: String, start: Int, end: Int) async throws -> String {
        let bundle = try ensureBundle()
        let region = GenomicRegion(chromosome: chromosome, start: start, end: end)

        logger.debug("BundleDataProvider: Fetching sequence \(region.description)")
        let sequence = try await bundle.fetchSequence(region: region)
        logger.debug("BundleDataProvider: Fetched \(sequence.count) bases")

        return sequence
    }

    /// Fetches sequence bases synchronously for a genomic region.
    ///
    /// This synchronous variant is useful during AppKit drawing where async
    /// calls cannot be awaited. Uses `SyncBgzipFASTAReader` internally.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based, inclusive)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: The sequence string for the region
    /// - Throws: `ReferenceBundleError` or `BgzipError` if the sequence cannot be fetched
    public func fetchSequenceSync(chromosome: String, start: Int, end: Int) throws -> String {
        let bundle = try ensureBundle()
        let region = GenomicRegion(chromosome: chromosome, start: start, end: end)

        logger.debug("BundleDataProvider: Sync fetching sequence \(region.description)")
        let sequence = try bundle.fetchSequenceSync(region: region)
        logger.debug("BundleDataProvider: Sync fetched \(sequence.count) bases")

        return sequence
    }

    /// Fetches annotation features for a genomic region from all annotation tracks.
    ///
    /// Queries each BigBed annotation track in the bundle and aggregates the results
    /// into `SequenceAnnotation` objects suitable for display in the viewer.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based, inclusive)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: Array of annotations in the region, from all tracks
    /// - Throws: `ReferenceBundleError` if annotations cannot be fetched
    public func fetchAnnotations(chromosome: String, start: Int, end: Int) async throws -> [SequenceAnnotation] {
        let bundle = try ensureBundle()
        let region = GenomicRegion(chromosome: chromosome, start: start, end: end)

        var allAnnotations: [SequenceAnnotation] = []

        for trackInfo in manifest.annotations {
            do {
                let trackAnnotations = try await bundle.getAnnotations(trackId: trackInfo.id, region: region)
                allAnnotations.append(contentsOf: trackAnnotations)
                logger.debug("BundleDataProvider: Fetched \(trackAnnotations.count) annotations from track '\(trackInfo.id, privacy: .public)'")
            } catch {
                // Log warning but continue with other tracks
                logger.warning("BundleDataProvider: Failed to fetch annotations from '\(trackInfo.id, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }

        logger.debug("BundleDataProvider: Total \(allAnnotations.count) annotations for \(region.description)")
        return allAnnotations
    }

    /// Fetches annotations from a specific track.
    ///
    /// - Parameters:
    ///   - trackId: The annotation track identifier
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based, inclusive)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: Array of annotations from the specified track
    /// - Throws: `ReferenceBundleError` if annotations cannot be fetched
    public func fetchAnnotations(trackId: String, chromosome: String, start: Int, end: Int) async throws -> [SequenceAnnotation] {
        let bundle = try ensureBundle()
        let region = GenomicRegion(chromosome: chromosome, start: start, end: end)

        let annotations = try await bundle.getAnnotations(trackId: trackId, region: region)
        logger.debug("BundleDataProvider: Fetched \(annotations.count) annotations from '\(trackId, privacy: .public)' for \(region.description)")

        return annotations
    }

    // MARK: - Private

    /// Ensures the reference bundle reader is initialized.
    ///
    /// Creates the `ReferenceBundle` on first access using the synchronous initializer
    /// with the pre-loaded manifest, avoiding an async requirement.
    ///
    /// - Returns: The initialized reference bundle
    /// - Throws: Error if the bundle cannot be created
    private func ensureBundle() throws -> ReferenceBundle {
        if let bundle = referenceBundle {
            return bundle
        }

        let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)
        self.referenceBundle = bundle
        logger.info("BundleDataProvider: Created ReferenceBundle for '\(self.manifest.name, privacy: .public)'")
        return bundle
    }
}
