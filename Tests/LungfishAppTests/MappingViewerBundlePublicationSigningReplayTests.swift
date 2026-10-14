// MappingViewerBundlePublicationSigningReplayTests.swift - The record a mapping publication rewrites is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, family L6. A mapping onto a `.lungfishref` ends with `MappingViewerBundlePublicationService`
// rewriting the analysis folder's record (`rewriteCanonicalProvenance`) through
// `ProvenanceWriter(signingProvider: nil)`. The mapping pipeline signs that record when a key is set, and the
// rewrite then removed the signature, so the record the result opens first, which both the in-process route and
// `lungfish-cli map` leave, ended unsigned. This maps the golden's reads onto a reference bundle in process
// with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the test's folder. It sets a process
// variable and runs minimap2 and samtools, so its name ends in ReplayTests and it runs in the integration tier.
//
// The fixture helpers at the end are shared with MappingRouteSigningReplayTests, which runs the three sides.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MappingViewerBundlePublicationSigningReplayTests: XCTestCase {
    func testTheAnalysisRecordOfAMappingOntoAReferenceBundleIsSignedWhenAKeyIsSet() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let scratch = try TestTempDirectory.make(prefix: "mapping-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try Self.writeFixture(root, onReferenceBundle: true)
        let request = try Self.request(in: root, onReferenceBundle: true)
        let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
            Task { @MainActor in
                await AppDelegate().runSingleManagedMappingAwaitingCompletion(
                    request: request, warning: nil, routeContext: nil,
                    preassignedAnalysisDirectory: request.outputDirectory, registerCancel: { _ in }
                )
            }
        }
        let outcome = ReadsRouteParity.outcome(of: item)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)

        let record = Self.openingRecord(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "the mapping left no record at \(record.path)")
        XCTAssertTrue(RouteParityHarness.isSigned(record), "\(record.lastPathComponent) has no signature and public key though a key is set")
    }
}

// MARK: - The fixture, shared with MappingRouteSigningReplayTests

extension MappingViewerBundlePublicationSigningReplayTests {
    /// The title of the Map Reads row of the request of any root.
    nonisolated static let title = "Map Reads (\(MappingTool.minimap2.displayName)): \(MappingRouteGolden.sampleName)"

    /// The golden's project in `root`, with the analysis folder completed as a fresh run would find it, and its
    /// FASTA in a `.lungfishref` of the project when `onReferenceBundle` is set.
    @MainActor
    static func writeFixture(_ root: URL, onReferenceBundle: Bool) throws {
        let fixture = try MappingRouteGolden.Fixture(in: root)
        if onReferenceBundle { _ = try MappingRouteRow.referenceBundle(from: fixture.reference, in: fixture.project) }
        _ = AnalysisRunRecord.markComplete(fixture.analysisDirectory)
    }

    /// The record the analysis folder of a side root opens first. A root with no analysis folder gives a path
    /// that does not exist, so the assertion reports a missing record.
    nonisolated static func openingRecord(in root: URL) -> URL {
        let folder = (try? MappingRouteParityReplayTests.analysisFolder(in: root))
            ?? root.appendingPathComponent("Project.lungfish/Analyses/no-analysis-folder", isDirectory: true)
        return folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }

    /// The request of the Map Reads window for the fixture in `root`, with the FASTA of the `.lungfishref` that
    /// the fixture holds as the reference when `onReferenceBundle` is set. Every path keeps the spelling of
    /// `root`, since the viewer publication wants its candidate bundle and the final one spelled alike, and a
    /// folder listing hands back the other spelling of the temporary folder (`/private/var`).
    nonisolated static func request(in root: URL, onReferenceBundle: Bool) throws -> MappingRunRequest {
        func only(_ folder: URL, suffix: String? = nil, prefix: String? = nil) throws -> URL {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { (suffix.map($0.hasSuffix) ?? true) && (prefix.map($0.hasPrefix) ?? true) }
                .sorted()
            return folder.appendingPathComponent(try XCTUnwrap(names.first, "nothing to use in \(folder.path)"), isDirectory: true)
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputs = project.appendingPathComponent("inputs", isDirectory: true)
        let reference = onReferenceBundle
            ? try only(project.appendingPathComponent("Reference Sequences", isDirectory: true), suffix: ".lungfishref")
                .appendingPathComponent("genome/sequence.fa")
            : inputs.appendingPathComponent("genome.fasta")
        let modeID = MappingMode.defaultShortRead.id
        return MappingRunRequest(
            tool: .minimap2,
            modeID: modeID,
            inputFASTQURLs: [inputs.appendingPathComponent("test_1.fastq.gz"), inputs.appendingPathComponent("test_2.fastq.gz")],
            referenceFASTAURL: reference,
            projectURL: project,
            outputDirectory: try only(project.appendingPathComponent("Analyses", isDirectory: true), prefix: "\(MappingTool.minimap2.rawValue)-"),
            sampleName: MappingRouteGolden.sampleName,
            readGroup: MappingReadGroup.resolved(
                sampleName: MappingRouteGolden.sampleName, id: nil, readGroupSampleName: nil, library: nil,
                platform: nil, platformUnit: nil, defaultPlatform: MappingReadGroup.defaultPlatform(forModeID: modeID)
            ),
            pairedEnd: true,
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
    }
}
