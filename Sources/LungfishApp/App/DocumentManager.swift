// DocumentManager.swift - Central document state management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - Logging

/// Logger for document operations
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

    public init(url: URL, type: DocumentType) {
        self.url = url
        self.name = url.lastPathComponent
        self.type = type
        logger.info("Created LoadedDocument: \(self.name, privacy: .public) type=\(type.rawValue, privacy: .public)")
    }
}

/// Types of documents the app can handle.
public enum DocumentType: String, CaseIterable, Sendable {
    case fasta
    case fastq
    case genbank
    case gff3
    case bed
    case vcf
    case bam
    case lungfishProject         // Native .lungfish project format
    case lungfishReferenceBundle // .lungfishref reference genome bundle
    case lungfishMultipleSequenceAlignmentBundle // .lungfishmsa MSA bundle
    case lungfishPhylogeneticTreeBundle // .lungfishtree tree bundle

    /// File extensions for this document type.
    public var extensions: [String] {
        switch self {
        case .fasta: return ["fa", "fasta", "fna", "fas"]
        case .fastq: return ["fq", "fastq", FASTQBundle.directoryExtension]
        case .genbank: return ["gb", "gbk", "genbank"]
        case .gff3: return ["gff", "gff3"]
        case .bed: return ["bed"]
        case .vcf: return ["vcf"]
        case .bam: return ["bam", "cram", "sam"]
        case .lungfishProject: return ["lungfish"]
        case .lungfishReferenceBundle: return ["lungfishref"]
        case .lungfishMultipleSequenceAlignmentBundle: return [MultipleSequenceAlignmentBundle.directoryExtension]
        case .lungfishPhylogeneticTreeBundle: return ["lungfishtree"]
        }
    }

    /// Whether this is a directory-based format
    public var isDirectoryFormat: Bool {
        switch self {
        case .lungfishProject, .lungfishReferenceBundle, .lungfishMultipleSequenceAlignmentBundle,
             .lungfishPhylogeneticTreeBundle:
            return true
        default:
            return false
        }
    }

    /// Detect document type from file extension.
    /// Handles gzip-compressed files (e.g., .fasta.gz, .fastq.gz)
    public static func detect(from url: URL) -> DocumentType? {
        var ext = url.pathExtension.lowercased()
        var urlToCheck = url

        // Handle gzip-compressed files: strip .gz and check the underlying extension
        if ext == "gz" {
            urlToCheck = url.deletingPathExtension()
            ext = urlToCheck.pathExtension.lowercased()
            logger.debug("DocumentType.detect: Stripped .gz, checking extension='\(ext, privacy: .public)'")
        }

        let detected = DocumentType.allCases.first { $0.extensions.contains(ext) }
        logger.debug("DocumentType.detect: extension='\(ext, privacy: .public)' -> \(detected?.rawValue ?? "nil", privacy: .public)")
        return detected
    }
}

// MARK: - Document Manager

/// Manages loaded documents and notifies observers of changes.
@Observable
@MainActor
public final class DocumentManager {

    /// Shared instance
    public static let shared = DocumentManager()

    /// Currently loaded documents
    public private(set) var documents: [LoadedDocument] = []

    /// Currently active/selected document
    public var activeDocument: LoadedDocument?

    /// Currently active Lungfish project (for persistent storage)
    public private(set) var activeProject: ProjectFile?

    /// Notification posted when a document is loaded
    public static let documentLoadedNotification = Notification.Name("DocumentManagerDocumentLoaded")

    /// Notification posted when active document changes
    public static let activeDocumentChangedNotification = Notification.Name("DocumentManagerActiveDocumentChanged")

    /// Notification posted when a project is opened
    public static let projectOpenedNotification = Notification.Name("DocumentManagerProjectOpened")

    private init() {
        logger.info("DocumentManager initialized")
    }

    // MARK: - Project Management

    /// Creates a new Lungfish project.
    ///
    /// - Parameters:
    ///   - url: The project directory URL (will have .lungfish extension added if missing)
    ///   - name: The project name
    ///   - description: Optional project description
    ///   - author: Optional author name
    /// - Returns: The created project
    public func createProject(
        at url: URL,
        name: String,
        description: String? = nil,
        author: String? = nil
    ) throws -> ProjectFile {
        logger.info("createProject: Creating project '\(name, privacy: .public)' at \(url.path, privacy: .public)")

        let project = try ProjectFile.create(
            at: url,
            name: name,
            description: description,
            author: author
        )

        // Bootstrap the primer-scheme folder so imported schemes and the
        // sidebar scanner find a stable home from the project's first moment.
        do {
            _ = try PrimerSchemesFolder.ensureFolder(in: project.url)
        } catch {
            logger.warning("createProject: Could not create Primer Schemes folder: \(error.localizedDescription)")
        }

        activeProject = project
        transitionDocumentState(to: [], activeDocument: nil)
        logger.info("createProject: Project created and set as active")

        NotificationCenter.default.post(
            name: Self.projectOpenedNotification,
            object: self,
            userInfo: ["project": project]
        )

        return project
    }

