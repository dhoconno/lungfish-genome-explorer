// NextflowWorkflowDescriptorTests.swift - The Nextflow workflow descriptor's lock pin, refusal and two instances
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (panel N4). A descriptor takes a workflow's repository, commit and tag only from the lock,
// and a lock with no pin refuses the workflow with UX's words and exit 126 instead of running a fallback revision.
// Each damaged lock here is a copy of the bundled one with its pipelines changed, so the bundled lock stays
// untouched. The instance tests hold each fact the two descriptors state to the code that launches the workflow
// today. Pure apart from one scratch folder in the system temporary folder, so it runs in the unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class NextflowWorkflowDescriptorTests: XCTestCase {
    private func lock(_ lock: ManagedToolLock, pipelines: [PipelineSpec]) -> ManagedToolLock {
        ManagedToolLock(
            packID: lock.packID, displayName: lock.displayName, version: lock.version,
            tools: lock.tools, managedData: lock.managedData,
            packTools: lock.packTools, pipelines: pipelines)
    }

    private func bundledLock(without id: String) throws -> ManagedToolLock {
        let bundled = try ManagedToolLock.loadFromBundle()
        return lock(bundled, pipelines: bundled.pipelines.filter { $0.id != id })
    }

    /// The refusal `body` throws, after failing the test when it resolves a pin or throws another error.
    private func expectRefusal(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> NextflowPipelinePin
    ) -> NextflowDescriptorRefusal? {
        do {
            let pin = try body()
            XCTFail("Resolved \(pin) instead of refusing", file: file, line: line)
        } catch let refusal as NextflowDescriptorRefusal {
            return refusal
        } catch {
            XCTFail("Threw \(error) instead of a NextflowDescriptorRefusal", file: file, line: line)
        }
        return nil
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - The lock's pin

    func testEachDescriptorTakesItsPinFromTheLockUnchanged() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        for descriptor in [NextflowWorkflowDescriptor.taxTriage, .viralRecon] {
            let spec = try XCTUnwrap(bundled.pipeline(id: descriptor.lockPipelineID), descriptor.lockPipelineID)
            let pin = try descriptor.resolvePin(in: bundled)
            XCTAssertEqual(
                pin,
                NextflowPipelinePin(
                    pipelineID: spec.id, repository: spec.repository,
                    revision: spec.revision, releaseVersion: spec.releaseVersion))
            XCTAssertEqual(pin, NextflowPipelinePin(spec))
            XCTAssertEqual(try descriptor.resolveBundledPin(), pin, "`.bundled` is the lock file")
        }
    }

    /// With the bundled lock the descriptor resolves the pin today's builders read, so moving a caller onto it
    /// changes no run.
    func testTheBundledPinIsThePinTodaysBuildersRead() throws {
        let taxTriage = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        XCTAssertEqual(taxTriage.repository, TaxTriageConfig.pipelineRepository)
        XCTAssertEqual(taxTriage.revision, TaxTriageConfig.defaultRevision)
        XCTAssertEqual(taxTriage.releaseVersion, TaxTriageConfig.defaultGithubReleaseVersion)

        let viralRecon = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        XCTAssertEqual(viralRecon.repository, workflow.fullName)
        XCTAssertEqual(viralRecon.revision, workflow.pinnedVersion)
    }

    // MARK: - Refusal (N4)

    func testALockWithNoTaxTriagePinRefusesWithTheN4WordsAndExit126() throws {
        let damaged = try bundledLock(without: "taxtriage")
        XCTAssertNil(damaged.pipeline(id: "taxtriage"))

        let refusal = try XCTUnwrap(expectRefusal { try NextflowWorkflowDescriptor.taxTriage.resolvePin(in: damaged) })
        XCTAssertEqual(refusal.message, "LGE's tool lock has no pinned version of TaxTriage, so LGE will not run it.")
        XCTAssertEqual(refusal.errorDescription, refusal.message)
        XCTAssertEqual(refusal.analysisRunExitCode, 126)
        XCTAssertEqual(refusal, .noPinnedVersion(of: "TaxTriage"))

        // The executor reads a plan refusal's exit code through the protocol, as it reads Kraken2's.
        let thrown: any Error = refusal
        XCTAssertEqual((thrown as? any AnalysisRunExitCoding)?.analysisRunExitCode, 126)
        XCTAssertEqual(NextflowDescriptorRefusal.dependencyCode, Kraken2RunRefusal.dependencyCode)
    }

    func testALockWithNoViralReconPinRefusesWithItsNameAndKeepsTheOtherPin() throws {
        let damaged = try bundledLock(without: "nf-core-viralrecon")

        let refusal = expectRefusal { try NextflowWorkflowDescriptor.viralRecon.resolvePin(in: damaged) }
        XCTAssertEqual(
            refusal,
            NextflowDescriptorRefusal(
                message: "LGE's tool lock has no pinned version of Viral Recon, so LGE will not run it.",
                analysisRunExitCode: 126))
        XCTAssertEqual(
            try NextflowWorkflowDescriptor.taxTriage.resolvePin(in: damaged),
            try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())
    }

    func testAnEntryWithNoRevisionOrNoRepositoryIsNoPin() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(bundled.pipeline(id: "taxtriage"))
        let others = bundled.pipelines.filter { $0.id != "taxtriage" }
        let blanks = [
            PipelineSpec(id: "taxtriage", repository: spec.repository, revision: "", releaseVersion: spec.releaseVersion),
            PipelineSpec(id: "taxtriage", repository: spec.repository, revision: " \n", releaseVersion: spec.releaseVersion),
            PipelineSpec(id: "taxtriage", repository: "", revision: spec.revision, releaseVersion: spec.releaseVersion),
        ]
        for blank in blanks {
            let damaged = lock(bundled, pipelines: others + [blank])
            let refusal = expectRefusal { try NextflowWorkflowDescriptor.taxTriage.resolvePin(in: damaged) }
            XCTAssertEqual(refusal, .noPinnedVersion(of: "TaxTriage"), "\(blank)")
        }
    }

    // MARK: - Release environment

    func testTheReleaseEnvironmentIsKeyedOnThePinnedReleaseTag() {
        func pin(revision: String, release: String) -> NextflowPipelinePin {
            NextflowPipelinePin(
                pipelineID: "nf-core-viralrecon", repository: "nf-core/viralrecon",
                revision: revision, releaseVersion: release)
        }
        let viralRecon = NextflowWorkflowDescriptor.viralRecon
        XCTAssertEqual(viralRecon.launchEnvironment(for: pin(revision: "3.0.0", release: "3.0.0")), ["NXF_SYNTAX_PARSER": "v1"])
        // A commit of release 3.0.0 carries the tag's defect, so the release tag keys the setting and `-r` does not.
        XCTAssertEqual(viralRecon.launchEnvironment(for: pin(revision: "0123abc", release: "3.0.0")), ["NXF_SYNTAX_PARSER": "v1"])
        XCTAssertEqual(viralRecon.launchEnvironment(for: pin(revision: "3.1.0", release: "3.1.0")), [:])
    }

    func testTheBundledPinsGetTheEnvironmentTodaysLaunchesSet() throws {
        let viralReconPin = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        XCTAssertEqual(
            NextflowWorkflowDescriptor.viralRecon.launchEnvironment(for: viralReconPin),
            workflow.launchEnvironment(forVersion: viralReconPin.revision))

        let taxTriagePin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        XCTAssertEqual(NextflowWorkflowDescriptor.taxTriage.launchEnvironment(for: taxTriagePin), [:])
    }

    // MARK: - The instances state today's facts

    func testTaxTriageStatesTheFactsItsPipelineLaunchesWith() throws {
        let descriptor = NextflowWorkflowDescriptor.taxTriage
        XCTAssertEqual(descriptor.toolID, .taxtriage)
        XCTAssertEqual(descriptor.lockPipelineID, "taxtriage")
        XCTAssertEqual(descriptor.containerRuntime, .docker)
        XCTAssertEqual(descriptor.releaseEnvironment, [:])
        XCTAssertNil(descriptor.parameterSchemaPath)
        XCTAssertNil(descriptor.expectedTaskCountPerSample, "W2, no count keeps the engine's estimate")
        XCTAssertEqual(descriptor.finalizeProgressShare, 0.1, "W3")

        let output = URL(fileURLWithPath: "/tmp/lungfish-descriptor/out", isDirectory: true)
        let work = URL(fileURLWithPath: "/tmp/lungfish-descriptor/work", isDirectory: true)
        let config = TaxTriageConfig(samples: [], outputDirectory: output)
        XCTAssertEqual(descriptor.profile, config.profile)

        let pipeline = TaxTriagePipeline()
        let args = pipeline.buildNextflowArguments(
            config: config,
            pipelineLaunchTarget: TaxTriageConfig.pipelineRepository,
            pipelineRevision: TaxTriageConfig.defaultRevision,
            workDirectory: work)
        XCTAssertEqual(value(after: "-profile", in: args), descriptor.profile)
        XCTAssertEqual(value(after: descriptor.workDirectoryOption, in: args), work.path)
        let traceFileName = try XCTUnwrap(descriptor.traceFileName)
        XCTAssertEqual(value(after: "-with-trace", in: args), output.appendingPathComponent(traceFileName).path)

        XCTAssertEqual(descriptor.keepWorkEnvironmentKey, TaxTriagePipeline.keepWorkEnvironmentKey)
        let scratch = try pipeline.makeLocalLaunchScratch(
            contextURL: FileManager.default.temporaryDirectory,
            volumeQualifiesForScratch: false)
        defer { try? FileManager.default.removeItem(at: scratch.launchDirectory) }
        XCTAssertTrue(
            scratch.launchDirectory.lastPathComponent.hasPrefix(descriptor.scratchPrefix),
            scratch.launchDirectory.lastPathComponent)
    }

    func testViralReconStatesTheFactsItsCommandLaunchesWith() throws {
        let descriptor = NextflowWorkflowDescriptor.viralRecon
        XCTAssertEqual(descriptor.toolID, .viralrecon)
        XCTAssertEqual(descriptor.lockPipelineID, "nf-core-viralrecon")
        XCTAssertEqual(descriptor.containerRuntime, .docker)
        XCTAssertEqual(descriptor.parameterSchemaPath, "nextflow_schema.json")
        XCTAssertNil(descriptor.traceFileName)
        XCTAssertEqual(descriptor.scratchPrefix, "nfcore-run-")
        XCTAssertNil(descriptor.keepWorkEnvironmentKey)
        XCTAssertNil(descriptor.expectedTaskCountPerSample)
        XCTAssertEqual(descriptor.finalizeProgressShare, 0)

        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let work = URL(fileURLWithPath: "/tmp/lungfish-descriptor/work", isDirectory: true)
        let request = NFCoreRunRequest(
            workflow: workflow, version: "", executor: .docker, inputURLs: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/lungfish-descriptor/out", isDirectory: true),
            workDirectory: work)
        XCTAssertNoThrow(try request.validateExecutorSupported())
        XCTAssertEqual(descriptor.profile, NFCoreExecutor.docker.rawValue)
        XCTAssertEqual(value(after: "-profile", in: request.nextflowArguments), descriptor.profile)
        XCTAssertEqual(value(after: descriptor.workDirectoryOption, in: request.nextflowArguments), work.path)
        XCTAssertFalse(descriptor.releaseEnvironment.isEmpty)
        for (release, environment) in descriptor.releaseEnvironment {
            XCTAssertEqual(workflow.launchEnvironment(forVersion: release), environment, release)
        }
    }

    // MARK: - Launch types

    func testALaunchRequestStartsWithNoConfigFilesNoWorkFolderAndNoOptions() throws {
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        let request = NextflowLaunchRequest(
            target: .pinned(pin),
            samplesheet: URL(fileURLWithPath: "/tmp/lungfish-descriptor/samplesheet.csv"),
            outputDirectory: URL(fileURLWithPath: "/tmp/lungfish-descriptor/out", isDirectory: true))
        XCTAssertEqual(request.configFiles, [])
        XCTAssertNil(request.workDirectory)
        XCTAssertEqual(request.pipelineArguments, [])
        XCTAssertEqual(request.target, .pinned(pin))
        XCTAssertNotEqual(request.target, .snapshot(URL(fileURLWithPath: "/tmp/lungfish-descriptor/snapshot")))
    }
}
