// ViewerExportSelection.swift - The selection file for view state a viewer export leaf cannot rebuild
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The selection file of ARCH ruling 1.3, for view state that lives only in memory.
///
/// Before `begin` the GUI writes it to `selection.json` in a new `.lungfish-export-inputs/<UUID>/` folder beside the
/// output, the folder the retained-selection helper makes today. The leaf takes `--selection <file>`, reads the source
/// files named as its inputs and applies the selection with the shared builder, and its record names the file with
/// its digest. The file holds identities, predicates and edited values, never rendered output
/// (`docs/contracts/CLI-EQUIVALENCE.md`, an input held only in memory).
public struct ViewerExportSelection: Codable, Sendable, Equatable {
    /// The file name inside the inputs folder.
    public static let fileName = "selection.json"
    /// The folder beside the output that holds one `<UUID>` folder per export.
    public static let inputsFolderName = ".lungfish-export-inputs"
    /// The newest schema this type reads. It writes 3 for a selection whose annotation table names
    /// `bundleCodingFeatureTrackIDs` (Phase 2.13 lane 13.38, V1-1), 2 for one with another family field and 1 for one
    /// with none, so a region selection keeps its schema 2 bytes and a selection with no family field its schema 1
    /// bytes and digest (ARCH ruling on 12.39 R2). An older build refuses schema 3 instead of misreading it.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    /// Row identities the view holds selected, spelled as the result records them.
    public var identities: [String]
    /// The predicates and other view state the selection was made under.
    public var state: ViewerTableExportState
    /// Values edited in the view and not saved, keyed by row identity and then by field.
    public var editedValues: [String: [String: String]]
    /// The annotation table's columns, query and coding feature region (lane 12.39, ARCH ruling on 12.39 R1).
    public var annotationTable: AnnotationTableExportSelection?
    /// An open document's annotations for the GFF3 export (lane 12.39, ARCH ruling on 12.39 R2).
    public var documentAnnotations: AnnotationExportDocumentSelection?

    public init(
        identities: [String] = [],
        state: ViewerTableExportState = ViewerTableExportState(),
        editedValues: [String: [String: String]] = [:],
        annotationTable: AnnotationTableExportSelection? = nil,
        documentAnnotations: AnnotationExportDocumentSelection? = nil
    ) {
        self.identities = identities
        self.state = state
        self.editedValues = editedValues
        self.annotationTable = annotationTable
        self.documentAnnotations = documentAnnotations
        self.schemaVersion = 1
        self.schemaVersion = writtenSchemaVersion
    }

    /// 3 when the annotation table names `bundleCodingFeatureTrackIDs`, else 2 when a family field is set, else 1, and
    /// never below a schema set by hand.
    var writtenSchemaVersion: Int {
        if annotationTable?.bundleCodingFeatureTrackIDs != nil { return max(schemaVersion, 3) }
        return max(schemaVersion, annotationTable == nil && documentAnnotations == nil ? 1 : 2)
    }

    /// The bytes of the file, JSON with sorted keys so that one selection always writes one digest. A nil family
    /// field writes no key.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var written = self
        written.schemaVersion = writtenSchemaVersion
        return try encoder.encode(written)
    }

    /// Writes the file into a new `.lungfish-export-inputs/<UUID>/` folder beside `outputURL` and returns its URL.
    /// A failed write removes the new folder.
    public func write(besideOutput outputURL: URL) throws -> URL {
        let directory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(Self.inputsFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded().write(to: fileURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return fileURL
    }

    /// Reads a selection file. A schema newer than this type's is refused.
    public static func read(from url: URL) throws -> ViewerExportSelection {
        let selection = try JSONDecoder().decode(ViewerExportSelection.self, from: Data(contentsOf: url))
        guard selection.schemaVersion <= currentSchemaVersion else {
            throw ReadError.unsupportedSchema(selection.schemaVersion)
        }
        return selection
    }

    public enum ReadError: Error, LocalizedError, Equatable {
        case unsupportedSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "The selection file has schema \(version), newer than this build reads."
            }
        }
    }
}
