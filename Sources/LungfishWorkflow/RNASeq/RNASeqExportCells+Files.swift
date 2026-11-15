// RNASeqExportCells+Files.swift - Copies a single-cell result's matrix files into the staged export (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each file is copied in 1 MiB chunks and hashed as it is read, so a 3 GB matrix never sits in memory. A file whose sha256 differs
// from the manifest row is refused by name, as the reader refuses a replaced file, and the stage is removed by the caller.

import CryptoKit
import Foundation
import LungfishIO

extension RNASeqExportCells {
    /// Copies each file into `staged/<folder>/<name>` and checks its hash against the manifest row.
    static func copy(_ files: [MatrixFile], into staged: URL) throws {
        for file in files {
            try Task.checkCancellation()
            let folder = staged.appendingPathComponent(file.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (sha256, _) = try copyHashing(file.source, to: folder.appendingPathComponent(file.name))
            guard sha256 == file.sha256 else {
                throw RNASeqExportRefusal(
                    "The matrix file \(file.sourcePath) changed after LGE read the result, so it no longer matches the sha256 the result lists. "
                        + "Restore the file from a copy, or import the sample again.")
            }
        }
    }

    /// Copies `source` to `destination` in 1 MiB chunks, each read in its own autorelease pool, and returns the sha256 and size.
    static func copyHashing(_ source: URL, to destination: URL) throws -> (sha256: String, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw RNASeqExportRefusal("The file \(destination.lastPathComponent) could not be created in the export. Check the space and the permissions of the --output folder.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            try Task.checkCancellation()
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            size += Int64(chunk.count)
            return true
        }) {}
        try output.synchronize()
        return (RNASeqResultBundle.hex(hasher.finalize()), size)
    }
}
