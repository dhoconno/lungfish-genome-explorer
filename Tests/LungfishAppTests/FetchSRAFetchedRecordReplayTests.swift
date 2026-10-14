// FetchSRAFetchedRecordReplayTests.swift - The record of lungfish-cli fetch sra download --bundle states what the bundle holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

/// Ruling A45-M3 section 1 (lane A45 M3c): the record is one per child, written last, and it holds the
/// sidecar's digest. The import writes its own record before the leaf adds the download's facts to the
/// bundle's metadata sidecar, and the leaf's record merges the import's steps in, so a digest the import
/// stated for the sidecar is stale unless the leaf states it again (B-5). The built CLI runs the recorded
/// single-end run on the toolkit stand-in scripts, and every file the record names inside the published
/// bundle must exist with the digest and size the record states.
///
/// It launches the built CLI and the managed tools of the import, so its name ends in ReplayTests, which
/// sends it to the integration tier.
final class FetchSRAFetchedRecordReplayTests: XCTestCase {
    func testTheRecordStatesTheDigestOfTheSidecarAsItStands() async throws {
        let (bundle, envelope) = try await runLeaf(accession: SRAToolkitRecordedRunner.singleEndRun)
        let inBundle = Self.descriptors(of: envelope).filter { Self.isInside($0.path, bundle) }
        XCTAssertFalse(inBundle.isEmpty, "the record names no file of the bundle")
        let sidecars = inBundle.filter { $0.path.hasSuffix(".lungfish-meta.json") }
        XCTAssertFalse(sidecars.isEmpty, "the record names the metadata sidecar of the bundle: \(inBundle.map(\.path))")
        for descriptor in inBundle {
            let url = URL(fileURLWithPath: descriptor.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the record names \(descriptor.path), which does not exist")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            XCTAssertEqual(
                descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: url),
                "the record states a stale digest for \(url.lastPathComponent)")
        }
    }

    /// The published bundle of one run and its record.
    private func runLeaf(accession: String) async throws -> (bundle: URL, envelope: ProvenanceEnvelope) {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let root = try TestTempDirectory.make(prefix: "fetch-sra-record")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let scripts = root.appendingPathComponent("toolkit", isDirectory: true)
        try SRAToolkitStandInScripts.write(
            into: scripts, fixtures: SRAToolkitStandInScripts.fixturesFolder(testFile: #filePath))
        let run = await RouteParityHarness.runCLI(
            cli,
            arguments: [
                "fetch", "sra", "download", accession, "--bundle", "--project", project.path, "--use-toolkit",
                "--platform", "illumina", "--compression", "fast", "--no-optimize-storage", "--format", "json",
            ],
            timeout: .seconds(120),
            environment: [
                SRAToolkitStandInScripts.variable: scripts.path,
                NCBIServiceEndpoints.standInOriginVariable: "http://127.0.0.1:1",
                "NCBI_API_KEY": "",
            ])
        XCTAssertEqual(run.status, 0, run.detail)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: imports.path).filter { $0.hasSuffix(".lungfishfastq") }
        XCTAssertEqual(names.count, 1, "the run publishes one bundle: \(names)")
        let bundle = imports.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the bundle holds no record")
        return (bundle, envelope)
    }

    /// Every file the record names, wherever it lists one.
    private static func descriptors(of envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.files + envelope.outputs + (envelope.output.map { [$0] } ?? [])
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
    }

    private static func isInside(_ path: String, _ bundle: URL) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix(bundle.resolvingSymlinksInPath().path + "/")
    }
}
