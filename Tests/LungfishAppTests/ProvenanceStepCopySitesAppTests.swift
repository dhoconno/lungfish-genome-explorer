// ProvenanceStepCopySitesAppTests.swift - What the App step copies keep of a recorded step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4b, scope rows B6 and B8. The Workflow step copies are pinned in
// `ProvenanceStepCopySitesTests`, and this file pins the two in LungfishApp, the reference bundle merge and
// the FASTQ bundle merge. Each test sends `StepCopyFacts.fullStep` through the site and states what the
// copy did to each fact. A fact missing from the expected changes is kept as it was.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishOperations

final class ProvenanceStepCopySitesAppTests: XCTestCase {
    private typealias Facts = StepCopyFacts

    // MARK: ReferenceBundleMergeService.normalizedNestedSteps

    func testReferenceBundleMergeBuilderStepCopy() throws {
        let root = try TestTempDirectory.make(prefix: "StepCopyReferenceMerge")
        defer { TestTempDirectory.cleanup(root) }
        let source = root.appendingPathComponent("Sources/source.fa")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(">chr1\nACGT\n".utf8).write(to: source)
        let bundle = root.appendingPathComponent("Merged.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome/sequence.fa")
        try FileManager.default.createDirectory(at: genome.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(">chr1\nACGT\n".utf8).write(to: genome)
        let temporaryInput = root.appendingPathComponent(".merge-staging/input.fa")
        let step = Facts.fullStep(
            toolName: "NativeBundleBuilder.build",
            input: temporaryInput,
            inputs: [ProvenanceFileDescriptor(path: temporaryInput.path, role: .input)]
        )
        let envelope = ProvenanceEnvelope(workflowName: "merge", toolName: "lungfish-app", steps: [step])

        let copy = try XCTUnwrap(
            ReferenceBundleMergeService.normalizedNestedSteps(
                from: envelope,
                inputPayloadURLs: [source],
                outputPayloadURLs: [genome],
                bundleURL: bundle,
                resolvedBundleName: "Merged"
            ).first
        )

        XCTAssertEqual(Facts.changes(from: step, in: copy), ["durableReplayArgv": .changed, "resolvedOptions": .changed])
        XCTAssertEqual(Facts.filePath(of: "input", in: copy), genome.standardizedFileURL.path, "the option follows the replay")
        XCTAssertEqual(copy.durableReplayArgv?.last, genome.standardizedFileURL.path, "the replay reads the durable FASTA")
    }

    // MARK: FASTQBundleMergeService.normalizeTransientNativeSteps

    func testFASTQBundleMergeReformatStepCopy() throws {
        let step = Facts.fullStep(
            toolName: NativeTool.reformat.executableName,
            input: URL(fileURLWithPath: "/project/.merge-staging/interleaved.fastq")
        )

        let copy = try XCTUnwrap(FASTQBundleMergeService.normalizeTransientNativeSteps([step]).first)

        // A transient step's replay would name files the merge removed, so only the replay command goes.
        XCTAssertEqual(Facts.changes(from: step, in: copy), ["durableReplayArgv": .lost])
        XCTAssertEqual(copy.outputs, [], "a transient step names no output")
    }
}
