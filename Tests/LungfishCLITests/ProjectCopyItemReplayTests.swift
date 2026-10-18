// ProjectCopyItemReplayTests.swift - The record of project copy-item names its source and replays
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18, BIO ruling on F3 (`ProjectCopyItemReplayTests`). The built lungfish-cli copies a
// read bundle and a reference bundle from S.lungfish into T.lungfish. Each copy's envelope names the item by
// its path inside the source project and never by the copy's own path. The envelope's `durableReplayArgv`,
// with its placeholders resolved and only `--project` changed to a new empty U.lungfish, copies the same
// bytes again. The envelope is resolved with the placeholder-only `PortablePath.resolveJSON`, never through
// `ProvenanceEnvelopeReader`, whose re-root would turn the source item into the copy.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ProjectCopyItemReplayTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!
    private var replayProject: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "project-copy-item-replay")
        sourceProject = root.appendingPathComponent("S.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("T.lungfish", isDirectory: true)
        replayProject = root.appendingPathComponent("U.lungfish", isDirectory: true)
        for project in [sourceProject!, targetProject!, replayProject!] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testCopyItemRecordNamesItsSourceAndReplaysIntoANewProject() throws {
        try makeReadBundleWithProvenance("Imports/R.lungfishfastq")
        try makeBundle("Reference Sequences/NC_045512.lungfishref", files: ["sequence.fasta": ">NC_045512\nACGTACGT\n"])

        for relative in ["Imports/R.lungfishfastq", "Reference Sequences/NC_045512.lungfishref"] {
            let first = try runCLI([
                "project", "copy-item", relative, "--source-project", sourceProject.path, "--project", targetProject.path,
            ])
            XCTAssertEqual(first.status, 0, "\(relative). \(first.stderr)")
            let copy = targetProject.appendingPathComponent(relative, isDirectory: true)
            let sidecar = copy.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar), relative)
            let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: copy), relative)
            XCTAssertEqual(record.sourceItemRelativePath, relative)
            for token in envelope.argv {
                XCTAssertNotEqual(token, copy.standardizedFileURL.path, "\(relative) names the copy. \(envelope.argv)")
                XCTAssertNotEqual(token, copy.resolvingSymlinksInPath().path, "\(relative) names the copy. \(envelope.argv)")
            }
            XCTAssertEqual(envelope.argv.dropFirst().prefix(3), ["project", "copy-item", relative])
            XCTAssertEqual(envelope.workflowName, "lungfish project copy-item")
            XCTAssertEqual(envelope.toolName, "lungfish project copy-item")
            XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("cli"), relative)
            XCTAssertEqual(envelope.options.explicit["item"], .string(relative), relative)
            XCTAssertEqual(envelope.options.resolvedDefaults["item"], .string(relative), relative)
            let fileOptions: [(String, ParameterValue?, URL)] = [
                ("sourceProject", envelope.options.explicit["sourceProject"], sourceProject),
                ("project", envelope.options.explicit["project"], targetProject),
                ("destination", envelope.options.resolvedDefaults["destination"], copy),
            ]
            for (key, value, expected) in fileOptions {
                guard case .file(let url)? = value else { XCTFail("\(relative): \(key) is not a file option"); continue }
                XCTAssertEqual(url.resolvingSymlinksInPath().path, expected.resolvingSymlinksInPath().path, "\(relative): \(key)")
            }

            let resolved = try PortablePath.resolveJSON(Data(contentsOf: sidecar), context: .forFile(at: sidecar))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: resolved) as? [String: Any])
            var replay = try XCTUnwrap(json["durableReplayArgv"] as? [String], relative)
            let projectIndex = try XCTUnwrap(replay.firstIndex(of: "--project"), "\(replay)") + 1
            replay[projectIndex] = replayProject.path
            let second = try runCLI(Array(replay.dropFirst()))
            XCTAssertEqual(second.status, 0, "\(replay). \(second.stderr)")

            let replayed = replayProject.appendingPathComponent(relative, isDirectory: true)
            let replayRecord = try XCTUnwrap(ProjectItemCopyRecord.load(from: replayed), relative)
            XCTAssertNotNil(record.sourceItemDigest)
            XCTAssertEqual(replayRecord.sourceItemDigest, record.sourceItemDigest, relative)
            let replayEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
                fromSidecar: replayed.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            ))
            let checked = replayEnvelope.outputs.filter { $0.checksumSHA256 != nil }
            XCTAssertFalse(checked.isEmpty, relative)
            for output in checked {
                XCTAssertEqual(
                    try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: output.path)), output.checksumSHA256, output.path
                )
            }
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeBundle(_ relative: String, files: [String: String]) throws -> URL {
        let bundle = sourceProject.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return bundle
    }

    /// A read bundle with readable provenance and no link into its project, so the copy goes through
    /// `FASTQBundleCopyImportWorkflow`.
    @discardableResult
    private func makeReadBundleWithProvenance(_ relative: String) throws -> URL {
        let bundle = try makeBundle(relative, files: ["reads.fastq": "@r1\nACGT\n+\nIIII\n"])
        let reads = bundle.appendingPathComponent("reads.fastq")
        let output = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output)
        let argv = ["source-fastq-tool", "reads.fastq"]
        let step = ProvenanceStep(toolName: "source-fastq-tool", toolVersion: "1.0", argv: argv, outputs: [output], exitStatus: 0, wallTimeSeconds: 0.1)
        let envelope = ProvenanceEnvelope(
            workflowName: "source FASTQ bundle", workflowVersion: "1.0", toolName: "source-fastq-tool", toolVersion: "1.0",
            argv: argv, files: [output], output: output, outputs: [output], steps: [step], wallTimeSeconds: 0.1, exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundle)
        return bundle
    }

    /// Runs the built `lungfish-cli` to the end from the test's folder.
    private func runCLI(_ arguments: [String]) throws -> ProcessResult {
        let binary = try XCTUnwrap(
            CLISIGTERMHarness.cliBinaryURL(for: Self.self),
            "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
        )
        return try ProcessRunner.run(
            binary, arguments, environment: CLISIGTERMHarness.childEnvironment(), cwd: root, timeout: 60
        )
    }
}
