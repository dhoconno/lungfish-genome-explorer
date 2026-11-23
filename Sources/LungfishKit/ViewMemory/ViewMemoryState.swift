// ViewMemoryState.swift - The view a viewport keeps for one item, and where that item lives
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The view one viewport keeps for one item, such as its filter, its sort and its selection.
///
/// Each adopter declares one struct beside its viewport that copies only the view fields of its injected model. It
/// holds a selection by a stable row id and never by an index. ``kind`` and ``schemaVersion`` name the shape the
/// store wrote, so a record of another kind or another schema reads as no entry and shows no line.
public protocol ViewMemoryState: Codable, Sendable, Equatable {
    /// The kind of view the state belongs to, as ``SurfaceKind/description`` spells it.
    static var kind: String { get }
    /// The shape of the struct. A record of another schema reads as no entry.
    static var schemaVersion: Int { get }
    /// How many identities the selection holds, for the cap of 1,000 (VS A9).
    var selectionCount: Int { get }
    /// The same view with no selection, for a selection past the cap, which is dropped whole and never cut short.
    func withoutSelection() -> Self
}

extension ViewMemoryState {
    /// A view with no selection of its own holds none.
    public var selectionCount: Int { 0 }

    /// A view with no selection of its own is the same without one.
    public func withoutSelection() -> Self { self }
}

/// What a restore could not bring back, for the reset line's words (VS U2, word 2). A clamp alone loses nothing.
public struct ViewMemoryLoss: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The locus, the zoom or the scroll.
    public static let place = ViewMemoryLoss(rawValue: 1 << 0)
    /// The selected rows, cells or region.
    public static let selection = ViewMemoryLoss(rawValue: 1 << 1)
    /// The count filters and search texts.
    public static let filters = ViewMemoryLoss(rawValue: 1 << 2)
    /// The samples a person picked.
    public static let sampleChoice = ViewMemoryLoss(rawValue: 1 << 3)
}

/// The file number and creation date of an item's own folder or file, so a new folder at the same path is told from
/// the one a record was kept for (VS A3).
public struct ViewMemoryFolderIdentity: Codable, Sendable, Hashable {
    public let fileNumber: UInt64
    public let createdAt: Date

    public init(fileNumber: UInt64, createdAt: Date) {
        self.fileNumber = fileNumber
        self.createdAt = createdAt
    }

    /// The identity of the item at `url`, or nil when it cannot be read. It reads the disk, so it runs off the main
    /// actor, in an adopter's load and never at a capture or a restore.
    public static func read(at url: URL) -> ViewMemoryFolderIdentity? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let file = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        return ViewMemoryFolderIdentity(fileNumber: file.uint64Value, createdAt: created)
    }
}

/// Where one item lives, read once off the main actor in an adopter's load, so a capture and a restore read only
/// memory (SWIFT 2).
public struct ViewMemoryItem: Sendable, Hashable {
    /// The item as the route named it.
    public let url: URL
    /// The canonical root of the project that holds the item, nil for an item outside any project.
    public let projectRoot: URL?
    /// The item's path under ``projectRoot``, standardized and in NFC, or its own canonical absolute path when it is
    /// outside any project.
    public let path: String
    /// The item's folder identity, nil when it could not be read.
    public let folder: ViewMemoryFolderIdentity?

    public init(url: URL, projectRoot: URL?, path: String, folder: ViewMemoryFolderIdentity?) {
        self.url = url
        self.projectRoot = projectRoot
        self.path = path
        self.folder = folder
    }

    /// Reads where the item at `url` lives. The root is the nearest project folder that
    /// ``ProjectTempDirectory/findProjectRoot(_:)`` finds, and the relative path is computed against the same
    /// canonical root that ``ProjectRoot/rootIdentity(at:)`` builds, so `/private/var` and `/var` give one path. It
    /// reads the disk, so it runs off the main actor.
    public static func read(at url: URL) -> ViewMemoryItem {
        let item = canonical(url)
        let folder = ViewMemoryFolderIdentity.read(at: url)
        if let root = ProjectTempDirectory.findProjectRoot(url) {
            let canonicalRoot = canonical(root)
            let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
            if item.path.hasPrefix(prefix) {
                let relative = String(item.path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
                return ViewMemoryItem(url: url, projectRoot: canonicalRoot, path: relative, folder: folder)
            }
        }
        return ViewMemoryItem(url: url, projectRoot: nil, path: item.path.precomposedStringWithCanonicalMapping,
                              folder: folder)
    }

    /// The URL as ``ProjectRoot/rootIdentity(at:)`` canonicalizes it.
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
