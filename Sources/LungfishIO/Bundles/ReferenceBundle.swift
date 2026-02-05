// ReferenceBundle.swift - Reference genome bundle reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

// MARK: - ReferenceBundle

/// Reader for `.lungfishref` reference genome bundles.
///
/// `ReferenceBundle` provides access to the contents of a reference genome bundle,
/// including the genome sequence, annotation tracks, variant tracks, and signal tracks.
/// All operations support efficient random access to specific genomic regions.
///
/// ## Bundle Structure
///
/// Reference bundles are directories with the `.lungfishref` extension containing:
/// - `manifest.json` - Bundle metadata and track definitions
/// - `genome/` - bgzip-compressed FASTA with .fai and .gzi indices
/// - `annotations/` - BigBed annotation files
/// - `variants/` - Indexed BCF variant files
/// - `tracks/` - BigWig signal tracks
///
/// ## Thread Safety
///
/// `ReferenceBundle` is `Sendable` and thread-safe for read operations.
/// Multiple threads can fetch sequence data concurrently.
///
/// ## Example Usage
///
/// ```swift
/// // Open a bundle
/// let bundle = try await ReferenceBundle(url: bundleURL)
///
/// // Fetch sequence for a region
/// let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
/// let sequence = try await bundle.fetchSequence(region: region)
///
/// // Get annotations
/// let genes = try await bundle.getAnnotations(trackId: "genes", region: region)
///
/// // Get signal values
/// let coverage = try await bundle.getSignal(trackId: "coverage", region: region, bins: 100)
/// ```
public final class ReferenceBundle: Sendable {

    // MARK: - Properties

    /// URL to the bundle directory.
    public let url: URL

    /// Bundle manifest containing metadata and track definitions.
    public let manifest: BundleManifest

    /// Logger for bundle operations.
    private let logger = Logger(
        subsystem: "com.lungfish.core",
        category: "ReferenceBundle"
    )

    // MARK: - Initialization

    /// Opens a reference bundle at the specified URL.
    ///
    /// - Parameter url: URL to the `.lungfishref` bundle directory
    /// - Throws: `ReferenceBundleError` if the bundle cannot be opened
    public init(url: URL) async throws {
        self.url = url

        // Validate bundle exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ReferenceBundleError.notADirectory(url)
        }

        // Validate extension
        guard url.pathExtension == "lungfishref" else {
            throw ReferenceBundleError.invalidExtension(url.pathExtension)
        }

        // Load manifest
        do {
            self.manifest = try BundleManifest.load(from: url)
        } catch {
            throw ReferenceBundleError.manifestLoadFailed(error)
        }

