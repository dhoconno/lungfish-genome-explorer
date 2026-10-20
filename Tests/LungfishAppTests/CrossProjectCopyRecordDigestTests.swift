// CrossProjectCopyRecordDigestTests.swift - A copied read bundle's digests match its files (BIO 6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The BIO ruling on lane 12.18 (answer 4, F7). Before the lane the read
// bundle's envelope hashed each copied file, and only then did the link
// rewriter change a JSON sidecar that named a path inside the source project,
// so the recorded digest no longer matched the file on disk.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class CrossProjectCopyRecordDigestTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CrossProjectCopyRecordDigestTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    func testReadBundleOutputDigestsMatchAfterLinkRewrite() throws {
        let sourceProject = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        let targetProject = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        try fm.createDirectory(at: targetProject, withIntermediateDirectories: true)
        let bundle = sourceProject.appendingPathComponent("Imports/HG002.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let sidecar: [String: Any] = ["readsPath": reads.standardizedFileURL.path, "sampleName": "HG002"]
        try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys]).write(to: bundle.appendingPathComponent("sample-notes.json"))
        let output = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output)
        let step = ProvenanceStep(toolName: "source-fastq-tool", toolVersion: "1.0", argv: ["source-fastq-tool"], outputs: [output], exitStatus: 0, wallTimeSeconds: 0.1)
        try ProvenanceWriter(signingProvider: nil).write(ProvenanceEnvelope(
            workflowName: "source FASTQ bundle", workflowVersion: "1.0", toolName: "source-fastq-tool", toolVersion: "1.0",
            argv: ["source-fastq-tool"], files: [output], output: output, outputs: [output], steps: [step], wallTimeSeconds: 0.1, exitStatus: 0
        ), to: bundle)

        let outcome = try CrossProjectItemCopier.copy(itemAt: bundle, intoProject: targetProject, identity: .neutral)

        let notes = try String(contentsOf: outcome.destinationURL.appendingPathComponent("sample-notes.json"), encoding: .utf8)
        XCTAssertTrue(notes.contains(outcome.destinationURL.appendingPathComponent("reads.fastq").path), "the sidecar link moved with the item: \(notes)")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: outcome.destinationURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        ))
        var checked: [String] = []
        for descriptor in envelope.outputs {
            guard let recorded = descriptor.checksumSHA256 else { continue }
            let onDisk = try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: descriptor.path))
            XCTAssertEqual(onDisk, recorded, "recorded digest of \(descriptor.path) does not match the file")
            checked.append(URL(fileURLWithPath: descriptor.path).lastPathComponent)
        }
        XCTAssertEqual(checked.sorted(), ["reads.fastq", "sample-notes.json"])
    }
}
