// NextflowViralReconFitTests.swift - Viral Recon's launch from its descriptor against NFCoreRunRequest (N12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (panel N12, API brief risk 6), and Phase 2.10 lane A30 M2 (N1). `lungfish-cli workflow run`
// launches Viral Recon with this descriptor's argv, from the launch `NFCoreRunRequest.viralReconLaunch(samplesheet:
// configFiles:)` builds for the run's request. These tests show that the launch fits, by building the same arguments
// and the same environment as the request for the pinned release and a picked one. The request writes the work
// folder before the profile and sorts every parameter by name, `--input` and `--outdir` among them, which TaxTriage's
// order does not fit, so the descriptor names that order as its argument layout and the launch request can resume.
// The launch takes one samplesheet by type, so it writes one `--input` where the request writes none without input
// and joins several with commas (fit difference 1), and it writes the resource-limit config with `-c` before `run`
// (fit difference 2). Pure, so it runs in the unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class NextflowViralReconFitTests: XCTestCase {
    private let descriptor = NextflowWorkflowDescriptor.viralRecon
    private let samplesheet = URL(fileURLWithPath: "/Volumes/Lab Drive/run.lungfishrun/inputs/samplesheet.csv")
    private let output = URL(fileURLWithPath: "/Volumes/Lab Drive/Analyses/viralrecon-2026-10-12", isDirectory: true)
    private let work = URL(fileURLWithPath: "/private/tmp/nfcore-run-abc/work", isDirectory: true)

    /// Parameters whose names sort before `input`, between `input` and `outdir`, and after `outdir`, with one empty
    /// value that the request leaves out.
    private let params = [
        "platform": "illumina", "protocol": "amplicon", "genome": "MN908947.3",
        "primer_set": "artic", "primer_set_version": "3", "kraken2_db": "/db/kraken2/host",
        "nextclade_dataset": "", "skip_assembly": "true",
    ]

    private func viralRecon() throws -> NFCoreSupportedWorkflow {
        try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
    }

    /// The launch `workflow run` builds for `request`, whose one input is the samplesheet the command passes.
    private func launch(for request: NFCoreRunRequest) throws -> NextflowLaunchRequest {
        XCTAssertEqual(request.inputURLs.count, 1, "workflow run passes one samplesheet")
        return request.viralReconLaunch(samplesheet: try XCTUnwrap(request.inputURLs.first))
    }

    func testTheDescriptorBuildsTheRequestsArgumentsForThePinnedRelease() throws {
        let workflow = try viralRecon()
        let pin = try descriptor.resolveBundledPin()
        var cases = 0
        for version in ["", pin.revision] {
            for resume in [false, true] {
                for workDirectory in [nil, work] as [URL?] {
                    let request = NFCoreRunRequest(
                        workflow: workflow, version: version, executor: .docker, inputURLs: [samplesheet],
                        outputDirectory: output, params: params, resume: resume, workDirectory: workDirectory)
                    XCTAssertEqual(request.version, pin.revision, "an empty version is the pinned release")
                    XCTAssertEqual(try launch(for: request).target, .pinned(pin), "the lock's pin")
                    XCTAssertEqual(
                        descriptor.nextflowArguments(for: try launch(for: request)),
                        request.nextflowArguments,
                        "version '\(version)', resume \(resume), work \(workDirectory?.path ?? "none")")
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, 8)
    }

    /// Risk 6 of the API brief. In TaxTriage's order the same words come out in another order, even with the
    /// workflow's options sorted as the request sorts them, so Viral Recon's descriptor names a layout of its own.
    func testTaxTriagesOrderGivesTheRequestsWordsInAnotherOrder() throws {
        let workflow = try viralRecon()
        let inTaxTriagesOrder = NextflowWorkflowDescriptor(
            toolID: descriptor.toolID, lockPipelineID: descriptor.lockPipelineID, profile: descriptor.profile,
            containerRuntime: descriptor.containerRuntime, releaseEnvironment: descriptor.releaseEnvironment,
            parameterSchemaPath: descriptor.parameterSchemaPath,
            workDirectoryOption: descriptor.workDirectoryOption, traceFileName: descriptor.traceFileName,
            argumentLayout: .inputFirst,
            scratchPrefix: descriptor.scratchPrefix, keepWorkEnvironmentKey: descriptor.keepWorkEnvironmentKey,
            expectedTaskCountPerSample: descriptor.expectedTaskCountPerSample,
            finalizeProgressShare: descriptor.finalizeProgressShare)
        let request = NFCoreRunRequest(
            workflow: workflow, version: "", executor: .docker, inputURLs: [samplesheet],
            outputDirectory: output, params: params, workDirectory: work)
        var sortedLaunch = try launch(for: request)
        sortedLaunch.pipelineArguments = request.effectiveParams.keys
            .filter { $0 != "input" && $0 != "outdir" }
            .sorted()
            .flatMap { name -> [String] in
                guard let value = request.effectiveParams[name], !value.isEmpty else { return [] }
                return ["--\(name)", value]
            }
        let arguments = inTaxTriagesOrder.nextflowArguments(for: sortedLaunch)

        XCTAssertNotEqual(arguments, request.nextflowArguments)
        XCTAssertEqual(arguments.sorted(), request.nextflowArguments.sorted())
    }

    func testTheSortedLayoutPutsTheWorkFolderFirstAndSortsInputAndOutdirAmongTheParameters() throws {
        let pin = try descriptor.resolveBundledPin()
        let launch = NextflowLaunchRequest(
            target: .pinned(pin),
            samplesheet: samplesheet,
            outputDirectory: output,
            workDirectory: work,
            pipelineArguments: ["--platform", "illumina", "--genome", "MN908947.3", "--kraken2_db", "/db/kraken2/host"])
        XCTAssertEqual(descriptor.nextflowArguments(for: launch), [
            "run", pin.repository, "-r", pin.revision,
            "-work-dir", work.path,
            "-profile", "docker",
            "--genome", "MN908947.3",
            "--input", samplesheet.path,
            "--kraken2_db", "/db/kraken2/host",
            "--outdir", output.path,
            "--platform", "illumina",
        ])
    }

    /// The executor is the request's profile, so the launch's own profile carries it, and a release the user picks
    /// is a pin with that revision.
    func testEveryExecutorAndAPickedReleaseFitThroughTheLaunchsProfileAndPin() throws {
        let workflow = try viralRecon()
        let bundled = try descriptor.resolveBundledPin()
        let picked = NextflowPipelinePin(
            pipelineID: bundled.pipelineID, repository: bundled.repository, revision: "3.0.1", releaseVersion: "3.0.1")
        for executor in [NFCoreExecutor.docker, .conda, .local] {
            let request = NFCoreRunRequest(
                workflow: workflow, version: "3.0.1", executor: executor, inputURLs: [samplesheet],
                outputDirectory: output, params: params, workDirectory: work)
            let built = try launch(for: request)
            XCTAssertEqual(built.target, .pinned(picked), executor.rawValue)
            XCTAssertEqual(built.profile, executor.rawValue)
            XCTAssertEqual(descriptor.nextflowArguments(for: built), request.nextflowArguments, executor.rawValue)
        }
    }

    /// Fit differences 1 and 2 closed (Phase 2.10 N1). The launch writes the one samplesheet it is given as
    /// `--input` whatever inputs the request holds, and its `-c` files before `run`. Given the request's one
    /// samplesheet, the words after the `-c` files are the request's own.
    func testTheLaunchWritesOneSamplesheetAndItsConfigFilesBeforeRun() throws {
        let workflow = try viralRecon()
        let config = work.deletingLastPathComponent().appendingPathComponent("lungfish-resource-limits.config")
        let other = URL(fileURLWithPath: "/Volumes/Lab Drive/other.lungfishrun/inputs/samplesheet.csv")
        for inputs in [[], [samplesheet], [samplesheet, other]] {
            let request = NFCoreRunRequest(
                workflow: workflow, version: "", executor: .docker, inputURLs: inputs,
                outputDirectory: output, params: params, resume: true, workDirectory: work)
            let arguments = descriptor.nextflowArguments(
                for: request.viralReconLaunch(samplesheet: samplesheet, configFiles: [config]))
            let written = arguments.indices.filter { arguments[$0] == "--input" }.map { arguments[$0 + 1] }
            XCTAssertEqual(written, [samplesheet.path], "\(inputs.count) inputs")
            XCTAssertEqual(Array(arguments.prefix(4)), ["-c", config.path, "run", workflow.fullName])
            if inputs == [samplesheet] {
                XCTAssertEqual(Array(arguments.dropFirst(2)), request.nextflowArguments)
            }
        }
    }

    func testTheDescriptorSetsTheRequestsEnvironmentForEachRelease() throws {
        let workflow = try viralRecon()
        let pin = try descriptor.resolveBundledPin()
        for version in ["", pin.revision] {
            let request = NFCoreRunRequest(
                workflow: workflow, version: version, executor: .docker, inputURLs: [samplesheet],
                outputDirectory: output)
            XCTAssertEqual(descriptor.launchEnvironment(for: pin), request.launchEnvironment, "version '\(version)'")
        }

        // The release the override is for, and one it is not for, whatever the lock pins.
        for release in ["3.0.0", "3.1.0"] {
            let releasePin = NextflowPipelinePin(
                pipelineID: pin.pipelineID, repository: pin.repository, revision: release, releaseVersion: release)
            let request = NFCoreRunRequest(
                workflow: workflow, version: release, executor: .docker, inputURLs: [samplesheet],
                outputDirectory: output)
            XCTAssertEqual(descriptor.launchEnvironment(for: releasePin), request.launchEnvironment, release)
        }
        let tagged = NextflowPipelinePin(
            pipelineID: pin.pipelineID, repository: pin.repository, revision: "3.0.0", releaseVersion: "3.0.0")
        XCTAssertEqual(descriptor.launchEnvironment(for: tagged), ["NXF_SYNTAX_PARSER": "v1"])
    }
}
