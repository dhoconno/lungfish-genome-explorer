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
        version: String = "2.7.11b", overhang: String? = "100", gtf: (path: String, sha256: String)? = nil
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
        let gtfPath = gtf?.path ?? "references/\(setID)/derived/genes.gtf"
        let input: [String: Any] = [
            "role": "reference", "relativePath": gtfPath, "size": 10,
            "sha256": gtf?.sha256 ?? set.manifest.derived.countingGTF?.sha256 ?? "",
            "reference": ["setID": setID, "path": String(gtfPath.dropFirst("references/\(setID)/".count))]]
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

    // MARK: - A bulk key and a bulk record keep their bytes (ARCH-SOLO-GTF items 3 and 7, SOLO-PLAN)

    static let (setSHA, gtfSHA, fileSHA) = (String(repeating: "a", count: 64), String(repeating: "c", count: 64),
                                            String(repeating: "0", count: 64))

    /// A bulk key of fixed values, made by the memberwise form EX-INDEX's code had.
    func bulkKey() -> STARIndexKey {
        STARIndexKey(
            folderName: "star-2.7.11b-sa7-sparse2", setID: "set-0001", referenceSetSHA256: Self.setSHA,
            star: PlanToolPin(id: "STAR", version: "2.7.11b", build: "h0_0"), genomeSAindexNbases: 7, genomeSAsparseD: 2,
            sjdbOverhang: 100, genomeFastaFiles: ["genome/cynomolgus-mt.fa", "extras/sars-cov-2.fa"],
            countingGTFSHA256: Self.gtfSHA)
    }

    static let bulkKeyBytes = "{\"countingGTFSHA256\":\"\(gtfSHA)\",\"folderName\":\"star-2.7.11b-sa7-sparse2\","
        + "\"genomeFastaFiles\":[\"genome/cynomolgus-mt.fa\",\"extras/sars-cov-2.fa\"],\"genomeSAindexNbases\":7,"
        + "\"genomeSAsparseD\":2,\"referenceSetSHA256\":\"\(setSHA)\",\"setID\":\"set-0001\",\"sjdbOverhang\":100,"
        + "\"star\":{\"build\":\"h0_0\",\"id\":\"STAR\",\"version\":\"2.7.11b\"}}"

    static let bulkRecordBytes = """
        {
          "files" : [
            {
              "bytes" : 1000,
              "path" : "Genome",
              "planPath" : "star-index/Genome",
              "sha256" : "\(fileSHA)",
              "stagingPath" : "/staging/group/project/batches/star-index/index/staged/star-index/Genome"
            }
          ],
          "key" : {
            "countingGTFSHA256" : "\(gtfSHA)",
            "folderName" : "star-2.7.11b-sa7-sparse2",
            "genomeFastaFiles" : [
              "genome/cynomolgus-mt.fa",
              "extras/sars-cov-2.fa"
            ],
            "genomeSAindexNbases" : 7,
            "genomeSAsparseD" : 2,
            "referenceSetSHA256" : "\(setSHA)",
            "setID" : "set-0001",
            "sjdbOverhang" : 100,
            "star" : {
              "build" : "h0_0",
              "id" : "STAR",
              "version" : "2.7.11b"
            }
          },
          "schemaVersion" : 1,
          "setID" : "set-0001",
          "tool" : {
            "build" : "h0_0",
            "id" : "STAR",
            "version" : "2.7.11b"
          }
        }
        """

    /// The bytes EX-INDEX's code wrote for a bulk key and a bulk record, pinned before the 10x variant and kept after it.
    func testABulkKeyAndABulkRecordKeepTheirBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try encoder.encode(bulkKey()), as: UTF8.self), Self.bulkKeyBytes)
        let record = STARIndexRecord(
            setID: "set-0001", key: bulkKey(), tool: PlanToolPin(id: "STAR", version: "2.7.11b", build: "h0_0"),
            files: [.init(path: "Genome", planPath: "star-index/Genome",
                          stagingPath: "/staging/group/project/batches/star-index/index/staged/star-index/Genome",
                          bytes: 1000, sha256: Self.fileSHA)])
        let url = try STARIndexRecordStore(storageRoot: root).write(record)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), Self.bulkRecordBytes)
        XCTAssertEqual(try STARIndexRecordStore(storageRoot: root).find(setID: "set-0001", key: record.key.folderName), record)
        XCTAssertNil(bulkKey().gtfFilter, "a bulk key has no filter, so it writes no gtfFilter key")
    }

    /// ARCH-SOLO-GTF item 3: the variant's key adds `gtfFilter` and the folder suffix, and nothing else of the key moves.
    func testAVariantKeyAddsGTFFilterAndTheFolderSuffix() throws {
        XCTAssertEqual(STARIndexKey.folderName(star: "2.7.11b", nbases: 14, sparseD: 2, filter: .mkgtf300),
                       "star-2.7.11b-sa14-sparse2-tenx1-mkgtf-3.0.0")
        var key = bulkKey()
        key.folderName = STARIndexKey.folderName(star: "2.7.11b", nbases: 7, sparseD: 2, filter: .gencode2020A)
        key.gtfFilter = .init(rule: "tenx", ruleVersion: 1, list: "gencode-2020-A", sha256: Self.fileSHA, size: 2000, genesLeftOut: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let filter = "\"gtfFilter\":{\"genesLeftOut\":1,\"list\":\"gencode-2020-A\",\"rule\":\"tenx\",\"ruleVersion\":1,"
            + "\"sha256\":\"\(Self.fileSHA)\",\"size\":2000},"
        XCTAssertEqual(String(decoding: try encoder.encode(key), as: UTF8.self), Self.bulkKeyBytes
            .replacingOccurrences(of: "star-2.7.11b-sa7-sparse2", with: "star-2.7.11b-sa7-sparse2-tenx1-gencode-2020-A")
            .replacingOccurrences(of: "\"referenceSetSHA256\"", with: filter + "\"referenceSetSHA256\""))
    }

    /// ARCH-SOLO-GTF item 4: `index-adopt --tenx-filter` makes the file again from the set and refuses a run record whose
    /// GTF has another SHA-256, reading nothing from the plan.
    func testTheVariantAdoptMakesTheFileAgainAndRefusesARunOfAnotherGTFSHA256() async throws {
        let set = try await builtSet()
        let id = set.manifest.id
        let made = try TenxGTFFilter.make(from: set.url, manifest: set.manifest, list: .mkgtf300)
        let path = "references/\(id)/made/tenx1-mkgtf-3.0.0/genes.gtf"
        let good = try runRecord(for: set, gtf: (path, made.sha256)).data
        let record = try STARIndexAdopt.adopt(runRecord: good, setFolder: set.url, staging: Self.stagingLayout, tenxFilter: .mkgtf300)
        XCTAssertEqual(record.key.folderName, "star-2.7.11b-sa7-sparse2-tenx1-mkgtf-3.0.0")
        XCTAssertEqual(record.key.gtfFilter, .init(rule: "tenx", ruleVersion: 1, list: "mkgtf-3.0.0", sha256: made.sha256,
                                                   size: made.size, genesLeftOut: 0))
        XCTAssertEqual(record.key.countingGTFSHA256, set.manifest.derived.countingGTF?.sha256, "the unfiltered file's")
        let other = String(repeating: "d", count: 64)
        let bad = try runRecord(for: set, gtf: (path, other)).data
        let words = refusal {
            _ = try STARIndexAdopt.adopt(runRecord: bad, setFolder: set.url, staging: Self.stagingLayout, tenxFilter: .mkgtf300)
        }
        XCTAssertEqual(words, "The run read \(path) with SHA-256 \(other), and the 10x filter rule mkgtf-3.0.0 makes \(made.sha256) "
            + "from the set \(id)'s derived/genes.gtf, so its index is not that set's under that rule and no record was written.")
        let bulk = refusal { _ = try STARIndexAdopt.adopt(runRecord: good, setFolder: set.url, staging: Self.stagingLayout) }
        XCTAssertTrue(bulk.hasSuffix("It read \(path), so adopt it with --tenx-filter mkgtf-3.0.0."), bulk)
        let plain = refusal {
            _ = try STARIndexAdopt.adopt(runRecord: try runRecord(for: set).data, setFolder: set.url, staging: Self.stagingLayout,
                                         tenxFilter: .mkgtf300)
        }
        XCTAssertTrue(plain.hasPrefix("The run read no GTF that the 10x filter rule mkgtf-3.0.0 made from the set \(id)"), plain)
        let crossed = "references/\(id)/made/tenx1-gencode-2020-A/genes.gtf"
        let crossedWords = refusal {
            _ = try STARIndexAdopt.adopt(runRecord: try runRecord(for: set, gtf: (crossed, made.sha256)).data, setFolder: set.url,
                                         staging: Self.stagingLayout, tenxFilter: .mkgtf300)
        }
        XCTAssertTrue(crossedWords.hasSuffix("It read \(crossed), so adopt it with --tenx-filter gencode-2020-A."), crossedWords)
    }

    // MARK: - A set that loses a gene tells the unfiltered digest from the made file's (SOLO-PLAN M1 BIO should-fix 2)

    /// `builtSet()` with a tRNA gene added to the annotation, which neither biotype list keeps.
    func builtSetWithATRNAGene() async throws -> ReferenceSetOutcome {
        var text = try String(contentsOf: ReferenceSetMitoFixture.folder.appendingPathComponent("cynomolgus-mt.gtf"), encoding: .utf8)
        if !text.hasSuffix("\n") { text += "\n" }
        text += "NC_012670.1\tRefSeq\tgene\t100\t160\t.\t+\t.\tgene_id \"TRNA-X\"; gene \"TRNA-X\"; gene_biotype \"tRNA\";\n"
            + "NC_012670.1\tRefSeq\texon\t100\t160\t.\t+\t.\tgene_id \"TRNA-X\"; transcript_id \"TRNA-X:1\"; gbkey \"tRNA\";\n"
        let annotation = root.appendingPathComponent("mt-trna.gtf")
        try text.write(to: annotation, atomically: true, encoding: .utf8)
        var request = ReferenceSetMitoFixture.request(.lge)
        request.annotation = annotation
        request.extras = [ReferenceSetExtraInput(
            name: "sars-cov-2", kind: .virus,
            fasta: ReferenceSetMitoFixture.folder.appendingPathComponent("sars-cov-2.fa"), annotation: nil)]
        let owner = ReferenceSetOwner(
            storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(request)
    }

    /// A swap of `countingGTFSHA256` and the made file's digest passes every row on the plain set, where the two are equal.
    func testAVariantOfASetThatLosesAGeneKeepsTheUnfilteredDigestAndNamesTheFilteredFile() async throws {
        let set = try await builtSetWithATRNAGene()
        let id = set.manifest.id
        let derived = try XCTUnwrap(set.manifest.derived.countingGTF)
        let derivedSize = try Data(contentsOf: set.url.appendingPathComponent("derived/genes.gtf")).count
        var variant = request(set.url)
        variant.tenxFilter = .mkgtf300
        variant.planFolder = root.appendingPathComponent("plan-folder", isDirectory: true)
        let made = try STARIndexPlan.make(variant)
        let file = try XCTUnwrap(made.made)
        XCTAssertEqual(file.genesLeftOut, ["TRNA-X"])
        XCTAssertNotEqual(file.sha256, derived.sha256, "the made file lost the gene's two lines")
        XCTAssertLessThan(Int(file.size), derivedSize)
        let path = "references/\(id)/made/tenx1-mkgtf-3.0.0/genes.gtf"
        let entry = try XCTUnwrap(made.plan.entries.first { $0.relativePath == path })
        XCTAssertEqual([entry.sha256, "\(entry.size)"], [file.sha256, "\(file.size)"], "the entry names the made file")
        XCTAssertEqual(made.key.countingGTFSHA256, derived.sha256, "the key keeps the unfiltered file's digest")
        XCTAssertEqual(made.key.gtfFilter, .init(rule: "tenx", ruleVersion: 1, list: "mkgtf-3.0.0", sha256: file.sha256,
                                                 size: file.size, genesLeftOut: 1))
        let record = try STARIndexAdopt.adopt(
            runRecord: try runRecord(for: set, gtf: (path, file.sha256)).data, setFolder: set.url, staging: Self.stagingLayout,
            tenxFilter: .mkgtf300)
        XCTAssertEqual(record.key.gtfFilter, made.key.gtfFilter)
        XCTAssertEqual(record.key.countingGTFSHA256, derived.sha256)
        let unfiltered = refusal {
            _ = try STARIndexAdopt.adopt(runRecord: try runRecord(for: set, gtf: (path, derived.sha256)).data, setFolder: set.url,
                                         staging: Self.stagingLayout, tenxFilter: .mkgtf300)
        }
        XCTAssertTrue(unfiltered.contains("with SHA-256 \(derived.sha256)"), unfiltered)
    }
}
