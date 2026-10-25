// V15ParityComparisonTests.swift - The V15 comparison's roots, typed options and command lines (CHTC C4 lane A, QA-V15lines)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
@testable import LungfishWorkflow

final class V15ParityComparisonTests: XCTestCase {
    private let project = "/var/folders/T/case/Project.lungfish"
    private let scratchName = ".tmp/fastq-import-1F2A0176-2D6D-419F-A6C5-7B3B358C6A1B"
    private let macSplit = ".clumpify-split-947BE779-7447-40C3-B084-94EC349841F9"
    private let nodeSplit = ".clumpify-split-08BCAE40-8217-4A4B-AD6E-6D493F47ADC7"
    private let storage = "/Users/x/dbroot"
    private let index = "databases/deacon-panhuman/panhuman-1.k31w15.idx"

    /// QV-10: the Mac's deacon `-d` token strips to the node's plan-relative path in both its sidecar and envelope forms,
    /// each route's clumpify split folder strips to the same file, and a token under no listed root is unchanged.
    func testStripRootLeavesPlanRelativePaths() {
        let scratch = "\(project)/\(scratchName)"
        let found = V15Comparison.routeRoots(
            project: project, returned: "/var/folders/T/case/plan", storageRoot: storage,
            macStrings: ["\(storage)/\(index)", "in=\(scratch)/\(macSplit)/pairs.fastq"],
            adoptedStrings: ["in=\(nodeSplit)/pairs.fastq"]
        )
        XCTAssertEqual(found.problems, [])
        let mac = found.roots[.mac] ?? [], adopted = found.roots[.adopted] ?? []
        XCTAssertEqual(V15Comparison.stripRoot("\(storage)/\(index)", roots: mac), index)
        XCTAssertEqual(V15Comparison.stripRoot("<storage-root>/\(index)", roots: mac), index)
        XCTAssertEqual(V15Comparison.stripRoot(index, roots: adopted), index)
        XCTAssertEqual(V15Comparison.stripRoot("in=@/\(scratchName)/\(macSplit)/pairs.fastq", roots: mac), "in=pairs.fastq")
        XCTAssertEqual(V15Comparison.stripRoot("in=\(scratch)/\(macSplit)/pairs.fastq", roots: mac), "in=pairs.fastq")
        XCTAssertEqual(V15Comparison.stripRoot("in=\(nodeSplit)/pairs.fastq", roots: adopted), "in=pairs.fastq")
        XCTAssertEqual(V15Comparison.stripRoot("/elsewhere/C079876_S1_1M_R1.fastq.gz", roots: mac), "/elsewhere/C079876_S1_1M_R1.fastq.gz")

        let two = V15Comparison.routeRoots(
            project: project, returned: "/r", storageRoot: nil,
            macStrings: [scratch, "\(project)/.tmp/fastq-import-00000000-0000-0000-0000-000000000000"], adoptedStrings: []
        )
        XCTAssertEqual(two.problems.count, 1, "a Mac record that names two import folders has no one root")
    }

    /// QV-25: a source rule reads the value of a typed option, so a typed `plan` against a typed `option` passes, a typed
    /// null against a typed number passes the basis rule, and a typed `default` fails.
    func testTypedOptionValuesMeetSourceRules() {
        func typed(_ value: String) -> [String: Any] { ["type": "string", "value": value] }
        let path = ["envelope", "options", "resolvedDefaults"]
        var passing = V15Comparison(roots: [:], payloadFileNames: [])
        passing.walk(["threadsSource": typed("plan"), "clumpingThresholdBytes": ["type": "null"]],
                     ["threadsSource": typed("option"), "clumpingThresholdBytes": ["type": "integer", "value": NSNumber(value: 42)]],
                     path: path)
        XCTAssertEqual(passing.findings.map(\.description), [])

        var failing = V15Comparison(roots: [:], payloadFileNames: [])
        failing.walk(["threadsSource": typed("plan")], ["threadsSource": typed("default")], path: path)
        XCTAssertEqual(failing.findings.map(\.key), ["envelope.options.resolvedDefaults.threadsSource"])
    }

