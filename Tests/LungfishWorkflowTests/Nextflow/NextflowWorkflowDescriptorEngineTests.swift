// NextflowWorkflowDescriptorEngineTests.swift - The engine settings a workflow's descriptor gives one launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9, the descriptor bridge, and ruling 2 of the A16 M1 review. The Docker wait follows
// the launch's effective profile, never the workflow's container runtime alone, so a conda run and a
// stand-in run with `local` never ask the daemon.

import XCTest
@testable import LungfishWorkflow

final class NextflowWorkflowDescriptorEngineTests: XCTestCase {
    func testOnlyALaunchWithTheWorkflowsDockerProfileWaitsForDocker() {
        let descriptor = NextflowWorkflowDescriptor.taxTriage

        XCTAssertTrue(descriptor.engineConfiguration(profile: "docker").waitsForDocker)
        for profile in ["local", "conda", "docker,test", ""] {
            XCTAssertFalse(
                descriptor.engineConfiguration(profile: profile).waitsForDocker,
                "a launch with profile \"\(profile)\" never waits for Docker"
            )
        }
    }

    func testAWorkflowWhoseTasksRunOnTheHostNeverWaits() {
        let taxTriage = NextflowWorkflowDescriptor.taxTriage
        let hostOnly = NextflowWorkflowDescriptor(
            toolID: taxTriage.toolID, lockPipelineID: taxTriage.lockPipelineID, profile: taxTriage.profile,
            containerRuntime: .hostOnly, releaseEnvironment: taxTriage.releaseEnvironment,
            parameterSchemaPath: taxTriage.parameterSchemaPath, workDirectoryOption: taxTriage.workDirectoryOption,
            traceFileName: taxTriage.traceFileName, argumentLayout: taxTriage.argumentLayout,
            scratchPrefix: taxTriage.scratchPrefix,
            keepWorkEnvironmentKey: taxTriage.keepWorkEnvironmentKey,
            expectedTaskCountPerSample: taxTriage.expectedTaskCountPerSample,
            finalizeProgressShare: taxTriage.finalizeProgressShare
        )

        XCTAssertFalse(hostOnly.engineConfiguration(profile: taxTriage.profile).waitsForDocker)
    }

    func testTheScratchSettingsComeFromTheDescriptorWithTheEnginesDefaults() {
        let descriptor = NextflowWorkflowDescriptor.taxTriage
        let configuration = descriptor.engineConfiguration(profile: descriptor.profile)

        XCTAssertEqual(configuration.scratchPrefix, descriptor.scratchPrefix)
        XCTAssertEqual(configuration.keepWorkEnvironmentKey, descriptor.keepWorkEnvironmentKey)
        XCTAssertEqual(configuration.terminationGracePeriod, NextflowEngineProcess.terminationGracePeriod, "N6")
        XCTAssertEqual(configuration.logTailLineCount, 200)
        XCTAssertEqual(configuration.tracePollInterval, .seconds(5))
    }
}
