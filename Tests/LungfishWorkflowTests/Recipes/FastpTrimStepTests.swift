// FastpTrimStepTests.swift - The fastp argv of the merged recipe's trim and dedup steps (ruling BIO-PRESET P1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Runs the merged recipe's fastp steps against a stand-in fastp that records nothing but its outputs, and reads the
/// argv the step records back. The real-tool run on the C079876 slice is `MergedRecipeSliceConformanceTests`.
final class FastpTrimStepTests: XCTestCase {

    /// The flags ruling BIO-PRESET P1 names for the trim, every value written out.
    static let ruledTrimFlags = [
        "--detect_adapter_for_pe", "-g", "--poly_g_min_len", "10",
        "-q", "15", "-u", "40", "-n", "5", "-l", "15", "-W", "5", "--cut_tail", "-M", "20",
    ]

    func test_mergedRecipeFusedArgv() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let (r1, r2) = try writePairedFASTQ(in: root)
        let preset = try XCTUnwrap(try RecipeResolver.resolve("vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes()))
        let fastpSteps = Array(preset.activeSteps.prefix(2))
        XCTAssertEqual(fastpSteps.map(\.type), ["fastp-dedup", "fastp-trim"])

        let result = try await RecipeEngine().execute(
            recipe: Recipe(id: "fused-argv", name: "Fused argv", requiredInput: .paired, steps: fastpSteps),
            input: StepInput(r1: r1, r2: r2, format: .pairedR1R2),
            context: StepContext(
                workspace: workspace, threads: 1, sampleName: "sample",
                runner: try makeFakeFastpRunner(in: root), progress: { _, _ in }
            )
        )

        let step = try XCTUnwrap(result.stepRecords.first)
        XCTAssertEqual(result.stepRecords.count, 1, "The dedup and trim steps run as one fastp call")
        let arguments = try XCTUnwrap(step.commandArguments)
        let start = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        let argv = Array(arguments[start...])
        guard argv.count > 8 else { return XCTFail("argv too short: \(argv)") }
        let report = try XCTUnwrap(step.auxiliaryOutputPaths.first)
        XCTAssertTrue(argv[5].hasSuffix("sample_fused_R1.fq.gz"), argv[5])
        XCTAssertTrue(argv[7].hasSuffix("sample_fused_R2.fq.gz"), argv[7])
        XCTAssertEqual(resolved(argv[1]), resolved(r1.path))
        XCTAssertEqual(resolved(argv[3]), resolved(r2.path))
        XCTAssertEqual(
            argv,
            ["-i", argv[1], "-I", argv[3], "-o", argv[5], "-O", argv[7],
             "--dedup", "--dup_calc_accuracy", "3"] + Self.ruledTrimFlags
                + ["-w", "1", "-j", report, "-h", "/dev/null"]
        )
    }

    func test_keptDuplicatesTrimRunsAloneWithItsReport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (r1, r2) = try writePairedFASTQ(in: root)
        let kept = try XCTUnwrap(try RecipeResolver.resolve(
            "vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes(), switchOptions: ["removeDuplicates": false]
        ))
        let trimStep = try XCTUnwrap(kept.activeSteps.first)
        XCTAssertEqual(trimStep.type, "fastp-trim")
        let plan = try RecipeEngine().plan(recipe: kept, inputFormat: .pairedR1R2)
        guard case .singleStep(let executor, _) = plan.first else {
            return XCTFail("A run that keeps duplicates runs the trim alone, got \(String(describing: plan.first))")
        }
        let trim = try XCTUnwrap(executor as? FastpTrimStep)

        let output = try await trim.execute(
            input: StepInput(r1: r1, r2: r2, format: .pairedR1R2),
            context: StepContext(
                workspace: root, threads: 1, sampleName: "sample",
                runner: try makeFakeFastpRunner(in: root), progress: { _, _ in }
            )
        )

        let arguments = try XCTUnwrap(output.arguments)
        let start = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        let flags = Array(arguments[(start + 8)...].prefix(Self.ruledTrimFlags.count))
        XCTAssertEqual(flags, Self.ruledTrimFlags)
        XCTAssertFalse(arguments.contains("--dedup"))
        let reportIndex = try XCTUnwrap(arguments.firstIndex(of: "-j"))
        XCTAssertNotEqual(arguments[reportIndex + 1], "/dev/null")
        XCTAssertEqual(output.auxiliaryOutputs.map(\.path), [arguments[reportIndex + 1]])
        XCTAssertEqual(output.inputReadCount, 3, "pairs read, from the report")
        XCTAssertEqual(output.readCount, 2, "pairs written, from the report")
    }