    /// Opens an existing Lungfish project.
    ///
    /// - Parameter url: The project directory URL
    /// - Returns: The opened project
    public func openProject(at url: URL) throws -> ProjectFile {
        logger.info("openProject: Opening project at \(url.path, privacy: .public)")

        let project = try ProjectFile.open(at: url)
        let projectDocuments = try loadSequencesFromProject(project)

        activeProject = project
        transitionDocumentState(to: projectDocuments, activeDocument: projectDocuments.first)
        logger.info("openProject: Opened project '\(project.name, privacy: .public)' with \(projectDocuments.count) loaded documents")

        NotificationCenter.default.post(
            name: Self.projectOpenedNotification,
            object: self,
            userInfo: ["project": project]
        )

        return project
    }

    /// Saves the active project.
    public func saveActiveProject() throws {
        guard let project = activeProject else {
            logger.warning("saveActiveProject: No active project to save")
            return
        }

        try project.save()
        logger.info("saveActiveProject: Saved project '\(project.name, privacy: .public)'")
    }

    /// Closes the active project.
    public func closeActiveProject() {
        guard let project = activeProject else {
            return
        }

        logger.info("closeActiveProject: Closing project '\(project.name, privacy: .public)'")
        activeProject = nil
        transitionDocumentState(to: [], activeDocument: nil)
    }

    /// Loads sequences from a project into documents.
    private func loadSequencesFromProject(_ project: ProjectFile) throws -> [LoadedDocument] {
        let sequenceSummaries = try project.listSequences()
        logger.info("loadSequencesFromProject: Found \(sequenceSummaries.count) sequences")
        var projectDocuments: [LoadedDocument] = []

        for summary in sequenceSummaries {
            // Get full sequence content
            let content = try project.getSequenceContent(id: summary.id)

            // Create a sequence object
            let alphabet: SequenceAlphabet = summary.alphabet == "dna" ? .dna :
                                             summary.alphabet == "rna" ? .rna : .protein
            let sequence = try Sequence(
                id: summary.id,
                name: summary.name,
                alphabet: alphabet,
                bases: content
            )

            // Create a loaded document for this sequence
            let document = LoadedDocument(
                url: project.url.appendingPathComponent(summary.name),
                type: .lungfishProject
            )
            document.sequences = [sequence]

            // Load annotations
            let storedAnnotations = try project.getAnnotations(for: summary.id)
            document.annotations = storedAnnotations.map { stored in
                SequenceAnnotation(
                    id: stored.id,
                    type: AnnotationType(rawValue: stored.type) ?? .region,
                    name: stored.name,
                    intervals: [AnnotationInterval(
                        start: stored.startPosition,
                        end: stored.endPosition
                    )],
                    strand: stored.strand == "+" ? .forward : (stored.strand == "-" ? .reverse : .unknown),
                    qualifiers: (stored.qualifiers ?? [:]).mapValues { AnnotationQualifier($0) }
                )
            }

            projectDocuments.append(document)
            logger.debug("loadSequencesFromProject: Loaded sequence '\(summary.name, privacy: .public)'")
        }

        return projectDocuments
    }

    /// Adds a sequence to the active project.
    ///
    /// - Parameter sequence: The sequence to add
    /// - Returns: The sequence ID in the project
    @discardableResult
    public func addSequenceToProject(_ sequence: Sequence) throws -> UUID {
        guard let project = activeProject else {
            throw DocumentLoadError.parseError("No active project")
        }

        let sequenceId = try project.addSequence(sequence)
        logger.info("addSequenceToProject: Added sequence '\(sequence.name, privacy: .public)' with ID \(sequenceId.uuidString)")

        return sequenceId
    }

    // MARK: - Document Loading

