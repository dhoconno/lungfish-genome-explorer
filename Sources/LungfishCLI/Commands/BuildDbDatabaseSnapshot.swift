// BuildDbDatabaseSnapshot.swift - The earlier database a build-db rebuild puts back when it stops
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

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
        for url in [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm"),
            sidecarURL,
        ] {
            try? FileManager.default.removeItem(at: url)
        }
        for file in capturedFiles {
            try FileManager.default.copyItem(at: file.destination, to: file.source)
        }
        try discard()
    }

    func discard() throws {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }
}