    /// QV-14 and QV-27: a command line of two launches joined by ` && ` compares part by part, and an absolute path token
    /// that holds `//` fails with both raw values.
    func testCommandLinePartsCompareAsArgvAndDoubledSlashFails() {
        let roots: [V15Route: [String]] = [.adopted: ["/node"], .mac: ["/mac"]]
        var joined = V15Comparison(roots: roots, payloadFileNames: [])
        joined.walk(["commandLine": "/node/bin/clumpify.sh in=/node/a.fq && /node/bin/clumpify.sh in=/node/b.fq"],
                    ["commandLine": "clumpify.sh in=/mac/a.fq && clumpify.sh in=/mac/b.fq"], path: ["sidecar", "step"])
        XCTAssertEqual(joined.findings.map(\.description), [])

        var oneLaunch = V15Comparison(roots: roots, payloadFileNames: [])
        oneLaunch.walk(["commandLine": "/node/bin/clumpify.sh in=/node/a.fq"],
                       ["commandLine": "clumpify.sh in=/mac/a.fq && clumpify.sh in=/mac/b.fq"], path: ["sidecar", "step"])
        XCTAssertEqual(oneLaunch.findings.count, 1, "one launch against two differs")

        var doubled = V15Comparison(roots: roots, payloadFileNames: [])
        doubled.walk(["commandLine": "seqkit seq /node/a.fq"], ["commandLine": "seqkit seq /mac//Users/a.fq"], path: ["sidecar", "step"])
        let slash = doubled.findings.first { $0.why.contains("//") }
        XCTAssertNotNil(slash, doubled.findings.description)
        XCTAssertEqual(slash?.raw?.mac, "\"seqkit seq /mac//Users/a.fq\"")
    }

    /// AMV1 QA fix 3 (XC-6 B) as C4-4 D-1 amends it: V15-16 and V15-17 test that each listed key is present on the route that
    /// must carry it and never compare a value. The peak memory is the adopt route's to carry and the Mac records none (Phase 2.7
    /// P4), so a key the adopt route has and the Mac lacks gives no finding, a Mac step that carries it fails (QA Q4-1), and an
    /// adopted step that lacks it while the Mac carries it fails. Stderr is the Mac's to carry, and the names only the run record
    /// holds are free.
    func testPeakMemoryAndStderrMustBePresentOnTheRoutesThatCarryThem() {
        let path = ["envelope", "steps[fastp#1]"]
        let none = [String: Any]()
        var adoptedOnly = V15Comparison(roots: [:], payloadFileNames: [])
        adoptedOnly.walk(["peakMemoryBytes": 1], none, path: path)
        XCTAssertEqual(adoptedOnly.findings.map(\.description), [], "the adopted route carries it and the Mac records none")

        var macCarries = V15Comparison(roots: [:], payloadFileNames: [])
        macCarries.walk(["peakMemoryBytes": 1], ["peakMemoryBytes": 2], path: path)
        XCTAssertEqual(macCarries.findings.count, 1, macCarries.findings.description)
        XCTAssertTrue(macCarries.findings.first?.why.contains("must be absent on the mac route") == true, macCarries.findings.description)

        var adoptedLacks = V15Comparison(roots: [:], payloadFileNames: [])
        adoptedLacks.walk(none, ["peakMemoryBytes": 2], path: path)
        XCTAssertTrue(adoptedLacks.findings.contains { $0.why.contains("must be present on the adopted route") }, adoptedLacks.findings.description)

        var macStderr = V15Comparison(roots: [:], payloadFileNames: [])
        macStderr.walk(["stderr": "node text"], none, path: path)
        XCTAssertEqual(macStderr.findings.count, 1, macStderr.findings.description)
        XCTAssertTrue(macStderr.findings.first?.why.contains("must be present on the mac route") == true, macStderr.findings.description)

        var adoptedWithout = V15Comparison(roots: [:], payloadFileNames: [])
        adoptedWithout.walk(none, ["stderr": "mac text"], path: path)
        XCTAssertEqual(adoptedWithout.findings.map(\.description), [])

        var nodeOnly = V15Comparison(roots: [:], payloadFileNames: [])
        nodeOnly.walk(["peakResidentBytes": 1, "stderrTail": "x", "stderrTruncated": false, "stderrBytes": 1], none, path: path)
        XCTAssertEqual(nodeOnly.findings.map(\.description), [])
    }

