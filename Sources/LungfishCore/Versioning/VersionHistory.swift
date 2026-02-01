// VersionHistory.swift - Linear version history management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Version Control Specialist (Role 17)

import Foundation

/// Manages the version history for a sequence.
///
/// VersionHistory provides git-like functionality for tracking changes to sequences:
/// - Commit new versions with diffs
/// - Navigate through history
/// - Checkout specific versions
/// - Compute diffs between versions
///
/// ## Example
/// ```swift
/// var history = VersionHistory(originalSequence: "ATCGATCG")
///
/// // Make changes and commit
/// let newSequence = "ATCGGGGATCG"
/// try history.commit(newSequence: newSequence, message: "Added GGG insertion")
///
/// // Navigate history
/// let oldSequence = try history.checkout(at: 0)
/// ```
@MainActor
public final class VersionHistory: ObservableObject {

    // MARK: - Published Properties

    /// All versions in chronological order
    @Published public private(set) var versions: [Version] = []

    /// Index of the currently checked out version
    @Published public private(set) var currentVersionIndex: Int = 0

    /// Whether there are newer versions to move forward to
    @Published public private(set) var canGoForward: Bool = false

    /// Whether there are older versions to move back to
    @Published public private(set) var canGoBack: Bool = false

    // MARK: - Properties

    /// The original sequence (version 0)
    public let originalSequence: String

    /// Name of the sequence being versioned
    public let sequenceName: String

    /// Current sequence content
    public private(set) var currentSequence: String

    /// Current version (nil if at original)
    public var currentVersion: Version? {
        guard currentVersionIndex > 0 && currentVersionIndex <= versions.count else {
            return nil
        }
        return versions[currentVersionIndex - 1]
    }

    /// Total number of versions (including original)
    public var versionCount: Int {
        versions.count + 1  // +1 for original
    }

    // MARK: - Initialization

    /// Creates a new version history starting from an original sequence.
    ///
    /// - Parameters:
    ///   - originalSequence: The initial sequence content
    ///   - sequenceName: Name of the sequence
    public init(originalSequence: String, sequenceName: String = "sequence") {
        self.originalSequence = originalSequence
        self.sequenceName = sequenceName
        self.currentSequence = originalSequence
        updateNavigationState()
    }

    // MARK: - Commit

    /// Commits a new version with the given sequence content.
    ///
    /// - Parameters:
    ///   - newSequence: The new sequence content
    ///   - message: Optional commit message
    ///   - author: Optional author name
    /// - Returns: The created version
    /// - Throws: `VersionError` if the commit fails
    @discardableResult
    public func commit(
        newSequence: String,
        message: String? = nil,
        author: String? = nil
    ) throws -> Version {
        // Compute diff from current state
        let diff = SequenceDiff.compute(from: currentSequence, to: newSequence)

        // Don't create empty commits
        guard !diff.isEmpty else {
            throw VersionError.noChanges
        }

        // Get parent hash
        let parentHash = currentVersion?.contentHash

        // Create version
        let version = Version(
            content: newSequence,
            diff: diff,
            parentHash: parentHash,
            message: message,
            author: author
        )

        // If we're not at the head, truncate forward history
        if currentVersionIndex < versions.count {
            versions = Array(versions.prefix(currentVersionIndex))
        }

        // Add version and update state
        versions.append(version)
        currentVersionIndex = versions.count
        currentSequence = newSequence
        updateNavigationState()

        return version
    }

    /// Commits changes from an EditableSequence.
    ///
    /// - Parameters:
    ///   - editable: The editable sequence with changes
    ///   - message: Optional commit message
    /// - Returns: The created version
    @discardableResult
    public func commit(
        from editable: EditableSequence,
        message: String? = nil
    ) throws -> Version {
        try commit(newSequence: editable.sequence, message: message)
    }

    // MARK: - Navigation

    /// Checks out the version at the specified index.
    ///
    /// - Parameter index: The version index (0 = original)
    /// - Returns: The sequence content at that version
    /// - Throws: `VersionError` if the index is invalid
    public func checkout(at index: Int) throws -> String {
        guard index >= 0 && index <= versions.count else {
            throw VersionError.invalidVersionIndex(index: index, count: versions.count + 1)
        }

        currentVersionIndex = index
        currentSequence = try reconstructSequence(at: index)
        updateNavigationState()

        return currentSequence
    }

    /// Checks out a specific version by its content hash.
    ///
    /// - Parameter hash: The content hash of the version
    /// - Returns: The sequence content at that version
    /// - Throws: `VersionError` if the version is not found
    public func checkout(hash: String) throws -> String {
        if let index = versions.firstIndex(where: { $0.contentHash == hash }) {
            return try checkout(at: index + 1)
        }

        // Check if it's the original
        if Version.computeHash(originalSequence) == hash {
            return try checkout(at: 0)
        }

        throw VersionError.versionNotFound(hash: hash)
    }

