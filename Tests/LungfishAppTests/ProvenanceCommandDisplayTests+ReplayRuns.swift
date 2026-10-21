// ProvenanceCommandDisplayTests+ReplayRuns.swift - The exported shell script of a moved record, run with bash
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.45 (SW2 R-REPLAY), ARCH-13.45 M2d. Each test runs the shell script a provenance export writes
/// with `/bin/bash`, `LUNGFISH_PROJECT` and `OUTDIR` set, and checks on disk what the run read and wrote. The record is
/// a `/bin/cp` step, so the replay runs with no stub.
extension ProvenanceCommandDisplayTests {

    enum ReplayRelocation { case none, rename, duplicate }

    struct CopyStepRecord {
        let project: URL
        /// The folder the record was written in, `Analyses/copy-step`.
        let source: URL
        /// The record's folder after the relocation.
        let folder: URL
        let recordURL: URL
    }

    static let copyStepReads = Data("@r\nACGT\n+\nIIII\n".utf8)

    /// Ruling (c). The replay of a Duplicate reads the copy's input, writes only `OUTDIR`, and every file under the
    /// source keeps its SHA-256.
    func testTheReplayOfADuplicateReadsTheCopyAndLeavesTheSourceUnchanged() throws {
        let copy = try copyStepRecord(.duplicate, inputInFolder: true)
        let before = try digests(under: copy.source)
        let outputs = copy.project.deletingLastPathComponent().appendingPathComponent("replay-outputs")

        let run = try runExportedScript(of: copy, outputs: outputs)

        XCTAssertEqual(run.status, 0, run.stderr + run.script)
        XCTAssertTrue(run.script.contains("copy-step copy/in.fastq"), run.script)
        XCTAssertFalse(run.script.contains("Analyses/copy-step/"), run.script)
        XCTAssertEqual(try Data(contentsOf: outputs.appendingPathComponent("out.fastq")), Self.copyStepReads)
        XCTAssertEqual(try digests(under: copy.source), before, "the replay wrote under the source")
    }