    /// Loads a document from the given URL.
    ///
    /// - Parameter url: The file URL to load
    /// - Returns: The loaded document, or nil if loading failed
    /// - Throws: Error if the file cannot be read or parsed
    @discardableResult
    public func loadDocument(at url: URL) async throws -> LoadedDocument {
        logger.info("loadDocument: Starting load for \(url.path, privacy: .public)")

        // Check if file exists
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        logger.info("loadDocument: File exists = \(fileExists)")

        if !fileExists {
            logger.error("loadDocument: File not found at \(url.path, privacy: .public)")
            throw DocumentLoadError.fileNotFound(url)
        }

        // Check file readability
        let isReadable = FileManager.default.isReadableFile(atPath: url.path)
        logger.info("loadDocument: File readable = \(isReadable)")

        if !isReadable {
            logger.error("loadDocument: File not readable at \(url.path, privacy: .public)")
            throw DocumentLoadError.accessDenied(url)
        }

        // Detect document type
        guard let type = DocumentType.detect(from: url) else {
            logger.error("loadDocument: Unsupported format for extension '\(url.pathExtension, privacy: .public)'")
            throw DocumentLoadError.unsupportedFormat(url.pathExtension)
        }

        logger.info("loadDocument: Detected type = \(type.rawValue, privacy: .public)")

        let document = LoadedDocument(url: url, type: type)

        // Load based on type
        do {
            switch type {
            case .fasta:
                logger.info("loadDocument: Loading FASTA...")
                try await loadFASTA(into: document)
            case .fastq:
                logger.info("loadDocument: Loading FASTQ...")
                try await loadFASTQ(into: document)
            case .genbank:
                logger.info("loadDocument: Loading GenBank...")
                try await loadGenBank(into: document)
            case .gff3:
                logger.info("loadDocument: Loading GFF3...")
                try await loadGFF3(into: document)
            case .bed:
                logger.info("loadDocument: Loading BED...")
                try await loadBED(into: document)
            case .vcf:
                logger.info("loadDocument: Loading VCF...")
                try await loadVCF(into: document)
            case .bam:
                logger.info("loadDocument: BAM/CRAM files are imported as alignment tracks via File > Import Center…")
                throw DocumentLoadError.unsupportedFormat("BAM/CRAM files are imported as alignment tracks. Use File \u{203A} Import Center\u{2026} with a bundle open.")
            case .lungfishProject:
                // For .lungfish projects, use openProject instead
                logger.info("loadDocument: Opening Lungfish project...")
                _ = try openProject(at: url)
                return activeDocument ?? document
            case .lungfishReferenceBundle:
                logger.info("loadDocument: Loading reference bundle...")
                try loadReferenceBundle(into: document)
            case .lungfishMultipleSequenceAlignmentBundle:
                logger.info("loadDocument: MSA bundles are displayed by the native bundle viewer")
                throw DocumentLoadError.unsupportedFormat("Use the MSA bundle viewer for .lungfishmsa bundles")
            case .lungfishPhylogeneticTreeBundle:
                logger.info("loadDocument: Tree bundles are displayed by the native bundle viewer")
                throw DocumentLoadError.unsupportedFormat("Use the tree bundle viewer for .lungfishtree bundles")
            }
        } catch {
            logger.error("loadDocument: Load failed with error: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        logger.info("loadDocument: Loaded \(document.sequences.count) sequences, \(document.annotations.count) annotations")

        // Add to documents list
        documents.append(document)
        logger.info("loadDocument: Added to documents list (total: \(self.documents.count))")

        // Set as active
        setActiveDocument(document)
        logger.info("loadDocument: Set as active document")

        // Post notifications
        NotificationCenter.default.post(
            name: Self.documentLoadedNotification,
            object: self,
            userInfo: ["document": document]
        )
        logger.info("loadDocument: Posted documentLoadedNotification")

        logger.info("loadDocument: Successfully completed loading \(document.name, privacy: .public)")
        return document
    }

    /// Closes a document.
    public func closeDocument(_ document: LoadedDocument) {
        logger.info("closeDocument: Closing \(document.name, privacy: .public)")
        let wasActiveDocument = activeDocument?.id == document.id
        documents.removeAll { $0.id == document.id }
        if wasActiveDocument {
            setActiveDocument(documents.first)
        }
    }

    /// Sets the active document.
    public func setActiveDocument(_ document: LoadedDocument?) {
        logger.info("setActiveDocument: \(document?.name ?? "nil", privacy: .public)")
        activeDocument = document
        NotificationCenter.default.post(
            name: Self.activeDocumentChangedNotification,
            object: self,
            userInfo: document.map { ["document": $0] }
        )
    }

    /// Registers a pre-loaded document with the document manager.
    /// Used when documents are loaded synchronously outside the normal async flow.
    public func registerDocument(_ document: LoadedDocument) {
        // Check if already registered
        if documents.contains(where: { $0.url == document.url }) {
            logger.debug("registerDocument: Document already registered: \(document.name, privacy: .public)")
            return
        }

        logger.info("registerDocument: Registering \(document.name, privacy: .public)")
        documents.append(document)
    }

    private func transitionDocumentState(to newDocuments: [LoadedDocument], activeDocument newActiveDocument: LoadedDocument?) {
        documents = newDocuments

        guard activeDocument?.id != newActiveDocument?.id else {
            activeDocument = newActiveDocument
            return
        }

        setActiveDocument(newActiveDocument)
    }

    // MARK: - Project Folder Loading

    /// Notification posted when a project folder is loaded
    public static let projectLoadedNotification = Notification.Name("DocumentManagerProjectLoaded")

    /// Loads all supported documents from a folder recursively.
    ///
    /// - Parameter folderURL: The folder URL to scan
    /// - Returns: Array of loaded documents
    /// - Throws: Error if folder cannot be accessed
    public func loadProjectFolder(at folderURL: URL) async throws -> [LoadedDocument] {
        logger.info("loadProjectFolder: Scanning \(folderURL.path, privacy: .public)")

        let fileManager = FileManager.default

        // Verify folder exists and is a directory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            logger.error("loadProjectFolder: Not a valid directory: \(folderURL.path, privacy: .public)")
            throw DocumentLoadError.fileNotFound(folderURL)
        }

        var loadedDocuments: [LoadedDocument] = []

        // Enumerate all files recursively
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            logger.error("loadProjectFolder: Failed to create enumerator for \(folderURL.path, privacy: .public)")
            throw DocumentLoadError.accessDenied(folderURL)
        }

        // Collect files synchronously to avoid async iterator issues
        // The enumerator's makeIterator() is unavailable in async contexts
        let filesToLoad: [URL] = {
            var files: [URL] = []
            while let fileURL = enumerator.nextObject() as? URL {
                // Check if it's a regular file with supported extension
                if let type = DocumentType.detect(from: fileURL) {
                    logger.debug("loadProjectFolder: Found supported file \(fileURL.lastPathComponent, privacy: .public) (\(type.rawValue, privacy: .public))")
                    files.append(fileURL)
                }
            }
            return files
        }()

        logger.info("loadProjectFolder: Found \(filesToLoad.count) supported files")

        // Load each file
        for fileURL in filesToLoad {
            do {
                let document = try await loadDocument(at: fileURL)
                loadedDocuments.append(document)
                logger.debug("loadProjectFolder: Loaded \(fileURL.lastPathComponent, privacy: .public)")
            } catch {
                // Log warning but continue with other files
                logger.warning("loadProjectFolder: Skipped \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        logger.info("loadProjectFolder: Successfully loaded \(loadedDocuments.count) documents")

        // Post notification for project loaded
        NotificationCenter.default.post(
            name: Self.projectLoadedNotification,
            object: self,
            userInfo: [
                "folderURL": folderURL,
                "documents": loadedDocuments
            ]
        )

        return loadedDocuments
    }

    // MARK: - Private Loading Methods

    private func loadFASTA(into document: LoadedDocument) async throws {
        logger.info("loadFASTA: Creating FASTAReader for \(document.url.path, privacy: .public)")

        let reader = try FASTAReader(url: document.url)
        logger.info("loadFASTA: FASTAReader created, calling readAll()")

        let sequences = try await reader.readAll()
        logger.info("loadFASTA: Read \(sequences.count) sequences")

        for (index, seq) in sequences.enumerated() {
            logger.debug("loadFASTA: Sequence[\(index)]: name='\(seq.name, privacy: .public)' length=\(seq.length)")
        }

        document.sequences = sequences
        logger.info("loadFASTA: Assigned sequences to document")
    }

    private func loadFASTQ(into document: LoadedDocument) async throws {
        logger.info("loadFASTQ: Creating FASTQReader for \(document.url.path, privacy: .public)")

        let reader = FASTQReader()
        var sequences: [Sequence] = []
        var count = 0

        logger.info("loadFASTQ: Starting to read records...")

        for try await record in reader.records(from: document.url) {
            // Extract raw quality scores from the QualityScore struct
            // QualityScore conforms to RandomAccessCollection, allowing iteration over UInt8 values
            let qualityValues = Array(record.quality)

            // Convert FASTQRecord to Sequence, preserving quality scores
            let sequence = try Sequence(
                name: record.identifier,
                description: record.description,
                alphabet: .dna,
                bases: record.sequence,
                qualityScores: qualityValues
            )
            sequences.append(sequence)

            count += 1
            if count % 1000 == 0 {
                logger.debug("loadFASTQ: Read \(count) records so far...")
            }

            // Limit for memory
            if count >= 10000 {
                logger.info("loadFASTQ: Reached 10000 record limit")
                break
            }
        }

        logger.info("loadFASTQ: Read \(sequences.count) sequences total with quality scores preserved")
        document.sequences = sequences
    }

    private func loadGFF3(into document: LoadedDocument) async throws {
        logger.info("loadGFF3: Creating GFF3Reader for \(document.url.path, privacy: .public)")

        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: document.url)

        logger.info("loadGFF3: Read \(annotations.count) annotations")
        document.annotations = annotations
    }

    private func loadBED(into document: LoadedDocument) async throws {
        logger.info("loadBED: Creating BEDReader for \(document.url.path, privacy: .public)")

        let reader = BEDReader()
        let annotations = try await reader.readAsAnnotations(from: document.url)

        logger.info("loadBED: Read \(annotations.count) annotations")
        document.annotations = annotations
    }

    private func loadVCF(into document: LoadedDocument) async throws {
        logger.info("loadVCF: Creating VCFReader for \(document.url.path, privacy: .public)")

        let reader = VCFReader()
        let variants = try await reader.readAll(from: document.url)

        logger.info("loadVCF: Read \(variants.count) variants")
        document.annotations = variants.map { $0.toAnnotation() }
    }

    private func loadGenBank(into document: LoadedDocument) async throws {
        logger.info("loadGenBank: Creating GenBankReader for \(document.url.path, privacy: .public)")

        let reader = try GenBankReader(url: document.url)
        let records = try await reader.readAll()

        logger.info("loadGenBank: Read \(records.count) records")

        // Extract sequences and annotations from all records
        var sequences: [Sequence] = []
        var annotations: [SequenceAnnotation] = []

        for record in records {
            sequences.append(record.sequence)
            annotations.append(contentsOf: record.annotations)
            logger.debug("loadGenBank: Record '\(record.locus.name, privacy: .public)' with \(record.annotations.count) annotations")
        }

        document.sequences = sequences
        document.annotations = annotations

        logger.info("loadGenBank: Total \(sequences.count) sequences, \(annotations.count) annotations")
    }

    /// Loads a `.lungfishref` reference bundle into a document.
    ///
    /// Reads the bundle manifest and stores the chromosome list. The actual
    /// sequence and annotation data is fetched on-demand via `BundleDataProvider`
    /// rather than being loaded entirely into memory.
    ///
    /// - Parameter document: The document to populate with bundle data
    /// - Throws: Error if the manifest cannot be read or decoded
    private func loadReferenceBundle(into document: LoadedDocument) throws {
        logger.info("loadReferenceBundle: Loading manifest from \(document.url.path, privacy: .public)")

        let manifest = try BundleManifest.load(from: document.url)

        // Validate manifest
        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            let messages = validationErrors.map { $0.localizedDescription }.joined(separator: "; ")
            logger.error("loadReferenceBundle: Validation failed: \(messages, privacy: .public)")
            throw DocumentLoadError.parseError("Bundle validation failed: \(messages)")
        }

        document.bundleManifest = manifest

        logger.info("loadReferenceBundle: Bundle '\(manifest.name, privacy: .public)' loaded with \(manifest.genome?.chromosomes.count ?? 0) chromosomes, \(manifest.annotations.count) annotation tracks")
    }
}

// MARK: - Errors

/// Errors that can occur during document loading.
public enum DocumentLoadError: Error, LocalizedError {
    case unsupportedFormat(String)
    case fileNotFound(URL)
    case parseError(String)
    case accessDenied(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: \(ext)"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .accessDenied(let url):
            return "Access denied: \(url.lastPathComponent)"
        }
    }
}

// MARK: - Drag and Drop Types

/// UTTypes supported for drag and drop
extension DocumentManager {
    /// All supported file extensions for drag and drop
    public static var supportedExtensions: [String] {
        DocumentType.allCases.flatMap { $0.extensions }
    }

    /// NSPasteboard types for drag and drop
    public static var pasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL]
    }
}
