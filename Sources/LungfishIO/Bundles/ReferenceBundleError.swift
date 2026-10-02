// ReferenceBundleError.swift - Errors that can occur when working with reference bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

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

    /// Failed to read alignment data.
    case alignmentReadFailed(String)

    /// Failed to validate or read the declared record metadata store.
    case recordStoreReadFailed(String)

    /// Alignment file path is stale and cannot be resolved.
    case alignmentFileNotFound(String)

    /// The track exists but has no supported query representation.
    case unsupportedTrackFormat(trackId: String, format: String, reason: String)

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
        case .alignmentReadFailed(let reason):
            return "Failed to read alignment data: \(reason)"
        case .recordStoreReadFailed(let reason):
            return "Failed to read record store: \(reason)"
        case .alignmentFileNotFound(let path):
            return "Alignment file not found: '\(path)'"
        case .unsupportedTrackFormat(let trackId, let format, let reason):
            return "Track '\(trackId)' uses unsupported format '\(format)': \(reason)"
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
        case .unsupportedTrackFormat:
            return "Rebuild or import the reference bundle with a SQLite variant database sidecar, or query the BCF with a workflow that supports BCF/CSI."
        default:
            return nil
        }
    }
}
