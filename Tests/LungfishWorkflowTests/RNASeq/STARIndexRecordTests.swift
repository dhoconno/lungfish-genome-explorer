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
    func runRecord(
        for set: ReferenceSetOutcome, naming claimed: String? = nil, outcome: String = "succeeded", leaving missing: String? = nil,
        version: String = "2.7.11b", overhang: String? = "100"
    ) throws -> (data: Data, outputs: [[String: Any]]) {
        let setID = claimed ?? set.manifest.id
        var outputs: [[String: Any]] = STARIndexPlan.indexFiles.enumerated().map { index, file in
            ["path": "star-index/\(file)", "bytes": 1_000 + index, "sha256": String(repeating: String(index % 10), count: 64),
             "policy": "staged"]
        }
        outputs.append(["path": "star-index/Log.out", "bytes": 5_000, "sha256": String(repeating: "f", count: 64), "policy": "home"])
        outputs.removeAll { $0["path"] as? String == missing }
        let argv = ["--runMode", "genomeGenerate", "--genomeDir", "star-index", "--runThreadN", "8"]
            + (overhang.map { ["--sjdbOverhang", $0] } ?? []) + ["--genomeSAindexNbases", "7", "--genomeSAsparseD", "2"]
        let step: [String: Any] = [
            "id": "star-index", "outcome": outcome, "argv": argv, "outputs": outputs,
            "tool": ["id": "STAR", "version": version, "build": "h0_0", "path": "/opt/lge/rnaseq/bin/STAR"]]
        let input: [String: Any] = [
            "role": "reference", "relativePath": "references/\(setID)/derived/genes.gtf", "size": 10,
            "sha256": set.manifest.derived.countingGTF?.sha256 ?? "", "reference": ["setID": setID, "path": "derived/genes.gtf"]]
        var record: [String: Any] = ["schemaVersion": 1, "outcome": outcome, "inputs": [input], "steps": [step]]
        if outcome != "succeeded" { record["reason"] = "STAR ran out of memory"; record["failedStepID"] = "star-index" }
        return (try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), outputs)
    }

    func adopted(_ set: ReferenceSetOutcome, staging: ExecutorPlanStagingLayout = STARIndexPlanTests.stagingLayout) throws -> (STARIndexRecord, [[String: Any]]) {
        let (data, outputs) = try runRecord(for: set)
        return (try STARIndexAdopt.adopt(runRecord: data, setFolder: set.url, staging: staging), outputs)
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

    // MARK: - A name that is not one folder, --sjdbOverhang, and refusal words that say what differs (FIX-IDX-1)

    /// SWIFT B2: the set id comes from a manifest and the key's folder name from a run record, so the one owner refuses
    /// any that is not one plain folder name and writes nothing, inside `rnaseq-index-records/` or outside it.
    func testASetIDOrKeyThatIsNotOnePlainFolderNameIsRefusedAndWritesNothing() async throws {
        let (record, _) = try adopted(try await builtSet())
        let store = STARIndexRecordStore(storageRoot: root.appendingPathComponent("store", isDirectory: true))
        var escaping = record
        escaping.key.folderName = "star-/../../../../escape-sa7-sparse2"
        var parent = record
        parent.setID = ".."
        for (made, name) in [(escaping, escaping.key.folderName), (parent, "..")] {
            let words = refusal { _ = try store.write(made) }
            XCTAssertTrue(words.contains("\"\(name)\" is not one plain folder name"), words)
        }
        let found = refusal { _ = try store.find(setID: "a/b", key: record.key.folderName) }
        XCTAssertTrue(found.contains("\"a/b\" is not one plain folder name"), found)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape-sa7-sparse2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageRoot.path), "nothing written, not even the records folder")
    }

    /// SWIFT B2: the key's version comes from the run record, so the adopt reads only the two STARs the image holds.
    func testARunRecordNamingAnotherStarVersionIsRefused() async throws {
        let set = try await builtSet()
        let made = try runRecord(for: set, version: "../x")
        let words = refusal { _ = try STARIndexAdopt.adopt(runRecord: made.data, setFolder: set.url, staging: Self.stagingLayout) }
        XCTAssertTrue(words.contains("STAR ../x") && words.contains("2.7.11b and 2.7.3a only"), words)
    }

    func encoded(_ key: STARIndexKey) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as? [String: Any])
    }

    /// BIO should-fix 1: `--sjdbOverhang` changes the index's bytes, so the plan's key, the adopted key and the written
    /// record name it, and the adopt refuses a run record whose argv lacks it.
    func testThePlanKeyAndTheRecordNameSjdbOverhangAndARunWithoutItIsRefused() async throws {
        let set = try await builtSet()
        XCTAssertEqual(try encoded(try STARIndexPlan.make(request(set.url)).key)["sjdbOverhang"] as? Int, 100)
        let (record, _) = try adopted(set)
        XCTAssertEqual(try encoded(record.key)["sjdbOverhang"] as? Int, 100)
        let url = try STARIndexRecordStore(storageRoot: root).write(record)
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((written["key"] as? [String: Any])?["sjdbOverhang"] as? Int, 100, "the record on disk names it")
        let made = try runRecord(for: set, overhang: nil)
        let words = refusal { _ = try STARIndexAdopt.adopt(runRecord: made.data, setFolder: set.url, staging: Self.stagingLayout) }
        XCTAssertTrue(words.contains("names no --sjdbOverhang") && !words.contains("--genomeSAsparseD"), words)
    }

    /// SWIFT S3 and BIO should-fix 2: the same index adopted again under another batch has equal digests and other staging
    /// paths, so the refusal says that, names the record's file and both folders, and never says other digests.
    func testAReAdoptAtAnotherStagingPathIsRefusedInWordsThatSayWhatDiffers() async throws {
        let set = try await builtSet()
        let store = STARIndexRecordStore(storageRoot: root)
        let url = try store.write(try adopted(set).0)
        let before = try Data(contentsOf: url)
        let moved = ExecutorPlanStagingLayout(folder: "/staging/group/project", batch: "star-index-2")
        let words = refusal { _ = try store.write(try adopted(set, staging: moved).0) }
        for part in ["the same digests", url.path, "/staging/group/project/batches/star-index/index/staged/star-index,",
                     "/staging/group/project/batches/star-index-2/index/staged/star-index,", "remove that file"] {
            XCTAssertTrue(words.contains(part), "\(part) is missing from: \(words)")
        }
        XCTAssertFalse(words.contains("other digests"), words)
        var changed = try adopted(set).0
        changed.files[3].sha256 = String(repeating: "e", count: 64)
        let digests = refusal { _ = try store.write(changed) }
        XCTAssertTrue(digests.contains("other digests for 1 of 15 files") && digests.contains(url.path), digests)
        XCTAssertFalse(digests.contains("staging") || digests.contains("same digests"), digests)
        XCTAssertEqual(try Data(contentsOf: url), before, "a refusal leaves the record as it was")
    }
}
