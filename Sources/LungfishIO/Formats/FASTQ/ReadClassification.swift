// ReadClassification.swift - Tracks the composition of a FASTQ bundle containing heterogeneous read
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

// MARK: - Read Classification

/// Tracks the composition of a FASTQ bundle containing heterogeneous read types.
///
/// After operations like paired-end merging, a single dataset may contain
/// paired reads, merged reads, and orphan/unpaired reads. This struct records
/// the breakdown so downstream tools receive the correct input format.
///
/// When a bundle is homogeneous (all paired or all single-end), this struct
/// is nil in the metadata — the existing `IngestionMetadata.PairingMode` suffices.
public struct ReadClassification: Codable, Sendable, Equatable {

    /// Role of a FASTQ file within a multi-file bundle.
    public enum FileRole: String, Codable, Sendable, CaseIterable {
        case pairedR1 = "paired_r1"
        case pairedR2 = "paired_r2"
        case merged = "merged"
        case unpaired = "unpaired"
    }

    /// A single FASTQ file entry in the read manifest.
    public struct FileEntry: Codable, Sendable, Equatable {
        public let filename: String
        public let role: FileRole
        public let readCount: Int

        public init(filename: String, role: FileRole, readCount: Int) {
            self.filename = filename
            self.role = role
            self.readCount = readCount
        }
    }

    /// Files in this bundle and their roles.
    public let files: [FileEntry]

    /// Number of paired reads (individual reads, always even: R1 count + R2 count).
    public var pairedReadCount: Int {
        files.filter { $0.role == .pairedR1 || $0.role == .pairedR2 }
            .reduce(0) { $0 + $1.readCount }
    }

    /// Number of merged reads (overlap-merged from paired input).
    public var mergedReadCount: Int {
        files.filter { $0.role == .merged }.reduce(0) { $0 + $1.readCount }
    }

    /// Number of orphan/unpaired reads.
    public var unpairedReadCount: Int {
        files.filter { $0.role == .unpaired }.reduce(0) { $0 + $1.readCount }
    }

    /// Total surviving reads across all files.
    public var totalReadCount: Int {
        files.reduce(0) { $0 + $1.readCount }
    }

    /// Number of fragments (the conserved quantity across merge operations).
    public var fragmentCount: Int {
        (pairedReadCount / 2) + mergedReadCount + unpairedReadCount
    }

    /// True when all reads are the same type (no mixed composition).
    public var isHomogeneous: Bool {
        let nonEmpty = files.map(\.role).reduce(into: Set<FileRole>()) { $0.insert($1) }
        if nonEmpty.count <= 1 { return true }
        // R1 + R2 together counts as one type (paired)
        if nonEmpty == [.pairedR1, .pairedR2] { return true }
        return false
    }

    /// Human-readable composition label for the sidebar (e.g. "5,000 pairs + 2,617 merged").
    public var compositionLabel: String {
        var parts: [String] = []
        let pairs = pairedReadCount / 2
        if pairs > 0 {
            parts.append("\(pairs.formatted()) pairs")
        }
        if mergedReadCount > 0 {
            parts.append("\(mergedReadCount.formatted()) merged")
        }
        if unpairedReadCount > 0 {
            parts.append("\(unpairedReadCount.formatted()) singles")
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: " + ")
    }

    public init(files: [FileEntry]) {
        self.files = files
    }

    /// Convenience initializer for bundles where counts are known but files are separate.
    public init(pairedR1File: String, pairedR1Count: Int,
                pairedR2File: String, pairedR2Count: Int,
                mergedFile: String? = nil, mergedCount: Int = 0,
                unpairedFile: String? = nil, unpairedCount: Int = 0) {
        var entries: [FileEntry] = [
            FileEntry(filename: pairedR1File, role: .pairedR1, readCount: pairedR1Count),
            FileEntry(filename: pairedR2File, role: .pairedR2, readCount: pairedR2Count),
        ]
        if let mergedFile, mergedCount > 0 {
            entries.append(FileEntry(filename: mergedFile, role: .merged, readCount: mergedCount))
        }
        if let unpairedFile, unpairedCount > 0 {
            entries.append(FileEntry(filename: unpairedFile, role: .unpaired, readCount: unpairedCount))
        }
        self.files = entries
    }
}
