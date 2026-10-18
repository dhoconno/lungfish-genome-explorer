// VCFImportHelperRealToolTests.swift - The per-chromosome VCF import with the real managed bcftools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import os
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishApp

/// The one test of `VCFImportHelperToolProcessTests` that needs the real
/// managed bcftools (Phase 2.2 lane 5C, finding R7). It sits in the
/// tool-conformance selection so the unit tier keeps the fake-script tests.
final class VCFImportHelperRealToolTests: VCFImportHelperSubprocessTestCase {
    /// The real per-chromosome pass, with the real managed bcftools and the
    /// built app as its child helper, builds the database a direct import of
    /// the same chromosome builds.
    func testPerChromosomeImportWithRealBcftoolsMatchesADirectImport() throws {
        let lungfish = try builtLungfishExecutable()
        let condaRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda")
        guard FileManager.default.isExecutableFile(atPath: condaRoot.appendingPathComponent("envs/bcftools/bin/bcftools").path) else {
            try ToolAvailability.skipOrFail("The managed bcftools of ~/.lungfish is required")
        }
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")

        let result = try runHelperSubprocess(
            lungfish: lungfish, argv0: lungfish.path, condaRoot: condaRoot,
            arguments: ["--vcf-path", input.path, "--output-db-path", output.path, "--import-profile", "ultra-low-memory"]
        )
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("\"variantCount\":9"), result.stdout)
        XCTAssertEqual(try metadataValue(output, key: "import_partition_mode"), "helper-subprocess-per-chromosome")

        let direct = tempDirectory.appendingPathComponent("direct.db")
        _ = try VCFBundleVariantImport.createDatabase(
            vcfURL: fixtures.appendingPathComponent("test.vcf.gz"), outputDBURL: direct,
            sourceFile: input.lastPathComponent, importProfile: .ultraLowMemory, onlyChromosome: "MT192765.1"
        )
        XCTAssertEqual(try Self.dump(output), try Self.dump(direct))
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path + ".csi"), "The source index the helper made is removed")
    }

    /// Ruling ARCH-12.07-partition, step 1 (BIO). The helper sequence the Import Center ran at the ultra-low-memory
    /// profile, the split and then the resume and materialize modes on its database, against `import vcf` on the same
    /// VCF. The split imports only the first 512 contigs its header lists, so it holds 6 of the 8 records, and on `c1`
    /// to `c3` both build the same rows, compared by each variant's natural key. The class goes with the helper.
    @MainActor
    func testTheSplitAndImportVCFBuildTheSameRowsUnderTheContigCap() async throws {
        let lungfish = try builtLungfishExecutable()
        let condaRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda")
        guard FileManager.default.isExecutableFile(atPath: condaRoot.appendingPathComponent("envs/bcftools/bin/bcftools").path) else {
            try ToolAvailability.skipOrFail("The managed bcftools of ~/.lungfish is required")
        }
        let vcf = try VCFImportModesPinTests.writeContigCapVCF(in: tempDirectory)
        let viaHelper = tempDirectory.appendingPathComponent("helper.db")
        let result = try runHelperSubprocess(
            lungfish: lungfish, argv0: lungfish.path, condaRoot: condaRoot,
            arguments: [
                "--vcf-path", vcf.path, "--output-db-path", viaHelper.path,
                "--source-file", vcf.lastPathComponent, "--import-profile", "ultra-low-memory",
            ]
        )
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertEqual(try metadataValue(viaHelper, key: "import_partition_mode"), "helper-subprocess-per-chromosome")
        if VariantDatabase.importState(at: viaHelper) == "indexing" {
            XCTAssertEqual(try runHelperInProcess(arguments: ["Lungfish", "--vcf-resume-helper", "--output-db-path", viaHelper.path]), 0)
        }
        XCTAssertEqual(try runHelperInProcess(arguments: ["Lungfish", "--vcf-materialize-helper", "--output-db-path", viaHelper.path]), 0)

        let bundle = try VCFImportModesPinTests.contigCapBundle(in: tempDirectory)
        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--import-profile", "ultra-low-memory"],
            in: tempDirectory
        )
        XCTAssertNil(run.failure)
        let published = bundle.appendingPathComponent("variants/contigs.db")
        XCTAssertEqual(try Self.rows(viaHelper, "SELECT COUNT(*) FROM variants", quoted: false), ["6"])
        XCTAssertEqual(try Self.rows(published, "SELECT COUNT(*) FROM variants", quoted: false), ["8"])
        for query in VCFImportModesPinTests.naturalKeyQueries(chromosomes: ["c1", "c2", "c3"]) {
            let rows = try Self.rows(viaHelper, query)
            XCTAssertFalse(rows.isEmpty, query)
            XCTAssertEqual(rows, try Self.rows(published, query), query)
        }
    }
}
