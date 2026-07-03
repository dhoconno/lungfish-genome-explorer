// FASTQDerivedBundleManifest.swift - Pointer-based FASTQ derivative datasets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

// MARK: - Sample Provenance

/// Tracks the origin, preparation, and processing history of a sample.
/// Stored in the manifest for traceability across the derivative lineage.
public struct SampleProvenance: Codable, Sendable, Equatable {
    /// Sample identifier (e.g., lab sample ID, accession number).
    public let sampleID: String?
    /// Organism or species name.
    public let organism: String?
    /// Tissue or sample type.
    public let tissue: String?
    /// Library preparation method (e.g., "SQK-LSK114", "Nextera XT").
    public let libraryPrep: String?
    /// Sequencing instrument (e.g., "MinION", "NovaSeq 6000").
    public let instrument: String?
    /// Sequencing run ID or flow cell ID.
    public let runID: String?
    /// Date the sample was sequenced.
    public let sequencingDate: Date?
    /// Free-form notes.
    public let notes: String?

    public init(
        sampleID: String? = nil,
        organism: String? = nil,
        tissue: String? = nil,
        libraryPrep: String? = nil,
        instrument: String? = nil,
        runID: String? = nil,
        sequencingDate: Date? = nil,
        notes: String? = nil
    ) {
        self.sampleID = sampleID
        self.organism = organism
        self.tissue = tissue
        self.libraryPrep = libraryPrep
        self.instrument = instrument
        self.runID = runID
        self.sequencingDate = sequencingDate
        self.notes = notes
    }
}

// MARK: - Payload Checksum

/// SHA-256 checksums for verifying payload integrity.
public struct PayloadChecksum: Codable, Sendable, Equatable {
    /// Filename → hex-encoded SHA-256 hash.
    public let checksums: [String: String]

    public init(checksums: [String: String] = [:]) {
        self.checksums = checksums
    }

    /// Result of a checksum validation.
    public enum ValidationResult: Sendable, Equatable {
        /// No checksum recorded for this file — validation was not performed.
        case notRecorded
        /// Checksum matches the expected value.
        case valid
        /// Checksum does not match the expected value.
        case invalid
    }

    /// Validates that a file's contents match the recorded checksum.
    public func validate(filename: String, data: Data) -> ValidationResult {
        guard let expected = checksums[filename] else { return .notRecorded }
        let actual = Self.sha256Hex(data)
        return actual == expected ? .valid : .invalid
    }

    /// Computes the SHA-256 hex string for the given data.
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the SHA-256 hex string by streaming from a file handle (memory-efficient for large files).
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 65536
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Derived Bundle Manifest

/// Pointer manifest saved in derived `.lungfishfastq` bundles.
///
/// Derived bundles do not duplicate FASTQ payload bytes. They store either
/// a read ID list (subset operations) or trim position records (trim operations),
/// plus lineage metadata pointing back to a parent/root bundle.
public struct FASTQDerivedBundleManifest: Codable, Sendable, Equatable {
    /// Current schema version. Increment when making breaking changes to the manifest format.
    public static let currentSchemaVersion = 2

    /// Schema version of this manifest. Version 1 = original, 2 = added orientMapFilename to demuxedVirtual.
    public let schemaVersion: Int

    public let id: UUID
    public let name: String
    public let createdAt: Date

    /// Relative path from this bundle to the immediate parent bundle.
    public let parentBundleRelativePath: String

    /// Relative path from this bundle to the root (physical FASTQ payload) bundle.
    public let rootBundleRelativePath: String

    /// FASTQ filename inside the root bundle (first file for multi-file bundles).
    public let rootFASTQFilename: String

    /// What this derivative stores on disk (read ID list or trim positions).
    public let payload: FASTQDerivativePayload

    /// Sequence of operations from root to this dataset (inclusive of latest operation).
    public let lineage: [FASTQDerivativeOperation]

    /// Latest operation used to produce this dataset.
    public let operation: FASTQDerivativeOperation

    /// Cached dataset statistics for immediate dashboard/inspector rendering.
    public let cachedStatistics: FASTQDatasetStatistics

    /// Pairing mode inherited at generation time.
    public let pairingMode: IngestionMetadata.PairingMode?

    /// Read classification for mixed-type bundles (after merge/repair).
    /// Nil for homogeneous bundles.
    public let readClassification: ReadClassification?

    /// Batch operation ID linking this bundle to a batch processing run.
    /// Nil for individually-created derivatives.
    public let batchOperationID: UUID?

    /// The sequence format of the root payload file.
    /// Nil for legacy manifests (assumed FASTQ).
    public let sequenceFormat: SequenceFormat?

    /// Sample provenance metadata (organism, library prep, instrument, etc.).
    /// Nil for bundles without sample-level metadata.
    public let provenance: SampleProvenance?

    /// SHA-256 checksums of payload files for integrity verification.
    /// Nil for bundles without checksum tracking.
    public let payloadChecksums: PayloadChecksum?

