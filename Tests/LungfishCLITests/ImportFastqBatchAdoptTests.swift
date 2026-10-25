// ImportFastqBatchAdoptTests.swift - `import fastq <batch folder> --adopt` adopts every sample or none (CHTC C5 lane BADOPT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// D2 a and UX-c5 point 7. Each end reads the exit code, the last event and the project folder, never source text (QA 2).
// The batch holds three small synthetic samples, A, B and C, in the shape a Linux batch has once the lab has copied each
// job's files next to the plan.json the Mac wrote: one folder a sample, `<sample>/`, with the plan, the record and the
// payload, and no reads, since a job reads its inputs where they were staged (ARCH-c5 point 1, BADOPT review fix 2).

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ImportFastqBatchAdoptTests: XCTestCase {
    private var scratch: ImportStreamCapture.Scratch!

    override func setUpWithError() throws {
        scratch = try ImportStreamCapture.Scratch()
    }

    override func tearDownWithError() throws {
        scratch?.remove()
    }

    private static let samples = ["A", "B", "C"]
    private static let refusedWayOn = "Fix or rerun each refused sample on the Linux machine, then adopt the whole batch again."
    private static let restDetail = "Imported: A.lungfishfastq, B.lungfishfastq.\nNot imported: C.\n"
        + "To adopt the rest, delete the imported bundles and adopt the batch again."

    /// The batch of `names` (A, B and C unless a test names others), each sample made for its sheet name with the plan naming
    /// the platform and placed as one folder a sample, and a `logs` folder beside them as a submit folder holds.
    private func batch(_ names: [String] = ImportFastqBatchAdoptTests.samples) throws -> URL {
        let batch = scratch.root.appendingPathComponent("batch", isDirectory: true)
        for name in names {
            let returned = try ExecutorReturnedFolder.make(
                root: scratch.root.appendingPathComponent("made-\(name)", isDirectory: true), clumping: .bbtools,
                platform: "illumina", sample: name
            )
            for pin in returned.plan.entries where pin.role == .input {
                try FileManager.default.removeItem(at: returned.folder.appendingPathComponent(pin.relativePath))
            }
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: returned.folder, to: batch.appendingPathComponent(name, isDirectory: true))
        }
        try FileManager.default.createDirectory(at: batch.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true)
        return batch
    }

    /// All adopted: exit 0, `complete` with `Adopted 3 samples` and the three bundles with the role bundle. The same batch
    /// again is refused whole, since the project holds each sample's name (D3), and the project does not change.
    func testBatchAdoptAllAdoptedEndsWithSampleCount() async throws {
        let batch = try batch()
        let output = try await run(batch)
        XCTAssertNil(output.thrown, "\(output.standardError)")
        let end = try Self.lastEvent(output)
        guard case let .complete(outputs, message)? = end.event else { return XCTFail("\(output.standardOutput)") }
        XCTAssertEqual(message, "Adopted 3 samples")
        let bundles = Self.samples.map { "/work/Project.lungfish/Imports/\($0).lungfishfastq" }
        XCTAssertEqual(outputs, bundles)
        XCTAssertEqual(end.artifacts.map(\.path), bundles)
        XCTAssertEqual(end.artifacts.map(\.role), Array(repeating: CLIEventArtifact.Role.bundle, count: 3))
        for line in ["Checking 2 of 3: B…", "Adopting 2 of 3: B…", "Adopted B as B.lungfishfastq", "Adopt Summary"] {
            XCTAssertTrue(output.standardError.contains { $0.contains(line) }, "\(line) is not in \(output.standardError)")
        }
        for sample in Self.samples { try assertWhole(sample) }

        let before = projectFiles()
        let again = try await run(batch)
        XCTAssertEqual(Self.exitCode(again), CLIExitCode.inputError.exitCode)
        let refused = try Self.failed(again)
        XCTAssertEqual(refused.message, "3 of 3 samples were refused. Nothing was imported.")
        XCTAssertEqual(refused.detail?.components(separatedBy: "\n").first, "A: The project already holds the bundle A.lungfishfastq.")
        XCTAssertEqual(projectFiles(), before)
    }

    /// One refused: exit `.inputError`, `1 of 3 samples was refused. Nothing was imported.`, the refused sample's line
    /// without that sentence, the way on, and a project equal before and after, listing and bytes.
    func testBatchAdoptOneRefusedImportsNothingAndListsIt() async throws {
        let batch = try batch()
        try Data("@other/1\nAAAAAAAAAA\n+\nIIIIIIIIII\n".utf8).write(to: payload(of: "B", in: batch))
        try Data("{}\n".utf8).write(to: scratch.project.appendingPathComponent("marker.json"))
        let before = projectFiles()
        let output = try await run(batch)
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.inputError.exitCode)
        let end = try Self.failed(output)
        XCTAssertEqual(end.message, "1 of 3 samples was refused. Nothing was imported.")
        let lines = try XCTUnwrap(end.detail).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines[0].hasPrefix("B: The payload \(ExecutorPlanEmitter.payloadPath) holds "), lines[0])
        XCTAssertFalse(lines[0].contains("Nothing was imported."), lines[0])
        XCTAssertEqual(lines.last, Self.refusedWayOn)
        XCTAssertTrue(output.standardError.contains { $0.contains("Refused samples:") }, "\(output.standardError)")
        XCTAssertEqual(projectFiles(), before)
        XCTAssertEqual(importedEntries(), [])
    }

    /// A sample whose job returned no reads is refused with the plain cause first (D14, UX-c5 point 7).
    func testBatchAdoptMissingPayloadSaysJobReturnedNoReads() async throws {
        let batch = try batch()
        try FileManager.default.removeItem(at: payload(of: "C", in: batch))
        let output = try await run(batch)
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.inputError.exitCode)
        let end = try Self.failed(output)
        XCTAssertEqual(
            end.detail?.components(separatedBy: "\n").first,
            "C: its job returned no reads. The payload \(ExecutorPlanEmitter.payloadPath) is missing from the folder."
        )
        XCTAssertEqual(importedEntries(), [])
    }

    /// A write failure after bundle 2: exit `.workflowError`, the count message, the bundles made, the sample left and the
    /// way on, with bundles 1 and 2 whole. The third payload goes once the second bundle is published.
    func testBatchAdoptWriteFailureAfterSecondBundleNamesTheRest() async throws {
        let batch = try batch()
        let third = payload(of: "C", in: batch)
        let output = try await run(batch) { step in
            if case .adopted(_, 2, _, _) = step { try? FileManager.default.removeItem(at: third) }
        }
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.workflowError.exitCode)
        let end = try Self.failed(output)
        XCTAssertTrue(end.message.hasPrefix("The adopt failed after 2 of 3 samples. "), end.message)
        XCTAssertEqual(end.detail, Self.restDetail)
        XCTAssertEqual(importedEntries(), ["A.lungfishfastq", "B.lungfishfastq"])
        try assertWhole("A")
        try assertWhole("B")
    }

    /// A cancel after bundle 2: exit `.cancelled`, `Adopt cancelled after 2 of 3 samples.`, and no staging bundle left.
    func testBatchAdoptCancelAfterSecondBundleKeepsThem() async throws {
        let output = try await run(try batch()) { step in
            if case .adopted(_, 2, _, _) = step { withUnsafeCurrentTask { $0?.cancel() } }
        }
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.cancelled.exitCode)
        let end = try Self.failed(output)
        XCTAssertEqual(end.message, "Adopt cancelled after 2 of 3 samples.")
        XCTAssertEqual(end.detail, Self.restDetail)
        XCTAssertEqual(importedEntries(), ["A.lungfishfastq", "B.lungfishfastq"])
        try assertWhole("B")
    }

    /// A folder of one sample keeps its words: `Adopted 1 sample`, and a refusal ending ` Nothing was imported.`.
    func testOneFolderAdoptWordsUnchanged() async throws {
        let one = try ExecutorReturnedFolder.make(root: scratch.root.appendingPathComponent("one", isDirectory: true), clumping: .bbtools)
        let output = try await run(one.folder)
        XCTAssertNil(output.thrown, "\(output.standardError)")
        guard case let .complete(_, message)? = try Self.lastEvent(output).event else { return XCTFail("\(output.standardOutput)") }
        XCTAssertEqual(message, "Adopted 1 sample")

        let other = try ExecutorReturnedFolder.make(
            root: scratch.root.appendingPathComponent("other", isDirectory: true), clumping: .bbtools, sample: "T"
        )
        try Data("@other/1\nAAAAAAAAAA\n+\nIIIIIIIIII\n".utf8).write(to: other.folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath))
        let refused = try await run(other.folder)
        XCTAssertEqual(Self.exitCode(refused), CLIExitCode.inputError.exitCode)
        let end = try Self.failed(refused)
        XCTAssertTrue(end.message.hasPrefix("The payload \(ExecutorPlanEmitter.payloadPath) holds "), end.message)
        XCTAssertTrue(end.message.hasSuffix(" Nothing was imported."), end.message)
    }

    /// D7 C (QA:15, BIOQA-c5 point 6): a sample adopted from a batch with no reads keeps the plan's platform, given, and
    /// states that no inference ran, with these exact values in the envelope and the sidecar.
    func testBatchAdoptedRecordKeepsPlatformNotInferred() async throws {
        let notInferred = "The returned folder holds no reads, so the platform was not inferred from them."
        let output = try await run(try batch())
        XCTAssertNil(output.thrown, "\(output.standardError)")
        for sample in Self.samples {
            let bundle = imports.appendingPathComponent("\(sample).lungfishfastq", isDirectory: true)
            let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(
                fromSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            ), sample)
            for (label, options) in [("explicit", envelope.options.explicit), ("resolvedDefaults", envelope.options.resolvedDefaults)] {
                XCTAssertEqual(options["platformConfidence"], .string("none"), "\(sample) \(label)")
                XCTAssertEqual(options["platformEvidence"], .array([.string(notInferred)]), "\(sample) \(label)")
            }
            XCTAssertEqual(envelope.options.explicit["platformSource"], .string("given"), sample)
            XCTAssertEqual(envelope.options.explicit["platformVendorDetail"], ParameterValue.null, sample)
            let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: bundle.appendingPathComponent("\(sample).fastq.gz")), sample)
            XCTAssertEqual(sidecar.sequencingPlatform, .illumina, sample)
            XCTAssertEqual(sidecar.assemblyReadType, .illuminaShortReads, sample)
            let assignment = try XCTUnwrap(sidecar.platformAssignment, sample)
            XCTAssertEqual(assignment.source, .given, sample)
            XCTAssertEqual(assignment.platform, .illumina, sample)
            XCTAssertEqual(assignment.readClass, .illuminaShortReads, sample)
            XCTAssertEqual(assignment.confidence?.rawValue, "none", sample)
            XCTAssertEqual(assignment.evidence, [notInferred], sample)
            XCTAssertEqual(assignment.sampledRecords, 0, sample)
            XCTAssertNil(assignment.vendorDetail, sample)
        }
    }

    /// BADOPT review fix 2 (ARCH-c5 point 1, UX 1): the job's files in `<sample>/result/` beside the plan.json the Mac wrote
    /// are a copy the lab has not finished, and the refusal names that copy. It does not blame the job, which did return, so
    /// a lab does not rerun a long Linux job to finish a copy.
    func testBatchAdoptRefusesResultFolderBesidePlanAndNamesTheCopy() async throws {
        let batch = try batch()
        let sample = batch.appendingPathComponent("B", isDirectory: true)
        let result = sample.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: sample.path) where name != "plan.json" && name != "result" {
            try FileManager.default.moveItem(at: sample.appendingPathComponent(name), to: result.appendingPathComponent(name))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent(ExecutorRunRecord.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.appendingPathComponent("plan.json").path))
        let before = projectFiles()
        let output = try await run(batch)
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.inputError.exitCode)
        let end = try Self.failed(output)
        XCTAssertEqual(end.message, "1 of 3 samples was refused. Nothing was imported.")
        let lines = try XCTUnwrap(end.detail).components(separatedBy: "\n")
        XCTAssertEqual(
            lines.first, "B: The job's files are in the folder result. Copy everything inside result into the folder B, next to plan.json."
        )
        XCTAssertEqual(lines.last, Self.refusedWayOn)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertEqual(projectFiles(), before)
        XCTAssertEqual(importedEntries(), [])
    }

    /// BADOPT review fix 3 (QA 4), a cancel before any bundle: exit `.cancelled`, `Adopt cancelled. Nothing was imported.`
    /// with no detail, and a project equal before and after. The observer cancels the task at the second preflight, so the
    /// third sample's turn meets the cancel before any write begins.
    func testBatchAdoptCancelBeforeAnyBundleImportsNothing() async throws {
        let batch = try batch()
        let before = projectFiles()
        let output = try await run(batch) { step in
            if case .checking(_, 2, _) = step { withUnsafeCurrentTask { $0?.cancel() } }
        }
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.cancelled.exitCode)
        let end = try Self.failed(output)
        XCTAssertEqual(end.message, "Adopt cancelled. Nothing was imported.")
        XCTAssertNil(end.detail)
        XCTAssertEqual(projectFiles(), before)
        XCTAssertEqual(importedEntries(), [])
    }

    /// BADOPT review fix 3 (QA 4), a write failure at the first bundle: exit `.workflowError`, `The adopt failed. <error>
    /// Nothing was imported.` with no detail, since no bundle stands, and no bundle or staging bundle in `Imports`. The
    /// observer removes the first payload as the first write begins.
    func testBatchAdoptWriteFailureAtFirstBundleImportsNothing() async throws {
        let batch = try batch()
        let first = payload(of: "A", in: batch)
        let output = try await run(batch) { step in
            if case .adopting(_, 1, _) = step { try? FileManager.default.removeItem(at: first) }
        }
        XCTAssertEqual(Self.exitCode(output), CLIExitCode.workflowError.exitCode)
        let end = try Self.failed(output)
        XCTAssertTrue(end.message.hasPrefix("The adopt failed. "), end.message)
        XCTAssertTrue(end.message.hasSuffix(" Nothing was imported."), end.message)
        XCTAssertNil(end.detail)
        XCTAssertEqual(importedEntries(), [])
    }

    /// BADOPT review fix 5 (BIO 5): the samples come in the byte order of their names, which no locale changes, so the
    /// preflight, the writes, the refusal lines and the events come in one order on every machine. A natural order that
    /// puts `a2` before `a10`, or a case-blind one, would be a different rule, and a locale-bound one is no contract.
    func testBatchAdoptOrdersSamplesByNameWhateverTheLocale() async throws {
        let batch = try batch(["a2", "a10", "B"])
        let output = try await run(batch)
        XCTAssertNil(output.thrown, "\(output.standardError)")
        let order = ["B", "a10", "a2"]
        for (position, name) in order.enumerated() {
            let line = "Checking \(position + 1) of 3: \(name)…"
            XCTAssertTrue(output.standardError.contains { $0.contains(line) }, "\(line) is not in \(output.standardError)")
        }
        guard case let .complete(outputs, _)? = try Self.lastEvent(output).event else { return XCTFail("\(output.standardOutput)") }
        XCTAssertEqual(outputs, order.map { "/work/Project.lungfish/Imports/\($0).lungfishfastq" })
    }

    private func payload(of sample: String, in batch: URL) -> URL {
        batch.appendingPathComponent(sample).appendingPathComponent(ExecutorPlanEmitter.payloadPath)
    }

    private var imports: URL { scratch.project.appendingPathComponent("Imports", isDirectory: true) }

    /// The bundles and folders in the project's `Imports` folder, hidden staging folders included.
    private func importedEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).sorted()
    }

    /// Each file and folder under the project with its bytes, so a test can tell that nothing was written.
    private func projectFiles() -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: scratch.project, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            files[url.path] = (try? Data(contentsOf: url)) ?? Data()
        }
        return files
    }

    private func run(
        _ folder: URL, observer: (@Sendable (ExecutorBatchAdoptProgress) -> Void)? = nil
    ) async throws -> ImportStreamCapture.Output {
        let command = try ImportCommand.FastqSubcommand.parse(
            [folder.path, "--adopt", "--project", scratch.project.path, "--format", "json", "--no-color"]
        )
        return try await ImportStreamCapture.capture(in: scratch) { try await command.runAdopt(batchObserver: observer) }
    }

    private static func lastEvent(_ output: ImportStreamCapture.Output) throws -> CLIEventLine {
        let line = try XCTUnwrap(output.standardOutput.last, "the run printed no event")
        return try XCTUnwrap(try CLIEventLineDecoder().decodeLine(line), line)
    }

    /// The `failed` line's message and detail.
    private static func failed(_ output: ImportStreamCapture.Output) throws -> (message: String, detail: String?) {
        guard case let .failed(message, detail)? = try lastEvent(output).event else {
            XCTFail("the run did not end with a failed line: \(output.standardOutput)")
            return ("", nil)
        }
        return (message, detail)
    }

    private static func exitCode(_ output: ImportStreamCapture.Output) -> ExitCode? {
        output.thrown as? ExitCode
    }

    /// A bundle the adopt published whole: its sidecar and its signed record read.
    private func assertWhole(_ sample: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let bundle = imports.appendingPathComponent("\(sample).lungfishfastq", isDirectory: true)
        XCTAssertNotNil(FASTQMetadataStore.load(for: bundle.appendingPathComponent("\(sample).fastq.gz")), sample, file: file, line: line)
        XCTAssertNotNil(
            try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)),
            sample, file: file, line: line
        )
    }
}