    /// The renamed case. After the run no folder of the old name exists and every file under the renamed folder keeps
    /// its SHA-256.
    func testTheReplayOfARenamedRecordMakesNoOldFolderAndLeavesTheRenamedOneUnchanged() throws {
        let renamed = try copyStepRecord(.rename, inputInFolder: true)
        let before = try digests(under: renamed.folder)
        let outputs = renamed.project.deletingLastPathComponent().appendingPathComponent("replay-outputs")

        let run = try runExportedScript(of: renamed, outputs: outputs)

        XCTAssertEqual(run.status, 0, run.stderr + run.script)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.source.path), "a folder of the old name came back")
        XCTAssertEqual(try digests(under: renamed.folder), before, "the replay wrote under the renamed folder")
        XCTAssertEqual(try Data(contentsOf: outputs.appendingPathComponent("out.fastq")), Self.copyStepReads)
    }

    /// SWIFT 6. With `OUTDIR` an existing folder that holds one sentinel file, the script exits non-zero before any
    /// tool runs and the folder still holds only the sentinel, unchanged.
    func testAReplayIntoAnExistingFolderStopsAndLeavesTheSentinel() throws {
        let record = try copyStepRecord(.none, inputInFolder: false)
        let before = try digests(under: record.folder)
        let outputs = record.project.deletingLastPathComponent().appendingPathComponent("replay-outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: false)
        let sentinel = outputs.appendingPathComponent("sentinel.txt")
        try Data("sentinel\n".utf8).write(to: sentinel)

        let run = try runExportedScript(of: record, outputs: outputs)

        XCTAssertNotEqual(run.status, 0, run.script)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputs.path), ["sentinel.txt"])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel\n".utf8))
        XCTAssertEqual(try digests(under: record.folder), before)
    }

    /// BIO 6 and X10. A record whose replay argv is `/bin/cp @/Inputs/reads.fastq @/Analyses/copy-step/out.fastq`,
    /// with no `replayScope` option, replays to `$OUTDIR/out.fastq` whose SHA-256 equals the output descriptor's.
    func testAReplayedCopyStepWritesTheRecordedBytesUnderOUTDIR() throws {
        let record = try copyStepRecord(.none, inputInFolder: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record.recordURL)) as? [String: Any])
        let step = try XCTUnwrap((json["steps"] as? [[String: Any]])?.first)
        XCTAssertEqual(step["durableReplayArgv"] as? [String], ["/bin/cp", "@/Inputs/reads.fastq", "@/Analyses/copy-step/out.fastq"])
        XCTAssertNil((step["resolvedOptions"] as? [String: Any])?["replayScope"])
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: record.recordURL))
        let recorded = try XCTUnwrap(envelope.outputs.first?.checksumSHA256)
        let outputs = record.project.deletingLastPathComponent().appendingPathComponent("replay-outputs")

        let run = try runExportedScript(of: record, outputs: outputs)

        XCTAssertEqual(run.status, 0, run.stderr + run.script)
        XCTAssertEqual(Self.sha256(try Data(contentsOf: outputs.appendingPathComponent("out.fastq"))), recorded)
    }

    /// C3. An input whose bytes differ from the SHA-256 the record holds, or that is gone, stops the script before
    /// `OUTDIR` is made, and the message names the file and both digests.
    func testAReplayStopsBeforeMakingOUTDIRWhenAnInputChangedOrIsGone() throws {
        let record = try copyStepRecord(.none, inputInFolder: false)
        let input = record.project.appendingPathComponent("Inputs/reads.fastq")
        let outputs = record.project.deletingLastPathComponent().appendingPathComponent("replay-outputs")
        let changed = Data("@r\nTTTT\n+\nIIII\n".utf8)
        try changed.write(to: input)

        let run = try runExportedScript(of: record, outputs: outputs)

        XCTAssertNotEqual(run.status, 0, run.script)
        XCTAssertTrue(run.stderr.contains(input.path), run.stderr)
        XCTAssertTrue(run.stderr.contains(Self.sha256(Self.copyStepReads)), run.stderr)
        XCTAssertTrue(run.stderr.contains(Self.sha256(changed)), run.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.path), "OUTDIR was made before the check")

        try FileManager.default.removeItem(at: input)
        let gone = try runExportedScript(of: record, outputs: outputs)
        XCTAssertNotEqual(gone.status, 0)
        XCTAssertTrue(gone.stderr.contains("is missing"), gone.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.path))
    }

    // MARK: - Helpers

    /// A `/bin/cp` record written into `Analyses/copy-step` that copies the reads (in the folder or in `Inputs`) to
    /// `out.fastq` in the folder, both descriptors with their SHA-256, then renamed to `copy-step renamed` or
    /// duplicated to `copy-step copy` as the sidebar does it.
    func copyStepRecord(_ relocation: ReplayRelocation, inputInFolder: Bool) throws -> CopyStepRecord {
        let root = try TestTempDirectory.make(prefix: "provenance-replay-run")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Replay.lungfish", isDirectory: true)
        let source = project.appendingPathComponent("Analyses/copy-step", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Inputs"), withIntermediateDirectories: true)
        let inputURL = inputInFolder ? source.appendingPathComponent("in.fastq") : project.appendingPathComponent("Inputs/reads.fastq")
        let outputURL = source.appendingPathComponent("out.fastq")
        try Self.copyStepReads.write(to: inputURL)
        try Self.copyStepReads.write(to: outputURL)
        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: outputURL, format: .fastq, role: .output)
        let argv = ["/bin/cp", inputURL.path, outputURL.path]
        let envelope = ProvenanceEnvelope(workflowName: "Copy step", toolName: "cp", toolVersion: "system",
            argv: argv, durableReplayArgv: argv, files: [input], output: output, outputs: [output],
            steps: [ProvenanceStep(toolName: "cp", toolVersion: "system", argv: argv, durableReplayArgv: argv,
                inputs: [input], outputs: [output], exitStatus: 0)], exitStatus: 0)
        let written = try ProvenanceWriter(signingProvider: nil).write(envelope, to: source)
        guard relocation != .none else {
            return CopyStepRecord(project: project, source: source, folder: source, recordURL: written)
        }
        let folder = project.appendingPathComponent(
            relocation == .rename ? "Analyses/copy-step renamed" : "Analyses/copy-step copy", isDirectory: true
        )
        if relocation == .rename {
            try FileManager.default.moveItem(at: source, to: folder)
        } else {
            try FileManager.default.copyItem(at: source, to: folder)
        }
        SidebarViewController().rehydrateScientificProvenance(from: source, to: folder)
        return CopyStepRecord(
            project: project, source: source, folder: folder, recordURL: folder.appendingPathComponent(written.lastPathComponent)
        )
    }

    /// Exports `record` as a shell script and runs it with bash, `LUNGFISH_PROJECT` the project and `OUTDIR` `outputs`.
    func runExportedScript(of record: CopyStepRecord, outputs: URL) throws -> (status: Int32, script: String, stderr: String) {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: record.recordURL))
        let exportRoot = try TestTempDirectory.make(prefix: "provenance-replay-run-export")
        addTeardownBlock { TestTempDirectory.cleanup(exportRoot) }
        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: .shell,
            to: exportRoot.appendingPathComponent("export", isDirectory: true),
            sourceSidecarURL: record.recordURL,
            sourceRootURL: record.folder,
            allowUnpinned: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [bundle.primaryArtifactURL.path]
        process.currentDirectoryURL = exportRoot
        var environment = ProcessInfo.processInfo.environment
        environment["LUNGFISH_PROJECT"] = record.project.path
        environment["OUTDIR"] = outputs.path
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8), stderr)
    }

    /// The SHA-256 of every regular file below `folder`, by its path below the folder.
    func digests(under folder: URL) throws -> [String: String] {
        let root = folder.resolvingSymlinksInPath().path
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .allObjects.compactMap { $0 as? URL } ?? []
        var result: [String: String] = [:]
        for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = file.resolvingSymlinksInPath().path
            result[path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path] = Self.sha256(try Data(contentsOf: file))
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
