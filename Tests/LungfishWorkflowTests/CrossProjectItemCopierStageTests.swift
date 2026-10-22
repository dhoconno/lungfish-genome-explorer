// CrossProjectItemCopierStageTests.swift - A copied item is built in the target's .tmp and renamed once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 M2 (SWIFT inv 85, BIO inv 101). A cancel at any file
// leaves no item and no stage, a finished copy leaves no stage, and the record
// names the source item by its project-relative path and the digests of the
// bytes the copy read.

import CryptoKit
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class CrossProjectItemCopierStageTests: XCTestCase {
    private var root: URL!
    private var sourceProject: URL!
    private var targetProject: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CrossProjectItemCopierStageTests-\(UUID().uuidString)", isDirectory: true)
        sourceProject = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        targetProject = root.appendingPathComponent("Target Project.lungfish", isDirectory: true)
        try fm.createDirectory(at: targetProject, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    /// A reference bundle of three files, one of them a symlink to a file outside the item.
    private func makeReference() throws -> URL {
        let bundle = sourceProject.appendingPathComponent("Reference Sequences/NC 045512.lungfishref", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("genome"), withIntermediateDirectories: true)
        try "{\"bundleKind\":\"fixture\"}".write(to: bundle.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try ">x\nACGT\n".write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("notes.txt")
        try "linked notes\n".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: bundle.appendingPathComponent("Notes.txt"), withDestinationURL: outside)
        return bundle
    }

    private func stages() -> [String] {
        let temp = ProjectTempDirectory.tempRoot(for: targetProject)
        return ((try? fm.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    func testACancelAtAnyFileLeavesNoItemAndNoStage() throws {
        let reference = try makeReference()
        var total = 0
        let counting = root.appendingPathComponent("Counting.lungfish", isDirectory: true)
        try fm.createDirectory(at: counting, withIntermediateDirectories: true)
        _ = try CrossProjectItemCopier.copy(itemAt: reference, intoProject: counting, identity: .neutral) { total += 1 }
        XCTAssertGreaterThanOrEqual(total, 5, "three files, the bytes and the gate before the rename")
        for cancelAt in 1...total {
            var checks = 0
            XCTAssertThrowsError(try CrossProjectItemCopier.copy(itemAt: reference, intoProject: targetProject, identity: .neutral) {
                checks += 1
                if checks == cancelAt { throw CancellationError() }
            }) { error in
                XCTAssertTrue(error is CancellationError, "check \(cancelAt): \(error)")
            }
            let landed = targetProject.appendingPathComponent("Reference Sequences", isDirectory: true)
            XCTAssertEqual((try? fm.contentsOfDirectory(atPath: landed.path)) ?? [], [], "check \(cancelAt) left a partial item")
            XCTAssertEqual(stages(), [], "check \(cancelAt) left its stage")
        }
    }

    func testTheRecordNamesTheSourceByRelativePathAndDigestAndNoStageRemains() throws {
        let reference = try makeReference()

        let outcome = try CrossProjectItemCopier.copy(itemAt: reference, intoProject: targetProject, identity: .neutral)

        XCTAssertEqual(stages(), [])
        let record = try XCTUnwrap(ProjectItemCopyRecord.load(from: outcome.destinationURL))
        XCTAssertEqual(record.schemaVersion, 2)
        XCTAssertEqual(record.sourceItemPath, reference.standardizedFileURL.path)
        XCTAssertEqual(record.sourceItemRelativePath, "Reference Sequences/NC 045512.lungfishref")
        let files = try XCTUnwrap(record.sourceItemFiles)
        XCTAssertEqual(files.map(\.path), ["Notes.txt", "genome/sequence.fa", "manifest.json"], "sorted by bytes, the symlink read through")
        XCTAssertEqual(files.first?.size, 13)
        XCTAssertEqual(files.first?.sha256, try ProvenanceFileHasher.sha256(of: root.appendingPathComponent("notes.txt")))
        let lines = files.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        let digest = SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(record.sourceItemDigest, digest)

        // Every digest the receipt records matches the published file, and nothing names the stage.
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: outcome.destinationURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        ))
        for output in receipt.outputs {
            guard let recorded = output.checksumSHA256 else { continue }
            XCTAssertEqual(try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: output.path)), recorded, output.path)
        }
        let receiptText = try String(
            contentsOf: outcome.destinationURL.appendingPathComponent(ProvenanceWriter.provenanceFilename), encoding: .utf8
        )
        XCTAssertFalse(receiptText.contains("project-copy-"), "the receipt names the stage")
    }

    /// CHTC program lane L2-COPYCHECK. The copier hands a read bundle to `FASTQBundleCopyImportWorkflow`, so reads cut
    /// short in transfer reach the workflow's refusal, and the copy leaves no item and no stage.
    func testATruncatedReadBundleIsRefusedAndLeavesNoItemAndNoStage() throws {
        let bundle = sourceProject.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try (1...50).map { "@r\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined().write(to: reads, atomically: true, encoding: .utf8)
        let output = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output)
        let step = ProvenanceStep(
            toolName: "source-fastq-tool", toolVersion: "1.0", argv: ["source-fastq-tool"],
            outputs: [output], exitStatus: 0, wallTimeSeconds: 0.1
        )
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "source FASTQ bundle", workflowVersion: "1.0", toolName: "source-fastq-tool",
                toolVersion: "1.0", argv: ["source-fastq-tool"], files: [output], output: output, outputs: [output],
                steps: [step], wallTimeSeconds: 0.1, exitStatus: 0
            ),
            to: bundle
        )
        let complete = try Data(contentsOf: reads)
        try complete.prefix(complete.count / 2).write(to: reads)

        XCTAssertThrowsError(try CrossProjectItemCopier.copy(itemAt: bundle, intoProject: targetProject, identity: .neutral)) { error in
            XCTAssertEqual(error as? FASTQBundleCopyImportError, .payloadDoesNotMatchRecord(reads.standardizedFileURL.path))
        }
        let landed = targetProject.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: landed.path)) ?? [], [], "the refused copy left a partial item")
        XCTAssertEqual(stages(), [], "the refused copy left its stage")
    }
}
