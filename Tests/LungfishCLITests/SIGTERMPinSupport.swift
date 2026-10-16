// SIGTERMPinSupport.swift - Small helpers for the SIGTERM tests of the five GUI runners' commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S61 (K7). `primer-trim`, `tree infer iqtree`, `align mafft` and the commands beside
// them run in the app through runners that passed no grace, so a cancel killed them at once. These
// tests start the built CLI against a stand-in tool that writes its process ID and waits, send one
// SIGTERM to the CLI alone through `CLISIGTERMHarness`, and read how the command ended.

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

enum SIGTERMPinSupport {
    /// Writes `script` as an executable file at `url`, making its folder first.
    static func writeExecutable(_ script: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Every path under `folder`, relative to it and sorted. A missing folder reads as empty.
    static func relativePaths(under folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        return enumerator.compactMap { $0 as? String }.sorted()
    }

    /// The paths under `folder` whose last component starts with `prefix`, such as the scratch folder a
    /// run makes and a kill leaves.
    static func paths(under folder: URL, startingWith prefix: String) -> [String] {
        relativePaths(under: folder).filter { ($0 as NSString).lastPathComponent.hasPrefix(prefix) }
    }

    /// Every file under `folder` whose name says it records a cancel, such as
    /// `provenance/cancelled/<run>.lungfish-provenance.json` or `<output>.cancelled.lungfish-provenance.json`.
    static func cancelledRecords(under folder: URL) -> [String] {
        relativePaths(under: folder).filter { $0.contains("cancelled") && $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }
    }

    /// The status of the one record at `url`, or nil when there is none.
    static func recordStatus(at url: URL) throws -> String? {
        try ProvenanceEnvelopeReader.load(fromSidecar: url)?.status.rawValue
    }

    /// The status of the one record under `bundle/provenance/cancelled`, or nil when there is none.
    static func cancelledRecordStatus(inBundle bundle: URL) throws -> String? {
        let folder = bundle.appendingPathComponent("provenance/cancelled", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let records = names.filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }
        guard records.count == 1, let name = records.first else { return nil }
        return try recordStatus(at: folder.appendingPathComponent(name))
    }
}
