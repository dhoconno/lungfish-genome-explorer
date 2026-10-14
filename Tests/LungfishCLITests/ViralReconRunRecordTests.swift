// ViralReconRunRecordTests.swift - What a launched Viral Recon run records against what its engine ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B31. Each run goes through `workflow run nf-core/viralrecon` in process on
// `ViralReconLaunchedRun.Runner`, which records the launch the engine got and writes Nextflow's own debug log in
// the launch folder, so every record fact can be checked against the launch it describes.

import Foundation
import LungfishCore
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ViralReconRunRecordTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-run-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Q33 fix 8 (BIO 4, ARCH 2). The run bundle's manifest records the command the engine launched, the resource-limit
    /// `-c` file and the work folder among it, and not the `--max_cpus` and `--max_memory` that the launch turns into
    /// `process.resourceLimits` and never passes.
    func testTheManifestRecordsTheCommandTheEngineLaunched() async throws {
        let run = try await ViralReconLaunchedRun.run(in: root)
        let launch = try XCTUnwrap(run.runner.launches.first, "the run launched nothing")
        let manifest = try NFCoreRunBundleStore.read(from: run.bundle)
        XCTAssertEqual(manifest.commandPreview, (["nextflow"] + launch.arguments).map(shellEscape).joined(separator: " "))
        XCTAssertFalse(manifest.commandPreview.contains("--max_cpus"), manifest.commandPreview)
        XCTAssertTrue(manifest.commandPreview.contains("lungfish-resource-limits.config"), manifest.commandPreview)
        XCTAssertEqual(manifest.params["max_cpus"], "2", "the limits the user chose stay among the parameters")
    }
}
