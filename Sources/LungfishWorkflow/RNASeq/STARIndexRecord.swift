// STARIndexRecord.swift - The record of a STAR index built on Linux, adopted from the run record (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// What a later plan builds its `reference` entries with `index` `{key, tool}` from (`docs/formats/executor-plan.md`,
/// Reference entries): the set id, the key, the tool and each staged file's plan path, staging path, bytes and SHA-256.
/// The tool, the key's STAR values and each file's bytes and SHA-256 come from the run record and never from the plan. The
/// staging paths come from the adopt's options, and the set id, the FASTA paths and the two set digests from the set folder.
package struct STARIndexRecord: Codable, Sendable, Equatable {
    package static let fileName = "index-record.json"

    package struct File: Codable, Sendable, Equatable {
        /// The path inside the index's folder, which the later plan's `reference.path` carries.
        package var path: String
        package var planPath: String
        /// `<staging folder>/batches/<batch>/<sample>/staged/<plan path>`, where the job left the file.
        package var stagingPath: String
        package var bytes: UInt64
        package var sha256: String
    }

    package var schemaVersion = 1
    package var setID: String
    package var key: STARIndexKey
    package var tool: PlanToolPin
    package var files: [File]
}

package enum STARIndexAdopt {
    /// The keys of the run record that the adopt reads, which it reads after the schema version and no other.
    private struct Run: Decodable {
        struct Reference: Decodable { var setID: String }
        struct Input: Decodable { var relativePath: String; var sha256: String; var reference: Reference? }
        struct Tool: Decodable { var id: String; var version: String; var build: String }
        struct Output: Decodable { var path: String; var bytes: UInt64; var sha256: String; var policy: PlanOutputPolicy? }
        struct Step: Decodable { var id: String; var tool: Tool?; var outcome: String; var argv: [String]; var outputs: [Output] }
        var schemaVersion: Int
        var outcome: String
        var reason: String?
        var failedStepID: String?
        var inputs: [Input]
        var steps: [Step]
    }

    /// The index record of a run that succeeded, or a refusal in words: a record that is not `succeeded`, one that names
    /// another set, one with no STAR step and one that lacks a staged file of the index.
    package static func adopt(
        runRecord data: Data, setFolder: URL, staging: ExecutorPlanStagingLayout, sample: String = STARIndexPlan.sampleName
    ) throws -> STARIndexRecord {
        let run: Run
        do { run = try JSONDecoder().decode(Run.self, from: data) } catch {
            throw STARIndexError("The run record cannot be read as an executor run record (\(error.localizedDescription)).")
        }
        guard run.schemaVersion == ExecutorRunRecord.currentSchemaVersion else {
            throw STARIndexError("The run record has schema version \(run.schemaVersion), and this build reads \(ExecutorRunRecord.currentSchemaVersion).")
        }
        guard run.outcome == "succeeded" else {
            throw STARIndexError("The run record reads \(run.outcome)" + (run.failedStepID.map { " at the step \($0)" } ?? "")
                + (run.reason.map { " (\($0))" } ?? "") + ", so no index was built.")
        }
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let gtf = try manifest.requireCountingGTF()
        let named = Set(run.inputs.compactMap { $0.reference?.setID })
        guard named == [manifest.id] else {
            throw STARIndexError("The run read \(named.isEmpty ? "no reference set" : "the set " + named.sorted().joined(separator: " and ")), "
                + "not the set \(manifest.id), so it built no index of that set.")
        }
        guard run.inputs.contains(where: { $0.relativePath == "references/\(manifest.id)/\(gtf.path)" && $0.sha256 == gtf.sha256 }) else {
            throw STARIndexError("The run did not read the set \(manifest.id)'s \(gtf.path) by its SHA-256, so its index is not that set's.")
        }
        guard let step = run.steps.first(where: { $0.tool?.id == "STAR" }), step.outcome == "succeeded", let tool = step.tool else {
            throw STARIndexError("The run record holds no STAR step that succeeded, so no index was built.")
        }
        guard STARIndexVersion(rawValue: tool.version) != nil else {
            throw STARIndexError("The run record names STAR \(tool.version), and this build records "
                + "\(STARIndexVersion.allCases.map(\.rawValue).joined(separator: " and ")) only, so no record was written.")
        }
        func value(of flag: String) -> Int? {
            guard let at = step.argv.firstIndex(of: flag), step.argv.indices.contains(at + 1) else { return nil }
            return Int(step.argv[at + 1])
        }
        let flags = ["--genomeSAindexNbases", "--genomeSAsparseD", "--sjdbOverhang"]
        let values = flags.compactMap { value(of: $0) }
        guard values.count == flags.count else {
            let missing = flags.filter { value(of: $0) == nil }.joined(separator: " or ")
            throw STARIndexError("The STAR step's recorded argv names no \(missing), so the index has no key and no record was written.")
        }
        let (nbases, sparse, overhang) = (values[0], values[1], values[2])
        let outputs = Dictionary(run.steps.flatMap(\.outputs).filter { $0.policy == .staged }.map { ($0.path, $0) }) { first, _ in first }
        let files = try STARIndexPlan.indexFiles.sorted().map { name -> STARIndexRecord.File in
            let planPath = "\(STARIndexPlan.genomeDirectory)/\(name)"
            guard let output = outputs[planPath] else {
                throw STARIndexError("The run record names no staged output \(planPath), so the index is not whole and no record was written.")
            }
            return STARIndexRecord.File(
                path: name, planPath: planPath, stagingPath: staging.samplePath(sample, "staged/\(planPath)"),
                bytes: output.bytes, sha256: output.sha256)
        }
        let pin = PlanToolPin(id: tool.id, version: tool.version, build: tool.build)
        let key = STARIndexKey(
            folderName: STARIndexKey.folderName(star: tool.version, nbases: nbases, sparseD: sparse), setID: manifest.id,
            referenceSetSHA256: try ProvenanceFileHasher.sha256(of: setFolder.appendingPathComponent(ReferenceSetManifest.filename)),
            star: pin, genomeSAindexNbases: nbases, genomeSAsparseD: sparse, sjdbOverhang: overhang,
            genomeFastaFiles: [manifest.genome.path] + manifest.extras.map(\.path), countingGTFSHA256: gtf.sha256)
        return STARIndexRecord(setID: manifest.id, key: key, tool: pin, files: files)
    }
}
