// ReferenceBundleAnnotationImportError.swift - Errors thrown while attaching an annotation track to a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

public enum ReferenceBundleAnnotationImportError: Error, LocalizedError {
    case unsupportedFormat(URL)
    case missingManifest(URL)
    case missingGenome(URL)
    case duplicateTrackID(String)
    case invalidTrackID(String)
    case noImportableAnnotations(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            return "\(url.lastPathComponent) is not a supported annotation format. Use GTF, GFF, GFF3, or BED."
        case .missingManifest(let url):
            return "\(url.lastPathComponent) is not a valid reference bundle."
        case .missingGenome(let url):
            return "\(url.lastPathComponent) does not contain genome sequence metadata for annotation import."
        case .duplicateTrackID(let id):
            return "This bundle already has an annotation track named \(id)."
        case .invalidTrackID(let id):
            return "Invalid annotation track ID '\(id)'. Use only letters, numbers, underscores, and hyphens."
        case .noImportableAnnotations(let url):
            return "No importable annotations were found in \(url.lastPathComponent). The file may be empty or malformed."
        }
    }
}
