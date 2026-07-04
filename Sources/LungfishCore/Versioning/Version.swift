// Version.swift - Version metadata for sequence history
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Version Control Specialist (Role 17)

import Foundation
import CryptoKit

/// A version snapshot in the sequence history.
///
/// Each version represents a specific state of a sequence, identified by
/// a content-addressable hash. Versions form a linear chain (like git commits).
///
/// ## Example
/// ```swift
/// let version = Version(
///     diff: myDiff,
///     parentHash: previousVersion?.contentHash,
///     message: "Fixed mutation at position 1234"
/// )
/// ```
public struct Version: Identifiable, Codable, Sendable {

    /// Unique identifier for this version
    public let id: UUID

    /// SHA-256 hash of the content at this version
    public let contentHash: String

    /// Hash of the parent version (nil for initial version)
    public let parentHash: String?

    /// The diff from the parent version
    public let diff: SequenceDiff

    /// When this version was created
    public let timestamp: Date

    /// Optional commit message
    public let message: String?

    /// Author of this version
    public let author: String?

    /// Additional metadata
    public var metadata: [String: String]

    /// Creates a new version.
    ///
    /// - Parameters:
    ///   - content: The full sequence content at this version (used for hash)
    ///   - diff: The diff from the parent version
    ///   - parentHash: Hash of the parent version
    ///   - message: Optional commit message
    ///   - author: Optional author name
    ///   - metadata: Additional key-value metadata
    public init(
        content: String,
        diff: SequenceDiff,
        parentHash: String?,
        message: String? = nil,
        author: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = UUID()
        self.contentHash = Self.computeHash(content)
        self.parentHash = parentHash
        self.diff = diff
        self.timestamp = Date()
        self.message = message
        self.author = author
        self.metadata = metadata
    }

    /// Creates a version with a pre-computed hash (for deserialization).
    internal init(
        id: UUID,
        contentHash: String,
        parentHash: String?,
        diff: SequenceDiff,
        timestamp: Date,
        message: String?,
        author: String?,
        metadata: [String: String]
    ) {
        self.id = id
        self.contentHash = contentHash
        self.parentHash = parentHash
        self.diff = diff
        self.timestamp = timestamp
        self.message = message
        self.author = author
        self.metadata = metadata
    }

    // MARK: - Hash Computation

    /// Computes SHA-256 hash of content.
    public static func computeHash(_ content: String) -> String {
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns abbreviated hash (first 8 characters).
    public var shortHash: String {
        String(contentHash.prefix(8))
    }

    // MARK: - Formatting

    /// Formats the timestamp for display.
    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Returns a one-line summary of this version.
    public var summary: String {
        let msg = message ?? "No message"
        let msgPreview = msg.count > 50 ? "\(msg.prefix(50))..." : msg
        return "\(shortHash) \(msgPreview)"
    }
}

// MARK: - Version Comparable

extension Version: Comparable {
    public static func < (lhs: Version, rhs: Version) -> Bool {
        lhs.timestamp < rhs.timestamp
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        lhs.contentHash == rhs.contentHash
    }
}

// MARK: - Version Hashable

extension Version: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(contentHash)
    }
}

// MARK: - VersionSummary

/// A lightweight summary of a version (for UI display).
public struct VersionSummary: Identifiable, Sendable {
    public let id: UUID
    public let shortHash: String
    public let message: String?
    public let timestamp: Date
    public let author: String?

    public init(from version: Version) {
        self.id = version.id
        self.shortHash = version.shortHash
        self.message = version.message
        self.timestamp = version.timestamp
        self.author = version.author
    }
}