        // Validate manifest
        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            throw ReferenceBundleError.validationFailed(validationErrors)
        }

        // Verify essential files exist
        let genomeURL = url.appendingPathComponent(manifest.genome.path)
        guard FileManager.default.fileExists(atPath: genomeURL.path) else {
            throw ReferenceBundleError.missingFile(manifest.genome.path)
        }

        let indexURL = url.appendingPathComponent(manifest.genome.indexPath)
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw ReferenceBundleError.missingFile(manifest.genome.indexPath)
        }

        logger.info("Opened bundle: \(self.manifest.name) (\(self.manifest.identifier))")
    }
    
    /// Creates a ReferenceBundle from a pre-loaded manifest.
    ///
    /// This synchronous initializer is useful when the manifest has already been loaded
    /// and validated separately.
    ///
    /// - Parameters:
    ///   - url: URL to the `.lungfishref` bundle directory
    ///   - manifest: Pre-loaded bundle manifest
    public init(url: URL, manifest: BundleManifest) {
        self.url = url
        self.manifest = manifest
        logger.info("Created bundle from pre-loaded manifest: \(manifest.name) (\(manifest.identifier))")
    }

    // MARK: - Bundle Information

    /// Name of the bundle.
    public var name: String {
        manifest.name
    }

    /// Unique identifier of the bundle.
    public var identifier: String {
        manifest.identifier
    }

    /// Assembly name (e.g., "GRCh38").
    public var assembly: String {
        manifest.source.assembly
    }

    /// Organism name (e.g., "Homo sapiens").
    public var organism: String {
        manifest.source.organism
    }

    /// List of chromosome names in the bundle.
    public var chromosomeNames: [String] {
        manifest.genome.chromosomes.map { $0.name }
    }

    /// Returns information about a specific chromosome.
    ///
    /// - Parameter name: Chromosome name (e.g., "chr1")
    /// - Returns: Chromosome information, or nil if not found
    public func chromosome(named name: String) -> ChromosomeInfo? {
        manifest.genome.chromosomes.first { chrom in
            chrom.name == name || chrom.aliases.contains(name)
        }
    }

    /// Returns the length of a chromosome.
    ///
    /// - Parameter name: Chromosome name
    /// - Returns: Length in base pairs, or nil if chromosome not found
    public func chromosomeLength(named name: String) -> Int64? {
        chromosome(named: name)?.length
    }

    // MARK: - Sequence Access

    /// Fetches sequence data for a genomic region.
    ///
    /// Uses the indexed bgzip-compressed FASTA for efficient random access.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The sequence string for the region
    /// - Throws: `ReferenceBundleError` if the sequence cannot be fetched
    public func fetchSequence(region: GenomicRegion) async throws -> String {
        // Validate chromosome exists
        guard let chromInfo = chromosome(named: region.chromosome) else {
            throw ReferenceBundleError.chromosomeNotFound(region.chromosome)
        }

        // Validate region bounds
        guard region.start >= 0 && region.end <= chromInfo.length else {
            throw ReferenceBundleError.regionOutOfBounds(region, chromInfo.length)
        }

        let genomeURL = url.appendingPathComponent(manifest.genome.path)
        let faiURL = url.appendingPathComponent(manifest.genome.indexPath)

        // Check if we have a bgzip-compressed file with GZI index
        if let gzipIndexPath = manifest.genome.gzipIndexPath {
            let gziURL = url.appendingPathComponent(gzipIndexPath)
            
            // Use bgzip-aware reader for random access to compressed files
            let reader = try await BgzipIndexedFASTAReader(url: genomeURL, faiURL: faiURL, gziURL: gziURL)
            let sequence = try await reader.fetch(region: region)
            
            logger.debug("Fetched sequence (bgzip): \(region.chromosome):\(region.start)-\(region.end) (\(sequence.count) bp)")
            return sequence
        } else {
            // Fall back to uncompressed indexed FASTA reader
            let reader = try IndexedFASTAReader(url: genomeURL, indexURL: faiURL)
            let sequence = try await reader.fetch(region: region)
            
            logger.debug("Fetched sequence: \(region.chromosome):\(region.start)-\(region.end) (\(sequence.count) bp)")
            return sequence
        }
    }

    /// Synchronously fetches sequence data for a genomic region.
    ///
    /// This version reads the FASTA file directly without async, useful when
    /// Swift Tasks are not executing properly in the app context.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The sequence string for the region
    /// - Throws: `ReferenceBundleError` if the sequence cannot be fetched
    public func fetchSequenceSync(region: GenomicRegion) throws -> String {
        // Validate chromosome exists
        guard let chromInfo = chromosome(named: region.chromosome) else {
            throw ReferenceBundleError.chromosomeNotFound(region.chromosome)
        }

        // Validate region bounds
        guard region.start >= 0 && region.end <= chromInfo.length else {
            throw ReferenceBundleError.regionOutOfBounds(region, chromInfo.length)
        }

        let genomeURL = url.appendingPathComponent(manifest.genome.path)
        let faiURL = url.appendingPathComponent(manifest.genome.indexPath)

        // Check if we have a bgzip-compressed file with GZI index
        if let gzipIndexPath = manifest.genome.gzipIndexPath {
            let gziURL = url.appendingPathComponent(gzipIndexPath)
            
            // Use synchronous bgzip reader
            let reader = try SyncBgzipFASTAReader(url: genomeURL, faiURL: faiURL, gziURL: gziURL)
            let sequence = try reader.fetchSync(region: region)
            
            logger.debug("Fetched sequence (sync bgzip): \(region.chromosome):\(region.start)-\(region.end) (\(sequence.count) bp)")
            return sequence
        } else {
            // Use the synchronous indexed FASTA reader for uncompressed files
            let reader = try IndexedFASTAReader(url: genomeURL, indexURL: faiURL)
            let sequence = try reader.fetchSync(region: region)
            
            logger.debug("Fetched sequence (sync): \(region.chromosome):\(region.start)-\(region.end) (\(sequence.count) bp)")
            return sequence
        }
    }

    /// Fetches sequence data for multiple regions.
    ///
    /// More efficient than calling `fetchSequence` multiple times for nearby regions.
    ///
    /// - Parameter regions: Array of genomic regions to fetch
    /// - Returns: Dictionary mapping region descriptions to sequences
    public func fetchSequences(regions: [GenomicRegion]) async throws -> [String: String] {
        var results: [String: String] = [:]

        for region in regions {
            let sequence = try await fetchSequence(region: region)
            results[region.description] = sequence
        }

        return results
    }

    // MARK: - Annotation Access

    /// Returns available annotation track IDs.
    public var annotationTrackIds: [String] {
        manifest.annotations.map { $0.id }
    }

    /// Returns information about an annotation track.
    public func annotationTrack(id: String) -> AnnotationTrackInfo? {
        manifest.annotations.first { $0.id == id }
    }

    /// Fetches annotations from a track for a genomic region.
    ///
    /// Uses BigBed random access for efficient querying.
    ///
    /// - Parameters:
    ///   - trackId: The annotation track ID
    ///   - region: The genomic region to query
    /// - Returns: Array of sequence annotations in the region
    /// - Throws: `ReferenceBundleError` if annotations cannot be fetched
    public func getAnnotations(trackId: String, region: GenomicRegion) async throws -> [SequenceAnnotation] {
        guard let trackInfo = annotationTrack(id: trackId) else {
            throw ReferenceBundleError.trackNotFound(trackId)
        }

        let trackURL = url.appendingPathComponent(trackInfo.path)

        guard FileManager.default.fileExists(atPath: trackURL.path) else {
            throw ReferenceBundleError.missingFile(trackInfo.path)
        }

        // Use BigBed reader for efficient random access to annotations
        do {
            let reader = try await BigBedReader(url: trackURL)
            let features = try await reader.features(region: region)
            
            // Convert BigBedFeature to SequenceAnnotation
            let annotations = features.map { feature in
                // Determine strand
                let strand: Strand
                if let strandChar = feature.strand {
                    switch strandChar {
                    case "+": strand = .forward
                    case "-": strand = .reverse
                    default: strand = .unknown
                    }
                } else {
                    strand = .unknown
                }
                
                // Build color from RGB if available
                var color: AnnotationColor?
                if let rgb = feature.itemRgb {
                    color = AnnotationColor(
                        red: Double(rgb.r) / 255.0,
                        green: Double(rgb.g) / 255.0,
                        blue: Double(rgb.b) / 255.0
                    )
                }
                
                // Build qualifiers from extra fields
                var qualifiers: [String: AnnotationQualifier] = [:]
                if let score = feature.score {
                    qualifiers["score"] = AnnotationQualifier(String(score))
                }
                if let extraFields = feature.extraFields {
                    qualifiers["extra"] = AnnotationQualifier(extraFields)
                }
                
                return SequenceAnnotation(
                    type: .gene,  // Default type - could be inferred from track info
                    name: feature.name ?? "unknown",
                    chromosome: feature.chromosome,
                    start: feature.start,
                    end: feature.end,
                    strand: strand,
                    qualifiers: qualifiers,
                    color: color
                )
            }
            
            logger.debug("Fetched \(annotations.count) annotations from \(trackId) for \(region.description)")
            return annotations
            
        } catch {
            logger.error("Failed to read BigBed annotations: \(error.localizedDescription)")
            throw ReferenceBundleError.annotationReadFailed(error.localizedDescription)
        }
    }

    // MARK: - Variant Access

    /// Returns available variant track IDs.
    public var variantTrackIds: [String] {
        manifest.variants.map { $0.id }
    }

    /// Returns information about a variant track.
    public func variantTrack(id: String) -> VariantTrackInfo? {
        manifest.variants.first { $0.id == id }
    }

    /// Fetches variants from a track for a genomic region.
    ///
    /// Uses indexed BCF for efficient random access.
    ///
    /// - Parameters:
    ///   - trackId: The variant track ID
    ///   - region: The genomic region to query
    /// - Returns: Array of variants in the region
    /// - Throws: `ReferenceBundleError` if variants cannot be fetched
    public func getVariants(trackId: String, region: GenomicRegion) async throws -> [BundleVariant] {
        guard let trackInfo = variantTrack(id: trackId) else {
            throw ReferenceBundleError.trackNotFound(trackId)
        }

        let trackURL = url.appendingPathComponent(trackInfo.path)

        guard FileManager.default.fileExists(atPath: trackURL.path) else {
            throw ReferenceBundleError.missingFile(trackInfo.path)
        }

        // TODO: Implement BCF reader for actual variant fetching
        // For now, return empty array as placeholder
        logger.debug("getVariants: \(trackId) for \(region.description) - BCF reader not yet implemented")

        return []
    }

    // MARK: - Signal Track Access

    /// Returns available signal track IDs.
    public var signalTrackIds: [String] {
        manifest.tracks.map { $0.id }
    }

    /// Returns information about a signal track.
    public func signalTrack(id: String) -> SignalTrackInfo? {
        manifest.tracks.first { $0.id == id }
    }

    /// Fetches signal values from a track for a genomic region.
    ///
    /// Uses BigWig random access for efficient querying. Values are binned
    /// to the specified resolution.
    ///
    /// - Parameters:
    ///   - trackId: The signal track ID
    ///   - region: The genomic region to query
    ///   - bins: Number of bins to divide the region into
    /// - Returns: Array of signal values (one per bin)
    /// - Throws: `ReferenceBundleError` if signal cannot be fetched
    public func getSignal(trackId: String, region: GenomicRegion, bins: Int) async throws -> [Float] {
        guard let trackInfo = signalTrack(id: trackId) else {
            throw ReferenceBundleError.trackNotFound(trackId)
        }

        let trackURL = url.appendingPathComponent(trackInfo.path)

        guard FileManager.default.fileExists(atPath: trackURL.path) else {
            throw ReferenceBundleError.missingFile(trackInfo.path)
        }

        // TODO: Use existing BigWigReader for actual signal fetching
        // For now, return empty array as placeholder
        logger.debug("getSignal: \(trackId) for \(region.description) bins=\(bins) - BigWig integration pending")

        return []
    }
}

