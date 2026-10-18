// OutputEquivalenceTests+Masks.swift - Self-tests for the masks that reviewed contract changes added
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// OutputEquivalenceTests.swift is over the size baseline and may not grow, so a mask added after it holds
// its test here, as an extension of the same class. Each test builds its own two roots.

import Foundation
import XCTest
import LungfishTestSupport

extension OutputEquivalenceTests {
    /// A demo project's install record (`.lgedemo.json`) holds the time `DemoProjectInstaller` installed the
    /// project, to the second. Two installs never take the same second, so the contract masks the value of
    /// the record's top-level `installedAt` in a JSON payload. The mask reads a document that holds the
    /// record's four keys and no other, so the same key in any other document, a key one level down, a record
    /// with another key, a missing `installedAt` and the record's other three values are still compared (manager
    /// answer to lane A45 M4's question 1, by the rule of BIO's ruling on M3c section b).
    func testTheDemoInstallClockIsMaskedAndNothingBesideIt() throws {
        let top = try TestTempDirectory.make(prefix: "demo-install-clock")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let name = "Installed/Demo Fixture.lungfish/.lgedemo.json"
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        let clockA = "2026-10-14T18:19:48Z"
        let clockB = "2026-10-14T18:19:49Z"

        // The record as DemoProjectInstaller writes it, with an edit applied to the document first.
        let record = { (clock: String, edit: (inout [String: Any]) -> Void) throws -> Data in
            var document: [String: Any] = [
                "id": "demo-fixture", "installedAt": clock, "sha256": String(repeating: "a", count: 64), "version": "2026.9.44",
            ]
            edit(&document)
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        }
        let write = { (data: Data, root: URL) throws in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        try write(record(clockA) { _ in }, a)
        try write(record(clockB) { _ in }, b)
        XCTAssertEqual(try found(), [], "only the install time differs")

        // Each change differs in the one file on top of the clocks. The last four leave the clock to be
        // compared as written, with each side's own time.
        let cases: [(label: String, both: Bool, edit: (inout [String: Any]) -> Void)] = [
            ("version", false, { $0["version"] = "2026.9.45" }),
            ("sha256", false, { $0["sha256"] = String(repeating: "b", count: 64) }),
            ("id", false, { $0["id"] = "demo-other" }),
            ("no installedAt", false, { $0["installedAt"] = nil }),
            ("another key", true, { $0["note"] = "x" }),
            ("only installedAt", true, { $0 = ["installedAt": $0["installedAt"] as Any] }),
            ("installedAt one level down", true, { $0 = ["record": $0] }),
            ("one key missing besides installedAt", true, { $0["version"] = nil }),
        ]
        for (label, both, edit) in cases {
            try write(record(clockA, both ? edit : { _ in }), a)
            try write(record(clockB, edit), b)
            let result = try found()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }

    /// A `blast submit` record (`blast-result.json`) holds three clock values, the time the leaf saved the
    /// record (`savedAt`) and the times its search was submitted and finished (`result.submittedAt` and
    /// `result.completedAt`). Two searches never take the same seconds, so the contract masks the three in a
    /// JSON payload. The mask reads a document that holds the record's six keys and no other, so the same keys
    /// in any other document, a key one level down, a record with another key or without `savedAt`, a
    /// `savedAt` alone and every other value of the record, such as the query digest, the lineage, the RID,
    /// the verdicts and the search settings, are still compared (Phase 2.11 lane A65 review, fix F1, by the
    /// rule of BIO's ruling on lane A45 M3c section b).
    func testBlastRecordClocksMaskThreeValuesAndNoOthers() throws {
        let top = try TestTempDirectory.make(prefix: "blast-record-clocks")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let name = "Project.lungfish/blast-verifications/Influenza-A-virus-2026-10-17T10-00-00-1a2b3c4d/blast-result.json"
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        typealias Clocks = (saved: String, submitted: String, completed: String)
        let clocksA: Clocks = ("2026-10-17T10:00:05Z", "2026-10-17T10:00:01Z", "2026-10-17T10:00:04Z")
        let clocksB: Clocks = ("2026-10-17T11:30:09Z", "2026-10-17T11:30:02Z", "2026-10-17T11:30:08Z")

        // The record as the leaf writes it, with an edit applied to the document first.
        let record = { (clocks: Clocks, edit: (inout [String: Any]) -> Void) throws -> Data in
            let reads: [[String: Any]] = [["readId": "read_1", "verdict": "verified"], ["readId": "read_2", "verdict": "unverified"]]
            let query: [String: Any] = ["fileName": "query.fasta", "sha256": String(repeating: "a", count: 64), "sequenceCount": 2]
            let lineage: [String: Any] = [
                "sourceResult": "/Project.lungfish/Analyses/naomgs", "sample": "S1,S2", "taxId": 11320, "subsampleCount": 2,
                "subsampleSeed": 0,
            ]
            let search: [String: Any] = [
                "program": "blastn", "database": "core_nt", "entrezQuery": "txid11320[Organism:exp]",
                "eValueThreshold": 0.01, "maxTargetSeqs": 10, "extraArgs": "",
            ]
            let result: [String: Any] = [
                "rid": "STANDIN1", "submittedAt": clocks.submitted, "completedAt": clocks.completed, "readResults": reads,
            ]
            var document: [String: Any] = [
                "schemaVersion": 1, "savedAt": clocks.saved, "query": query, "lineage": lineage, "search": search, "result": result,
            ]
            edit(&document)
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        }
        let write = { (data: Data, root: URL) throws in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        // `edit` applied to the object the record holds under `key`.
        func inObject(_ key: String, _ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
            { document in
                var object = document[key] as? [String: Any] ?? [:]
                edit(&object)
                document[key] = object
            }
        }

        try write(record(clocksA) { _ in }, a)
        try write(record(clocksB) { _ in }, b)
        XCTAssertEqual(try found(), [], "only the three clock values differ")

        // A search that left no submission or completion time still has its save time masked.
        let noResultClocks = inObject("result") { result in
            result["submittedAt"] = nil
            result["completedAt"] = nil
        }
        try write(record(clocksA, noResultClocks), a)
        try write(record(clocksB, noResultClocks), b)
        XCTAssertEqual(try found(), [], "a result without its two times still has savedAt masked")

        // Each change differs in the one file on top of the clocks. The last four leave the clocks to be
        // compared as written, with each side's own times.
        let cases: [(label: String, both: Bool, edit: (inout [String: Any]) -> Void)] = [
            ("query.sha256", false, inObject("query") { $0["sha256"] = String(repeating: "b", count: 64) }),
            ("lineage.sample", false, inObject("lineage") { $0["sample"] = "S3" }),
            ("lineage.subsampleSeed", false, inObject("lineage") { $0["subsampleSeed"] = 1 }),
            ("result.rid", false, inObject("result") { $0["rid"] = "STANDIN2" }),
            ("one read's verdict", false, inObject("result") { result in
                var reads = result["readResults"] as? [[String: Any]] ?? []
                reads[0]["verdict"] = "unverified"
                result["readResults"] = reads
            }),
            ("search.entrezQuery", false, inObject("search") { $0["entrezQuery"] = "txid11321[Organism:exp]" }),
            ("schemaVersion", false, { $0["schemaVersion"] = 2 }),
            ("no savedAt", true, { $0["savedAt"] = nil }),
            ("another key", true, { $0["note"] = "x" }),
            ("only savedAt", true, { $0 = ["savedAt": $0["savedAt"] as Any] }),
            ("savedAt one level down", true, { $0 = ["record": $0] }),
        ]
        for (label, both, edit) in cases {
            try write(record(clocksA, both ? edit : { _ in }), a)
            try write(record(clocksB, edit), b)
            let result = try found()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }

    /// Three result sidecars hold a run clock. A classification result (`classification-result.json`) states the
    /// seconds the pipeline or conversion ran (`runtime`) and the time it was saved (`savedAt`), an EsViritu result
    /// (`esviritu-result.json`) the time it was saved, and an analysis folder's `analysis-metadata.json` the time the
    /// folder was made (`created`). Two runs never take the same seconds, so the contract masks those values in a JSON
    /// payload, at the top level of a document that holds the sidecar's own keys and none beyond its optional ones.
    /// The EsViritu `runtime`, the same keys in any other document, a key one level down, a document with another
    /// key or without a named one, and every other value are still compared (Phase 2.12, ruling 1 of the review of
    /// lane 12.06 M1, by the rule of BIO's ruling on lane A45 M3c section b).
    func testResultSidecarClocksMaskTheNamedKeysAndNoOthers() throws {
        let top = try TestTempDirectory.make(prefix: "result-sidecar-clocks")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        let classification = "Analyses/kraken2-x/classification-result.json"
        let esViritu = "Analyses/esviritu-x/esviritu-result.json"
        let metadata = "Analyses/esviritu-x/analysis-metadata.json"
        typealias Clocks = (runtime: Double, saved: String)
        let clocksA: Clocks = (4.5, "2026-10-18T10:00:05Z")
        let clocksB: Clocks = (9.25, "2026-10-18T11:30:09Z")
        let config: [String: Any] = ["inputFiles": ["/in/S1.fastq"], "databaseName": "Viral", "threads": 4]

        // The documents as the writers emit them. The EsViritu runtime is the same on both sides, since only its
        // save time is masked.
        func classificationDocument(_ clocks: Clocks, withOptionalKeys: Bool = false) -> [String: Any] {
            var document: [String: Any] = [
                "config": config, "reportPath": "classification.kreport", "outputPath": "classification.kraken",
                "runtime": clocks.runtime, "toolVersion": "2.1.3", "savedAt": clocks.saved,
            ]
            if withOptionalKeys {
                document["brackenPath"] = "classification.bracken"
                document["profileOutcome"] = "profiled"
                document["provenanceId"] = "3f2c1d4e-0000-4000-8000-000000000001"
                document["fragmentComposition"] = ["pairs": 10]
                document["readPairingContract"] = 1
            }
            return document
        }
        func esVirituDocument(_ clocks: Clocks) -> [String: Any] {
            [
                "config": config, "detectionPath": "S1.detected_virus.info.tsv", "virusCount": 3, "runtime": 3.5,
                "toolVersion": "1.0.0", "savedAt": clocks.saved,
            ]
        }
        func metadataDocument(_ clocks: Clocks) -> [String: Any] {
            ["tool": "kraken2", "isBatch": false, "created": clocks.saved]
        }
        let documents: [String: (Clocks) -> [String: Any]] = [
            classification: { classificationDocument($0) }, esViritu: esVirituDocument, metadata: metadataDocument,
        ]
        let write = { (document: [String: Any], name: String, root: URL) throws in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted]).write(to: url)
        }
        // The three sidecars in both trees, each side with its own clocks.
        func reset() throws {
            for (name, document) in documents {
                try write(document(clocksA), name, a)
                try write(document(clocksB), name, b)
            }
        }

        try reset()
        XCTAssertEqual(try found(), [], "only the masked keys differ")

        // A classification result with none of its optional keys masks, and so does one with all five.
        try write(classificationDocument(clocksA, withOptionalKeys: true), classification, a)
        try write(classificationDocument(clocksB, withOptionalKeys: true), classification, b)
        XCTAssertEqual(try found(), [], "a classification result with its five optional keys still masks")

        // Each case differs in the one file. `both` puts the edit into the document of both sides, so a document
        // that the mask does not read keeps its different clocks and they are compared as written. Without it only
        // side B has the edit, and the clocks stay masked.
        typealias Edit = (inout [String: Any]) -> Void
        let cases: [(label: String, name: String, both: Bool, edit: Edit)] = [
            ("classification toolVersion", classification, false, { $0["toolVersion"] = "2.1.4" }),
            ("classification outputPath", classification, false, { $0["outputPath"] = "other.kraken" }),
            ("EsViritu runtime", esViritu, false, { $0["runtime"] = 4.5 }),
            ("EsViritu virusCount", esViritu, false, { $0["virusCount"] = 4 }),
            ("EsViritu detectionPath", esViritu, false, { $0["detectionPath"] = "S2.detected_virus.info.tsv" }),
            ("metadata tool", metadata, false, { $0["tool"] = "esviritu" }),
            ("metadata isBatch", metadata, false, { $0["isBatch"] = true }),
            ("classification keys one level down", classification, true, { $0 = ["record": $0] }),
            ("classification with an unknown key", classification, true, { $0["note"] = "x" }),
            ("classification without toolVersion", classification, true, { $0["toolVersion"] = nil }),
            ("EsViritu keys one level down", esViritu, true, { $0 = ["record": $0] }),
            ("EsViritu with an unknown key", esViritu, true, { $0["note"] = "x" }),
            ("EsViritu without virusCount", esViritu, true, { $0["virusCount"] = nil }),
            ("metadata keys one level down", metadata, true, { $0 = ["record": $0] }),
            ("metadata with a fourth key", metadata, true, { $0["note"] = "x" }),
        ]
        for (label, name, both, edit) in cases {
            try reset()
            var documentA = try XCTUnwrap(documents[name])(clocksA)
            var documentB = try XCTUnwrap(documents[name])(clocksB)
            if both { edit(&documentA) }
            edit(&documentB)
            try write(documentA, name, a)
            try write(documentB, name, b)
            let result = try found()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }

    /// G5 (Phase 2.10, lane A50 M2, BR7). GATK writes the run's date into the VCF header line
    /// `##GATKCommandLine`, so two runs of one command never agree on it. The GATK compare masks the value of that
    /// line's trailing `Date=` and nothing else. A changed `CommandLine=` value, `Version=` or ID, the same key
    /// on another header line and a changed record still differ, and the standard compare still reports the date.
    func testTheGATKCompareMasksOnlyTheDateOfTheGATKCommandLineHeader() throws {
        let top = try TestTempDirectory.make(prefix: "gatk-header-date")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let name = "variants/gatk/vc-1.vcf"
        let dateA = "October 16, 2026, 1:41:26\u{202F}PM CDT"
        let dateB = "October 16, 2026, 2:02:09\u{202F}PM CDT"
        let vcf = { (id: String, commandLine: String, version: String, date: String, source: String, record: String) -> Data in
            let header = "##GATKCommandLine=<ID=\(id),CommandLine=\"\(commandLine)\",Version=\"\(version)\",Date=\"\(date)\">"
            return Data(
                ["##fileformat=VCFv4.2", header, source, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO", record, ""]
                    .joined(separator: "\n").utf8
            )
        }
        let write = { (data: Data, root: URL) throws in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let gatk = { try OutputEquivalence.differences(a, b, kind: .files, masks: .gatk) }
        let call = "HaplotypeCaller --sample-ploidy 2"
        let source = "##source=Lungfish,Date=\"Monday\""
        let record = "chr1\t4\t.\tT\tG\t60\tPASS\tDP=18"

        try write(vcf("HaplotypeCaller", call, "4.6.2.0", dateA, source, record), a)
        try write(vcf("HaplotypeCaller", call, "4.6.2.0", dateB, source, record), b)
        XCTAssertEqual(try gatk(), [], "only the run's date differs")
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .files), [],
            "the standard VCF compare drops every command header line, so it sees neither the date nor the command (BR7)"
        )

        // Each change differs in the one file, on top of the two dates.
        let cases: [(label: String, side: Data)] = [
            ("CommandLine value", vcf("HaplotypeCaller", "HaplotypeCaller --sample-ploidy 1", "4.6.2.0", dateB, source, record)),
            ("Version", vcf("HaplotypeCaller", call, "4.6.1.0", dateB, source, record)),
            ("ID", vcf("SelectVariants", call, "4.6.2.0", dateB, source, record)),
            ("Date= on another header line", vcf("HaplotypeCaller", call, "4.6.2.0", dateB, "##source=Lungfish,Date=\"Tuesday\"", record)),
            ("record", vcf("HaplotypeCaller", call, "4.6.2.0", dateB, source, record.replacingOccurrences(of: "\tG\t", with: "\tC\t"))),
        ]
        for (label, side) in cases {
            try write(side, b)
            let result = try gatk()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }

    func testTheGATKCompareNumbersTheTrackIDInTheGATKCommandLineHeader() throws {
        let top = try TestTempDirectory.make(prefix: "gatk-header-track-id")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let idA = "0f8e1c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b"
        let idB = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"
        let idOther = "11111111-2222-4333-8444-555555555555"
        let write = { (root: URL, fileID: String, headerID: String, ploidy: Int, folder: String) throws in
            let output = "\(root.path)/\(folder)/vc-\(headerID).vcf"
            let header = "##GATKCommandLine=<ID=HaplotypeCaller,CommandLine=\"HaplotypeCaller --sample-ploidy \(ploidy) --output \(output)\","
                + "Version=\"4.6.2.0\",Date=\"October 16, 2026, 1:41:26\u{202F}PM CDT\">"
            let text = ["##fileformat=VCFv4.2", header, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO", "chr1\t4\t.\tT\tG\t60\tPASS\tDP=18", ""]
                .joined(separator: "\n")
            let url = root.appendingPathComponent("variants/gatk/vc-\(fileID).vcf")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // The bundle kind numbers the UUID in each file name, as the live class's compare does. The files kind reads
        // names as written, so each file would exist on one side only.
        let gatk = { try OutputEquivalence.differences(a, b, kind: .bundle, masks: .gatk) }
        try write(a, idA, idA, 2, "variants/gatk")
        try write(b, idB, idB, 2, "variants/gatk")
        XCTAssertEqual(try gatk(), [], "each header names its own file's ID, so only the IDs differ and they are numbered")
        let cases: [(label: String, headerID: String, ploidy: Int, folder: String)] = [
            ("another track's ID", idOther, 2, "variants/gatk"),
            ("another parameter", idB, 1, "variants/gatk"),
            ("another folder", idB, 2, "variants/other"),
        ]
        for (label, headerID, ploidy, folder) in cases {
            try write(b, idB, headerID, ploidy, folder)
            let result = try gatk()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: variants/gatk/vc-<UUID-1>.vcf") == true, "\(label): \(result)")
        }
    }
}
