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

    /// The run that built the index, from the run record the adopt read, so that a later STAR or STARsolo result can name the
    /// executor build and the run (`docs/formats/reference-set.md`, STAR indexes on Linux). The run record's byte copy sits
    /// beside the record as `run-record.json`, and its SHA-256 is `runRecordSHA256` (ARCH-5-1-C-3, What binds 9).
    package struct Run: Codable, Sendable, Equatable {
        /// The SHA-256 and the length of the `run-record.json` bytes the adopt read, which the copy beside the record repeats.
        package var runRecordSHA256: String
        package var runRecordBytes: UInt64
        /// The run record's `executor` as it states it, with the binary's `sha256` and `size` and the plan's `buildPin`.
        package var executor: ExecutorBinaryIdentity
        /// The adopt's `--batch` and `--sample`, which name the job's folder in the staging folder.
        package var batch: String
        package var sample: String
    }

    /// The schema a new adopt writes. Schema 1 holds no `run` and still reads.
    package static let currentSchemaVersion = 2
    /// The byte copy of the run record that sits beside the record.
    package static let runRecordFileName = ExecutorRunRecord.fileName

    package var schemaVersion = 1
    package var setID: String
    package var key: STARIndexKey
    package var tool: PlanToolPin
    package var files: [File]
    /// The run that built the index, which a record of schema 1 does not hold.
    package var run: Run?
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
        /// What the run record states of the binary that ran it, which the record keeps and which a run record must hold whole.
        var executor: ExecutorBinaryIdentity?
    }

    /// The index record of a run that succeeded, or a refusal in words: a record that is not `succeeded`, one that names
    /// another set, one with no STAR step and one that lacks a staged file of the index.
    /// With `tenxFilter` the adopt makes the variant's GTF again from the set and refuses a run that read another, so it
    /// reads nothing from the plan (ARCH-SOLO-GTF item 4).
    package static func adopt(
        runRecord data: Data, setFolder: URL, staging: ExecutorPlanStagingLayout, sample: String = STARIndexPlan.sampleName,
        tenxFilter: TenxGTFFilter.List? = nil
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
        let made = try tenxFilter.map { try TenxGTFFilter.make(from: setFolder, manifest: manifest, list: $0) }
        if let made {
            let path = "references/\(manifest.id)/\(made.list.path)"
            guard let read = run.inputs.first(where: { $0.relativePath == path }) else {
                let paths = Set(run.inputs.map(\.relativePath))
                let advice = TenxGTFFilter.List.allCases.first { paths.contains("references/\(manifest.id)/\($0.path)") }
                    .map { "It read references/\(manifest.id)/\($0.path), so adopt it with --tenx-filter \($0.rawValue)." }
                    ?? "Leave out --tenx-filter for a bulk index."
                throw STARIndexError("The run read no GTF that the 10x filter rule \(made.list.rawValue) made from the set "
                    + "\(manifest.id), so its index is not that variant and no record was written. " + advice)
            }
            guard read.sha256 == made.sha256 else {
                throw STARIndexError("The run read \(path) with SHA-256 \(read.sha256), and the 10x filter rule \(made.list.rawValue) "
                    + "makes \(made.sha256) from the set \(manifest.id)'s \(gtf.path), so its index is not that set's under that rule "
                    + "and no record was written.")
            }
        } else if !run.inputs.contains(where: { $0.relativePath == "references/\(manifest.id)/\(gtf.path)" && $0.sha256 == gtf.sha256 }) {
            let read = Set(run.inputs.map(\.relativePath))
            let hint = TenxGTFFilter.List.allCases.first { read.contains("references/\(manifest.id)/\($0.path)") }
                .map { " It read references/\(manifest.id)/\($0.path), so adopt it with --tenx-filter \($0.rawValue)." } ?? ""
            throw STARIndexError("The run did not read the set \(manifest.id)'s \(gtf.path) by its SHA-256, so its index is not that set's." + hint)
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
            folderName: STARIndexKey.folderName(star: tool.version, nbases: nbases, sparseD: sparse, filter: made?.list),
            setID: manifest.id,
            referenceSetSHA256: try ProvenanceFileHasher.sha256(of: setFolder.appendingPathComponent(ReferenceSetManifest.filename)),
            star: pin, genomeSAindexNbases: nbases, genomeSAsparseD: sparse, sjdbOverhang: overhang,
            genomeFastaFiles: [manifest.genome.path] + manifest.extras.map(\.path), countingGTFSHA256: gtf.sha256,
            gtfFilter: made.map(STARIndexKey.GTFFilter.init))
        // The record names the executor build that made the index, so a run record that does not state it whole is refused.
        let held = run.executor
        guard let executor = held, executor.buildPin != nil, executor.sha256 != nil, executor.size != nil else {
            let lacking = [held?.buildPin == nil ? "buildPin" : nil, held?.sha256 == nil ? "sha256" : nil,
                           held?.size == nil ? "size" : nil].compactMap { $0 }
            throw STARIndexError("The run record's executor names no \(lacking.joined(separator: ", ")), so the index record could not "
                + "name the executor build that made the index and no record was written. Adopt the run-record.json that the "
                + "executor wrote, which states all three.")
        }
        return STARIndexRecord(
            schemaVersion: STARIndexRecord.currentSchemaVersion, setID: manifest.id, key: key, tool: pin, files: files,
            run: .init(runRecordSHA256: PortableDigest.sha256Hex(of: data), runRecordBytes: UInt64(data.count), executor: executor,
                       batch: staging.batch, sample: sample))
    }
}
