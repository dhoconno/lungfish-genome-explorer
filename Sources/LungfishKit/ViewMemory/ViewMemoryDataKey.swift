// ViewMemoryDataKey.swift - The data key that a remembered view is compared against before it restores
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore

// MARK: - File facts

/// One file of a result folder, by relative path and size.
public struct ViewMemoryFileEntry: Sendable, Equatable {
    public var path: String
    public var size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }

    /// The regular files under `folder` with their sizes, sorted by relative path, or nil when
    /// the folder cannot be read. Hidden files are skipped. No file is opened or hashed.
    public static func entries(inFolder folder: URL) -> [ViewMemoryFileEntry]? {
        let base = folder.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var entries: [ViewMemoryFileEntry] = []
        while let next = enumerator.nextObject() as? URL {
            guard let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else {
                continue
            }
            let full = next.standardizedFileURL.path
            let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : next.lastPathComponent
            entries.append(ViewMemoryFileEntry(path: relative, size: Int64(size)))
        }
        return entries.sorted { $0.path < $1.path }
    }
}

/// The size and modification time of one file, read from its directory entry and never from
/// its content.
public struct ViewMemoryFileFacts: Sendable, Equatable {
    public let size: Int64
    public let modifiedMilliseconds: Int64

    public init(size: Int64, modifiedMilliseconds: Int64) {
        self.size = size
        self.modifiedMilliseconds = modifiedMilliseconds
    }

    /// The facts of the file at `url`, following a symbolic link, or nil when it cannot be read.
    public static func read(at url: URL) -> ViewMemoryFileFacts? {
        let path = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = integer(from: attributes[.size]),
              let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return ViewMemoryFileFacts(
            size: size,
            modifiedMilliseconds: Int64((modified.timeIntervalSince1970 * 1_000).rounded())
        )
    }

    private static func integer(from value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let size as UInt64:
            return Int64(clamping: size)
        case let size as Int:
            return Int64(size)
        default:
            return nil
        }
    }
}

// MARK: - Data key

/// What a bundle held when a view was remembered, compared before any field of that view
/// restores (VS B1).
///
/// A key is read from a manifest, a provenance record or a file list with sizes. No builder
/// hashes a file, so each builder is cheap enough to run off the main actor in the open that
/// already reads the manifest, and none of them is main-actor isolated.
///
/// A part that was not read yet holds a nil value. A key with such a part never compares equal
/// to any key, itself included, as a NaN does not. A caller that must not restore a coordinate
/// selection on a key it could not complete therefore drops it without a special case.
public struct ViewMemoryDataKey: Codable, Sendable, Equatable {
    /// One named piece of the key. A nil value means the piece was not read yet.
    public struct Part: Codable, Sendable, Equatable {
        public let name: String
        public let value: String?

        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// The family of builder that made the key, such as `reference`, `mapping` or `analysis`.
    public let family: String
    public let parts: [Part]

    public init(family: String, parts: [Part]) {
        self.family = family
        self.parts = parts
    }

    /// True when the key has a part and every part was read.
    public var isComplete: Bool {
        !parts.isEmpty && parts.allSatisfy { $0.value != nil }
    }

    /// True only when both keys are complete, of one family, and equal part for part.
    public func matches(_ other: ViewMemoryDataKey) -> Bool {
        guard isComplete, other.isComplete else { return false }
        return family == other.family && parts == other.parts
    }

    /// Equality is `matches`, so a key with a part not read yet is never equal to anything.
    public static func == (lhs: ViewMemoryDataKey, rhs: ViewMemoryDataKey) -> Bool {
        lhs.matches(rhs)
    }

    /// A key whose parts were not read yet, for a view that is open before its load ends.
    public static func unread(family: String, partNames: [String]) -> ViewMemoryDataKey {
        ViewMemoryDataKey(family: family, parts: partNames.map { Part(name: $0, value: nil) })
    }
}

// MARK: - Builders

extension ViewMemoryDataKey {
    /// The key of a reference bundle.
    ///
    /// It holds the identifier, the FASTA MD5 when the manifest records it, the list of sequence
    /// names and lengths, and each annotation and variant track with the size and modification
    /// time of its database file. A database that cannot be read leaves its part unread.
    public static func reference(manifest: BundleManifest, bundleURL: URL) -> ViewMemoryDataKey {
        ViewMemoryDataKey(family: "reference", parts: referenceParts(manifest: manifest, bundleURL: bundleURL))
    }

    /// The key of a mapping bundle, which is the reference key plus the alignment tracks.
    ///
    /// Each alignment track adds its `id`, `sourcePath` and `mappedReadCount` from the manifest
    /// with the size and modification time of its file. The evidence snapshot is never used,
    /// since it exists only after a contig pick and hashes each file in full. A file that
    /// cannot be read leaves the alignment part unread.
    public static func mapping(manifest: BundleManifest, bundleURL: URL) -> ViewMemoryDataKey {
        var parts = referenceParts(manifest: manifest, bundleURL: bundleURL)
        parts.append(Part(name: "alignments", value: alignmentsValue(manifest.alignments, bundleURL: bundleURL)))
        return ViewMemoryDataKey(family: "mapping", parts: parts)
    }

