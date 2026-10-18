// CrossProjectCopyLegacyRecordReplayTests.swift - An old cross-project copy record replays through fastq import-ont
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18, BIO ruling on `caller` (answer 3) as the ruling on F3 (section 1) re-rules it. Side A
// of the hidden key `CrossProjectCopyRoute`, the in-app copier, records a read bundle's copy as
// `lungfish fastq import-ont <source> --output <destination>` with `caller` `app-cross-project-copy`. Such a
// record keeps replaying through the built CLI, since `fastq import-ont` still takes an existing bundle. The
// envelope is read with the placeholder-only `PortablePath.resolveJSON`, never through
// `ProvenanceEnvelopeReader`, whose re-root would turn the source item into the copy. The source comes from
// `project-copy.json`'s `sourceItemPath`, the one record that keeps it in a form a replay can use. This test
// stays after lane 13.03 deletes side A, since old records still replay.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class CrossProjectCopyLegacyRecordReplayTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cross-project-copy-legacy-replay")
        sourceProject = root.appendingPathComponent("S.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("T.lungfish", isDirectory: true)
        for project in [sourceProject!, targetProject!] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testAppCrossProjectCopyRecordReplaysThroughFastqImportONT() throws {
        let source = try makeReadBundleWithProvenance("Imports/R.lungfishfastq")
        let copy = try CrossProjectItemCopier.copy(itemAt: source, intoProject: targetProject, requestedFolder: nil).destinationURL
        let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: copy))
        let sidecar = copy.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let resolved = try PortablePath.resolveJSON(Data(contentsOf: sidecar), context: .forFile(at: sidecar))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: resolved) as? [String: Any])
        let options = try JSONDecoder().decode(
            ProvenanceOptions.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(json["options"]))
        )
        XCTAssertEqual(options.resolvedDefaults["caller"], .string("app-cross-project-copy"))

        var replay = try XCTUnwrap(json["durableReplayArgv"] as? [String])
        XCTAssertEqual(Array(replay.dropFirst().prefix(2)), ["fastq", "import-ont"], "\(replay)")
        XCTAssertGreaterThan(replay.count, 3, "\(replay)")
        replay[3] = record.sourceItemPath
        let outputIndex = try XCTUnwrap(replay.firstIndex(of: "--output"), "\(replay)") + 1
        let replayFolder = root.appendingPathComponent("replay", isDirectory: true)
        try FileManager.default.createDirectory(at: replayFolder, withIntermediateDirectories: true)
        let replayed = replayFolder.appendingPathComponent("R.lungfishfastq", isDirectory: true)
        replay[outputIndex] = replayed.path

        let run = try runCLI(Array(replay.dropFirst()))
        XCTAssertEqual(run.status, 0, "\(replay). \(run.stderr)")

        let outputs = try XCTUnwrap(json["outputs"] as? [[String: Any]])
        var recorded: [String: String] = [:]
        for output in outputs {
            guard let checksum = output["checksumSHA256"] as? String, let path = output["path"] as? String else { continue }
            recorded[try XCTUnwrap(Self.relative(path, in: copy), path)] = checksum
        }
        let sourceFiles = Dictionary(uniqueKeysWithValues: (record.sourceItemFiles ?? []).map { ($0.path, $0.sha256) })
        var compared = 0
        for file in Self.regularFiles(in: replayed) {
            let name = try XCTUnwrap(Self.relative(file.path, in: replayed), file.path)
            if name.hasSuffix(ProvenanceWriter.provenanceFilename) || name == ProjectItemCopyRecord.filename { continue }
            let digest = try ProvenanceFileHasher.sha256(of: file)
            XCTAssertEqual(digest, recorded[name], "\(name) regenerates the digest the old record names")
            XCTAssertEqual(digest, sourceFiles[name], "\(name) holds the bytes the copy read")
            compared += 1
        }
        XCTAssertEqual(compared, recorded.count, "every output the old record names is compared")
        XCTAssertGreaterThan(compared, 0)
    }

    // MARK: - Helpers

    /// A read bundle with readable provenance and no link into its project, so the copy goes through
    /// `FASTQBundleCopyImportWorkflow`.
    private func makeReadBundleWithProvenance(_ relative: String) throws -> URL {
        let bundle = sourceProject.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
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

    /// `path` as a path inside `folder`, nil when it is outside, with symlinks such as `/var` resolved on both.
    private static func relative(_ path: String, in folder: URL) -> String? {
        let file = URL(fileURLWithPath: path)
        let prefixes = [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path]
        return ProjectItemLinkRewriter.relative(path: file.standardizedFileURL.path, toAny: prefixes)
            ?? ProjectItemLinkRewriter.relative(path: file.resolvingSymlinksInPath().path, toAny: prefixes)
    }

    private static func regularFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }
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
