// RecipeEngineArgvFreezeTests.swift - The in-process argv of the two parity recipes, frozen as literals (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow

extension RecipeEngineTests {
    /// QA fix 1 of the K4 part A review: the whole argv of each in-process tool run of `vsp2-target-enrichment` and
    /// `wastewater-metagenomics`, at threads 1 and sample `sample`, against literals. The plan and the in-process run
    /// share one builder per step, so only literals see a change inside a builder. The deacon scrub reads a stand-in
    /// index under an id the bundled lock does not hold, as the plan emitter's parity test does.
    func testInProcessRecipeArgvMatchesFrozenLiterals() async throws {
        let root = try TestTempDirectory.make(prefix: "RecipeArgvFreeze")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("pair", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pair = [folder.appendingPathComponent("S_R1.fastq"), folder.appendingPathComponent("S_R2.fastq")]
        try "@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: pair[0], atomically: true, encoding: .utf8)
        try "@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n".write(to: pair[1], atomically: true, encoding: .utf8)
        var indexes: [String: URL] = [:]
        for (id, name) in [("test-panhuman", "panhuman-1.k31w15.idx"), ("deacon-ribokmers", "ribokmers.k31w15.idx")] {
            let databaseFolder = root.appendingPathComponent("databases/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: databaseFolder, withIntermediateDirectories: true)
            let index = databaseFolder.appendingPathComponent(name)
            try Data("deacon index \(id)".utf8).write(to: index)
            indexes[id] = index
        }
        let runner = try RecipeToolFakes.runner(root: root)
        let builtin = RecipeRegistryV2.builtinRecipes()
        for (name, expected) in Self.frozenArgv {
            var merged = try XCTUnwrap(RecipeResolver.resolve(name, in: builtin), name)
            for index in merged.steps.indices where merged.steps[index].type == "deacon-scrub" {
                merged.steps[index].params?["database"] = .string("test-panhuman")
            }
            let (input, work) = try RecipeToolFakes.layOutWorkRoot(root: root, pair)
            let result = try await RecipeEngine().execute(
                recipe: merged, input: input,
                context: StepContext(workspace: work, threads: 1, sampleName: "sample", runner: runner,
                                     databasePaths: indexes, progress: { _, _ in })
            )
            XCTAssertEqual(RecipeToolFakes.recordedArguments(result, root: root), expected, name)
        }
    }

    /// Taken from the in-process run of this test at the K4 head 9918341d7, whose step sources M2 left byte equal to
    /// the inline argv they replaced (ARCH review of K4 part A, fix 2). The fused fastp flags come from the bundled
    /// recipe file.
    private static let fusedFastp = [
        "-i", "inputs/R1.fastq", "-I", "inputs/R2.fastq", "-o", "work/sample_fused_R1.fq.gz", "-O", "work/sample_fused_R2.fq.gz",
        "--dedup", "--dup_calc_accuracy", "3", "--detect_adapter_for_pe", "-g", "--poly_g_min_len", "10", "-q", "15",
        "-u", "40", "-n", "5", "-l", "15", "-W", "5", "--cut_tail", "-M", "20", "-w", "1",
        "-j", "work/sample_fused_fastp_report.json", "-h", "/dev/null",
    ]
    private static let scrub = [
        "filter", "-d", "databases/test-panhuman/panhuman-1.k31w15.idx", "work/sample_fused_R1.fq.gz", "work/sample_fused_R2.fq.gz",
        "-o", "work/sample_scrubbed_R1.fq.gz", "-O", "work/sample_scrubbed_R2.fq.gz",
        "--summary", "work/sample_deacon_summary.json", "-t", "1",
    ]
    private static let riboFilter = [
        "filter", "--deplete", "-a", "1", "-r", "0.0", "databases/deacon-ribokmers/ribokmers.k31w15.idx",
        "work/sample_scrubbed_R1.fq.gz", "work/sample_scrubbed_R2.fq.gz",
        "-o", "work/sample_norrna_R1.fastq.gz", "-O", "work/sample_norrna_R2.fastq.gz",
        "--summary", "work/sample_deacon_ribo_summary.json", "-t", "1",
    ]
    private static func merge(_ r1: String, _ r2: String) -> [String] {
        [
            "-i", r1, "-I", r2, "--merge", "--merged_out", "work/sample_merged.fq.gz",
            "--out1", "work/sample_unmerged_R1.fq.gz", "--out2", "work/sample_unmerged_R2.fq.gz",
            "--overlap_len_require", "15", "-A", "-G", "-Q", "-L", "-w", "1",
            "-j", "work/sample_merge_fastp_report.json", "-h", "/dev/null",
        ]
    }
    private static let lengthFilterMerged = [
        "seq", "-j", "1", "-m", "50", "work/sample_merged.fq.gz", "-o", "work/sample_lengthfilter_merged.fq.gz",
    ]
    private static let lengthFilterPairs = [
        "-i", "work/sample_unmerged_R1.fq.gz", "-I", "work/sample_unmerged_R2.fq.gz",
        "-o", "work/sample_lengthfilter_unmerged_R1.fq.gz", "-O", "work/sample_lengthfilter_unmerged_R2.fq.gz",
        "-A", "-G", "-Q", "-l", "50", "-w", "1",
        "-j", "work/sample_lengthfilter_unmerged_fastp_report.json", "-h", "/dev/null",
    ]
    private static let frozenArgv: [(String, [[String]])] = [
        ("vsp2-target-enrichment", [
            fusedFastp, scrub, merge("work/sample_scrubbed_R1.fq.gz", "work/sample_scrubbed_R2.fq.gz"),
            lengthFilterMerged, lengthFilterPairs,
        ]),
        ("wastewater-metagenomics", [
            fusedFastp, scrub, riboFilter, merge("work/sample_norrna_R1.fastq.gz", "work/sample_norrna_R2.fastq.gz"),
            lengthFilterMerged, lengthFilterPairs,
        ]),
    ]
}