    /// Materialization lifecycle state. Nil for legacy manifests (treated as virtual
    /// for derived bundles, materialized for bundles with full/fullPaired/fullMixed payloads).
    public var materializationState: MaterializationState?

    /// Resolved materialization state, applying defaults for nil values and
    /// treating stale `.materializing` states (from crashed sessions) as `.virtual`.
    public var resolvedState: MaterializationState {
        if let state = materializationState {
            if case .materializing = state {
                return .virtual
            }
            return state
        }
        switch payload {
        case .full, .fullPaired, .fullMixed, .fullFASTA:
            return .materialized(checksum: payloadChecksums?.checksums.values.first ?? "")
        default:
            return .virtual
        }
    }

    /// Whether this bundle has been materialized to a full FASTQ on disk.
    public var isMaterialized: Bool {
        if case .materialized = resolvedState { return true }
        return false
    }

    /// Checks whether the root FASTQ file has been modified after this derivative was created.
    ///
    /// A stale derivative means the root data has changed since this bundle's creation,
    /// so the derivative's pointer-based or materialized data may no longer be correct.
    /// Returns `nil` if the root bundle cannot be resolved.
    public func isStale(bundleURL: URL) -> Bool? {
        let rootURL = FASTQBundle.resolveBundle(relativePath: rootBundleRelativePath, from: bundleURL)
        let rootFASTQ = rootURL.appendingPathComponent(rootFASTQFilename)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: rootFASTQ.path),
              let rootModDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return rootModDate > createdAt
    }

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        parentBundleRelativePath: String,
        rootBundleRelativePath: String,
        rootFASTQFilename: String,
        payload: FASTQDerivativePayload = .subset(readIDListFilename: "read-ids.txt"),
        lineage: [FASTQDerivativeOperation],
        operation: FASTQDerivativeOperation,
        cachedStatistics: FASTQDatasetStatistics,
        pairingMode: IngestionMetadata.PairingMode?,
        readClassification: ReadClassification? = nil,
        batchOperationID: UUID? = nil,
        sequenceFormat: SequenceFormat? = .fastq,
        provenance: SampleProvenance? = nil,
        payloadChecksums: PayloadChecksum? = nil,
        materializationState: MaterializationState? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentBundleRelativePath = parentBundleRelativePath
        self.rootBundleRelativePath = rootBundleRelativePath
        self.rootFASTQFilename = rootFASTQFilename
        self.payload = payload
        self.lineage = lineage
        self.operation = operation
        self.cachedStatistics = cachedStatistics
        self.pairingMode = pairingMode
        self.readClassification = readClassification
        self.batchOperationID = batchOperationID
        self.sequenceFormat = sequenceFormat
        self.provenance = provenance
        self.payloadChecksums = payloadChecksums
        self.materializationState = materializationState
    }

    // Custom decoding for backward compatibility with schema version 1 manifests
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.parentBundleRelativePath = try container.decode(String.self, forKey: .parentBundleRelativePath)
        self.rootBundleRelativePath = try container.decode(String.self, forKey: .rootBundleRelativePath)
        self.rootFASTQFilename = try container.decode(String.self, forKey: .rootFASTQFilename)
        self.payload = try container.decode(FASTQDerivativePayload.self, forKey: .payload)
        self.lineage = try container.decode([FASTQDerivativeOperation].self, forKey: .lineage)
        self.operation = try container.decode(FASTQDerivativeOperation.self, forKey: .operation)
        self.cachedStatistics = try container.decode(FASTQDatasetStatistics.self, forKey: .cachedStatistics)
        self.pairingMode = try container.decodeIfPresent(IngestionMetadata.PairingMode.self, forKey: .pairingMode)
        self.readClassification = try container.decodeIfPresent(ReadClassification.self, forKey: .readClassification)
        self.batchOperationID = try container.decodeIfPresent(UUID.self, forKey: .batchOperationID)
        self.sequenceFormat = try container.decodeIfPresent(SequenceFormat.self, forKey: .sequenceFormat)
        self.provenance = try container.decodeIfPresent(SampleProvenance.self, forKey: .provenance)
        self.payloadChecksums = try container.decodeIfPresent(PayloadChecksum.self, forKey: .payloadChecksums)
        self.materializationState = try container.decodeIfPresent(MaterializationState.self, forKey: .materializationState)
    }

    // MARK: - Referential Integrity Validation

    /// Issues found during referential integrity validation.
    public struct IntegrityReport: Sendable, Equatable {
        public let parentBundleExists: Bool
        public let rootBundleExists: Bool
        public let rootPayloadFileExists: Bool
        public let payloadFilesExist: Bool
        public let checksumValid: Bool?  // nil if no checksums recorded

        public var isValid: Bool {
            parentBundleExists && rootBundleExists && rootPayloadFileExists && payloadFilesExist && (checksumValid ?? true)
        }

        public var issues: [String] {
            var result: [String] = []
            if !parentBundleExists { result.append("Parent bundle not found") }
            if !rootBundleExists { result.append("Root bundle not found") }
            if !rootPayloadFileExists { result.append("Root payload file not found") }
            if !payloadFilesExist { result.append("Payload sidecar file(s) missing") }
            if let valid = checksumValid, !valid { result.append("Payload checksum mismatch") }
            return result
        }
    }

    /// Validates referential integrity of this manifest relative to the bundle at `bundleURL`.
    public func validateIntegrity(bundleURL: URL) -> IntegrityReport {
        let fm = FileManager.default

        // Resolve relative paths from the bundle's containing directory.
        // Relative paths like "../root.lungfishfastq" are relative to the bundle location.
        let containerDir = bundleURL.deletingLastPathComponent()
        let parentURL = containerDir.appendingPathComponent(parentBundleRelativePath).standardizedFileURL
        let rootURL = containerDir.appendingPathComponent(rootBundleRelativePath).standardizedFileURL

        let parentExists = fm.fileExists(atPath: parentURL.path)
        let rootExists = fm.fileExists(atPath: rootURL.path)
        let rootPayloadExists = rootExists && fm.fileExists(
            atPath: rootURL.appendingPathComponent(rootFASTQFilename).path
        )

        // Check payload sidecar files exist
        let payloadExists: Bool
        switch payload {
        case .subset(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .trim(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .full(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .fullFASTA(let filename):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(filename).path)
        case .fullPaired(let r1, let r2):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(r1).path)
                && fm.fileExists(atPath: bundleURL.appendingPathComponent(r2).path)
        case .fullMixed(let classification):
            payloadExists = classification.files.map(\.filename).allSatisfy {
                fm.fileExists(atPath: bundleURL.appendingPathComponent($0).path)
            }
        case .demuxedVirtual(_, let readIDFile, let previewFile, let trimFile, let orientFile):
            var exists = fm.fileExists(atPath: bundleURL.appendingPathComponent(readIDFile).path)
                && fm.fileExists(atPath: bundleURL.appendingPathComponent(previewFile).path)
            if let trimFile { exists = exists && fm.fileExists(atPath: bundleURL.appendingPathComponent(trimFile).path) }
            if let orientFile { exists = exists && fm.fileExists(atPath: bundleURL.appendingPathComponent(orientFile).path) }
            payloadExists = exists
        case .demuxGroup:
            payloadExists = true // Directory-level, always valid
        case .orientMap(let mapFile, let previewFile):
            payloadExists = fm.fileExists(atPath: bundleURL.appendingPathComponent(mapFile).path)
                && fm.fileExists(atPath: bundleURL.appendingPathComponent(previewFile).path)
        }

        // Validate checksums if present (streams file in chunks to avoid loading large files into memory)
        var checksumValid: Bool?
        if let checksums = payloadChecksums, !checksums.checksums.isEmpty {
            checksumValid = true
            for (filename, expectedHash) in checksums.checksums {
                let fileURL = bundleURL.appendingPathComponent(filename)
                guard let actualHash = try? PayloadChecksum.sha256Hex(fileAt: fileURL) else {
                    checksumValid = false
                    break
                }
                if actualHash != expectedHash {
                    checksumValid = false
                    break
                }
            }
        }

        return IntegrityReport(
            parentBundleExists: parentExists,
            rootBundleExists: rootExists,
            rootPayloadFileExists: rootPayloadExists,
            payloadFilesExist: payloadExists,
            checksumValid: checksumValid
        )
    }

    // MARK: - Methods Text Export

    /// Generates a publication-ready methods paragraph describing the processing pipeline.
    ///
    /// Includes tool names, versions, and non-default parameters for each step.
    /// Optionally includes per-step read count statistics.
    ///
    /// Example output:
    /// ```
    /// Raw reads were processed using the following pipeline: Quality trimming was
    /// performed using fastp (Q20, window size 4, cut-right mode). Adapter sequences
    /// were removed using fastp with auto-detection. 150,000 reads (95.2%) were
    /// retained after processing.
    /// ```
    public func generateMethodsText(includeStats: Bool = true) -> String {
        let allSteps = lineage + [operation]
        guard !allSteps.isEmpty else { return "No processing steps were applied." }

        var sentences: [String] = []
        sentences.append("Raw reads were processed using the following pipeline:")

        for step in allSteps {
            sentences.append(step.methodsSentence)
        }

        if includeStats {
            let stats = cachedStatistics
            if stats.readCount > 0 {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                let readStr = formatter.string(from: NSNumber(value: stats.readCount)) ?? "\(stats.readCount)"
                let meanQ = String(format: "%.1f", stats.meanQuality)
                let meanLen = String(format: "%.0f", stats.meanReadLength)
                sentences.append(
                    "\(readStr) reads were retained after processing"
                    + " (mean quality: \(meanQ), mean length: \(meanLen) bp)."
                )
            }
        }

        return sentences.joined(separator: " ")
    }
}
