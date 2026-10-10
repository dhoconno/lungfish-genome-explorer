// MapRecordedMapperIdentityTests.swift - The mapper version and environment each mapping record names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.5 decision S10. Each test maps with the stand-in toolchain, whose
// micromamba fails for an environment that does not exist and whose BBTools
// wrappers print what the real ones print, then reads the version and the
// environment back from the mapping record and the provenance envelope.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MapRecordedMapperIdentityTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var standIn: MapReadSetStandIn!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "map-identity")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        standIn = try MapReadSetStandIn.make(in: root.appendingPathComponent("tools", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// BBMap records the version the BBTools environment it runs in prints,
    /// and that environment, in standard and PacBio mode. Before the fix the
    /// probe ran `micromamba run -n bbmap`, an environment the lock never
    /// builds, and every record named micromamba's error line,
    /// `critical libmamba The given prefix does not exist: "<root>/envs/bbmap"`,
    /// as the BBMap version and `bbmap` as its environment. Renaming the
    /// environment alone would have recorded `0.40` in PacBio mode, read from
    /// the `minratio=0.40` that `mapPacBio.sh` echoes.
    func testBBMapRecordsTheBBToolsVersionAndEnvironment() async throws {
        let version = MapReadSetStandIn.bbToolsVersion
        for (mode, executable) in [(MappingMode.bbmapStandard, "bbmap.sh"), (.bbmapPacBio, "mapPacBio.sh")] {
            let recorded = try await mapAndRead(tool: .bbmap, mode: mode, executable: executable)
            XCTAssertEqual(recorded.mapperVersion, version, mode.id)
            XCTAssertEqual(recorded.envelopeVersion, version, mode.id)
            XCTAssertEqual(recorded.toolIdentityVersion, version, mode.id)
            XCTAssertEqual(recorded.condaEnvironment, "bbtools", mode.id)
            XCTAssertEqual(
                recorded.stepVersionPrefix,
                "\(version) (managed conda environment bbtools; executable \(executable); package ",
                mode.id
            )
        }
    }

    /// The other mappers record what they recorded before the fix, the
    /// version their probe in their own environment printed and that
    /// environment.
    func testOtherMappersRecordTheirOwnEnvironmentAndProbedVersion() async throws {
        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2] {
            let recorded = try await mapAndRead(tool: tool, mode: .defaultShortRead, executable: tool.executableName)
            XCTAssertEqual(recorded.mapperVersion, "2.2.1", tool.rawValue)
            XCTAssertEqual(recorded.envelopeVersion, "2.2.1", tool.rawValue)
            XCTAssertEqual(recorded.toolIdentityVersion, "2.2.1", tool.rawValue)
            XCTAssertEqual(recorded.condaEnvironment, tool.rawValue, tool.rawValue)
            XCTAssertEqual(
                recorded.stepVersion,
                "2.2.1 (managed conda environment \(tool.rawValue); executable \(tool.executableName))",
                tool.rawValue
            )
        }
    }

    // MARK: - Helpers

    private struct Recorded {
        let mapperVersion: String
        let envelopeVersion: String
        let toolIdentityVersion: String
        let condaEnvironment: String?
        let stepVersion: String
        var stepVersionPrefix: String {
            guard let open = stepVersion.range(of: "; package ") else { return stepVersion }
            return String(stepVersion[..<open.upperBound])
        }
    }

    private func mapAndRead(tool: MappingTool, mode: MappingMode, executable: String) async throws -> Recorded {
        let outputDirectory = root.appendingPathComponent("\(tool.rawValue)-\(mode.id)", isDirectory: true)
        let resolved = try await MappingInputResolver.resolve(
            request: MappingRunRequest(
                tool: tool,
                modeID: mode.id,
                inputFASTQURLs: [fixtures.singleRoot],
                referenceFASTAURL: standIn.referenceURL,
                outputDirectory: outputDirectory,
                sampleName: "sample",
                threads: 2,
                compatibilityReadClassOverride: mode == .bbmapPacBio ? .pacBioCLR : .illuminaShortReads
            ),
            materializer: fixtures.materializer
        )
        _ = try await standIn.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )
        _ = try standIn.takeCalls()

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
        let step = try XCTUnwrap(provenance.steps.first { $0.toolName == executable }, "\(provenance.steps.map(\.toolName))")
        return Recorded(
            mapperVersion: provenance.mapperVersion,
            envelopeVersion: envelope.toolVersion,
            toolIdentityVersion: envelope.tool.version,
            condaEnvironment: envelope.runtimeIdentity.condaEnvironment,
            stepVersion: step.toolVersion
        )
    }
}
