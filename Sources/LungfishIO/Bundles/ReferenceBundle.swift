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
/// ```
// MARK: - Annotation Type Inference

/// Infers annotation type from BigBed feature name and metadata.
///
/// Since GFF3 feature types are lost during BED conversion, this uses NCBI naming
/// conventions and size heuristics to infer the most likely type.
///
/// Priority:
/// 1. Explicit type in extra fields column 13 (future bundles)
/// 2. NCBI accession prefix patterns (XM_, NM_, XR_, NR_, LOC, etc.)
/// 3. GFF3-derived name patterns (gene-, rna-, cds-, exon-, id-)
/// 4. Size heuristic fallback
private func inferAnnotationType(name: String, featureSize: Int, extraFields: String?) -> AnnotationType {
    // 1. Check extra fields for explicit type (column 13 in future bundles)
    if let extra = extraFields {
        let parts = extra.split(separator: "\t")
        // Column 13 (index 0 in extra fields after the standard 12) = feature type
        if let typeStr = parts.first,
           let mapped = AnnotationType.from(rawString: String(typeStr)) {
            return mapped
        }
    }

    // 2. NCBI accession prefix patterns
    let upper = name.uppercased()
    if upper.hasPrefix("XM_") || upper.hasPrefix("NM_") {
        return .mRNA
    }
    if upper.hasPrefix("XR_") || upper.hasPrefix("NR_") {
        return .transcript
    }
    if upper.hasPrefix("LOC") {
        // LOC followed by digits = predicted gene
        let afterLOC = name.dropFirst(3)
        if afterLOC.first?.isNumber == true {
            return .gene
        }
    }
    if upper.hasPrefix("MIR") || upper.hasPrefix("SNORD") || upper.hasPrefix("SNORA") || upper.hasPrefix("TRNA") {
        return .transcript
    }

    // 3. GFF3-derived name patterns (e.g., gene-LOC123, rna-XM_456, cds-XM_789)
    let lower = name.lowercased()
    if lower.hasPrefix("gene-") { return .gene }
    if lower.hasPrefix("rna-") || lower.hasPrefix("mrna-") { return .mRNA }
    if lower.hasPrefix("cds-") { return .cds }
    if lower.hasPrefix("exon-") { return .exon }
    if lower.hasPrefix("id-") { return .region }

    // 4. Size heuristic fallback
    if featureSize < 300 { return .exon }
    if featureSize > 100_000 { return .region }

    return .gene
}

