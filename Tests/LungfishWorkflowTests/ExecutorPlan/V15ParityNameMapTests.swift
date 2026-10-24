// V15ParityNameMapTests.swift - C4-3 C-2: the names XC-10's one strip function maps, each at its anchor only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation

/// XC-10 B as amended by C4-3 C-2 (QA Q-2a to Q-2f, ARCH A-C2-1 to A-C2-4, SWIFT, BIO B3-4 to B3-6, CHTC CH-C2-1).
final class V15ParityNameMapTests: XCTestCase {
    private let returned = "/r/wastewater-metagenomics/plan"
    private let scratch = "/p/Project.lungfish/.tmp/fastq-import-F7496D2A-0762-44D6-BADE-06B95B9BA4A8"
    private let mates = ["581aa5a8cd55", "a0b163cdf6d1"]
    private let reportUUID = "E4179EEA-3EBC-4157-A740-94D976E7F09B"

    private var nodeNames: V15RouteNames {
        V15RouteNames(stem: "sample", workFolder: "work", inputs: V15RouteNames.mates(
            ["inputs/R1.fastq.gz": mates[0], "inputs/R2.fastq.gz": mates[1]], plan: mates))
    }

    private var macNames: V15RouteNames {
        V15RouteNames(stem: "C079876_S1", reportUUID: true, inputs: V15RouteNames.mates(
            ["<external>/C079876_S1_1M_R1.fastq.gz": mates[0], "<external>/C079876_S1_1M_R2.fastq.gz": mates[1]], plan: mates))
    }

    private func node(_ token: String) -> String { V15Comparison.stripRoot(token, roots: [returned], names: nodeNames) }
    private func mac(_ token: String) -> String { V15Comparison.stripRoot(token, roots: [scratch], names: macNames) }

    private func argvFindings(adopted: [String], mac macArgv: [String]) -> [V15Finding] {
        var comparison = V15Comparison(roots: [.adopted: [returned], .mac: [scratch]], payloadFileNames: [])
        comparison.names = [.adopted: nodeNames, .mac: macNames]
        comparison.walk(adopted, macArgv, path: ["envelope", "steps[fastp#1]", "argv"])
        return comparison.findings
    }

    /// QA Q-2f, ARCH A-C2-4, CHTC CH-C2-1, BIO B3-6: the work stem, the node's `work/` folder and the Mac's report UUID
    /// map to one token, and everything after the stem still compares, so the mate stays compared.
    func testStripMapsStemWorkFolderAndReportUUID() {
        XCTAssertEqual(node("work/sample_fused_R1.fq.gz"), mac("\(scratch)/C079876_S1_fused_R1.fq.gz"))
        XCTAssertEqual(node("work/sample_fused_R1.fq.gz"), "<work-stem>_fused_R1.fq.gz")
        XCTAssertNotEqual(node("work/sample_fused_R1.fq.gz"), mac("\(scratch)/C079876_S1_fused_R2.fq.gz"))
        XCTAssertEqual(node("work/sample_fused_fastp_report.json"),
                       mac("\(scratch)/C079876_S1_fused_fastp_report_\(reportUUID).json"))
        // Another sample's stem stays byte for byte and fails.
        XCTAssertEqual(mac("\(scratch)/C079876_S2_fused_R1.fq.gz"), "C079876_S2_fused_R1.fq.gz")
        XCTAssertEqual(mac("\(scratch)/C079877_S1_fused_R1.fq.gz"), "C079877_S1_fused_R1.fq.gz")
        // A UUID outside a fastp report name stays.
        XCTAssertEqual(mac("\(scratch)/C079876_S1_\(reportUUID).fq.gz"), "<work-stem>_\(reportUUID).fq.gz")
        XCTAssertEqual(mac("\(scratch)/C079876_S1_summary_\(reportUUID).json"), "<work-stem>_summary_\(reportUUID).json")
        // The node's names carry no report UUID, so a UUID in a node report name stays.
        XCTAssertEqual(node("work/sample_fused_fastp_report_\(reportUUID).json"), "<work-stem>_fused_fastp_report_\(reportUUID).json")
    }

