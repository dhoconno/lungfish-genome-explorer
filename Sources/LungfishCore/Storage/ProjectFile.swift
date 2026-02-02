// ProjectFile.swift - Lungfish project file format (.lungfish)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import os.log

// MARK: - ProjectFile

/// Represents a Lungfish project file (.lungfish).
///
/// A .lungfish project is a directory bundle containing:
/// - `project.db` - SQLite database with sequences, versions, annotations
/// - `metadata.json` - Project-level metadata
/// - `sequences/` - Optional raw sequence files (for large sequences)
/// - `cache/` - Cached data (track tiles, indices)
///
/// ## File Format
///
/// The project directory structure:
/// ```
/// MyProject.lungfish/
/// ├── project.db          # SQLite database (primary storage)
/// ├── metadata.json       # Project metadata
/// ├── sequences/          # Raw sequence storage (for large files)
/// │   └── {uuid}.seq      # Memory-mapped sequence data
/// ├── indices/            # Search indices
/// │   └── {uuid}.fai      # FASTA index files
/// └── cache/              # Cached data
///     └── tiles/          # Rendered track tiles
/// ```
///
/// ## Example
///
/// ```swift
/// // Create a new project
/// let project = try ProjectFile.create(at: projectURL, name: "My Genome Project")
///
/// // Add a sequence
/// try project.addSequence(sequence, withHistory: history)
///
/// // Save changes
/// try project.save()
///
/// // Open existing project
/// let existing = try ProjectFile.open(at: projectURL)
/// ```
@MainActor
public final class ProjectFile: ObservableObject {

    // MARK: - Properties

    /// The project directory URL
    public let url: URL

    /// Project name
    @Published public var name: String

    /// Project description
    @Published public var description: String?

    /// Creation date
    public let createdAt: Date

    /// Last modified date
    @Published public private(set) var modifiedAt: Date

    /// Author/creator
    @Published public var author: String?

    /// Project version
    @Published public var version: String = "1.0"

    /// Custom metadata
    @Published public var customMetadata: [String: String] = [:]

    /// The underlying storage
    private let store: ProjectStore

    /// Whether the project has unsaved changes
    @Published public private(set) var isDirty: Bool = false

    /// Logger for project operations
    private static let logger = Logger(
        subsystem: "com.lungfish.browser",
        category: "ProjectFile"
    )

    /// File extension for Lungfish projects
    public static let fileExtension = "lungfish"

    /// Project file format version
    public static let formatVersion = "1.0"

    // MARK: - Initialization

    private init(
        url: URL,
        name: String,
        store: ProjectStore,
        createdAt: Date,
        modifiedAt: Date
    ) {
        self.url = url
        self.name = name
        self.store = store
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    // MARK: - Factory Methods

    /// Creates a new project at the specified location.
    ///
    /// - Parameters:
    ///   - url: The project directory URL (should end in .lungfish)
    ///   - name: The project name
    ///   - description: Optional project description
    ///   - author: Optional author name
    /// - Returns: The created project
    public static func create(
        at url: URL,
        name: String,
        description: String? = nil,
        author: String? = nil
    ) throws -> ProjectFile {
        let projectURL = url.pathExtension == fileExtension
            ? url
            : url.appendingPathExtension(fileExtension)

        logger.info("Creating project at \(projectURL.path, privacy: .public)")

        // Create the project store (creates directory and database)
        let store = try ProjectStore(at: projectURL)

        let now = Date()
        let project = ProjectFile(
            url: projectURL,
            name: name,
            store: store,
            createdAt: now,
            modifiedAt: now
        )

        project.description = description
        project.author = author

        // Save initial metadata
        try project.saveMetadata()

        logger.info("Project created: \(name, privacy: .public)")
        return project
    }

    /// Opens an existing project.
    ///
    /// - Parameter url: The project directory URL
    /// - Returns: The opened project
    public static func open(at url: URL) throws -> ProjectFile {
        logger.info("Opening project at \(url.path, privacy: .public)")

        // Verify it's a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectFileError.notAProject(url: url)
        }

        // Open the store
        let store = try ProjectStore(at: url)

        // Load metadata
        let metadata = try loadMetadata(from: url)

        let project = ProjectFile(
            url: url,
            name: metadata.name,
            store: store,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt
        )

        project.description = metadata.description
        project.author = metadata.author
        project.version = metadata.version
        project.customMetadata = metadata.customMetadata

        logger.info("Project opened: \(metadata.name, privacy: .public)")
        return project
    }

    // MARK: - Sequence Operations

    /// Adds a sequence to the project.
    ///
    /// - Parameters:
    ///   - sequence: The sequence to add
    ///   - history: Optional version history to preserve
    /// - Returns: The sequence ID
    @discardableResult
    public func addSequence(
        _ sequence: Sequence,
        withHistory history: VersionHistory? = nil
    ) throws -> UUID {
        let sequenceId = try store.storeSequence(
            name: sequence.name,
            content: sequence.asString(),
            alphabet: sequence.alphabet.rawValue,
            metadata: nil
        )

        // If we have history, replay the versions
        if let history = history {
            for version in history.versions {
                let hash = Version.computeHash(try version.diff.apply(to: sequence.asString()))
                try store.recordVersion(
                    sequenceId: sequenceId,
                    diff: version.diff,
                    newContentHash: hash,
                    message: version.message,
                    author: version.author
                )
            }

            // Set to the current version
            try store.checkoutVersion(
                sequenceId: sequenceId,
                versionIndex: history.currentVersionIndex
            )
        }

        markDirty()
        Self.logger.info("Added sequence '\(sequence.name, privacy: .public)'")
        return sequenceId
    }

