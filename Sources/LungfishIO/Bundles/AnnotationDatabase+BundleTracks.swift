// AnnotationDatabase+BundleTracks.swift - The one reader of a bundle's annotation databases, which names each track it could not read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// ANNOT-EXPORT-MISSING-TRACK (BIO-EXPORT-MISSING-TRACK-17). A bundle's manifest can list an annotation track whose
/// database is missing or cannot be read. Every route that writes a bundle's annotations, the GFF3 export, the sequence
/// export with annotations, the extraction to a new bundle, the drawer's table export and iVar's codon merging, opens
/// the databases through this one reader, so each knows by name the tracks it leaves out and says so.
extension AnnotationDatabase {
    /// A listed annotation track whose database is missing, lies outside the bundle or cannot be opened, so a route
    /// that writes the bundle's annotations leaves its features out.
    public struct LeftOutTrack: Sendable, Equatable, Hashable, Codable {
        /// The manifest's track id.
        public let id: String
        /// The track's name as the sidebar and the drawer show it.
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        /// One line for this track, in the drawer's words (`AnnotationDrawerIndexHandoff.trackNotInTableLine`).
        /// `place` names what the route wrote, such as "file", "bundle" or "table".
        public func line(notIn place: String) -> String {
            "\(name): its annotation database is missing or cannot be read, so its annotations are not in this \(place)."
        }
    }

    /// One track a caller lists, with the database file it names, or nil when the path leaves the bundle.
    public struct ListedTrack: Sendable {
        public let id: String
        public let name: String
        public let url: URL?

        public init(id: String, name: String, url: URL?) {
            self.id = id
            self.name = name
            self.url = url
        }
    }

    /// A listed track whose database opened.
    public struct OpenedTrack: Sendable {
        public let id: String
        public let name: String
        public let url: URL
        public let database: AnnotationDatabase
    }

    /// The databases of a bundle's listed tracks: those that opened, in the manifest's order, and by name each one
    /// that could not be read.
    public struct BundleTracks: Sendable {
        public let opened: [OpenedTrack]
        public let leftOut: [LeftOutTrack]

        /// Whether the manifest lists tracks with databases and none of them could be read.
        public var noneCouldBeRead: Bool { opened.isEmpty && !leftOut.isEmpty }
    }

    /// The tracks of `manifest` that name an annotation database, in the manifest's order. A path that leaves the
    /// bundle keeps its track with no file, so the reader leaves it out by name.
    public static func listedTracks(bundleURL: URL, manifest: BundleManifest) -> [ListedTrack] {
        manifest.annotations.compactMap { track in
            guard let path = track.databasePath else { return nil }
            let url = try? BundleManifest.validatedBundleMemberURL(
                for: path, in: bundleURL, field: "annotations[\(track.id)].databasePath"
            )
            return ListedTrack(id: track.id, name: track.name, url: url)
        }
    }

    /// Opens the database of every track `manifest` lists with a database path, in the manifest's order. A missing
    /// file, a path that leaves the bundle and a file SQLite cannot open each leave the track out by name.
    public static func openBundleTracks(bundleURL: URL, manifest: BundleManifest) -> BundleTracks {
        openTracks(listedTracks(bundleURL: bundleURL, manifest: manifest))
    }

    /// Opens the database of each listed track, in order, and names each one that could not be read.
    public static func openTracks(_ listed: [ListedTrack]) -> BundleTracks {
        var opened: [OpenedTrack] = []
        var leftOut: [LeftOutTrack] = []
        for track in listed {
            guard let url = track.url, FileManager.default.fileExists(atPath: url.path),
                  let database = try? AnnotationDatabase(url: url) else {
                leftOut.append(LeftOutTrack(id: track.id, name: track.name))
                continue
            }
            opened.append(OpenedTrack(id: track.id, name: track.name, url: url, database: database))
        }
        return BundleTracks(opened: opened, leftOut: leftOut)
    }
}

/// The words every route shows when it leaves out tracks whose databases could not be read, in the drawer's style
/// (`AnnotationDrawerIndexHandoff.swift`), so the app and `lungfish-cli` say one thing. It is nested, as the reader's
/// types are, so the module's list of public types does not move.
extension AnnotationDatabase {
public enum LeftOutWords {
    /// The remedy, the drawer's line for a track whose database could not be read.
    public static let remedy = "Reopen the bundle, and if this repeats, import those annotations again."

    /// The record's key, an array of the left-out tracks' names in the manifest's order.
    public static let provenanceKey = "left_out_tracks"

    /// The track names, joined for a sentence.
    public static func names(_ tracks: [AnnotationDatabase.LeftOutTrack]) -> String {
        tracks.map(\.name).joined(separator: ", ")
    }

    /// The sentence a completion message ends with, or nil when no track was left out. `place` names what the route
    /// wrote, such as "file", "bundle" or "table".
    public static func summary(_ tracks: [AnnotationDatabase.LeftOutTrack], notIn place: String) -> String? {
        guard !tracks.isEmpty else { return nil }
        let lead = tracks.count == 1
            ? "1 annotation track is not in this \(place), because its annotation database is missing or cannot be read"
            : "\(tracks.count) annotation tracks are not in this \(place), because their annotation databases are missing or cannot be read"
        return "\(lead): \(names(tracks)). \(remedy)"
    }

    /// `message`, then the summary when a track was left out.
    public static func message(_ message: String, leftOut tracks: [AnnotationDatabase.LeftOutTrack], notIn place: String) -> String {
        guard let summary = summary(tracks, notIn: place) else { return message }
        let base = message.hasSuffix(".") ? message : message + "."
        return "\(base) \(summary)"
    }

    /// One standard error line per left-out track.
    public static func standardErrorLines(_ tracks: [AnnotationDatabase.LeftOutTrack], notIn place: String) -> [String] {
        tracks.map { "warning: " + $0.line(notIn: place) }
    }

    /// Writes one standard error line per left-out track.
    public static func writeStandardErrorLines(_ tracks: [AnnotationDatabase.LeftOutTrack], notIn place: String) {
        for line in standardErrorLines(tracks, notIn: place) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    /// The refusal when the manifest lists annotation tracks and no database of them can be read (BIO item 6).
    public static func noneCouldBeRead(sourceName: String, _ tracks: [AnnotationDatabase.LeftOutTrack]) -> String {
        let count = tracks.count == 1 ? "1 annotation track" : "\(tracks.count) annotation tracks"
        let its = tracks.count == 1 ? "its annotation database is" : "their annotation databases are"
        return "\(sourceName) lists \(count), but \(its) missing or cannot be read: \(names(tracks)). "
            + "Nothing was written. \(remedy)"
    }

    /// The not-found words of Go to Gene when some tracks were not searched.
    public static func notSearched(_ tracks: [AnnotationDatabase.LeftOutTrack]) -> String? {
        guard !tracks.isEmpty else { return nil }
        let lead = tracks.count == 1
            ? "1 annotation track was not searched, because its annotation database is missing or cannot be read"
            : "\(tracks.count) annotation tracks were not searched, because their annotation databases are missing or cannot be read"
        return "\(lead): \(names(tracks)). \(remedy)"
    }
}
}
