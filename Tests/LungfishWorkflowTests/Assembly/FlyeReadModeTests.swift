// FlyeReadModeTests.swift - Flye's read mode follows the read type (manager ruling, Phase 1.5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Flye on PacBio HiFi reads ran `--nano-hq`, because the read type was
/// swapped to ONT. Flye has its own PacBio modes: HiFi takes `--pacbio-hifi`
/// and CLR takes `--pacbio-raw`. ONT keeps the read-quality rule, an unknown
/// read type keeps today's default, and a mode the user gives always wins.
final class FlyeReadModeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "flye-read-mode")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func request(readType: AssemblyReadType, profile: String? = nil) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: .flye,
            readType: readType,
            inputURLs: [root.appendingPathComponent("reads.fastq")],
            projectName: "flye",
            outputDirectory: root.appendingPathComponent("out"),
            threads: 2,
            selectedProfileID: profile
        )
    }

    func testFlyeTakesHiFiReadsAsHiFi() throws {
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .flye, for: .pacBioHiFi))
        let executed = request(readType: .pacBioHiFi).normalizedForExecution()
        XCTAssertEqual(executed.readType, .pacBioHiFi)
        XCTAssertEqual(executed.selectedProfileID, "pacbio-hifi")
        let command = try ManagedAssemblyPipeline.buildCommand(for: request(readType: .pacBioHiFi))
        XCTAssertTrue(command.arguments.contains("--pacbio-hifi"), "\(command.arguments)")
    }

    func testAnExplicitModeWins() throws {
        let command = try ManagedAssemblyPipeline.buildCommand(for: request(readType: .pacBioHiFi, profile: "nano-hq"))
        XCTAssertTrue(command.arguments.contains("--nano-hq"), "\(command.arguments)")
    }

    func testTheSelectorFollowsTheReadTypeAndTheReads() async throws {
        let hifi = try PlatformHeaderFixtures.copy("pacbio-revio-ccs.fastq", to: root)
        let hifiSelection = await FlyeProfileSelector.select(forInputURL: hifi, readType: .pacBioHiFi)
        XCTAssertEqual(hifiSelection.profileID, "pacbio-hifi")
        XCTAssertEqual(hifiSelection.basis, .readType)

        let subreads = try PlatformHeaderFixtures.copy("pacbio-subreads.fastq", to: root)
        let clr = await FlyeProfileSelector.select(forInputURL: subreads, readType: nil)
        XCTAssertEqual(clr.profileID, "pacbio-raw")

        let ont = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: root)
        let ontSelection = await FlyeProfileSelector.select(forInputURL: ont, readType: .ontReads)
        XCTAssertTrue(["nano-hq", "nano-raw"].contains(ontSelection.profileID), ontSelection.profileID)
    }

    func testHifiasmModeFollowsTheReadType() throws {
        func hifiasm(_ readType: AssemblyReadType) throws -> [String] {
            try ManagedAssemblyPipeline.buildCommand(for: AssemblyRunRequest(
                tool: .hifiasm, readType: readType, inputURLs: [root.appendingPathComponent("reads.fastq")],
                projectName: "h", outputDirectory: root.appendingPathComponent("h-\(readType.rawValue)"), threads: 2
            )).arguments
        }
        XCTAssertTrue(try hifiasm(.ontReads).contains("--ont"))
        XCTAssertFalse(try hifiasm(.pacBioHiFi).contains("--ont"))
    }
}
