// MergedRecipeSliceConformanceTests.swift - The merged recipe's fused fastp call on the C079876 slice
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Freezes ruling BIO-PRESET's preset E on the 1,000,000-pair slice of C079876_S1 that lanes C0-M1 and the ruling
// measured: at one thread the fused call keeps 869,933 pairs and 242,843,520 bases, and two runs there were
// byte-identical. The flags come from the planner, so the test follows the recipe file. It needs the real fastp and
// the slice on this Mac, so a missing tool or slice is a skip, and LUNGFISH_REQUIRE_TOOLS=1 makes either a failure.
// The class name holds Conformance, so the unit tier never runs it.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class MergedRecipeSliceConformanceTests: XCTestCase {
    private static let sliceFolder = URL(fileURLWithPath: "/Users/dho/Documents/lungfish-chtc-testing/32748")

    func test_vsp2PresetFusedCallOnSliceAtOneThread() async throws {
        let fastp = try await ToolAvailability.require("fastp", environment: "fastp")
        let r1 = Self.sliceFolder.appendingPathComponent("C079876_S1_1M_R1.fastq.gz")
        let r2 = Self.sliceFolder.appendingPathComponent("C079876_S1_1M_R2.fastq.gz")
        guard FileManager.default.isReadableFile(atPath: r1.path),
              FileManager.default.isReadableFile(atPath: r2.path) else {
            try ToolAvailability.skipOrFail("The C079876 1M slice is not at \(Self.sliceFolder.path)")
        }

        let recipe = try XCTUnwrap(try RecipeResolver.resolve("vsp2", in: RecipeRegistryV2.builtinRecipes()))
        let plan = try RecipeEngine().plan(recipe: recipe, inputFormat: .pairedR1R2)
        guard case .fusedFastp(let flags, _, _, _) = plan.first else {
            return XCTFail("The vsp2 preset starts with one fused fastp call, got \(String(describing: plan.first))")
        }

        let tmp = try ConformanceFixtures.tempDir("merged-recipe-slice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let report = tmp.appendingPathComponent("fastp.json")
        let argv = [
            "-i", r1.path, "-I", r2.path,
            "-o", tmp.appendingPathComponent("out_R1.fq.gz").path,
            "-O", tmp.appendingPathComponent("out_R2.fq.gz").path,
        ] + flags + ["-w", "1", "-j", report.path, "-h", "/dev/null"]
        let run = try ProcessRunner.run(fastp, argv)
        XCTAssertEqual(run.status, 0, run.stderr)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        let after = try XCTUnwrap((json["summary"] as? [String: Any])?["after_filtering"] as? [String: Any])
        let reads = try XCTUnwrap(after["total_reads"] as? Int)
        let bases = try XCTUnwrap(after["total_bases"] as? Int)
        XCTAssertEqual(reads, 2 * 869_933, "pairs kept at -w 1")
        XCTAssertEqual(bases, 242_843_520, "bases kept at -w 1")
    }
}