// MARK: - BundleVariant

/// Represents a variant from a bundle's variant track.
public struct BundleVariant: Sendable, Equatable, Identifiable {
    /// Unique identifier.
    public let id: String

    /// Chromosome name.
    public let chromosome: String

    /// Position (0-based).
    public let position: Int64

    /// Reference allele.
    public let ref: String

    /// Alternate allele(s).
    public let alt: [String]

    /// Variant quality score.
    public let quality: Float?

    /// Variant ID from source (e.g., rsID).
    public let variantId: String?

    /// Filter status.
    public let filter: String?

    /// Creates a bundle variant.
    public init(
        id: String = UUID().uuidString,
        chromosome: String,
        position: Int64,
        ref: String,
        alt: [String],
        quality: Float? = nil,
        variantId: String? = nil,
        filter: String? = nil
    ) {
        self.id = id
        self.chromosome = chromosome
        self.position = position
        self.ref = ref
        self.alt = alt
        self.quality = quality
        self.variantId = variantId
        self.filter = filter
    }
}

// MARK: - ReferenceBundleError

/// Errors that can occur when working with reference bundles.
public enum ReferenceBundleError: Error, LocalizedError, Sendable {
    /// The URL does not point to a directory.
    case notADirectory(URL)

    /// The bundle has an invalid extension.
    case invalidExtension(String)

