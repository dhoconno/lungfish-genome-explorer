// ConformanceFixtures.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Shared helpers for the tool-version and pipeline conformance suites: fixture
// path resolution, scratch directories, the bundled dependency manifest, the
// version probe lookup, and the installed Kraken2 viral DB.

import Foundation
import CryptoKit
import LungfishIO
@testable import LungfishWorkflow

enum ConformanceFixtures {
    /// Root of the shared fixtures tree (`Tests/Fixtures`), resolved relative to
    /// this source file so it works regardless of the current working directory.
    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Conformance/
            .deletingLastPathComponent()   // LungfishWorkflowTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/Fixtures")
    }

    /// The shared SARS-CoV-2 fixture directory (`Tests/Fixtures/sarscov2`).
    static var sarscov2: URL {
        fixturesRoot.appendingPathComponent("sarscov2")
    }

    /// Resolves a path under `Tests/Fixtures/` for the given relative path.
    static func fixture(_ relative: String) -> URL {
        fixturesRoot.appendingPathComponent(relative)
    }

    /// Creates a unique scratch directory under the system temp directory. The
    /// caller is responsible for removing it (e.g. in `tearDown`).
    static func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-conformance-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The bundled dependency manifest (`third-party-tools-lock.json`).
    static func manifest() throws -> ManagedToolLock {
        try ManagedToolLock.loadFromBundle()
    }

    /// The installed Kraken2 "Viral" database directory, if ready.
    ///
    /// Returns `nil` when the database is not registered, not `.ready`, or its
    /// directory is missing `hash.k2d` -- callers route that through
    /// `ToolAvailability.requireDatabase` to skip or fail depending on
    /// `LUNGFISH_REQUIRE_TOOLS`.
    static func viralKrakenDB() async throws -> URL? {
        try await installedDatabase(name: "Viral", registry: .shared)
    }

    /// Generic registry seam: conformance must validate identity at the point of use.
    static func installedDatabase(name: String, registry: MetagenomicsDatabaseRegistry) async throws -> URL? {
        try await registry.loadIfNeeded()
        guard let db = try await registry.database(named: name),
              db.status == .ready,
              let path = db.path else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent("hash.k2d").path) else {
            return nil
        }
        let identity = try MetagenomicsDatabaseConformanceIdentity.verify(db)
        // The release gate retains and hashes stdout with the selected test result.
        print("LUNGFISH_DATABASE_CONFORMANCE_IDENTITY " + (try identity.evidenceJSON()))
        return path
    }

    /// Generic seam for installed standalone database files used by conformance.
    static func installedManagedDatabaseFile(id: String, path: URL) throws -> URL {
        let resolved = path.standardizedFileURL
        let receiptURL = resolved.deletingLastPathComponent().appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let receiptBytes = try Data(contentsOf: receiptURL)
        let receipt = try ProvenanceEnvelopeReader.decodeCanonical(receiptBytes)
        let output = try ProvenanceFileDescriptor.file(url: resolved, role: .index)
        guard receipt.exitStatus == 0,
              receipt.options.explicit["databaseID"]?.stringValue == id,
              receipt.outputs.contains(where: {
                  $0.path == resolved.path && $0.checksumSHA256 == output.checksumSHA256 && $0.fileSize == output.fileSize
              }) else { throw MetagenomicsDatabaseIdentityError.changed(id) }
        let identity: [String: Any] = [
            "schemaVersion": 1, "databaseID": id, "path": resolved.path,
            "payloadSHA256": output.checksumSHA256 ?? "", "payloadSizeBytes": output.fileSize ?? 0,
            "canonicalReceiptSHA256": SHA256.hash(data: receiptBytes).map { String(format: "%02x", $0) }.joined(),
            "sourcePolicy": ManagedToolLock.bundled.database(id: id)?.effectiveSourcePolicy.rawValue ?? "userProvided",
        ]
        let json = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        print("LUNGFISH_DATABASE_CONFORMANCE_IDENTITY " + String(decoding: json, as: UTF8.self))
        return resolved
    }

    /// Whether `text` reports the exact pinned `version` as a standalone
    /// version token, not merely as a substring.
    ///
    /// Plain `contains` gives false positives on short pins: `"2.3"` matches
    /// inside `"2.30"` or `"2.3.0-rc1"`, and `"1.0.0"` would even match inside
    /// an unrelated `"31.0.0"`. This anchors the match so `expected` must be
    /// followed (and preceded) by something that is not part of a longer
    /// version/number token -- i.e. not a digit and not `.` on either side.
    static func textReportsVersion(_ text: String, version expected: String) -> Bool {
        guard !expected.isEmpty else { return true }
        let escaped = NSRegularExpression.escapedPattern(for: expected)
        let pattern = "(?<![0-9.])\(escaped)(?![0-9.])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.contains(expected)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
