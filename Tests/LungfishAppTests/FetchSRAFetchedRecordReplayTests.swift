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
/// BIO's ruling on lane A45 M3c, section b item 3: the leaf publishes the record with `FetchNCBIBundleRecord.rebase`,
/// so the root record and every record of `provenance/` are the run's own, written for the final place. The import
/// wrote records of its own into the staged bundle, and a record that kept them named a folder the run deleted.
///
/// It launches the built CLI and the managed tools of the import, so its name ends in ReplayTests, which
/// sends it to the integration tier.
final class FetchSRAFetchedRecordReplayTests: XCTestCase {
    func testEveryRecordOfTheBundleNamesItsFilesInTheFinalBundle() async throws {
        let (_, bundle, _) = try await runLeaf(accession: SRAToolkitRecordedRunner.singleEndRun)
        try Self.assertEveryRecordNamesItsFilesInTheBundle(bundle, side: "the leaf")
    }

    func testTheRecordStatesTheDigestOfTheSidecarAsItStands() async throws {
        let (_, bundle, envelope) = try await runLeaf(accession: SRAToolkitRecordedRunner.singleEndRun)
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

    /// The project, the published bundle of one run and its record.
    private func runLeaf(accession: String) async throws -> (project: URL, bundle: URL, envelope: ProvenanceEnvelope) {
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
        return (project, bundle, envelope)
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

    /// A path of the folder the leaf imports into before it publishes, `<project>/.tmp/fetch-sra-<UUID>/import/`.
    /// The leaf deletes that folder, so no record may name a file in it.
    private static func isInTheStagedImport(_ path: String) -> Bool {
        guard let staging = path.range(of: "/.tmp/fetch-sra-") else { return false }
        return path[staging.upperBound...].contains("/import/")
    }

    /// Every record of `bundle`, the root record first and then each record of `provenance/`, by its name
    /// inside the bundle.
    static func records(of bundle: URL) throws -> [(name: String, envelope: ProvenanceEnvelope)] {
        let root = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle), "the bundle holds no root record")
        var records = [(name: ProvenanceRecorder.provenanceFilename, envelope: root)]
        let folder = bundle.appendingPathComponent("provenance", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }
            .sorted()
        for name in names {
            let envelope = try XCTUnwrap(
                ProvenanceRecorder.loadEnvelope(fromSidecar: folder.appendingPathComponent(name)),
                "provenance/\(name) does not decode")
            records.append((name: "provenance/\(name)", envelope: envelope))
        }
        return records
    }

    /// B-5 over every record (BIO ruling on lane A45 M3c, section b item 3). The bundle holds the root record
    /// and a record of `provenance/` for the bundle and for each of its files, at least four. Each one is the
    /// run's own, so it holds the run's argv. No path in a record lies in the folder the leaf staged its
    /// import in, and each file a record names inside the bundle exists with the digest and size it states.
    static func assertEveryRecordNamesItsFilesInTheBundle(
        _ bundle: URL, side: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let records = try records(of: bundle)
        XCTAssertGreaterThanOrEqual(records.count, 4, "\(side): \(records.map(\.name))", file: file, line: line)
        let rootArgv = try XCTUnwrap(records.first).envelope.argv
        for (name, envelope) in records {
            XCTAssertEqual(envelope.argv, rootArgv, "\(side): \(name) holds the argv of another run", file: file, line: line)
            let named = descriptors(of: envelope)
            for descriptor in named {
                XCTAssertFalse(
                    isInTheStagedImport(descriptor.path),
                    "\(side): \(name) names \(descriptor.path), in the folder the run deleted", file: file, line: line)
            }
            let inside = named.filter { isInside($0.path, bundle) }
            XCTAssertFalse(inside.isEmpty, "\(side): \(name) names no file of the bundle", file: file, line: line)
            for descriptor in inside {
                let url = URL(fileURLWithPath: descriptor.path)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: url.path),
                    "\(side): \(name) names \(descriptor.path), which does not exist", file: file, line: line)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                XCTAssertEqual(
                    descriptor.checksumSHA256, try ProvenanceFileHasher.sha256(of: url),
                    "\(side): \(name) states a stale digest for \(url.lastPathComponent)", file: file, line: line)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
                XCTAssertEqual(
                    descriptor.fileSize, size,
                    "\(side): \(name) states a stale size for \(url.lastPathComponent)", file: file, line: line)
            }
        }
    }
}