    /// Moves to the previous version.
    ///
    /// - Returns: The sequence content at the previous version
    /// - Throws: `VersionError` if already at the original
    @discardableResult
    public func goBack() throws -> String {
        guard canGoBack else {
            throw VersionError.atOldestVersion
        }
        return try checkout(at: currentVersionIndex - 1)
    }

    /// Moves to the next version.
    ///
    /// - Returns: The sequence content at the next version
    /// - Throws: `VersionError` if already at the latest
    @discardableResult
    public func goForward() throws -> String {
        guard canGoForward else {
            throw VersionError.atNewestVersion
        }
        return try checkout(at: currentVersionIndex + 1)
    }

    /// Moves to the latest version.
    ///
    /// - Returns: The sequence content at the latest version
    @discardableResult
    public func goToLatest() throws -> String {
        return try checkout(at: versions.count)
    }

    /// Moves to the original version.
    ///
    /// - Returns: The original sequence content
    @discardableResult
    public func goToOriginal() throws -> String {
        return try checkout(at: 0)
    }

    // MARK: - Diff Operations

    /// Computes the diff between two versions.
    ///
    /// - Parameters:
    ///   - fromIndex: Source version index
    ///   - toIndex: Target version index
    /// - Returns: The diff between the two versions
    public func diff(from fromIndex: Int, to toIndex: Int) throws -> SequenceDiff {
        let fromSequence = try reconstructSequence(at: fromIndex)
        let toSequence = try reconstructSequence(at: toIndex)
        return SequenceDiff.compute(from: fromSequence, to: toSequence)
    }

    /// Returns the diff for a specific version.
    ///
    /// - Parameter index: The version index
    /// - Returns: The diff from the previous version
    public func diffForVersion(at index: Int) -> SequenceDiff? {
        guard index > 0 && index <= versions.count else {
            return nil
        }
        return versions[index - 1].diff
    }

    // MARK: - Query

    /// Returns summaries of all versions for UI display.
    public func getVersionSummaries() -> [VersionSummary] {
        versions.map { VersionSummary(from: $0) }
    }

    /// Finds a version by its content hash.
    public func findVersion(byHash hash: String) -> Version? {
        versions.first { $0.contentHash == hash }
    }

    /// Returns the sequence content at a specific version.
    public func sequenceAt(index: Int) throws -> String {
        try reconstructSequence(at: index)
    }

    // MARK: - Private Methods

    private func reconstructSequence(at index: Int) throws -> String {
        guard index >= 0 && index <= versions.count else {
            throw VersionError.invalidVersionIndex(index: index, count: versions.count + 1)
        }

        // Start from original and apply diffs
        var result = originalSequence

        for i in 0..<index {
            result = try versions[i].diff.apply(to: result)
        }

        return result
    }

    private func updateNavigationState() {
        canGoBack = currentVersionIndex > 0
        canGoForward = currentVersionIndex < versions.count
    }
}

// MARK: - VersionError

/// Errors that can occur during version operations.
public enum VersionError: Error, LocalizedError, Sendable {

    case noChanges
    case invalidVersionIndex(index: Int, count: Int)
    case versionNotFound(hash: String)
    case atOldestVersion
    case atNewestVersion
    case corruptedHistory(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noChanges:
            return "No changes to commit"
        case .invalidVersionIndex(let index, let count):
            return "Invalid version index \(index) (valid range: 0..<\(count))"
        case .versionNotFound(let hash):
            return "Version with hash '\(hash)' not found"
        case .atOldestVersion:
            return "Already at the oldest version"
        case .atNewestVersion:
            return "Already at the newest version"
        case .corruptedHistory(let reason):
            return "History is corrupted: \(reason)"
        }
    }
}

// MARK: - Persistence

extension VersionHistory {

    /// Exports the version history to JSON.
    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let export = VersionHistoryExport(
            sequenceName: sequenceName,
            originalSequence: originalSequence,
            versions: versions,
            currentVersionIndex: currentVersionIndex
        )

        return try encoder.encode(export)
    }

    /// Creates a version history from JSON.
    public static func fromJSON(_ data: Data) throws -> VersionHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let export = try decoder.decode(VersionHistoryExport.self, from: data)
        let history = VersionHistory(
            originalSequence: export.originalSequence,
            sequenceName: export.sequenceName
        )
        history.versions = export.versions
        history.currentVersionIndex = export.currentVersionIndex
        _ = try? history.checkout(at: export.currentVersionIndex)

        return history
    }
}

/// Internal structure for serializing version history.
private struct VersionHistoryExport: Codable {
    let sequenceName: String
    let originalSequence: String
    let versions: [Version]
    let currentVersionIndex: Int
}