    /// SW4-2, UX U4-1, BIO B-D1-1: the walk reaches a key only when one route holds it, so a paired adopted step with no
    /// `peakMemoryBytes` (the Mac has none either) is found in `compareStep`: one finding that names V15-16 and the adopted
    /// route. The key on the adopted step alone gives none, and a peak of 0 is no peak.
    func testPeakMemoryRequiredOnAdoptedStepOnly() {
        let roles = V15StepRoles.mac([], importToolName: "lungfish import fastq")
        let step: [String: Any] = ["toolVersion": "1.3.6"]
        func findings(adopted: [String: Any], mac: [String: Any]) -> [V15Finding] {
            var comparison = V15Comparison(roots: [:], payloadFileNames: [])
            comparison.compareStep(adopted, mac, label: "fastp#1", adoptedRoles: roles, macRoles: roles)
            return comparison.findings.filter { $0.key.hasSuffix("peakMemoryBytes") }
        }
        func carrying(_ value: Any) -> [String: Any] {
            var carried = step
            carried["peakMemoryBytes"] = value
            return carried
        }
        XCTAssertEqual(findings(adopted: carrying(4_690_345_984), mac: step).map(\.description), [])
        let removed = findings(adopted: step, mac: step)
        XCTAssertEqual(removed.count, 1, removed.description)
        XCTAssertEqual(removed.first?.key, "envelope.steps[fastp#1].peakMemoryBytes")
        XCTAssertTrue(removed.first?.why.contains("V15-16") == true && removed.first?.why.contains("adopted") == true, removed.description)
        XCTAssertEqual(findings(adopted: carrying(0), mac: step).count, 1, "a peak of 0 is no peak")
    }

    /// CH-8 and W0: `peakWorkRootBytes` is held by the node's run record only, a node-only row in XC-6 B's run-varying class. It
    /// on the adopted route alone passes, and a node-only key the list does not name still fails.
    func testPeakWorkRootBytesIsAListedNodeOnlyRunVaryingKey() {
        let path = ["envelope", "steps[clumpify.sh#1]", "storage"]
        var listed = V15Comparison(roots: [:], payloadFileNames: [])
        listed.walk(["peakWorkRootBytes": 8_388_608], [String: Any](), path: path)
        XCTAssertEqual(listed.findings.map(\.description), [])
        var unlisted = V15Comparison(roots: [:], payloadFileNames: [])
        unlisted.walk(["peakWorkRootBytesPlanted": 8_388_608], [String: Any](), path: path)
        XCTAssertEqual(unlisted.findings.count, 1, unlisted.findings.description)
        let line = V15ParityList.lines.first { $0.patterns.contains("**.peakWorkRootBytes") }
        XCTAssertEqual(line?.n9Class, 4)
        XCTAssertTrue(line?.decision.contains("CH-8") == true, line?.decision ?? "no line")
    }

    /// AMV1 BIO fix 3 (XC-9, QA ruling 3 condition 1): only `file` is skipped, so a value column that maps to no key of the
    /// Mac's sidecar is read from a seqkit row of the Mac's payload. A changed `Q3`, or any other unmapped column, gives one
    /// finding named `statistics.<column>`, two tables that differ only in `file` give none, and a column the sidecar keys
    /// map (Q2) is left to the sidecar comparison.
    func testParityFailsOnPlantedUnmappedStatisticsColumn() {
        let columns = ["file", "format", "type", "num_seqs", "sum_len", "min_len", "avg_len", "max_len", "Q1", "Q2", "Q3", "sum_gap",
                       "N50", "N50_num", "Q20(%)", "Q30(%)", "AvgQual", "GC(%)", "sum_n"]
        let values = ["FASTQ", "DNA", "2", "20", "10", "10.0", "10", "10", "10", "10", "0", "10", "1", "95.00", "91.00", "40.00", "50.00", "0"]
        func table(file: String, changing column: String? = nil, to value: String = "") -> String {
            let row = [file] + zip(columns.dropFirst(), values).map { $0 == column ? value : $1 }
            return columns.joined(separator: "\t") + "\n" + row.joined(separator: "\t") + "\n"
        }
        let mac = table(file: "/project/Imports/S.lungfishfastq/S.fastq.gz")
        XCTAssertEqual(V15Statistics.compareTables(standardOutput: table(file: "out/S.fastq.gz"), macTable: mac).map(\.description), [])

        let q3 = V15Statistics.compareTables(standardOutput: table(file: "out/S.fastq.gz", changing: "Q3", to: "11"), macTable: mac)
        XCTAssertEqual(q3.map(\.key), ["statistics.Q3"], q3.description)
        XCTAssertEqual(q3.first?.adopted, "11")
        XCTAssertEqual(q3.first?.mac, "10")

        for column in ["format", "type", "Q1", "sum_gap", "N50_num", "sum_n"] {
            let planted = V15Statistics.compareTables(standardOutput: table(file: "out/S.fastq.gz", changing: column, to: "9"), macTable: mac)
            XCTAssertEqual(planted.map(\.key), ["statistics.\(column)"], column)
        }
        let mapped = V15Statistics.compareTables(standardOutput: table(file: "out/S.fastq.gz", changing: "Q2", to: "9"), macTable: mac)
        XCTAssertEqual(mapped.map(\.description), [], "Q2 is compared against the sidecar's medianReadLength")
        let noRow = V15Statistics.compareTables(standardOutput: table(file: "out/S.fastq.gz"), macTable: "")
        XCTAssertEqual(noRow.map(\.key), ["statistics.macTable"], "an empty Mac table is a finding and never a pass")
    }

