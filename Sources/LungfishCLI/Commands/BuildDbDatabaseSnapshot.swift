// BuildDbDatabaseSnapshot.swift - The earlier database a build-db rebuild puts back when it stops
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The database of an earlier `build-db` run with its journal, its shared-memory file and its record,
/// copied aside before a rebuild so that a rebuild which fails or is cancelled can put them back.
///
/// ``restore()`` never empties a name it has something to put under. It opens every captured copy first,
/// so a snapshot it cannot read ends it before any name changes. It then visits the journal, the
/// shared-memory file, the database and the record in that order, inside one ``DurableReplace``
/// transaction. A captured file goes back as one publication, staged beside its name and swapped in, so the
/// name holds a complete file at every step, on every volume a project can live on. A file the snapshot did
/// not hold is removed. The journal and the shared-memory file come before the database because a journal
/// that stays beside an older database is replayed into it. The copies are discarded only after every
/// name is done, so a restore that stops leaves them for a second attempt (lane S33, 2.8 row 266).
struct BuildDbDatabaseSnapshot {
    private let dbURL: URL
    private let sidecarURL: URL
    private let snapshotDirectory: URL
    private let capturedFiles: [(source: URL, destination: URL)]

    static func capture(dbURL: URL) throws -> BuildDbDatabaseSnapshot {
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-build-db-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: dbURL)
        let urls = [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm"),
            sidecarURL,
        ]
        var capturedFiles: [(source: URL, destination: URL)] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let destination = snapshotDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: destination)
            capturedFiles.append((source: url, destination: destination))
        }

        return BuildDbDatabaseSnapshot(
            dbURL: dbURL,
            sidecarURL: sidecarURL,
            snapshotDirectory: snapshotDirectory,
            capturedFiles: capturedFiles
        )
    }

    func restore() throws {
        for file in capturedFiles {
            try Self.confirmReadable(file.destination)
        }
        try DurableReplace.transaction {
            for url in [
                URL(fileURLWithPath: dbURL.path + "-wal"),
                URL(fileURLWithPath: dbURL.path + "-shm"),
                dbURL,
                sidecarURL,
            ] {
                if let captured = capturedFiles.first(where: { $0.source == url }) {
                    try Self.publish(captured.destination, as: url)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        try discard()
    }

    func discard() throws {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }

    /// Opens the captured copy at `url`, or throws why it cannot be read.
    private static func confirmReadable(_ url: URL) throws {
        try FileHandle(forReadingFrom: url).close()
    }

    /// Publishes the bytes of the captured copy `captured` as `url`, swapping out any regular file the name
    /// holds. A failure leaves the name with the file it held and no stage file in its folder.
    private static func publish(_ captured: URL, as url: URL) throws {
        try DurableReplace.replace(
            named: url.lastPathComponent,
            in: url.deletingLastPathComponent(),
            recovery: .none
        ) { stage in
            let input = try FileHandle(forReadingFrom: captured)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                try stage.write(chunk)
            }
        }
    }

    /// The bytes read from a captured copy at a time.
    private static let chunkSize = 1 << 20
}
