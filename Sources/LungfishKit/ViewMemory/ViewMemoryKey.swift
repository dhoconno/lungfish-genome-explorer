// ViewMemoryKey.swift - The key of one item's kept view and the record the store keeps under it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishIO

/// The key of one item's view (VS A3).
///
/// For an item in a project it is the SHA-256 of `v1|<root identity>|<path under the root>`. The root identity is
/// what ``ProjectRoot/rootIdentity(at:)`` reads, with the root's canonical absolute path in place of its
/// `device:<st_dev>` fallback, which a remount changes. So a renamed or moved project keeps its views, while a copied
/// project, a renamed bundle and a project on another volume open at their starting views. An item outside any
/// project keys on its canonical absolute path, and its record's folder identity tells a new file at that path.
/// Never the manifest identifier, which a mapping viewer bundle copies from its source, and never a project id,
/// which would be written into the project.
public struct ViewMemoryKey: Hashable, Sendable, CustomStringConvertible {
    /// The SHA-256 in lowercase hex, which names the item's file without `.json`.
    public let rawValue: String
    /// The store folder that holds the item, the SHA-256 of `v1|<root identity>`, or `loose`.
    public let folder: String

    /// The folder of the items outside any project.
    public static let looseFolder = "loose"

    public var description: String { "\(folder)/\(rawValue)" }

    /// The name of the item's file in its folder.
    var fileName: String { rawValue + ".json" }

    /// The root identity as one line: the volume UUID or, where the volume has none, the canonical root path, then
    /// the root folder's file number and creation time.
    static func rootText(identity: ProjectRoot.RootIdentity, canonicalRoot: URL) -> String {
        let volume = identity.volume.hasPrefix("device:") ? "path:" + canonicalRoot.path : "volume:" + identity.volume
        return "\(volume)|\(identity.fileNumber)|\(identity.createdAt.timeIntervalSinceReferenceDate)"
    }

    /// The store folder of a project, one a project (VS A9).
    static func projectFolder(rootText: String) -> String {
        sha256("v1|" + rootText)
    }

    /// The key of the item at `path` under a project whose root identity reads `rootText`.
    static func project(rootText: String, path: String) -> ViewMemoryKey {
        ViewMemoryKey(rawValue: sha256("v1|\(rootText)|\(path)"), folder: projectFolder(rootText: rootText))
    }

    /// The key of an item outside any project, at its canonical absolute `path`.
    static func loose(path: String) -> ViewMemoryKey {
        ViewMemoryKey(rawValue: sha256("v1|loose|\(path)"), folder: looseFolder)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One item's record, as one file of the store and as one entry in memory (VS A9).
struct ViewMemoryRecord: Codable, Sendable, Equatable {
    /// The shape of the file. A file of another format reads as no entry.
    static let currentFormat = 1

    var format: Int
    /// The ``ViewMemoryState/kind`` of the view.
    var kind: String
    /// The ``ViewMemoryState/schemaVersion`` of the view.
    var schemaVersion: Int
    /// The adopter's data key when the view was kept (VS B1). Nil was never read and never compares equal.
    var dataKey: String?
    /// The item's folder identity when the view was kept.
    var folder: ViewMemoryFolderIdentity?
    /// When the view was last restored, or kept when it never was.
    var lastRestored: Date
    /// The view as the adopter's state encodes it. Nil in a retire mark and in memory until the writer encodes it.
    var state: Data?
    /// Whether this record is a retire mark, which holds no view field. Reset View and an item's first entry leave
    /// one, so an older bundle's own view file is never read again for the item (Revisits, 2.6 S11).
    var retired: Bool
    /// Whether the selection passed its cap and was dropped, so the next restore says so (word 4).
    var selectionDropped: Bool

    init(kind: String, schemaVersion: Int, dataKey: String?, folder: ViewMemoryFolderIdentity?, lastRestored: Date,
         state: Data? = nil, retired: Bool = false, selectionDropped: Bool = false) {
        self.format = Self.currentFormat
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.dataKey = dataKey
        self.folder = folder
        self.lastRestored = lastRestored
        self.state = state
        self.retired = retired
        self.selectionDropped = selectionDropped
    }

    /// A retire mark for an item whose record was `record`: no view field, the same kind and folder.
    static func retireMark(after record: ViewMemoryRecord?, kind: String, folder: ViewMemoryFolderIdentity?,
                           at now: Date) -> ViewMemoryRecord {
        ViewMemoryRecord(kind: record?.kind ?? kind, schemaVersion: 0, dataKey: nil, folder: record?.folder ?? folder,
                         lastRestored: now, retired: true)
    }
}
