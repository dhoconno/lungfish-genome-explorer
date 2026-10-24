// V15ParityComparisonTests.swift - The V15 comparison's roots, typed options and command lines (CHTC C4 lane A, QA-V15lines)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation

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
}