    /// QA Q-2f, BIO B3-5 and B3-6, ARCH A-C2-2: inputs map to their mate by digest, never by name, and a swap fails.
    func testInputTokensPairByDigest() {
        XCTAssertEqual(node("inputs/R1.fastq.gz"), "<input:R1>")
        XCTAssertEqual(mac("<external>/C079876_S1_1M_R1.fastq.gz"), "<input:R1>")
        XCTAssertEqual(mac("<external>/C079876_S1_1M_R2.fastq.gz"), "<input:R2>")
        XCTAssertEqual(node("\(returned)/inputs/R2.fastq.gz"), "<input:R2>")
        let nodeArgv = ["/env/fastp", "-i", "inputs/R1.fastq.gz", "-I", "inputs/R2.fastq.gz", "-o", "work/sample_fused_R1.fq.gz"]
        let inOrder = ["/env/fastp", "-i", "<external>/C079876_S1_1M_R1.fastq.gz", "-I", "<external>/C079876_S1_1M_R2.fastq.gz",
                       "-o", "\(scratch)/C079876_S1_fused_R1.fq.gz"]
        XCTAssertEqual(argvFindings(adopted: nodeArgv, mac: inOrder).count, 0)
        var swapped = inOrder
        swapped.swapAt(2, 4)
        XCTAssertEqual(argvFindings(adopted: nodeArgv, mac: swapped).count, 1, "R1 and R2 swapped on one route fail")
        // An input of a third digest maps to nothing.
        let third = V15RouteNames(stem: "C079876_S1", inputs: V15RouteNames.mates(["<external>/other.fastq.gz": "ffff"], plan: mates))
        XCTAssertEqual(V15Comparison.stripRoot("<external>/other.fastq.gz", roots: [], names: third), "<external>/other.fastq.gz")
    }

    /// QA Q-2f: flags and key=value tokens come out unchanged.
    func testStripRewritesNoFlagOrValue() {
        for token in ["-Xmx4g", "threads=1", "zl=4", "-w", "1", "sample", "C079876_S1", "interleaved=t", "--merge"] {
            XCTAssertEqual(node(token), token)
            XCTAssertEqual(mac(token), token)
        }
    }

    /// SWIFT C-2: a stem maps only as the whole leading part of the last component followed by `_`, `work/` only as a
    /// node token's first folder, and a sample named `R1` or `sample` changes nothing else.
    func testStripMapsWorkStemOnlyAtItsAnchor() {
        let r1 = V15RouteNames(stem: "R1")
        XCTAssertEqual(V15Comparison.stripRoot("R1_fused_R1.fq.gz", roots: [], names: r1), "<work-stem>_fused_R1.fq.gz")
        XCTAssertEqual(V15Comparison.stripRoot("x_R1_fused.fq.gz", roots: [], names: r1), "x_R1_fused.fq.gz")
        XCTAssertEqual(V15Comparison.stripRoot("inputs/R1.fastq.gz", roots: [], names: r1), "inputs/R1.fastq.gz")
        XCTAssertEqual(node("work/presample_fused.fq.gz"), "presample_fused.fq.gz")
        XCTAssertEqual(node("out/work/sample_x.fq.gz"), "out/work/<work-stem>_x.fq.gz")
        XCTAssertEqual(mac("work/sample_fused_R1.fq.gz"), "work/sample_fused_R1.fq.gz", "the Mac route holds no work folder or node stem")
    }

    /// SWIFT C-2, QA Q-2e: an input whose digest matches no mate, or a run whose mates share a digest, maps to nothing.
    func testStripRefusesInputWithNoMatchingDigest() {
        XCTAssertEqual(V15RouteNames.mates(["inputs/R1.fastq.gz": "ffff"], plan: mates), [:])
        XCTAssertEqual(V15RouteNames.mates(["inputs/R1.fastq.gz": "aaaa", "inputs/R2.fastq.gz": "aaaa"], plan: ["aaaa", "aaaa"]), [:])
        let names = V15RouteNames(stem: "sample", workFolder: "work")
        XCTAssertEqual(V15Comparison.stripRoot("inputs/R1.fastq.gz", roots: [], names: names), "inputs/R1.fastq.gz")
        XCTAssertNotEqual(V15Comparison.stripRoot("inputs/R1.fastq.gz", roots: [], names: names), mac("<external>/C079876_S1_1M_R1.fastq.gz"))
    }
}
