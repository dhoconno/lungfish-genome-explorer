// STARIndexRecordTests.swift - The adopted STAR index record (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishPortable
import XCTest
@testable import LungfishWorkflow

extension STARIndexPlanTests {
    static let stagingLayout = ExecutorPlanStagingLayout(folder: "/staging/group/project", batch: "star-index")

    /// The run record of a recorded run of the small set, with the tool, the argv, the reference entries and the outputs
    /// as the executor states them. The adopt reads these and never the plan.
    func runRecord(for set: ReferenceSetOutcome, naming claimed: String? = nil, outcome: String = "succeeded", leaving missing: String? = nil) throws
        -> (data: Data, outputs: [[String: Any]]) {
        let setID = claimed ?? set.manifest.id
        var outputs: [[String: Any]] = STARIndexPlan.indexFiles.enumerated().map { index, file in
            ["path": "star-index/\(file)", "bytes": 1_000 + index, "sha256": String(repeating: String(index % 10), count: 64),
             "policy": "staged"]
        }
        outputs.append(["path": "star-index.Log.out", "bytes": 5_000, "sha256": String(repeating: "f", count: 64), "policy": "home"])
        outputs.removeAll { $0["path"] as? String == missing }
        let argv = ["--runMode", "genomeGenerate", "--genomeDir", "star-index", "--runThreadN", "8",
                    "--genomeSAindexNbases", "7", "--genomeSAsparseD", "2"]
        let step: [String: Any] = [
            "id": "star-index", "outcome": outcome, "argv": argv, "outputs": outputs,
            "tool": ["id": "STAR", "version": "2.7.11b", "build": "h0_0", "path": "/opt/lge/rnaseq/bin/STAR"]]
        let input: [String: Any] = [
            "role": "reference", "relativePath": "references/\(setID)/derived/genes.gtf", "size": 10,
            "sha256": set.manifest.derived.countingGTF?.sha256 ?? "", "reference": ["setID": setID, "path": "derived/genes.gtf"]]
        var record: [String: Any] = ["schemaVersion": 1, "outcome": outcome, "inputs": [input], "steps": [step]]
        if outcome != "succeeded" { record["reason"] = "STAR ran out of memory"; record["failedStepID"] = "star-index" }
        return (try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), outputs)
    }

    func adopted(_ set: ReferenceSetOutcome) throws -> (STARIndexRecord, [[String: Any]]) {
        let (data, outputs) = try runRecord(for: set)
        return (try STARIndexAdopt.adopt(runRecord: data, setFolder: set.url, staging: Self.stagingLayout), outputs)
    }

    func testTheAdoptedRecordHoldsTheRunRecordsDigestsAndTheStagingPathOfEachFile() async throws {
        let set = try await builtSet()
        let (record, outputs) = try adopted(set)
        XCTAssertEqual(record.setID, set.manifest.id)
        XCTAssertEqual(record.key.folderName, "star-2.7.11b-sa7-sparse2")
        XCTAssertEqual(record.key.referenceSetSHA256, try ProvenanceFileHasher.sha256(of: set.url.appendingPathComponent("reference-set.json")))
        XCTAssertEqual(record.tool, PlanToolPin(id: "STAR", version: "2.7.11b", build: "h0_0"))
        let staged = outputs.filter { $0["policy"] as? String == "staged" }.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        XCTAssertEqual(record.files.count, 15)
        for (file, output) in zip(record.files, staged) {
            XCTAssertEqual(file.planPath, output["path"] as? String)
            XCTAssertEqual(file.sha256, output["sha256"] as? String)
            XCTAssertEqual(file.bytes, (output["bytes"] as? NSNumber)?.uint64Value)
            XCTAssertEqual(file.stagingPath, "/staging/group/project/batches/star-index/index/staged/\(file.planPath)")
            XCTAssertEqual(file.path, String(file.planPath.dropFirst("star-index/".count)))
        }
    }

    func testAFailedRecordAMissingStagedOutputAndAnotherSetsIdAreRefusedInWords() async throws {
        let set = try await builtSet()
        func words(_ made: (data: Data, outputs: [[String: Any]])) -> String {
            refusal { _ = try STARIndexAdopt.adopt(runRecord: made.data, setFolder: set.url, staging: Self.stagingLayout) }
        }
        let failed = words(try runRecord(for: set, outcome: "failed"))
        XCTAssertTrue(failed.contains("reads failed") && failed.contains("STAR ran out of memory") && failed.contains("no index"), failed)
        let missing = words(try runRecord(for: set, leaving: "star-index/SA"))
        XCTAssertTrue(missing.contains("star-index/SA"), missing)
        let other = words(try runRecord(for: set, naming: "another-set-0001"))
        XCTAssertTrue(other.contains("another-set-0001") && other.contains(set.manifest.id), other)
    }

    func testTheRecordIsWrittenOnceInOnePlaceFoundBySetAndKeyAndADifferentDigestIsRefused() async throws {
        let (record, _) = try adopted(try await builtSet())
        let store = STARIndexRecordStore(storageRoot: root)
        let url = try store.write(record)
        XCTAssertEqual(url.path, root.path + "/rnaseq-index-records/\(record.setID)/\(record.key.folderName)/index-record.json")
        XCTAssertEqual(try store.find(setID: record.setID, key: record.key.folderName), record)
        XCTAssertEqual(try store.write(record), url, "the same record again changes nothing")
        var other = record
        other.files[0].sha256 = String(repeating: "e", count: 64)
        XCTAssertTrue(refusal { _ = try store.write(other) }.contains("already names other digests"))
        XCTAssertNil(try store.find(setID: record.setID, key: "star-2.7.11b-sa1-sparse2"))
    }
}
