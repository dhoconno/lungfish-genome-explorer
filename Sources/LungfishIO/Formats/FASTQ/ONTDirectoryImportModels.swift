// ONTDirectoryImportModels.swift - Models for ONT directory import
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Detected ONT output directory structure.
public struct ONTDirectoryLayout: Sendable {
    /// Root directory being scanned.
    public let rootDirectory: URL

    /// Detected barcode directories, sorted by name.
    public let barcodeDirectories: [ONTBarcodeDirectory]

    /// Whether an "unclassified" directory was found.
    public let hasUnclassified: Bool

    /// Total number of FASTQ chunk files across all barcodes.
    public var totalChunkCount: Int {
        barcodeDirectories.reduce(0) { $0 + $1.chunkFiles.count }
    }

    /// Total size of all chunk files in bytes.
    public var totalSizeBytes: Int64 {
        barcodeDirectories.reduce(0) { $0 + $1.totalSizeBytes }
    }
}

/// A single barcode directory within an ONT output.
public struct ONTBarcodeDirectory: Sendable {
    /// URL of the barcode directory.
    public let url: URL

    /// Barcode name (e.g., "barcode01", "unclassified").
    public let barcodeName: String

    /// Sorted list of .fastq.gz chunk files in this directory.
    public let chunkFiles: [URL]

    /// Total size of chunk files in bytes.
    public let totalSizeBytes: Int64

    /// Whether this is the "unclassified" directory.
    public var isUnclassified: Bool {
        barcodeName.lowercased() == "unclassified"
    }
}

/// Configuration for ONT directory import.
public enum ONTImportStorageMode: String, Codable, Sendable, CaseIterable {
    /// Preserve each ONT chunk in the bundle and record ordering in source-files.json.
    case chunked

    /// Byte-concatenate chunks into one FASTQ payload per barcode bundle.
    case flattened

    public var usesVirtualConcatenation: Bool {
        self == .chunked
    }
}

public struct ONTImportConfig: Sendable {
    /// Source directory (fastq_pass/ or a single barcode directory).
    public let sourceDirectory: URL

    /// Output directory where .lungfishfastq bundles will be created.
    public let outputDirectory: URL

    /// Maximum concurrent barcode concatenations.
    public let maxConcurrentBarcodes: Int

    /// Whether to include the "unclassified" directory.
    public let includeUnclassified: Bool

    /// How ONT per-barcode chunk files should be stored inside each bundle.
    public let storageMode: ONTImportStorageMode

    /// When true, creates symlink-based bundles with `source-files.json` instead of
    /// byte-concatenating chunks into a single `reads.fastq.gz`. This avoids duplicating
    /// data and enables virtual concatenation for downstream operations.
    ///
    /// Kept for compatibility with existing callers. New code should use
    /// ``storageMode``.
    public let useVirtualConcatenation: Bool

    public init(
        sourceDirectory: URL,
        outputDirectory: URL,
        maxConcurrentBarcodes: Int = 4,
        includeUnclassified: Bool = false,
        storageMode: ONTImportStorageMode = .chunked
    ) {
        self.sourceDirectory = sourceDirectory
        self.outputDirectory = outputDirectory
        self.maxConcurrentBarcodes = maxConcurrentBarcodes
        self.includeUnclassified = includeUnclassified
        self.storageMode = storageMode
        self.useVirtualConcatenation = storageMode.usesVirtualConcatenation
    }

    public init(
        sourceDirectory: URL,
        outputDirectory: URL,
        maxConcurrentBarcodes: Int = 4,
        includeUnclassified: Bool = false,
        useVirtualConcatenation: Bool
    ) {
        self.init(
            sourceDirectory: sourceDirectory,
            outputDirectory: outputDirectory,
            maxConcurrentBarcodes: maxConcurrentBarcodes,
            includeUnclassified: includeUnclassified,
            storageMode: useVirtualConcatenation ? .chunked : .flattened
        )
    }
}

/// Result of an ONT directory import.
public struct ONTImportResult: Sendable {
    /// Generated demultiplex manifest.
    public let manifest: DemultiplexManifest

    /// URLs of created .lungfishfastq bundles.
    public let bundleURLs: [URL]

    /// Flow cell ID extracted from read headers.
    public let flowCellID: String?

    /// Sample ID extracted from read headers.
    public let sampleID: String?

    /// Basecall model extracted from read headers.
    public let basecallModel: String?

    /// Total reads concatenated.
    public let totalReadCount: Int

    /// Wall clock time in seconds.
    public let wallClockSeconds: Double
}

public enum ONTImportError: Error, LocalizedError {
    case notONTDirectory(URL)
    case noBarcodesFound
    case concatenationFailed(barcode: String, underlying: Error)
    case readCountFailed(barcode: String)

    public var errorDescription: String? {
        switch self {
        case .notONTDirectory(let url):
            return "'\(url.lastPathComponent)' does not appear to be an ONT output directory"
        case .noBarcodesFound:
            return "No barcode directories found"
        case .concatenationFailed(let barcode, let error):
            return "Failed to concatenate \(barcode): \(error)"
        case .readCountFailed(let barcode):
            return "Failed to count reads for \(barcode)"
        }
    }
}