    /// Gets a sequence by ID.
    public func getSequence(id: UUID) throws -> StoredSequence? {
        try store.getSequence(id: id)
    }

    /// Lists all sequences in the project.
    public func listSequences() throws -> [SequenceSummary] {
        try store.listSequences()
    }

    /// Reconstructs a sequence at a specific version.
    public func getSequenceContent(id: UUID, atVersion: Int? = nil) throws -> String {
        let versionIndex: Int
        if let version = atVersion {
            versionIndex = version
        } else {
            versionIndex = try store.getCurrentVersionIndex(for: id)
        }
        return try store.reconstructSequence(id: id, atVersion: versionIndex)
    }

    /// Records an edit to a sequence.
    public func recordEdit(
        sequenceId: UUID,
        diff: SequenceDiff,
        message: String? = nil,
        author: String? = nil
    ) throws {
        // Get current content and compute new content
        let currentContent = try getSequenceContent(id: sequenceId)
        let newContent = try diff.apply(to: currentContent)
        let newHash = Version.computeHash(newContent)

        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff,
            newContentHash: newHash,
            message: message,
            author: author
        )

        markDirty()
    }

    /// Gets the version history for a sequence.
    public func getVersionHistory(for sequenceId: UUID) throws -> [StoredVersion] {
        try store.getVersionHistory(for: sequenceId)
    }

    /// Checks out a specific version of a sequence.
    public func checkoutVersion(sequenceId: UUID, versionIndex: Int) throws {
        try store.checkoutVersion(sequenceId: sequenceId, versionIndex: versionIndex)
        markDirty()
    }

    // MARK: - Annotation Operations

    /// Adds an annotation to a sequence.
    @discardableResult
    public func addAnnotation(
        to sequenceId: UUID,
        type: String,
        name: String,
        range: Range<Int>,
        strand: String = "+",
        qualifiers: [String: String]? = nil,
        color: String? = nil
    ) throws -> UUID {
        let id = try store.storeAnnotation(
            sequenceId: sequenceId,
            type: type,
            name: name,
            startPosition: range.lowerBound,
            endPosition: range.upperBound,
            strand: strand,
            qualifiers: qualifiers,
            color: color
        )
        markDirty()
        return id
    }

    /// Gets annotations for a sequence.
    public func getAnnotations(
        for sequenceId: UUID,
        inRange range: Range<Int>? = nil
    ) throws -> [StoredAnnotation] {
        try store.getAnnotations(sequenceId: sequenceId, inRange: range)
    }

    // MARK: - Persistence

    /// Saves project metadata.
    public func save() throws {
        try saveMetadata()
        isDirty = false
        Self.logger.info("Project saved: \(self.name, privacy: .public)")
    }

    private func saveMetadata() throws {
        let metadata = ProjectMetadata(
            formatVersion: Self.formatVersion,
            name: name,
            description: description,
            author: author,
            version: version,
            createdAt: createdAt,
            modifiedAt: Date(),
            customMetadata: customMetadata
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(metadata)
        let metadataURL = url.appendingPathComponent("metadata.json")
        try data.write(to: metadataURL)

        modifiedAt = metadata.modifiedAt
    }

    private static func loadMetadata(from url: URL) throws -> ProjectMetadata {
        let metadataURL = url.appendingPathComponent("metadata.json")

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ProjectFileError.missingMetadata(url: url)
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(ProjectMetadata.self, from: data)
    }

    private func markDirty() {
        isDirty = true
        modifiedAt = Date()
    }

    // MARK: - Edit Log

    /// Logs an edit operation for audit purposes.
    public func logEdit(
        sequenceId: UUID,
        operation: String,
        position: Int? = nil,
        length: Int? = nil,
        bases: String? = nil
    ) throws {
        try store.logEdit(
            sequenceId: sequenceId,
            operation: operation,
            position: position,
            length: length,
            bases: bases,
            sessionId: ProcessInfo.processInfo.processIdentifier.description
        )
    }

    /// Gets recent edits for a sequence.
    public func getRecentEdits(sequenceId: UUID, limit: Int = 100) throws -> [EditLogEntry] {
        try store.getRecentEdits(sequenceId: sequenceId, limit: limit)
    }

    // MARK: - Project Metadata

    /// Sets a custom metadata value.
    public func setCustomMetadata(key: String, value: String) {
        customMetadata[key] = value
        markDirty()
    }

    /// Gets a custom metadata value.
    public func getCustomMetadata(key: String) -> String? {
        customMetadata[key]
    }
}

// MARK: - ProjectMetadata

/// Serializable project metadata.
private struct ProjectMetadata: Codable {
    let formatVersion: String
    let name: String
    let description: String?
    let author: String?
    let version: String
    let createdAt: Date
    let modifiedAt: Date
    let customMetadata: [String: String]
}

// MARK: - ProjectFileError

/// Errors that can occur during project file operations.
public enum ProjectFileError: Error, LocalizedError, Sendable {
    case notAProject(url: URL)
    case missingMetadata(url: URL)
    case incompatibleVersion(found: String, required: String)
    case saveError(message: String)
    case loadError(message: String)

    public var errorDescription: String? {
        switch self {
        case .notAProject(let url):
            return "Not a valid Lungfish project: \(url.lastPathComponent)"
        case .missingMetadata(let url):
            return "Missing metadata.json in project: \(url.lastPathComponent)"
        case .incompatibleVersion(let found, let required):
            return "Incompatible project version: found \(found), required \(required)"
        case .saveError(let message):
            return "Failed to save project: \(message)"
        case .loadError(let message):
            return "Failed to load project: \(message)"
        }
    }
}

// Note: Version.computeHash is already defined in Version.swift
