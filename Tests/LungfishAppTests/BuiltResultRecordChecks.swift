// BuiltResultRecordChecks.swift - What the records of a built result folder must hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lanes FXA2 and R-REBIND. SidebarCopyOfBuiltClassifierResultsReplayTests and
// SidebarMoveOfABuiltResultFolderReplayTests read every record under a result folder the same way and ask the same
// question of it, which files a record names that the folder does not hold as the record states. The reading and the
// question moved here from the first of them. The only change is the access level, since they are static functions of
// this enum and the tests call them through it.

import XCTest
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

enum BuiltResultRecordChecks {

    // MARK: - The records of a tree

    /// Every record in `folder` with its path below it, the folder's own records and each file's sidecar.
    static func recordsOfTheTree(at folder: URL) throws -> [(name: String, envelope: ProvenanceEnvelope)] {
        let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(ProvenanceRecorder.provenanceFilename) } ?? []
        let prefix = Self.resolved(folder.path) + "/"
        return try urls.map { url in
            let envelope = url.lastPathComponent == ProvenanceRecorder.provenanceFilename
                ? ProvenanceRecorder.loadEnvelope(from: url.deletingLastPathComponent())
                : ProvenanceRecorder.loadEnvelope(fromSidecar: url)
            return (String(Self.resolved(url.path).dropFirst(prefix.count)), try XCTUnwrap(envelope, url.path))
        }
        .sorted { $0.name < $1.name }
    }

    /// One line for each file that a record names and does not hold as the record states. The run level of a record
    /// names only what is on disk (B3). A step keeps the file as it was when the step ran, so it may name a file that
    /// is gone or holds other bytes only when a removal step of the same record names that path, and the bytes when
    /// the file is still there (P1 of Phase 2.8).
    static func problems(of records: [(name: String, envelope: ProvenanceEnvelope)]) -> [String] {
        func digest(_ path: String) -> String?? {
            FileManager.default.fileExists(atPath: path) ? .some(ProvenanceRecorder.sha256(of: URL(fileURLWithPath: path))) : .none
        }
        var lines: Set<String> = []
        for (name, record) in records {
            let removed = record.steps
                .filter { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) }
                .flatMap(\.inputs)
                .map { (path: Self.resolved($0.path), digest: $0.checksumSHA256) }
            for file in record.files + record.outputs + [record.output].compactMap({ $0 }) {
                guard let found = digest(file.path) else {
                    lines.insert("\(name) run level names \(Self.resolved(file.path)), which does not exist")
                    continue
                }
                if let stated = file.checksumSHA256, found != stated {
                    lines.insert("\(name) run level names \(Self.resolved(file.path)) with a digest the file no longer has")
                }
            }
            for step in record.steps {
                for file in step.inputs + step.outputs {
                    guard let stated = file.checksumSHA256 else { continue }
                    let found = digest(file.path)
                    if let found, found == stated { continue }
                    let path = Self.resolved(file.path)
                    let excused = removed.contains { $0.path == path && (found == nil || $0.digest == stated) }
                    if !excused {
                        lines.insert("\(name) step \(step.toolName) names \(path), \(found == nil ? "which does not exist" : "which holds other bytes")")
                    }
                }
            }
        }
        return lines.sorted()
    }

    /// The path with its deepest existing folder resolved, since a removed file cannot be, so that /var/folders and
    /// /private/var/folders are one place.
    static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
}