    /// ARCH-X3 R-1 (V15-27): the CHTC image holds every tool at `/opt/lge/env/bin/<tool>`, so the writer's id is the linux-64
    /// lock entry that lists the program and pins the version and build the node read from the image manifest, and the harness
    /// reads that lock file itself. The envs-only rule failed a correct `htslib` there. A wrong id, a missing id, a build the
    /// lock does not pin and a version that is a plan pin are findings still.
    func testV15_27AcceptsLinuxLockEntryOnImagePath() {
        func typed(_ value: String) -> [String: Any] { ["type": "string", "value": value] }
        func tool(build: String, source: String) -> [String: Any] {
            ["type": "dictionary", "value": ["id": typed("bgzip"), "version": typed("1.24"), "build": typed(build), "versionSource": typed(source)]]
        }
        func adopted(_ id: String?, build: String = "ha79157c_0", source: String = "imageManifest") -> [String: Any] {
            var step: [String: Any] = ["toolVersion": "1.24", "argv": ["/opt/lge/env/bin/bgzip", "-@", "1"],
                                       "resolvedOptions": ["tool": tool(build: build, source: source)]]
            if let id { step["managedToolID"] = id }
            return step
        }
        let mac: [String: Any] = ["toolVersion": "1.24", "argv": ["/Users/x/.lungfish/conda/envs/htslib/bin/bgzip", "-@", "1"],
                                  "managedToolID": "htslib"]
        let roles = V15StepRoles.mac([], importToolName: "lungfish import fastq")
        func findings(_ adoptedStep: [String: Any]) -> [V15Finding] {
            var comparison = V15Comparison(roots: [:], payloadFileNames: [])
            comparison.compareStep(adoptedStep, mac, label: "bgzip#1", adoptedRoles: roles, macRoles: roles)
            return comparison.findings.filter { $0.why.contains("V15-27") }
        }
        XCTAssertEqual(findings(adopted("htslib")).map(\.description), [], "the image's bgzip 1.24 ha79157c_0 is the htslib entry")
        let wrong = findings(adopted("bbtools"))
        XCTAssertEqual(wrong.count, 1, wrong.description)
        XCTAssertTrue(wrong.first?.why.contains("adopted") == true, wrong.description)
        let absent = findings(adopted(nil))
        XCTAssertFalse(absent.isEmpty, "a step with no managedToolID is a finding")
        XCTAssertTrue(absent.allSatisfy { $0.why.contains("adopted") }, absent.description)
        XCTAssertFalse(findings(adopted("htslib", build: "h0000000_0")).isEmpty, "a build the lock does not pin names no entry")
        XCTAssertFalse(findings(adopted("htslib", source: "planPin")).isEmpty, "a plan pin is the plan's word, not what the node read")
    }

