// ViewerGraphicViewState.swift - The view-state file of a viewer image export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The per-track settings a viewer holds only in memory, which a figure of the view needs (ARCH ruling B10, 3.1).
///
/// Before `begin` the app writes it to `view-state.json` in a new `.lungfish-export-inputs/<UUID>/` folder beside
/// the output, and `bundle export-graphic` takes `--view-state <file>`. It holds settings and never pixels, and the
/// leaf's record names it with its digest as an input.
public struct ViewerGraphicViewState: Codable, Sendable, Equatable {
    /// The file name inside the inputs folder.
    public static let fileName = "view-state.json"
    /// The newest schema this type reads.
    public static let currentSchemaVersion = 1

    /// The settings of one track, by the id the manifest records.
    public struct Track: Codable, Sendable, Equatable {
        public var id: String
        /// The track's height in points, as the view drew it.
        public var height: Double?

        public init(id: String, height: Double? = nil) {
            self.id = id
            self.height = height
        }
    }

    public var schemaVersion: Int
    public var tracks: [Track]
    /// The read row cap to draw with, or nil for the figure's own default of 75 rows. A figure has no uncapped mode yet.
    public var readRowCap: Int?
    /// The sample order, filters, row heights and colour theme the variant track drew with, or nil for the defaults.
    public var sampleDisplay: SampleDisplayState?
    /// True when the window had Hide high-gap sites on. A figure does not hide those sites, so it records an omission
    /// that says so (ALIGN-IMAGE-EXPORT-MASKING) and draws every item it draws with the switch off. Nil is off and the
    /// file then holds no key, so a state at the defaults writes the bytes it wrote before.
    public var hideHighGapSites: Bool?

    public init(
        tracks: [Track] = [], readRowCap: Int? = nil, sampleDisplay: SampleDisplayState? = nil,
        hideHighGapSites: Bool? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.tracks = tracks
        self.readRowCap = readRowCap
        self.sampleDisplay = sampleDisplay
        self.hideHighGapSites = hideHighGapSites
    }

    /// The height set for `trackID`, if any.
    public func height(for trackID: String) -> Double? {
        tracks.first { $0.id == trackID }?.height
    }

    /// The bytes of the file, JSON with sorted keys so that one state always writes one digest.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Writes the file into a new `.lungfish-export-inputs/<UUID>/` folder beside `outputURL` and returns its URL.
    /// A failed write removes the new folder.
    public func write(besideOutput outputURL: URL) throws -> URL {
        let directory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true)
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

    /// Reads a view-state file. A schema newer than this type's is refused.
    public static func read(from url: URL) throws -> ViewerGraphicViewState {
        let state = try JSONDecoder().decode(ViewerGraphicViewState.self, from: Data(contentsOf: url))
        guard state.schemaVersion <= currentSchemaVersion else {
            throw ViewerExportSelection.ReadError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }
}
