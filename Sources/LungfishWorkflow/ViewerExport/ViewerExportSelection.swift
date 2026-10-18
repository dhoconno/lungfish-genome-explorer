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
    /// The schema this type writes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Row identities the view holds selected, spelled as the result records them.
    public var identities: [String]
    /// The predicates and other view state the selection was made under.
    public var state: ViewerTableExportState
    /// Values edited in the view and not saved, keyed by row identity and then by field.
    public var editedValues: [String: [String: String]]

    public init(
        identities: [String] = [],
        state: ViewerTableExportState = ViewerTableExportState(),
        editedValues: [String: [String: String]] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.identities = identities
        self.state = state
        self.editedValues = editedValues
    }

    /// The bytes of the file, JSON with sorted keys so that one selection always writes one digest.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
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