    /// BIOQA-X1 R1 (V15-29): a returned folder holds no R1, so the adopt keeps the plan's platform and states the inference as
    /// not run (confidence none, the one not-inferred sentence, 0 sampled records) while the Mac infers it from 32 reads. The
    /// seven keys of V15-29 pass in that one shape and print as PARITY-REPORTED, equal inferred values pass, any other adopted
    /// value or a Mac without the key is one finding, and the keys beside them (source, platform, vendorDetail) stay compared.
    func testAdoptedNotInferredPlatformIsTheOnlyPlatformDifference() {
        typealias Records = (env: [String: Any], side: [String: Any])
        let notInferred = "The returned folder holds no reads, so the platform was not inferred from them."
        func typed(_ type: String, _ value: Any) -> [String: Any] { ["type": type, "value": value] }
        func records(_ confidence: String?, _ evidence: [String], sampled: Int, source: String = "given",
                     platform: String = "illumina", vendor: String? = nil) -> Records {
            var options: [String: Any] = ["platformEvidence": typed("array", evidence.map { typed("string", $0) })]
            var assignment: [String: Any] = ["platform": platform, "readClass": "illuminaShortReads", "source": source,
                                             "evidence": evidence, "sampledRecords": sampled, "detectorVersion": 1]
            if let confidence {
                options["platformConfidence"] = typed("string", confidence)
                assignment["confidence"] = confidence
            }
            if let vendor { assignment["vendorDetail"] = vendor }
            return (["options": ["explicit": options, "resolvedDefaults": options]], ["platformAssignment": assignment])
        }
        func compare(_ adopted: Records, _ mac: Records) -> V15Comparison {
            var comparison = V15Comparison(roots: [:], payloadFileNames: [])
            comparison.walk(adopted.env, mac.env, path: ["envelope"])
            comparison.walk(adopted.side, mac.side, path: ["sidecar"])
            return comparison
        }
        let given = records("none", [notInferred], sampled: 0)
        let highEvidence = ["Illumina read names (original names kept by ENA or SRA) in 32 of 32 sampled reads.",
                            "Sampled reads are 151 bases long."]
        let high = records("high", highEvidence, sampled: 32)
        let low = records("low", ["The read headers match no known platform form (32 reads sampled).", "Sampled reads are 151 bases long.",
                                  "Read names carry no instrument tag."], sampled: 32)

        // 1. The adopt's not-inferred values against the Mac's inferred forms (S10): no finding, seven V15-29 lines each.
        for (form, mac) in [("high, 2 evidence lines", high), ("low, 3 evidence lines", low)] {
            let found = compare(given, mac)
            XCTAssertEqual(found.findings.count, 0, "\(form): \(found.findings.count) findings: \(found.findings.map(\.key))")
            XCTAssertEqual(found.reported.filter { $0.contains("line=V15-29") }.count, 7, "\(form): \(found.reported)")
        }
        let line = V15ParityList.lines.first { $0.id == "V15-29" }
        XCTAssertEqual(line?.n9Class, 3, "V15-29 is a class 3 line")
        XCTAssertEqual(line?.patterns.count, 7, "seven patterns cover the ten differing keys")

        // 2. Equal inferred values pass.
        XCTAssertEqual(compare(high, high).findings.map(\.key), [])

        // 3. One V15-29 finding each.
        let changed: [(String, Records, Records, String)] = [
            ("adopted low", (given.env, records("low", [notInferred], sampled: 0).side), high, "sidecar.platformAssignment.confidence"),
            ("a changed sentence", (given.env, records("none", ["The returned folder holds no reads."], sampled: 0).side), high,
             "sidecar.platformAssignment.evidence"),
            ("adopted sampledRecords 1", (given.env, records("none", [notInferred], sampled: 1).side), high,
             "sidecar.platformAssignment.sampledRecords"),
            ("a Mac without confidence", given, (high.env, records(nil, highEvidence, sampled: 32).side),
             "sidecar.platformAssignment.confidence"),
        ]
        for (what, adopted, mac, key) in changed {
            let found = compare(adopted, mac)
            XCTAssertEqual(found.findings.map(\.key), [key], what)
            XCTAssertTrue(found.findings.first?.why.contains("V15-29") == true, "\(what): \(found.findings)")
        }

        // 4. The keys beside them stay compared: one finding each, and none of them V15-29's.
        let others: [(String, Records, Records, String)] = [
            ("source given against inferred", given, records("high", highEvidence, sampled: 32, source: "inferred"),
             "sidecar.platformAssignment.source"),
            ("platform illumina against unknown", given, records("high", highEvidence, sampled: 32, platform: "unknown"),
             "sidecar.platformAssignment.platform"),
            ("vendorDetail absent against a PacBio detail", given, records("high", highEvidence, sampled: 32, vendor: "PacBio Revio"),
             "sidecar.platformAssignment.vendorDetail"),
        ]
        for (what, adopted, mac, key) in others {
            let found = compare(adopted, mac)
            XCTAssertEqual(found.findings.map(\.key), [key], what)
            XCTAssertFalse(found.findings.first?.why.contains("V15-29") == true, "\(what): \(found.findings)")
        }
    }