    /// The key of a result under `Analyses/`.
    ///
    /// The provenance record's envelope id wins, since a rerun writes a new record. Without one
    /// the manifest's modification date is used, and without that the file list with sizes.
    public static func analysis(
        provenanceEnvelopeID: UUID?,
        manifestModifiedDate: Date?,
        files: [ViewMemoryFileEntry]
    ) -> ViewMemoryDataKey {
        if let provenanceEnvelopeID {
            return ViewMemoryDataKey(
                family: "analysis",
                parts: [Part(name: "provenance-envelope", value: provenanceEnvelopeID.uuidString.lowercased())]
            )
        }
        if let manifestModifiedDate {
            return ViewMemoryDataKey(
                family: "analysis",
                parts: [Part(name: "manifest-date", value: String(milliseconds(of: manifestModifiedDate)))]
            )
        }
        return ViewMemoryDataKey(family: "analysis", parts: [Part(name: "files", value: filesValue(files))])
    }

    /// The key of any other bundle, from its manifest identifier with the record id or the
    /// payload checksums that the manifest lists.
    public static func payload(
        manifestIdentifier: String,
        recordID: String?,
        payloadChecksums: [String: String]
    ) -> ViewMemoryDataKey {
        let checksums = digest(payloadChecksums.keys.sorted().map { "\($0)=\(payloadChecksums[$0] ?? "")" })
        return ViewMemoryDataKey(
            family: "payload",
            parts: [
                Part(name: "identifier", value: manifestIdentifier),
                Part(name: "record", value: recordID ?? "none"),
                Part(name: "checksums", value: checksums),
            ]
        )
    }

    /// The key of a file list with sizes, the last resort for a result with no record.
    public static func fileList(_ files: [ViewMemoryFileEntry]) -> ViewMemoryDataKey {
        ViewMemoryDataKey(family: "files", parts: [Part(name: "files", value: filesValue(files))])
    }

    /// The key of the files under `folder`, read from the directory and never from file content.
    /// A folder that cannot be read gives a key with an unread part.
    public static func fileList(inFolder folder: URL) -> ViewMemoryDataKey {
        guard let entries = ViewMemoryFileEntry.entries(inFolder: folder) else {
            return unread(family: "files", partNames: ["files"])
        }
        return fileList(entries)
    }

    // MARK: Parts

    private struct DatabaseReference {
        let id: String
        let path: String?
    }

    private static func referenceParts(manifest: BundleManifest, bundleURL: URL) -> [Part] {
        let sequences: String
        if let genome = manifest.genome {
            sequences = digest(genome.chromosomes.map { "\($0.name):\($0.length)" })
        } else {
            sequences = "none"
        }
        let annotations = manifest.annotations.map { DatabaseReference(id: $0.id, path: $0.databasePath) }
        let variants = manifest.variants.map { DatabaseReference(id: $0.id, path: $0.databasePath) }
        return [
            Part(name: "identifier", value: manifest.identifier),
            Part(name: "fasta-md5", value: manifest.genome?.md5Checksum ?? "none"),
            Part(name: "sequences", value: sequences),
            Part(name: "annotations", value: databasesValue(annotations, bundleURL: bundleURL)),
            Part(name: "variants", value: databasesValue(variants, bundleURL: bundleURL)),
        ]
    }

    private static func databasesValue(_ references: [DatabaseReference], bundleURL: URL) -> String? {
        var lines: [String] = []
        for reference in references {
            guard let path = reference.path else {
                lines.append("\(reference.id)|no-database")
                continue
            }
            guard let facts = ViewMemoryFileFacts.read(at: resolve(path, in: bundleURL)) else {
                return nil
            }
            lines.append("\(reference.id)|\(facts.size)|\(facts.modifiedMilliseconds)")
        }
        return digest(lines)
    }

    private static func alignmentsValue(_ tracks: [AlignmentTrackInfo], bundleURL: URL) -> String? {
        var lines: [String] = []
        for track in tracks {
            guard let facts = ViewMemoryFileFacts.read(at: resolve(track.sourcePath, in: bundleURL)) else {
                return nil
            }
            let reads = track.mappedReadCount.map { String($0) } ?? "none"
            lines.append("\(track.id)|\(track.sourcePath)|\(reads)|\(facts.size)|\(facts.modifiedMilliseconds)")
        }
        return digest(lines)
    }

    private static func filesValue(_ files: [ViewMemoryFileEntry]) -> String {
        digest(files.sorted { $0.path < $1.path }.map { "\($0.path)|\($0.size)" })
    }

    private static func resolve(_ path: String, in bundleURL: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : bundleURL.appendingPathComponent(path)
    }

    private static func milliseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// A SHA-256 digest of text lines held in memory. It is the only hash here, and it never
    /// reads a file.
    private static func digest(_ lines: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(lines.count)\n".utf8))
        for line in lines {
            hasher.update(data: Data(line.utf8))
            hasher.update(data: Data("\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
