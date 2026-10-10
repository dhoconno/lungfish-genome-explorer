// ProvenanceEnvelopeStatusTests.swift - The envelope stores how a run ended
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishWorkflow

/// A cancelled run can end on a step that exited 0, so the exit status cannot say
/// the result is partial. The envelope therefore stores the status under the
/// `status` key, reads it back tolerantly and passes it through every copy.
@Suite("Provenance envelope status")
struct ProvenanceEnvelopeStatusTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// An envelope with no steps, so that only the status rules are in play.
    private static func envelope(
        exitStatus: Int?,
        status: RunStatus? = nil,
        nested: WorkflowRun? = nil
    ) -> ProvenanceEnvelope {
        ProvenanceEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000057A7")!,
            createdAt: startedAt,
            workflowName: "status fixture",
            workflowVersion: "fixture-workflow-version",
            toolName: "fixture-tool",
            toolVersion: "1.0.0",
            argv: ["fixture-tool", "--run"],
            runtimeIdentity: .fixture(),
            wallTimeSeconds: 2,
            exitStatus: exitStatus,
            status: status,
            legacyWorkflowRun: nested
        )
    }

    private static func nestedRun(status: RunStatus) -> WorkflowRun {
        WorkflowRun(
            name: "status fixture",
            startTime: startedAt,
            endTime: startedAt.addingTimeInterval(2),
            status: status,
            appVersion: "Lungfish fixture",
            hostOS: "macOS fixture",
            runtime: WorkflowRuntime(appVersion: "Lungfish fixture", hostOS: "macOS fixture", user: nil)
        )
    }

    /// A cancelled record whose last step exited 0, with one input and one output.
    private static func cancelledRecord(outputPath: String) -> ProvenanceEnvelope {
        let input = ProvenanceFileDescriptor(
            path: "/fixture/reads.fastq",
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 16,
            format: .fastq,
            role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: outputPath,
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 0,
            format: .fastq,
            role: .output
        )
        return ProvenanceEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000057A8")!,
            createdAt: startedAt,
            workflowName: "cancelled fixture",
            workflowVersion: "fixture-workflow-version",
            toolName: "fixture-tool",
            toolVersion: "1.0.0",
            argv: ["fixture-tool", input.path, output.path],
            runtimeIdentity: .fixture(),
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [
                ProvenanceStep(
                    toolName: "fixture-tool",
                    toolVersion: "1.0.0",
                    argv: ["fixture-tool", input.path, output.path],
                    inputs: [input],
                    outputs: [output],
                    exitStatus: 0,
                    wallTimeSeconds: 0.25,
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(0.25)
                ),
            ],
            wallTimeSeconds: 0.25,
            exitStatus: 0,
            status: .cancelled
        )
    }

    /// The encoded envelope as JSON, edited by `edit` and encoded again as bytes.
    private static func editedJSON(
        of envelope: ProvenanceEnvelope,
        _ edit: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let encoded = try ProvenanceJSON.encoder.encode(envelope)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        try edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Initializer rules

    @Test("the initializer stores the given status, else the nested run's, else what the exit status implies")
    func initializerPrecedence() {
        // Given status first, even when the nested run and the exit status disagree.
        #expect(Self.envelope(exitStatus: 0, status: .cancelled, nested: Self.nestedRun(status: .failed)).status == .cancelled)
        #expect(Self.envelope(exitStatus: 1, status: .completed).status == .completed)
        // The nested run's status next.
        #expect(Self.envelope(exitStatus: 0, nested: Self.nestedRun(status: .cancelled)).status == .cancelled)
        #expect(Self.envelope(exitStatus: nil, nested: Self.nestedRun(status: .completed)).status == .completed)
        // The exit status last: none means running, 0 completed, anything else failed.
        #expect(Self.envelope(exitStatus: nil).status == .running)
        #expect(Self.envelope(exitStatus: 0).status == .completed)
        #expect(Self.envelope(exitStatus: 1).status == .failed)
        #expect(Self.envelope(exitStatus: 130).status == .failed)
        #expect(Self.envelope(exitStatus: -9).status == .failed)
    }

    // MARK: Encode and decode

    @Test("every status survives encode, decode and encode byte for byte", arguments: [
        RunStatus.running, .completed, .failed, .cancelled,
    ])
    func everyStatusRoundTripsByteForByte(status: RunStatus) throws {
        for exitStatus in [nil, 0, 1, 130] as [Int?] {
            let original = Self.envelope(exitStatus: exitStatus, status: status)
            let first = try ProvenanceJSON.encoder.encode(original)
            let decoded = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: first)
            let second = try ProvenanceJSON.encoder.encode(decoded)

            #expect(decoded.status == status, "exit status \(String(describing: exitStatus))")
            #expect(decoded == original, "exit status \(String(describing: exitStatus))")
            #expect(first == second, "exit status \(String(describing: exitStatus))")
            let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
            #expect(object["status"] as? String == status.rawValue)
        }
    }

    @Test("a status that equals what a record wrote before is written as before")
    func storedStatusEqualToTheOldDerivationWritesTheSameKey() throws {
        // Before the status was stored the key held the nested run's status, else what the exit status implies.
        let cases: [(exitStatus: Int?, nested: RunStatus?, written: String)] = [
            (nil, nil, "running"),
            (0, nil, "completed"),
            (1, nil, "failed"),
            (0, .cancelled, "cancelled"),
            (nil, .completed, "completed"),
            (1, .running, "running"),
        ]
        for item in cases {
            let envelope = Self.envelope(exitStatus: item.exitStatus, nested: item.nested.map(Self.nestedRun(status:)))
            let object = try #require(
                JSONSerialization.jsonObject(with: ProvenanceJSON.encoder.encode(envelope)) as? [String: Any]
            )
            #expect(object["status"] as? String == item.written, "\(item)")
        }
    }

    @Test("a status of the wrong JSON type or an unknown word decodes as it did before the key was read")
    func aStatusOfTheWrongTypeDecodesAsBefore() throws {
        let unusable: [Any] = [7, 1.5, true, [String](), [String: String](), NSNull(), "success", "Completed", ""]
        let exitStatuses: [(exitStatus: Int?, implied: RunStatus)] = [(nil, .running), (0, .completed), (1, .failed)]

        for value in unusable {
            for item in exitStatuses {
                let bytes = try Self.editedJSON(of: Self.envelope(exitStatus: item.exitStatus, status: .cancelled)) {
                    $0["status"] = value
                }
                let decoded = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes)
                #expect(decoded.status == item.implied, "value \(value), exit status \(String(describing: item.exitStatus))")
                #expect(decoded.exitStatus == item.exitStatus)
            }

            // With a nested run the nested run's status is what it was before.
            let bytes = try Self.editedJSON(of: Self.envelope(exitStatus: 0)) {
                $0["status"] = value
                $0["legacyWorkflowRun"] = try JSONSerialization.jsonObject(
                    with: ProvenanceJSON.encoder.encode(Self.nestedRun(status: .cancelled))
                )
            }
            let decoded = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes)
            #expect(decoded.legacyRun?.status == .cancelled)
            #expect(decoded.status == .cancelled, "value \(value)")
        }
    }

    @Test("the status key wins over the nested run, and a record without the key keeps today's reading")
    func decodePrecedence() throws {
        let nested = try JSONSerialization.jsonObject(
            with: ProvenanceJSON.encoder.encode(Self.nestedRun(status: .cancelled))
        )

        let disagreeing = try Self.editedJSON(of: Self.envelope(exitStatus: 0)) {
            $0["status"] = "failed"
            $0["legacyWorkflowRun"] = nested
        }
        #expect(try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: disagreeing).status == .failed)

        let keyless = try Self.editedJSON(of: Self.envelope(exitStatus: 0)) {
            $0.removeValue(forKey: "status")
            $0["legacyWorkflowRun"] = nested
        }
        #expect(try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: keyless).status == .cancelled)

        let bare = try Self.editedJSON(of: Self.envelope(exitStatus: 1)) {
            $0.removeValue(forKey: "status")
        }
        #expect(try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bare).status == .failed)
    }

    // MARK: Frozen bytes

    @Test("the frozen cancelled capture reads cancelled from its bytes without the nested run")
    func frozenCancelledCaptureReadsCancelledWithoutItsNestedRun() throws {
        let materialized = try ProvenanceCompatCorpus.materialize("s1-cancelled-single-step")
        defer { materialized.cleanup() }

        let original = try Data(contentsOf: materialized.sidecar)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        #expect(object["legacyWorkflowRun"] is [String: Any], "the capture embeds the run")
        #expect(object["status"] as? String == "cancelled")
        #expect(object["exitStatus"] as? Int == 0, "the last step exited 0, so the exit status says completed")

        // The capture as it is.
        let embedded = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        #expect(embedded.legacyRun?.status == .cancelled)
        #expect(embedded.status == .cancelled)

        // The same bytes with the nested run removed, which is what a new record looks like.
        object.removeValue(forKey: "legacyWorkflowRun")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: materialized.sidecar)

        let tolerant = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        #expect(tolerant.legacyRun == nil)
        #expect(tolerant.exitStatus == 0)
        #expect(tolerant.status == .cancelled)
        #expect(tolerant.legacyWorkflowRun().status == .cancelled)
        #expect(tolerant.legacyWorkflowRun(preferCanonicalSteps: true).status == .cancelled)

        let strict = try #require(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: materialized.sidecar))
        #expect(strict.status == .cancelled)
    }

    // MARK: Producers and copies

    @Test("a cancelled run keeps its status when it becomes an envelope", arguments: [
        RunStatus.running, .completed, .failed, .cancelled,
    ])
    func canonicalEnvelopeKeepsTheRunStatus(status: RunStatus) throws {
        let run = WorkflowRun(
            name: "canonical status fixture",
            startTime: Self.startedAt,
            endTime: Self.startedAt.addingTimeInterval(1),
            status: status,
            steps: [
                StepExecution(
                    toolName: "fixture-tool",
                    toolVersion: "1.0.0",
                    command: ["fixture-tool", "--run"],
                    inputs: [],
                    outputs: [FileRecord(path: "/fixture/out.txt", format: .text, role: .output)],
                    exitCode: 0,
                    wallTime: 1,
                    startTime: Self.startedAt,
                    endTime: Self.startedAt.addingTimeInterval(1)
                ),
            ]
        )

        let envelope = run.canonicalEnvelope()

        #expect(envelope.status == status)
        // The last step exited 0, so only a failed run is given another exit status (1).
        #expect(envelope.exitStatus == (status == .failed ? 1 : 0))
        #expect(envelope.legacyWorkflowRun(preferCanonicalSteps: true).status == status)
        let object = try #require(
            JSONSerialization.jsonObject(with: ProvenanceJSON.encoder.encode(envelope)) as? [String: Any]
        )
        #expect(object["status"] as? String == status.rawValue)
    }

    @Test("every copy of an envelope keeps a cancelled status")
    func copiesKeepACancelledStatus() throws {
        let directory = try TestTempDirectory.make(prefix: "envelope-status-copies")
        defer { TestTempDirectory.cleanup(directory) }
        let outputPath = directory.appendingPathComponent("out.fastq").path
        let source = Self.cancelledRecord(outputPath: outputPath)
        #expect(source.status == .cancelled)
        #expect(source.exitStatus == 0)
        #expect(source.legacyRun == nil)
        let output = try #require(source.output)
        let signature = ProvenanceSignatureReference(
            provider: "fixture-provider",
            provenanceSHA256: String(repeating: "d", count: 64),
            signaturePath: "fixture.sig",
            publicKeyPath: "fixture.pub"
        )

        let copies: [(name: String, envelope: ProvenanceEnvelope)] = [
            ("focusedOnOutput", source.focusedOnOutput(output)),
            ("projectedToBundleOutputs", source.projectedToBundleOutputs([output])),
            ("replacingSignatures", source.replacingSignatures([signature])),
            ("upsertingSignatureReference", source.upsertingSignatureReference(signature)),
            // The output is missing from disk, so this copy really is rebuilt.
            ("droppingMissingRunLevelFiles", source.droppingMissingRunLevelFiles()),
        ]
        for copy in copies {
            #expect(copy.envelope.status == .cancelled, "\(copy.name)")
            #expect(copy.envelope.exitStatus == 0, "\(copy.name)")
        }
        #expect(copies.last?.envelope.outputs.isEmpty == true, "the dropped copy was rebuilt")
    }

    @Test("a focused sidecar of a cancelled record stays cancelled on disk")
    func focusedSidecarOfACancelledRecordStaysCancelled() throws {
        let directory = try TestTempDirectory.make(prefix: "envelope-status-focused")
        defer { TestTempDirectory.cleanup(directory) }
        let outputURL = directory.appendingPathComponent("out.fastq")
        let source = Self.cancelledRecord(outputPath: outputURL.path)
        let focused = source.focusedOnOutput(try #require(source.output))
        #expect(focused.legacyRun == nil, "only the status key can carry the status")

        let sidecar = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        try ProvenanceWriter(signingProvider: nil).write(focused, toSidecar: sidecar)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        )
        #expect(object["status"] as? String == "cancelled")
        #expect(object["exitStatus"] as? Int == 0)
        let reread = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        #expect(reread.status == .cancelled)
        #expect(reread.legacyWorkflowRun().status == .cancelled)
    }

    @Test("a recorder run completed as cancelled is saved as cancelled")
    func recorderSaveWritesACancelledStatus() async throws {
        let directory = try TestTempDirectory.make(prefix: "envelope-status-recorder")
        defer { TestTempDirectory.cleanup(directory) }
        let recorder = ProvenanceRecorder(signingProvider: nil)

        // Plain save, save with explicit options, and a save that drops a run-level file that is gone.
        for variant in ["plain", "options", "dropMissing"] {
            let runID = await recorder.beginRun(name: "Cancelled \(variant)")
            await recorder.recordStep(
                runID: runID,
                toolName: "fixture-tool",
                toolVersion: "1.0.0",
                command: ["fixture-tool", "--run"],
                inputs: [],
                outputs: [FileRecord(
                    path: directory.appendingPathComponent("missing-\(variant).txt").path,
                    format: .text,
                    role: .output
                )],
                exitCode: 0,
                wallTime: 0.5
            )
            await recorder.completeRun(runID, status: .cancelled)

            let target = directory.appendingPathComponent(variant, isDirectory: true)
            switch variant {
            case "options":
                try await recorder.save(
                    runID: runID,
                    to: target,
                    options: ProvenanceOptions(explicit: ["limit": .integer(5)])
                )
            case "dropMissing":
                try await recorder.save(runID: runID, to: target, dropMissingRunLevelFiles: true)
            default:
                try await recorder.save(runID: runID, to: target)
            }

            let bytes = try Data(contentsOf: target.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["status"] as? String == "cancelled", "\(variant)")
            #expect(object["exitStatus"] as? Int == 0, "\(variant)")
            let envelope = try ProvenanceEnvelopeReader.decodeCanonical(bytes)
            #expect(envelope.status == .cancelled, "\(variant)")
            #expect(envelope.legacyWorkflowRun().status == .cancelled, "\(variant)")
            if variant == "dropMissing" {
                #expect(envelope.outputs.isEmpty, "the run-level outputs were dropped")
            }
        }
    }
}
