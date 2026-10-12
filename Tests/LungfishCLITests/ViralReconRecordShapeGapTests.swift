// ViralReconRecordShapeGapTests.swift - What Viral Recon's record holds against the one Nextflow record shape
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B11, milestone M2, ruling N12. Decision R1 gives every Nextflow step one shape, the pipeline id at its
// revision with the release tag beside it, and `pipelineSource` and `nextflowVersion` among its resolved options
// (`NextflowRecordFacts`). In 2.9 only TaxTriage writes it. These tests state Viral Recon's gaps against that shape and
// the profile, parameter and input rows of the panel's BIO mapping, each as today's fact, and change nothing in it.
// Viral Recon's move onto the shape in Phase 2.10 flips them.

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ViralReconRecordShapeGapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-record-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// N12, declared gaps. The record's one step is LGE's `lungfish-cli workflow run` at LGE's version, where the shape
    /// has the lock's pipeline id `nf-core-viralrecon` at the pinned revision. The release tag is the step's
    /// `githubReleaseVersion`, as the shape has it, and a run parameter, and the step's resolved options hold no
    /// `nextflowVersion` and no `pipelineSource`. A kept log gives a Nextflow 26 version only when the workflow's own
    /// code prints one, as TaxTriage's does, so Viral Recon's move needs a version source of its own.
    func testViralReconRecordsTheCommandWhereTheShapeHasThePipelineAtItsRevision() async throws {
        let pin = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let shape = NextflowRecordFacts(pin: pin, pipelineSource: .remote)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nP,/tmp/P_R1.fastq.gz,/tmp/P_R2.fastq.gz\n"
            .write(to: samplesheet, atomically: true, encoding: .utf8)
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        try await RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", root.appendingPathComponent("results", isDirectory: true).path,
            "--bundle-path", runBundle.path,
            "--version", pin.releaseVersion,
            "--prepare-only",
            "--quiet",
        ]).run()

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: runBundle))
        XCTAssertEqual(record.steps.count, 1)
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(shape.toolName, "nf-core-viralrecon")
        XCTAssertEqual(step.toolName, "lungfish-cli workflow run", "gap, the step is LGE's command")
        XCTAssertNotEqual(step.toolName, shape.toolName)
        XCTAssertEqual(step.toolVersion, LungfishCLI.configuration.version, "gap, the version is LGE's")
        XCTAssertNotEqual(step.toolVersion, shape.toolVersion)
        XCTAssertEqual(step.githubReleaseVersion, shape.githubReleaseVersion, "the tag, as the shape has it")
        XCTAssertEqual(record.options.explicit["github_release_version"], .string(pin.releaseVersion))
        XCTAssertNil(step.resolvedOptions["nextflowVersion"], "gap, no Nextflow version")
        XCTAssertNil(step.resolvedOptions["pipelineSource"], "gap, no pipeline source")
        XCTAssertEqual(record.options.explicit["executor"], .string("docker"), "gap, the profile is recorded only as the executor")
        XCTAssertNil(record.options.explicit["profile"], "gap, no profile")
        XCTAssertEqual(record.options.resolvedDefaults, [:], "gap, every value is an explicit option, with no home for what LGE passed unasked")
        XCTAssertEqual(step.inputs.count, 1, "gap, the samplesheet is the one input with a digest, and the FASTQs it names are not inputs")
    }
}
