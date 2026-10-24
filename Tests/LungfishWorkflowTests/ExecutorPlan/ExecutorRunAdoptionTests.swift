// ExecutorRunAdoptionTests.swift - The adopt's refusals and the record it writes from a plan and a run record (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoption")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A returned plan folder: the emitter's plan, a payload and a succeeded run record that is true to both.
    private struct Returned {
        let folder: URL
        let plan: ExecutionPlan
        var record: ExecutorRunRecord

        func write() throws {
            try record.encoded().write(to: folder.appendingPathComponent(ExecutorRunRecord.fileName))
        }
    }

    private func returned(_ clumping: ClumpingTool, siteFacts: [PlanKeyValue] = []) throws -> Returned {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emission = try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: clumping), host: ExecutorPlanTestSupport.mac24
        )
        let folder = root.appendingPathComponent("returned-\(clumping.rawValue)", isDirectory: true)
        let planFile = try ExecutorPlanFolderWriter.write(emission, into: folder)
        let planBytes = try Data(contentsOf: planFile)
        let payloadBytes = Data("@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n".utf8)
        let payloadURL = folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payloadBytes.write(to: payloadURL)
        let payload = ExecutorFileDigest(
            relativePath: ExecutorPlanEmitter.payloadPath, sha256: PortableDigest.sha256Hex(of: payloadBytes),
            size: Int64(payloadBytes.count)
        )
        let plan = emission.plan
        let time = "2026-10-24T12:00:00.000Z"
        let steps = plan.steps.map { step in
            ExecutorStepRecord(
                id: step.id, kind: step.kind,
                tool: step.tool.map { ExecutorToolRecord(id: $0.id, version: $0.version, build: $0.build, path: "/opt/conda/bin/\($0.id)") },
                outcome: .succeeded, argv: step.arguments, environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30,
                deadlineSeconds: step.deadlineSeconds, toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 1,
                qualityCounts: step.kind == .qualityCount
                    ? ExecutorQualityCounts(baseCount: 20, q20Count: 20, q30Count: 20, recordCount: 2, file: payload) : nil,
                storage: step.kind == .storage
                    ? ExecutorStorageDetails(clumpingRan: plan.clumping.resolved == .bbtools, qualityBinning: plan.storage.qualityBinning,
                                             inputBytes: 200, outputBytes: payload.size)
                    : nil
            )
        }
        let record = ExecutorRunRecord(
            outcome: .succeeded, executorArguments: ["run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: ExecutorPlanTestSupport.digest, size: 17, buildPin: plan.executor),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)),
            recipe: plan.recipe,
            imageManifest: ExecutorImageManifestRecord(sha256: plan.imageManifest.sha256, size: plan.imageManifest.size, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2, observedLimits: [],
                subreaper: ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "0", getterResult: 0, getterValue: 1),
                orphanSweep: .subreaper
            ),
            siteFacts: siteFacts, inputs: plan.entries.filter { $0.role != .executor },
            payloads: [ExecutorPayloadRecord(
                relativePath: payload.relativePath, sha256: payload.sha256, size: payload.size, recordCount: 2, recordCountFile: payload
            )],
            steps: steps, startedAt: time, endedAt: time, wallSeconds: 3
        )
        let returned = Returned(folder: folder, plan: plan, record: record)
        try returned.write()
        return returned
    }

    private var project: URL { root.appendingPathComponent("Project.lungfish", isDirectory: true) }

    /// Every entry under the project's imports folder, hidden staging folders included.
    private func importedEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Imports").path)) ?? []
    }

    private func refusal(_ returned: Returned, policy: ExecutorAdoptPolicy = .release) async -> ExecutorAdoptRefusal? {
        do {
            _ = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project, policy: policy)
            return nil
        } catch let refusal as ExecutorAdoptRefusal {
            return refusal
        } catch {
            XCTFail("The adopt failed with \(error) in place of a refusal")
            return nil
        }
    }

    private func envelope(_ bundle: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(
            fromSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
    }

    /// S-2 and ARCH Q-C4-6: the public entry refuses a replay's record before any bundle file exists, and only the
    /// internal replay value lifts that one refusal.
    func testAdoptRefusesArgumentManifestSource() async throws {
        var returned = try returned(.bbtools)
        returned.record.imageManifest?.source = .argument
        try returned.write()
        let first = await refusal(returned)
        let refused = try XCTUnwrap(first)
        XCTAssertEqual(refused.field, "imageManifest.source")
        XCTAssertTrue(refused.reason.contains("--image-manifest"), refused.reason)
        XCTAssertEqual(importedEntries(), [])

        let bundle = try await ExecutorRunAdoption.adopt(
            resultFolder: returned.folder, projectDirectory: project, policy: .macReplayForTests
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("S.fastq.gz").path))

        // The replay value still checks the manifest's digest against the plan's pin.
        returned.record.imageManifest?.sha256 = String(repeating: "c", count: 64)
        try returned.write()
        let pinned = await refusal(returned, policy: .macReplayForTests)
        XCTAssertEqual(pinned?.field, "imageManifest.sha256")
    }

    /// C4-02: a record whose site facts break the executor's bounds is refused, naming the position and never the value.
    func testAdoptRefusesSiteFactOverBounds() async throws {
        let cases: [(facts: [PlanKeyValue], field: String, words: String)] = [
            ([PlanKeyValue(key: "Machine", value: "MARK" + String(repeating: "v", count: 1021))], "siteFacts[0]",
             "Site fact 1 has a value over 1024 bytes."),
            ((1...65).map { PlanKeyValue(key: "K\($0)", value: "MARK") }, "siteFacts[64]", "Site fact 65 is over the limit of 64 site facts."),
            ([PlanKeyValue(key: "A", value: "MARK1"), PlanKeyValue(key: "A", value: "MARK2")], "siteFacts[1]",
             "Site fact 2 repeats the key of an earlier site fact."),
            ([PlanKeyValue(key: "9lives", value: "MARK")], "siteFacts[0]", "Site fact 1 has a key that is not a letter"),
            ([PlanKeyValue(key: "C", value: "MARK\u{01}")], "siteFacts[0]", "Site fact 1 has a value that holds a control character."),
        ]
        for (facts, field, words) in cases {
            let returned = try returned(.bbtools, siteFacts: facts)
            let outcome = await refusal(returned)
            let refused = try XCTUnwrap(outcome, field)
            XCTAssertEqual(refused.field, field)
            XCTAssertTrue(refused.reason.hasPrefix(words), refused.reason)
            XCTAssertFalse(refused.reason.contains("MARK"), refused.reason)
            XCTAssertEqual(importedEntries(), [], field)
            try FileManager.default.removeItem(at: returned.folder)
            try FileManager.default.removeItem(at: root.appendingPathComponent("S", isDirectory: true))
        }
    }

    /// S-1: one flipped byte of a copied payload refuses the adopt, the message names that payload, and no bundle
    /// folder exists afterwards.
    func testAdoptRefusesPayloadWhoseDigestDiffersFromRecord() async throws {
        let returned = try returned(.bbtools)
        let payloadURL = returned.folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        var bytes = try Data(contentsOf: payloadURL)
        bytes[3] ^= 0x01
        try bytes.write(to: payloadURL)
        let outcome = await refusal(returned)
        let refused = try XCTUnwrap(outcome)
        XCTAssertEqual(refused.field, "payloads[0]")
        XCTAssertTrue(refused.reason.contains("The payload \(ExecutorPlanEmitter.payloadPath) has SHA-256"), refused.reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports/S.lungfishfastq").path))
        XCTAssertEqual(importedEntries(), [])
    }

    /// C4-02: a run from any Linux machine passes no site fact, and its record adopts.
    func testAdoptAcceptsRecordWithNoSiteFacts() async throws {
        let returned = try returned(.bbtools)
        XCTAssertEqual(returned.record.siteFacts, [])
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: project)
        XCTAssertEqual(bundle.lastPathComponent, "S.lungfishfastq")
        let fastq = bundle.appendingPathComponent("S.fastq.gz")
        XCTAssertEqual(try Data(contentsOf: fastq), try Data(contentsOf: returned.folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)))
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: fastq)?.ingestion)
        XCTAssertEqual(ingestion.storageOutputSizeBytes, returned.record.payloads[0].size)
        XCTAssertEqual(ingestion.originalFilenames, returned.plan.sample.originalFilenames)
        XCTAssertEqual(importedEntries(), ["S.lungfishfastq"])
    }

    /// C4-01, XC-7, XC-8 and XC-13 on the adopted record, for an automatic plan and for one that names the tool.
    func testAdoptedRecordOfAutoPlanNullsHostBasis() async throws {
        let physicalMemory = String(ProcessInfo.processInfo.physicalMemory)
        for clumping in [ClumpingTool.auto, .bbtools] {
            let returned = try returned(clumping)
            let projectFolder = root.appendingPathComponent("Project-\(clumping.rawValue).lungfish", isDirectory: true)
            let bundle = try await ExecutorRunAdoption.adopt(resultFolder: returned.folder, projectDirectory: projectFolder)
            let envelope = try envelope(bundle)
            let resolved = envelope.options.resolvedDefaults
            let label = clumping.rawValue
            for key in ["clumpingEstimatedInputBytes", "clumpingPhysicalMemoryBytes", "clumpingThresholdBytes"] {
                XCTAssertEqual(resolved[key], .null, "\(label) \(key)")
            }
            for key in ["threadsSource", "clumpifyHeapSource", "resolvedClumpingToolSource", "qualityBinningSource"] {
                XCTAssertEqual(resolved[key], .string("plan"), "\(label) \(key)")
            }
            XCTAssertEqual(resolved["requestedClumpingTool"], .string(clumping.rawValue), label)
            XCTAssertEqual(resolved["resolvedClumpingTool"], .string("bbtools"), label)
            XCTAssertEqual(resolved["clumpingResolutionReason"], .string(returned.plan.clumping.reason), label)
            XCTAssertEqual(resolved["clumpingPlanHeapBytes"], .integer(Int(returned.plan.clumping.heapBytes)), label)
            // BIO's testAdoptedRecordOfAutomaticPlanNamesNoHostEstimate: no key holds this Mac's memory.
            let text = String(decoding: try Data(contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)), as: UTF8.self)
            XCTAssertFalse(text.contains(physicalMemory), "\(label) names the Mac's physical memory")

            // QA ruling 2: the executor's step parents every node step, and the import step is the run's last.
            let executor = try XCTUnwrap(envelope.steps.first { $0.toolName == ExecutorRunAdoption.executorToolName }, label)
            let nodeSteps = envelope.steps.filter { $0.parentStepID == executor.id }
            XCTAssertEqual(nodeSteps.count, returned.record.steps.count, label)
            XCTAssertEqual(executor.parentStepID, envelope.steps.last?.id, label)
            XCTAssertEqual(envelope.steps.last?.toolName, "lungfish import fastq", label)
            XCTAssertFalse(envelope.steps.contains { $0.toolName == "seqkit" && $0.argv.contains("stats") && $0.parentStepID != executor.id }, label)
        }
    }
}
