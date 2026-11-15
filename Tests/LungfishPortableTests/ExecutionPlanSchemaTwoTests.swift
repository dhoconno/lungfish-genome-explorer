// ExecutionPlanSchemaTwoTests.swift - The decoder of plan schema 2 and the version 1 plan it leaves alone (Phase 5.3
// lane EX-TOOL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

/// A schema 2 plan of one sample: a stand-in counting tool `salmon` that reads one reference file, an image barcode
/// list, and one output of each policy.
enum SchemaTwoPlanFixture {
    static let digest = String(repeating: "b", count: 64)
    static let salmon = PlanToolPin(id: "salmon", version: "2.11.0", build: "t0")
    static let setID = "macaca_mulatta-Mmul_10-ensembl100-lge-3f9a1c2b7d10"

    static func pipeline(toolVersion: String = "2.11.0") -> PlanPipeline {
        PlanPipeline(
            id: "salmon-bulk", version: 1, preset: PlanPipelinePreset(id: "bulk", name: "Bulk counts (salmon)"),
            modality: .bulk,
            route: PlanPipelineRoute(id: "salmon", tool: "salmon", toolVersion: toolVersion, settings: [
                "duplicates": "Duplicates: kept. LGE removes duplicates only with UMIs.", "trimming": "Reads not trimmed",
            ]),
            referenceSet: PlanPipelineReferenceSet(id: setID, layout: .lge),
            settings: [
                PlanPipelineSetting(id: "trimming", label: "Trimming", value: "Reads not trimmed", source: .default),
                PlanPipelineSetting(id: "duplicates", label: "Duplicates", value: "Duplicates: kept. LGE removes duplicates only with UMIs.", source: .default),
            ]
        )
    }

    static func countStep(policy: [String: PlanOutputPolicy]? = nil, kind: PlanStepKind = .tool) -> PlanStep {
        PlanStep(
            id: "quant", title: "Count with salmon", kind: kind, tool: salmon,
            arguments: ["quant", "-i", "references/\(setID)/derived/transcripts.fa", "-r", "inputs/R1.fastq"],
            deadlineSeconds: ExecutionPlan.maximumDeadlineSeconds, inputs: ["inputs/R1.fastq"],
            outputs: ["out/quant.sf", "out/index.bin", "out/reads.bam"],
            outputPolicy: policy ?? ["out/quant.sf": .home, "out/index.bin": .staged, "out/reads.bam": .stays]
        )
    }

    static func plan(
        pipeline: PlanPipeline? = pipeline(), steps: [PlanStep] = [countStep()], instrument: PlanSampleInstrument? = nil
    ) -> ExecutionPlan {
        ExecutionPlan(
            entries: [
                PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: digest, size: 10),
                PlanEntry(role: .input, relativePath: "inputs/R1.fastq", sha256: digest, size: 20),
                PlanEntry(
                    role: .reference, relativePath: "references/\(setID)/derived/transcripts.fa", sha256: digest, size: 30,
                    reference: PlanReferenceIdentity(setID: setID, path: "derived/transcripts.fa")
                ),
                PlanEntry(
                    role: .barcodeList, relativePath: "barcodes/3M-february-2018.txt", sha256: digest, size: 40,
                    barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: .image)
                ),
            ],
            executor: PlanExecutorBuild(
                lgeVersion: "2026.11.9", lgeCommit: String(repeating: "c", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "swift-6.2", toolchainSHA256: digest, staticLinuxSDKID: "sdk", staticLinuxSDKSHA256: digest
            ),
            imageManifest: PlanImageManifestPin(sha256: digest, size: 512),
            tools: [salmon], recipe: nil, pipeline: pipeline,
            sample: PlanSampleValues(sampleName: "S1", originalFilenames: ["S1_R1.fastq"], originalSizeBytes: 20, instrument: instrument),
            storage: nil, clumping: nil, graceSeconds: 30, steps: steps
        )
    }
}

final class ExecutionPlanSchemaTwoTests: XCTestCase {
    private typealias Fixture = SchemaTwoPlanFixture