    /// BIOQA-X1 R2 (V15-30): above 1 clumpify group the stored order can differ between two imports of one sample, so the checksum of
    /// that launch's output and of the writer's input, the same two files in the run's files and outputs, and the three distributions
    /// drawn from the first 100,000 stored reads print as PARITY-REPORTED. They do so only with E2 and E3 equal and E4 different (S1),
    /// the same group count launch by launch with one above 1 (S2), an equal size beside each checksum (S3) and equal sampled counts
    /// (S4). Every other key stays compared, and so does a value that is no stored-order difference: a null checksum, an empty or
    /// wrong-kind distribution (BIO 4, BIO 6) and any other key of an entry whose digest is excused (X1F review fixes 1 and 2).
    func testStoredOrderLinesPassOnlyAboveOneGroupWithEqualE2AndE3() {
        struct Case {
            var adoptedGroups = [13, 1], macGroups = [13, 1]
            var e4Differs = true
            var macClumpedSize = 448, macSampledExtra = 0, macReadCount = 1000
            var adoptedUnpaired = "unpaired", macUnpaired = "unpaired"
            /// The Mac's pairs.clumped.fastq digest is a JSON null in the step, files and outputs entries.
            var macClumpedDigestNull = false
            /// The adopted qualityScoreHistogram is an empty list.
            var adoptedQualityEmpty = false
            /// The format of the Mac's pairs.clumped.fastq entry in the step, files and outputs.
            var macFormat = "fastq"
        }
        let importTool = "lungfish import fastq"
        func entry(_ role: String, _ name: String, _ digest: Any, _ size: Int, format: String = "fastq") -> [String: Any] {
            ["role": role, "path": "split/" + name, "checksumSHA256": digest, "fileSize": size, "format": format]
        }
        func records(adopted: Bool, _ c: Case) -> (envelope: [String: Any], steps: [[String: Any]], sidecar: [String: Any]) {
            let prefix = adopted ? "A" : "M"
            let groups = adopted ? c.adoptedGroups : c.macGroups
            var clumpedDigest: Any = adopted ? "pairs-a" : "pairs-m"
            if !adopted, c.macClumpedDigestNull { clumpedDigest = NSNull() }
            let clumped = entry("output", "pairs.clumped.fastq", clumpedDigest, adopted ? 448 : c.macClumpedSize,
                                format: adopted ? "fastq" : c.macFormat)
            let unpaired = entry("output", "unpaired.clumped.fastq", adopted ? c.adoptedUnpaired : c.macUnpaired, 257)
            let combined = entry("input", "combined.fastq", adopted ? "combined-a" : "combined-m", 705)
            func step(_ number: Int, _ tool: String, groups: Int? = nil, inputs: [[String: Any]] = [],
                      outputs: [[String: Any]] = []) -> [String: Any] {
                var object: [String: Any] = ["id": "\(prefix)\(number)", "toolName": tool, "toolVersion": "1.0",
                                             "inputs": inputs, "outputs": outputs]
                if number > 0 { object["parentStepID"] = "\(prefix)0" }
                if let groups { object["resolvedOptions"] = ["clumpifyGroups": ["type": "integer", "value": groups]] }
                if adopted { object["peakMemoryBytes"] = 1 }
                if tool == "bgzip" {
                    object["argv"] = ["/n/envs/htslib/bin/bgzip"]
                    object["managedToolID"] = "htslib"
                }
                return object
            }
            var steps = [step(0, adopted ? ExecutorRunAdoption.executorToolName : importTool),
                         step(1, "clumpify.sh", groups: groups[0], outputs: [clumped]),
                         step(2, "clumpify.sh", groups: groups[1], outputs: [unpaired]),
                         step(3, "bgzip", inputs: [combined])]
            if adopted { steps.append(step(4, importTool)) }
            let lengths: [String: Any] = adopted ? ["100": 60, "101": 40] : ["100": 55, "101": 45 + c.macSampledExtra]
            let statistics: [String: Any] = [
                "readCount": adopted ? 1000 : c.macReadCount, "readLengthHistogram": lengths,
                "qualityScoreHistogram": adopted && c.adoptedQualityEmpty ? [Int]() : [0, adopted ? 5 : 6, 13, 7],
                "perPositionQuality": [["position": 0, "mean": adopted ? 35.3 : 35.2]],
            ]
            let envelope: [String: Any] = ["steps": steps, "files": [clumped, unpaired, combined], "outputs": [clumped, unpaired]]
            return (envelope, steps, ["computedStatistics": statistics])
        }
        func run(_ change: (inout Case) -> Void = { _ in }) -> V15Comparison {
            var c = Case()
            change(&c)
            let adopted = records(adopted: true, c), mac = records(adopted: false, c)
            var comparison = V15Comparison(roots: [:], payloadFileNames: [])
            comparison.storedOrder.e4Differs = c.e4Differs
            comparison.compareEnvelopes(
                adopted: adopted.envelope, mac: mac.envelope,
                adoptedRoles: V15StepRoles.adopted(adopted.steps, executorToolName: ExecutorRunAdoption.executorToolName,
                                                   adoptToolName: importTool, nodeKinds: []),
                macRoles: V15StepRoles.mac(mac.steps, importToolName: importTool))
            comparison.compareSidecars(adopted: adopted.sidecar, mac: mac.sidecar)
            return comparison
        }
        func printed(_ comparison: V15Comparison) -> [String] { comparison.reported.filter { $0.contains("line=V15-30") } }

        // S1 to S4 met: the step checksums, the files and outputs entries and the three distributions print, and nothing is a finding.
        let met = run()
        XCTAssertEqual(met.findings.map(\.key), [], met.findings.description)
        XCTAssertEqual(printed(met).count, 8, printed(met).description)

        let checksum = "envelope.steps[clumpify.sh#1].outputs[0].checksumSHA256"
        let writer = "envelope.steps[bgzip#1].inputs[0].checksumSHA256"
        let lengths = "sidecar.computedStatistics.readLengthHistogram.100"
        func failing(_ what: String, expect keys: [String], printed count: Int, _ change: (inout Case) -> Void) {
            let found = run(change)
            let got = Set(found.findings.map(\.key))
            for key in keys { XCTAssertTrue(got.contains(key), "\(what): no finding for \(key) in \(got.sorted())") }
            XCTAssertEqual(printed(found).count, count, "\(what): \(printed(found))")
        }
        failing("1 and 1 groups", expect: [checksum, writer, lengths], printed: 0) { $0.adoptedGroups = [1, 1]; $0.macGroups = [1, 1] }
        failing("equal E4", expect: [checksum, writer, lengths], printed: 0) { $0.e4Differs = false }
        failing("13 against 11", expect: [checksum, writer, lengths], printed: 0) { $0.macGroups = [11, 1] }
        failing("a changed size", expect: [checksum, "envelope.steps[clumpify.sh#1].outputs[0].fileSize"], printed: 5) { $0.macClumpedSize = 449 }
        failing("unequal sampled counts", expect: ["sidecar.computedStatistics.readLengthHistogram.101"], printed: 5) { $0.macSampledExtra = 1 }
        failing("a changed readCount", expect: ["sidecar.computedStatistics.readCount"], printed: 8) { $0.macReadCount = 1001 }
        failing("a 1-group checksum", expect: ["envelope.steps[clumpify.sh#2].outputs[0].checksumSHA256"], printed: 8) { $0.macUnpaired = "other" }

        // A missing fact is no stored-order difference (X1F review fix 1; BIO 4, BIO 6): a null Mac checksum loses the step's line and
        // the two entries' lines, an empty adopted distribution loses its own line, and each is a finding.
        failing("a null Mac checksum", expect: [checksum], printed: 5) { $0.macClumpedDigestNull = true }
        failing("an empty adopted qualityScoreHistogram", expect: ["sidecar.computedStatistics.qualityScoreHistogram"], printed: 7) {
            $0.adoptedQualityEmpty = true
        }

        // The entries whose digest is excused keep every other key compared (X1F review fix 2): the digests still print, 8 lines, and a
        // different format is a finding in the run's files and outputs as it is in the step.
        failing("another key of an excused entry", expect: [
            "envelope.files[output split/pairs.clumped.fastq].format", "envelope.outputs[output split/pairs.clumped.fastq].format",
            "envelope.steps[clumpify.sh#1].outputs[0].format",
        ], printed: 8) { $0.macFormat = "fasta" }
    }
}
