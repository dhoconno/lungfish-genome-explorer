// ReferenceSetOwner+Uses.swift - A result's use of a reference set (an entry point of RS-REFSET's owner, added by lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `docs/formats/reference-set.md`, section Cleanup: a result whose record names a set gets one file in the set's `uses/`,
// `<sha256 of the result path>.json`, holding the result's path and its record's sha256. The owner creates it once and
// never rewrites it, as `SalmonIndexCache.recordUse` does for an index.

import CryptoKit
import Foundation
import LungfishCore

extension ReferenceSetOwner {
    public static let usesFolderName = "uses"

    /// Records that `resultFolder` used the set at `setURL`, as `uses/<sha256 of the result path>.json`. The file is
    /// written once and never rewritten, so a later call for the same result returns it as it is.
    @discardableResult
    public func recordUse(of setURL: URL, resultFolder: URL) throws -> URL {
        let uses = setURL.appendingPathComponent(Self.usesFolderName, isDirectory: true)
        let path = resultFolder.standardizedFileURL.path
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        let url = uses.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: uses, withIntermediateDirectories: true)
        let record = try ProvenanceFileHasher.sha256(
            of: resultFolder.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let use = SalmonIndexCache.Use(schemaVersion: 1, resultPath: path, recordSHA256: record)
        try DurableReplace.replace(try encoder.encode(use), named: name, in: uses)
        return url
    }
}
