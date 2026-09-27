// SPAdesCarefulModeCompatibilityTests.swift - --careful is refused with the SPAdes profiles that reject it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// SPAdes exits 67 on `--isolate --careful` ("you cannot specify
// --mismatch-correction or --careful in isolate mode!") and on `--meta
// --careful`; LGE then exited 64 after the launch. The combination is now
// refused before SPAdes runs, in the pipeline and in the CLI.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class SPAdesCarefulModeCompatibilityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spades-careful-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func request(
        tool: AssemblyTool,
        selectedProfileID: String? = nil,
        extraArguments: [String] = []
    ) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/hg002.fastq")],
            projectName: "hg002",
            outputDirectory: tempDir.appendingPathComponent("out-\(tool.rawValue)"),
            threads: 4,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments
        )
    }

    func testCarefulModeIsRefusedWithIsolateAndMetaButAllowedWithPlasmid() {
        XCTAssertFalse(SPAdesCarefulModeCompatibility.supportsCareful(profileID: nil))
        XCTAssertFalse(SPAdesCarefulModeCompatibility.supportsCareful(profileID: "isolate"))
        XCTAssertFalse(SPAdesCarefulModeCompatibility.supportsCareful(profileID: "meta"))
        XCTAssertTrue(SPAdesCarefulModeCompatibility.supportsCareful(profileID: "plasmid"))

        XCTAssertNil(SPAdesCarefulModeCompatibility.rejectionMessage(profileID: "isolate", extraArguments: ["--only-assembler"]))
        XCTAssertNil(SPAdesCarefulModeCompatibility.rejectionMessage(profileID: "plasmid", extraArguments: ["--careful"]))
        let rejection = SPAdesCarefulModeCompatibility.rejectionMessage(profileID: "meta", extraArguments: ["--careful"])
        XCTAssertEqual(
            rejection,
            "SPAdes rejects --careful with the Meta profile (\"you cannot specify --mismatch-correction or --careful in metagenomic mode!\"). Turn off Careful mode or choose the Plasmid profile."
        )
        XCTAssertNotNil(SPAdesCarefulModeCompatibility.rejectionMessage(profileID: nil, extraArguments: ["--mismatch-correction"]))
        XCTAssertEqual(
            SPAdesCarefulModeCompatibility.unavailableCaption(profileID: "isolate"),
            "Careful mode is unavailable with the Isolate profile: SPAdes rejects --careful in isolate mode."
        )
        XCTAssertNil(SPAdesCarefulModeCompatibility.unavailableCaption(profileID: "plasmid"))
    }

    func testPipelineRefusesCarefulWithIsolateBeforeLaunch() {
        XCTAssertThrowsError(
            try ManagedAssemblyPipeline.buildCommand(
                for: request(tool: .spades, selectedProfileID: "isolate", extraArguments: ["--careful"])
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("SPAdes rejects --careful with the Isolate profile"), error.localizedDescription)
        }
        XCTAssertNoThrow(
            try ManagedAssemblyPipeline.buildCommand(
                for: request(tool: .spades, selectedProfileID: "plasmid", extraArguments: ["--careful"])
            )
        )
    }
}