    private func json(_ plan: ExecutionPlan, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.encoded()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertRefused(_ data: Data, field: String, reason: String? = nil, line: UInt = #line) {
        XCTAssertThrowsError(try ExecutionPlan.decode(data), line: line) { error in
            let refusal = error as? PlanDecodeError
            XCTAssertEqual(refusal?.field, field, "\(error)", line: line)
            if let reason { XCTAssertEqual(refusal?.reason, reason, line: line) }
        }
    }

    private func assertRefused(_ plan: ExecutionPlan, field: String, reason: String? = nil, line: UInt = #line) throws {
        assertRefused(try plan.encoded(), field: field, reason: reason, line: line)
        XCTAssertThrowsError(try plan.validate(), line: line)
    }

    func testPlanWithAPipelineWritesSchemaTwoAndRoundTrips() throws {
        let plan = Fixture.plan()
        let text = String(decoding: try plan.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 2"), text)
        XCTAssertFalse(text.contains("\"storage\"") || text.contains("\"clumping\"") || text.contains("\"recipe\""), text)
        XCTAssertEqual(try ExecutionPlan.decode(plan.encoded()), plan)
        XCTAssertEqual(ExecutionPlan.currentSchemaVersion, 1)
    }

    func testSchemaThreeIsRefusedBeforeAnyOtherKey() throws {
        let data = try json(Fixture.plan()) { object in
            object["schemaVersion"] = 3
            object["entries"] = "not entries"
        }
        assertRefused(data, field: "schemaVersion", reason: "This plan has schema version 3, and this executor reads versions 1 and 2.")
    }

    func testVersionOnePlanHoldingASchemaTwoKeyIsRefusedWithItsSentence() throws {
        let pipeline = try json(Fixture.plan()) { object in
            object["schemaVersion"] = 1
            object["storage"] = nil
        }
        // A version 1 plan that leaves out storage keeps schema 1's words (EX-SCHEMA-ARCH backlog).
        assertRefused(pipeline, field: "storage", reason: "This plan has no storage.")
        var plan = Fixture.plan()
        plan.schemaVersion = 1
        plan.storage = PlanStorageSettings(
            clumpingTool: .none, compressor: .bgzip, qualityBinning: .illumina4, threads: 1, clumpifyHeapGB: 1,
            compressionLevel: 4, threadsSource: .option, clumpifyHeapSource: .option, clumpingToolSource: .option,
            compressorSource: .option, qualityBinningSource: .option
        )
        plan.clumping = PlanClumpingChoice(requested: .none, resolved: .none, resolvedSource: .option, heapBytes: 1 << 30, reason: "named")
        try assertRefused(plan, field: "entries[2].role", reason: "This plan has schema version 1 and holds entries[2].role reference, which schema 2 added.")
        plan.entries.removeLast(2)
        try assertRefused(plan, field: "pipeline", reason: "This plan has schema version 1 and holds pipeline, which schema 2 added.")
        plan.pipeline = nil
        try assertRefused(plan, field: "steps[0].kind", reason: "This plan has schema version 1 and holds steps[0].kind tool, which schema 2 added.")
        plan.steps[0].kind = .recipe
        try assertRefused(plan, field: "steps[0].outputPolicy", reason: "This plan has schema version 1 and holds steps[0].outputPolicy, which schema 2 added.")
        plan.steps[0].outputPolicy = nil
        XCTAssertNoThrow(try ExecutionPlan.decode(plan.encoded()))
    }

    func testStepOfAnotherKindAndAMissingPolicyAreRefused() throws {
        try assertRefused(
            Fixture.plan(steps: [Fixture.countStep(kind: .recipe)]), field: "steps[0].kind",
            reason: "This plan has schema version 2 and its step quant has kind recipe, which a schema 2 plan does not hold."
        )
        try assertRefused(Fixture.plan(steps: [Fixture.countStep(policy: ["out/quant.sf": .home])]), field: "steps[0].outputPolicy",
                          reason: "Step quant gives no policy for its output out/index.bin.")
        var extra: [String: PlanOutputPolicy] = ["out/quant.sf": .home, "out/index.bin": .staged, "out/reads.bam": .stays]
        extra["out/other"] = .home
        try assertRefused(Fixture.plan(steps: [Fixture.countStep(policy: extra)]), field: "steps[0].outputPolicy")
    }

    func testCountingStepWithNoHomeReportIsRefused() throws {
        let policy: [String: PlanOutputPolicy] = ["out/quant.sf": .stays, "out/index.bin": .staged, "out/reads.bam": .stays]
        try assertRefused(Fixture.plan(steps: [Fixture.countStep(policy: policy)]), field: "steps[0].outputPolicy",
                          reason: "Step quant runs salmon, the counting tool the route names, and returns none of its reports. A counting step names its tool's reports as home outputs.")
    }

    func testRouteVersionThatDiffersFromThePinIsRefused() throws {
        try assertRefused(Fixture.plan(pipeline: Fixture.pipeline(toolVersion: "2.11.1")), field: "pipeline.route.tool",
                          reason: "This plan's route names salmon 2.11.1, and no step runs a pin of that id and version.")
    }

    func testSchemaTwoRefusesSchemaOneKeysAndBrokenIdentity() throws {
        var plan = Fixture.plan()
        plan.storage = PlanStorageSettings.absent
        try assertRefused(plan, field: "storage", reason: "This plan has schema version 2 and holds storage, which a schema 2 plan does not hold.")
        try assertRefused(Fixture.plan(pipeline: nil).withVersion(2), field: "pipeline", reason: "This plan has no pipeline.")
        plan = Fixture.plan()
        plan.pipeline?.settings[0].source = .host
        try assertRefused(plan, field: "pipeline.settings[0].source")
        plan = Fixture.plan()
        plan.pipeline?.route?.settings["trimming"] = "Poly-G trimming: off (LGE default)"
        try assertRefused(plan, field: "pipeline.route.settings")
        plan = Fixture.plan()
        plan.pipeline?.modality = nil
        try assertRefused(plan, field: "pipeline.modality")
        plan = Fixture.plan()
        plan.entries[2].reference?.setID = "another-set"
        try assertRefused(plan, field: "entries[2].reference.setID")
        plan = Fixture.plan()
        plan.entries[2].reference = nil
        try assertRefused(plan, field: "entries[2].reference",
                          reason: "A reference entry carries its set id and its path in the set, and no other entry does.")
        plan = Fixture.plan()
        plan.entries[3].barcodeList = nil
        try assertRefused(plan, field: "entries[3].barcodeList")
        plan = Fixture.plan()
        plan.entries.swapAt(2, 3)
        try assertRefused(plan, field: "entries")
        try assertRefused(Fixture.plan(instrument: PlanSampleInstrument(model: " NovaSeq", inferred: true)), field: "sample.instrument")
        XCTAssertNoThrow(try Fixture.plan(instrument: PlanSampleInstrument(model: "NovaSeq 6000", inferred: true)).validate())
    }

    func testIndexBuildPlanHasNoSampleAndPinsAReference() throws {
        var plan = Fixture.plan()
        plan.pipeline?.route = nil
        plan.pipeline?.modality = nil
        plan.entries.remove(at: 1)
        try assertRefused(plan, field: "sample")
        plan.sampleValues = nil
        XCTAssertEqual(try ExecutionPlan.decode(plan.encoded()), plan)
        plan.entries.remove(at: 1)
        try assertRefused(plan, field: "entries")
    }

    func testTemplateWithAPipelineFillsSchemaTwoWithTheInstrument() throws {
        let plan = Fixture.plan()
        let template = PlanTemplate(
            entries: plan.entries.filter { $0.role != .input }, inputs: [PlanInputSlot(relativePath: "inputs/R1.fastq")],
            executor: plan.executor, imageManifest: plan.imageManifest, tools: plan.tools, recipe: nil,
            pipeline: plan.pipeline, platform: nil, storage: nil, clumping: nil, graceSeconds: 30, steps: plan.steps
        )
        XCTAssertEqual(template.schemaVersion, 2)
        let instrument = PlanSampleInstrument(model: "NovaSeq 6000", inferred: false)
        let filled = try template.fill(PlanSampleFill(
            sampleName: "S1", originalFilenames: ["S1_R1.fastq"],
            inputs: [PlanInputFile(sha256: Fixture.digest, size: 20)], instrument: instrument
        ))
        XCTAssertEqual(filled, Fixture.plan(instrument: instrument))
    }
}

private extension ExecutionPlan {
    func withVersion(_ version: Int) -> ExecutionPlan {
        var copy = self
        copy.schemaVersion = version
        return copy
    }
}