    func test_olderTrimParamsKeepTheirArgv() throws {
        let step = try FastpTrimStep(params: ["quality": .int(15), "window": .int(5), "cutMode": .string("right")])
        XCTAssertEqual(step.fastpArgs(), ["--detect_adapter_for_pe", "-q", "15", "-W", "5", "--cut_right"])
    }

    func test_qualifiedQualityBeatsQuality() throws {
        let step = try FastpTrimStep(params: ["quality": .int(30), "qualifiedQuality": .int(15)])
        XCTAssertEqual(step.quality, 15)
    }

    func test_outOfRangeWindowQualityIsRefused() {
        XCTAssertThrowsError(try FastpTrimStep(params: ["cutMeanQuality": .int(0)]))
        XCTAssertThrowsError(try FastpTrimStep(params: ["unqualifiedPercent": .int(101)]))
    }

    func test_dedupAloneTurnsOtherProcessingOff() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (r1, r2) = try writePairedFASTQ(in: root)

        let output = try await FastpDedupStep(params: nil).execute(
            input: StepInput(r1: r1, r2: r2, format: .pairedR1R2),
            context: StepContext(
                workspace: root, threads: 1, sampleName: "sample",
                runner: try makeFakeFastpRunner(in: root), progress: { _, _ in }
            )
        )

        let arguments = try XCTUnwrap(output.arguments)
        let start = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertEqual(
            Array(arguments[(start + 8)...].prefix(7)), ["--dedup", "--dup_calc_accuracy", "3", "-A", "-G", "-Q", "-L"]
        )
    }

    // MARK: - Helpers

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastpTrimStepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePairedFASTQ(in directory: URL) throws -> (r1: URL, r2: URL) {
        let r1 = directory.appendingPathComponent("sample_R1.fastq")
        let r2 = directory.appendingPathComponent("sample_R2.fastq")
        try "@pair1/1\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@pair1/2\nTGCA\n+\nIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        return (r1, r2)
    }

    /// A stand-in fastp under a temporary home that copies its inputs to its outputs and writes a report that
    /// read 3 pairs and wrote 2.
    private func makeFakeFastpRunner(in homeDirectory: URL) throws -> NativeToolRunner {
        let executableDirectory = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/fastp/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("fastp")
        let report = #"{"summary":{"before_filtering":{"total_reads":6},"after_filtering":{"total_reads":4}},"#
            + #""read1_before_filtering":{"total_reads":3},"read1_after_filtering":{"total_reads":2}}"#
        let script = """
        #!/bin/sh
        set -eu
        if [ "${1:-}" = "--version" ]; then
          echo "fastp 1.3.6"
          exit 0
        fi
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -i) in_r1="$2"; shift 2 ;;
            -I) in_r2="$2"; shift 2 ;;
            -o) out_r1="$2"; shift 2 ;;
            -O) out_r2="$2"; shift 2 ;;
            -j) report="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        /usr/bin/gzip -c "$in_r1" > "$out_r1"
        /usr/bin/gzip -c "$in_r2" > "$out_r2"
        printf '%s\\n' '\(report)' > "$report"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory, appIdentity: .preview)
    }
}