    /// The manifest could not be loaded.
    case manifestLoadFailed(Error)

    /// Manifest validation failed.
    case validationFailed([BundleValidationError])

    /// A required file is missing from the bundle.
    case missingFile(String)

    /// The requested chromosome was not found.
    case chromosomeNotFound(String)

    /// The requested region is out of bounds.
    case regionOutOfBounds(GenomicRegion, Int64)

    /// The requested track was not found.
    case trackNotFound(String)

    /// Failed to read sequence data.
    case sequenceReadFailed(String)

    /// Failed to read annotation data.
    case annotationReadFailed(String)

    /// Failed to read variant data.
    case variantReadFailed(String)

    /// Failed to read signal data.
    case signalReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "'\(url.lastPathComponent)' is not a directory"
        case .invalidExtension(let ext):
            return "Invalid bundle extension: '.\(ext)' (expected .lungfishref)"
        case .manifestLoadFailed(let error):
            return "Failed to load manifest: \(error.localizedDescription)"
        case .validationFailed(let errors):
            let messages = errors.map { $0.localizedDescription }.joined(separator: "; ")
            return "Bundle validation failed: \(messages)"
        case .missingFile(let path):
            return "Required file missing: '\(path)'"
        case .chromosomeNotFound(let name):
            return "Chromosome '\(name)' not found in bundle"
        case .regionOutOfBounds(let region, let length):
            return "Region \(region.description) is out of bounds (chromosome length: \(length))"
        case .trackNotFound(let id):
            return "Track '\(id)' not found in bundle"
        case .sequenceReadFailed(let reason):
            return "Failed to read sequence: \(reason)"
        case .annotationReadFailed(let reason):
            return "Failed to read annotations: \(reason)"
        case .variantReadFailed(let reason):
            return "Failed to read variants: \(reason)"
        case .signalReadFailed(let reason):
            return "Failed to read signal data: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notADirectory:
            return "Ensure the path points to a .lungfishref directory"
        case .invalidExtension:
            return "Reference bundles must have the .lungfishref extension"
        case .manifestLoadFailed:
            return "Check that manifest.json exists and is valid JSON"
        case .validationFailed:
            return "Fix the validation errors and try again"
        case .missingFile:
            return "Ensure all files referenced in the manifest exist"
        case .chromosomeNotFound:
            return "Check available chromosomes with bundle.chromosomeNames"
        case .regionOutOfBounds:
            return "Adjust the region to be within chromosome bounds"
        case .trackNotFound:
            return "Check available tracks with bundle.*TrackIds"
        default:
            return nil
        }
    }
}