/// Converts a BigBedFeature into a SequenceAnnotation, preserving block data as intervals.
private func bigBedFeatureToAnnotation(_ feature: BigBedFeature) -> SequenceAnnotation {
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

    var color: AnnotationColor?
    if let rgb = feature.itemRgb {
        color = AnnotationColor(
            red: Double(rgb.r) / 255.0,
            green: Double(rgb.g) / 255.0,
            blue: Double(rgb.b) / 255.0
        )
    }

    var qualifiers: [String: AnnotationQualifier] = [:]
    if let score = feature.score {
        qualifiers["score"] = AnnotationQualifier(String(score))
    }
    if let extraFields = feature.extraFields {
        qualifiers["extra"] = AnnotationQualifier(extraFields)
    }

    let featureName = feature.name ?? "unknown"
    let featureSize = feature.end - feature.start
    let annotationType = inferAnnotationType(
        name: featureName, featureSize: featureSize, extraFields: feature.extraFields
    )

    // Build intervals from block data if available (BED12 multi-part features)
    var intervals: [AnnotationInterval]
    if let blockCount = feature.blockCount, blockCount > 1,
       let blockSizes = feature.blockSizes, blockSizes.count == blockCount,
       let blockStarts = feature.blockStarts, blockStarts.count == blockCount {
        intervals = (0..<blockCount).map { i in
            let start = feature.start + blockStarts[i]
            let end = start + blockSizes[i]
            return AnnotationInterval(start: start, end: end)
        }
    } else {
        intervals = [AnnotationInterval(start: feature.start, end: feature.end)]
    }

    return SequenceAnnotation(
        type: annotationType,
        name: featureName,
        chromosome: feature.chromosome,
        intervals: intervals,
        strand: strand,
        qualifiers: qualifiers,
        color: color
    )
}

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
        logger.info("fetchSequenceSync: START \(region.description)")

        // Validate chromosome exists
        guard let chromInfo = chromosome(named: region.chromosome) else {
            logger.error("fetchSequenceSync: Chromosome '\(region.chromosome)' not found in manifest")
            throw ReferenceBundleError.chromosomeNotFound(region.chromosome)
        }

        // Validate region bounds
        guard region.start >= 0 && region.end <= chromInfo.length else {
            logger.error("fetchSequenceSync: Region out of bounds: end=\(region.end) > length=\(chromInfo.length)")
            throw ReferenceBundleError.regionOutOfBounds(region, chromInfo.length)
        }

        let genomeURL = url.appendingPathComponent(manifest.genome.path)
        let faiURL = url.appendingPathComponent(manifest.genome.indexPath)

        // Check if we have a bgzip-compressed file with GZI index
        if let gzipIndexPath = manifest.genome.gzipIndexPath {
            let gziURL = url.appendingPathComponent(gzipIndexPath)

            logger.info("fetchSequenceSync: Creating SyncBgzipFASTAReader for \(genomeURL.lastPathComponent)")
            // Use synchronous bgzip reader
            let reader = try SyncBgzipFASTAReader(url: genomeURL, faiURL: faiURL, gziURL: gziURL)
            logger.info("fetchSequenceSync: Reader created, calling fetchSync")
            let sequence = try reader.fetchSync(region: region)

            logger.info("fetchSequenceSync: DONE (bgzip) \(region.chromosome):\(region.start)-\(region.end) -> \(sequence.count) bp")
            return sequence
        } else {
            // Use the synchronous indexed FASTA reader for uncompressed files
            let reader = try IndexedFASTAReader(url: genomeURL, indexURL: faiURL)
            let sequence = try reader.fetchSync(region: region)

            logger.info("fetchSequenceSync: DONE (uncompressed) \(region.chromosome):\(region.start)-\(region.end) -> \(sequence.count) bp")
            return sequence
        }
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
            
            // Convert BigBedFeature to SequenceAnnotation (preserving block intervals)
            let annotations = features.map { bigBedFeatureToAnnotation($0) }
            
            logger.debug("Fetched \(annotations.count) annotations from \(trackId) for \(region.description)")
            return annotations
            
        } catch {
            logger.error("Failed to read BigBed annotations: \(error.localizedDescription)")
            throw ReferenceBundleError.annotationReadFailed(error.localizedDescription)
        }
    }

    /// Fetches annotations synchronously from a track for a genomic region.
    ///
    /// Uses `SyncBigBedReader` for synchronous file access, suitable for
    /// AppKit drawing contexts where async/await cannot be used.
    ///
    /// - Parameters:
    ///   - trackId: The annotation track ID
    ///   - region: The genomic region to query
    /// - Returns: Array of sequence annotations in the region
    /// - Throws: `ReferenceBundleError` if annotations cannot be fetched
    public func getAnnotationsSync(trackId: String, region: GenomicRegion) throws -> [SequenceAnnotation] {
        guard let trackInfo = annotationTrack(id: trackId) else {
            throw ReferenceBundleError.trackNotFound(trackId)
        }

        let trackURL = url.appendingPathComponent(trackInfo.path)

        guard FileManager.default.fileExists(atPath: trackURL.path) else {
            throw ReferenceBundleError.missingFile(trackInfo.path)
        }

        do {
            let reader = try SyncBigBedReader(url: trackURL)
            let features = try reader.features(region: region)

            let annotations = features.map { bigBedFeatureToAnnotation($0) }

            logger.debug("Fetched \(annotations.count) annotations (sync) from \(trackId) for \(region.description)")
            return annotations

        } catch {
            logger.error("Failed to read BigBed annotations (sync): \(error.localizedDescription)")
            throw ReferenceBundleError.annotationReadFailed(error.localizedDescription)
        }
    }

    /// Fetches annotations using a pre-created reader (avoids re-opening FileHandle and re-parsing header).
    ///
    /// This overload is for callers that cache `SyncBigBedReader` instances for reuse across
    /// multiple queries, which avoids the overhead of re-opening the file and re-parsing the
    /// BigBed header and chromosome B+ tree on every call.
    ///
    /// - Parameters:
    ///   - reader: A pre-created `SyncBigBedReader` for the annotation track
    ///   - region: The genomic region to query
    /// - Returns: Array of sequence annotations in the region
    /// - Throws: `ReferenceBundleError` if annotations cannot be fetched
    public func getAnnotationsSync(reader: SyncBigBedReader, region: GenomicRegion) throws -> [SequenceAnnotation] {
        do {
            let features = try reader.features(region: region)

            let annotations = features.map { bigBedFeatureToAnnotation($0) }

            logger.debug("Fetched \(annotations.count) annotations (sync, cached reader) for \(region.description)")
            return annotations

        } catch {
            logger.error("Failed to read BigBed annotations (sync, cached reader): \(error.localizedDescription)")
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
    /// Queries the SQLite variant database for fast region-based retrieval.
    /// Falls back to returning empty if no database is available.
    ///
    /// - Parameters:
    ///   - trackId: The variant track ID
    ///   - region: The genomic region to query
    /// - Returns: Array of variants in the region
    /// - Throws: `ReferenceBundleError` if variants cannot be fetched
    public func getVariants(trackId: String, region: GenomicRegion) throws -> [BundleVariant] {
        guard let trackInfo = variantTrack(id: trackId) else {
            throw ReferenceBundleError.trackNotFound(trackId)
        }

        // Try SQLite database first (fast path)
        if let dbPath = trackInfo.databasePath {
            let dbURL = url.appendingPathComponent(dbPath)
            if FileManager.default.fileExists(atPath: dbURL.path) {
                do {
                    let variantDB = try VariantDatabase(url: dbURL)
                    let records = variantDB.query(
                        chromosome: region.chromosome,
                        start: region.start,
                        end: region.end
                    )
                    logger.debug("getVariants: \(trackId) returned \(records.count) variants from SQLite for \(region.description)")
                    return records.map { $0.toBundleVariant() }
                } catch {
                    logger.error("getVariants: SQLite query failed for \(trackId): \(error.localizedDescription)")
                }
            }
        }

        // Fallback: check for BCF file
        let trackURL = url.appendingPathComponent(trackInfo.path)
        guard FileManager.default.fileExists(atPath: trackURL.path) else {
            throw ReferenceBundleError.missingFile(trackInfo.path)
        }

        logger.debug("getVariants: \(trackId) for \(region.description) - BCF reader not yet implemented, returning empty")
        return []
    }

    /// Fetches variants as SequenceAnnotations for rendering in the annotation pipeline.
    ///
    /// This converts variant records into annotations that can be rendered using
    /// the existing annotation rendering system with type-appropriate colors.
    ///
    /// - Parameters:
    ///   - trackId: The variant track ID
    ///   - region: The genomic region to query
    /// - Returns: Array of annotations representing variants in the region
    /// - Throws: `ReferenceBundleError` if variants cannot be fetched
    public func getVariantAnnotations(trackId: String, region: GenomicRegion) throws -> [SequenceAnnotation] {
        guard let trackInfo = variantTrack(id: trackId) else {
            throw ReferenceBundleError.trackNotFound(trackId)
        }

        // Try SQLite database (fast path)
        if let dbPath = trackInfo.databasePath {
            let dbURL = url.appendingPathComponent(dbPath)
            if FileManager.default.fileExists(atPath: dbURL.path) {
                do {
                    let variantDB = try VariantDatabase(url: dbURL)
                    let records = variantDB.query(
                        chromosome: region.chromosome,
                        start: region.start,
                        end: region.end
                    )
                    logger.debug("getVariantAnnotations: \(trackId) returned \(records.count) variant annotations for \(region.description)")
                    return records.map { $0.toAnnotation() }
                } catch {
                    logger.error("getVariantAnnotations: SQLite query failed for \(trackId): \(error.localizedDescription)")
                }
            }
        }

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
