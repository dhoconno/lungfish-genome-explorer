// LoadedDocument.swift - Represents a loaded document with its associated data
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DocumentManager")

// MARK: - Document State

/// Represents a loaded document with its associated data.
@Observable
@MainActor
public final class LoadedDocument: Identifiable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let type: DocumentType

    /// Stored identity for a catalog entry; its URL is a display path, not a file.
    public var projectSequenceID: UUID?

    /// The loaded sequences
    public var sequences: [Sequence] = []

    /// The loaded annotations
    public var annotations: [SequenceAnnotation] = []

    /// The bundle manifest, populated when type is `.lungfishReferenceBundle`.
    ///
    /// Stores the parsed `BundleManifest` from the `.lungfishref` bundle directory,
    /// providing chromosome information, annotation track metadata, and paths to
    /// the indexed genome files.
    public var bundleManifest: BundleManifest?

    /// True when a FASTQ document held more than ``DocumentManager/maxFASTQDocumentRecords``
    /// records and only the first records were loaded.
    public var isTruncated = false

    public init(url: URL, type: DocumentType) {
        self.url = url
        self.name = url.lastPathComponent
        self.type = type
        logger.info("Created LoadedDocument: \(self.name, privacy: .public) type=\(type.rawValue, privacy: .public)")
    }
}
