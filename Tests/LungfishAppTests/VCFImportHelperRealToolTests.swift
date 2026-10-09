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
}
