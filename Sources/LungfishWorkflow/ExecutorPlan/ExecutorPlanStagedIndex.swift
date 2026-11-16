// ExecutorPlanStagedIndex.swift - The pin of a STAR index an earlier run left in the staging folder (Phase 5.3 lane EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// A STAR index that an earlier run left in the group's staging folder, pinned from the record `rnaseq index-adopt` wrote
/// (`docs/formats/executor-plan.md`, Reference entries): one `reference` entry a file, by the SHA-256 and bytes the run
/// record stated, and each file's absolute path in the staging folder. The paths are submit values and never plan bytes.
/// The batch reads each file where it sits, as it reads a staged read (``ExecutorPlanBatchJob/stagedReferencePaths``).
package struct ExecutorPlanStagedIndex: Sendable, Equatable {
    package var record: STARIndexRecord
    /// One `reference` entry with `index` `{key, tool}` for each file of the index, in `relativePath` order.
    package var entries: [PlanEntry]
    /// Each entry's `relativePath` to the file's absolute path in the staging folder.
    package var stagingPaths: [String: String]

    /// The index of `setID` and `key` whose record `store` holds. A plan never builds an index, so a set and key with no
    /// record is refused in words that name `rnaseq index-plan` and `rnaseq index-adopt`.
    package static func pin(
        setID: String, key: String, store: STARIndexRecordStore, star: PlanToolPin, layout: ExecutorPlanStagingLayout
    ) throws -> ExecutorPlanStagedIndex {
        guard let record = try store.find(setID: setID, key: key) else {
            throw STARIndexError("The set \(setID) has no adopted STAR index \(key) on this Mac, and a plan never builds one. "
                + "Build it on Linux with lungfish-cli rnaseq index-plan --set \(setID) --star \(star.version), run that plan, "
                + "record the index it left with lungfish-cli rnaseq index-adopt, then write this plan again.")
        }
        guard record.setID == setID, record.key.folderName == key else {
            throw STARIndexError("The index record \(try store.url(setID: setID, key: key).path) names the index "
                + "\(record.key.folderName) of the set \(record.setID), not \(key) of the set \(setID), so adopt that index again.")
        }
        return try pin(record, star: star, layout: layout)
    }

    /// The entries and staging paths of `record`, mapped by `star`. A mapping STAR of another version than the one that
    /// built the index is refused, as is a file that is not below the batch's staging folder or lies in the batch's own
    /// folder, where its jobs write (``ExecutorPlanBatchWriter/checkStagedReference(_:of:layout:)``).
    package static func pin(
        _ record: STARIndexRecord, star: PlanToolPin, layout: ExecutorPlanStagingLayout
    ) throws -> ExecutorPlanStagedIndex {
        let key = record.key.folderName
        guard star.id == record.tool.id, star.version == record.tool.version else {
            throw STARIndexError("The plan maps with STAR \(star.version), and the index \(key) of the set \(record.setID) was "
                + "built by STAR \(record.tool.version). STAR maps only on an index of its own version, so pin an index built "
                + "with lungfish-cli rnaseq index-plan --star \(star.version), or map with STAR \(record.tool.version).")
        }
        let identity = PlanReferenceIndex(key: key, tool: record.tool)
        var entries: [PlanEntry] = []
        var paths: [String: String] = [:]
        for file in record.files {
            let reference = PlanReferenceIdentity(setID: record.setID, path: file.path, index: identity)
            guard let size = Int64(exactly: file.bytes) else {
                throw STARIndexError("The index record names \(file.bytes) bytes for \(file.path), more than a file holds.")
            }
            try ExecutorPlanBatchWriter.checkStagedReference(file.stagingPath, of: reference.relativePath, layout: layout)
            entries.append(PlanEntry(role: .reference, relativePath: reference.relativePath, sha256: file.sha256, size: size,
                                     reference: reference))
            paths[reference.relativePath] = file.stagingPath
        }
        return ExecutorPlanStagedIndex(
            record: record, entries: entries.sorted { $0.relativePath < $1.relativePath }, stagingPaths: paths)
    }

    /// The words the README and the dry run show for each index that a batch reads where an earlier run left it: the
    /// index's key, each file's name, the folder the jobs read it from and the same folder below a local run's data folder.
    package static func placements(
        of plan: ExecutionPlan, stagedReferencePaths: [String: String], layout: ExecutorPlanStagingLayout
    ) -> [String] {
        var groups: [(key: String, folder: String, names: [String])] = []
        for entry in plan.entries where entry.role == .reference {
            guard let path = stagedReferencePaths[entry.relativePath], let key = entry.reference?.index?.key else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            if let at = groups.firstIndex(where: { $0.key == key && $0.folder == folder }) {
                groups[at].names.append(name)
            } else {
                groups.append((key, folder, [name]))
            }
        }
        return groups.map { group in
            let one = group.names.count == 1
            let (files, them) = one ? ("the file", "it") : ("the \(group.names.count) files", "them")
            let names = one ? group.names.joined()
                : group.names.dropLast().joined(separator: ", ") + " and " + (group.names.last ?? "")
            return "The jobs read \(files) of the index \(group.key) (\(names)) where the run that built it left \(them), in "
                + "\(group.folder)/, and nothing copies \(them). A run of \(LinuxRunScript.fileName) reads \(them) from "
                + "\(layout.pathBelowFolder(group.folder))/ below its data folder."
        }
    }
}
