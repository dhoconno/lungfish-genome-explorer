// UMIPlanTests.swift - The UMI branch's kit preset and its layout check step in the plan (Phase 5.3 lane EX-UMI,
// milestone 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class UMIPlanTests: XCTestCase {
    var root: URL!
    var storageRoot: URL!

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rnaseq/umi-plan/plan.json")

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "umi-plan")
        storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    var pins: UMIPlanPins {
        let zeros = String(repeating: "0", count: 64)
        return UMIPlanPins(
            executor: ExecutorPlanSourceFile(
                url: root.appendingPathComponent("lungfish-executor"), sha256: String(repeating: "a", count: 64), size: 1000),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros),
            imageManifest: PlanImageManifestPin(sha256: String(repeating: "b", count: 64), size: 4000),
            pigz: PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_1"))
    }

    /// One C9 run in the staging folder, as `rnaseq quant --write-plan --samplesheet` names it, with the kit column's
    /// value.
    func made(kit: String = "quartz-seq2-x910") async throws -> UMIPlanOutcome {
        let owner = ReferenceSetOwner(
            storageRoot: storageRoot, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let set = try await owner.build(ReferenceSetMitoFixture.request(.lge))
        func read(_ name: String, _ fill: String) -> SalmonPlanStagedRead {
            SalmonPlanStagedRead(path: "/staging/c9/\(name)", size: 1_234_567, sha256: String(repeating: fill, count: 64))
        }
        let sample = SalmonPlan.stagedSample(
            name: "SRR28155077", pairs: [(read("SRR28155077_1.fastq.gz", "1"), read("SRR28155077_2.fastq.gz", "2"))],
            model: "HiSeq X Ten")
        return try UMIPlan.make(UMIPlanRequest(setFolder: set.url, sample: sample, kit: kit, pins: pins))
    }

    /// Item 3: the plan's bytes with the check step and the preset's settings.
    func testPlanBytesHoldTheCheckStepAndThePresetSettings() async throws {
        let made = try await made()
        let bytes = try made.plan.encoded()
        let pinned = (try? Data(contentsOf: Self.fixture)) ?? Data()
        if bytes != pinned {
            let written = root.deletingLastPathComponent().appendingPathComponent("umi-plan-\(UUID().uuidString).json")
            try bytes.write(to: written)
            XCTFail("the plan's bytes differ from \(Self.fixture.path), and this run's are at \(written.path)")
        }
    }

    /// Items 1 and 2: the check is the first `tool` step, pinned to the plan's own executor build, before extraction,
    /// and its argv and `pipeline.settings` state the motif, the UMI's length and read, the pairs, their choice and the
    /// bars.
    func testCheckStepIsTheExecutorsOwnAndItsArgvStatesThePreset() async throws {
        let plan = try await made().plan
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.id, "umi-layout-check-pair1")
        XCTAssertEqual(step.kind, .tool)
        XCTAssertEqual(step.tool, PlanToolPin(id: "lungfish-executor", version: "test", build: String(repeating: "0", count: 40)))
        XCTAssertEqual(plan.tools.map(\.id), ["lungfish-executor", "pigz"])
        let check = try UMILayoutCheck.Arguments(argv: step.arguments)
        XCTAssertEqual(check, UMILayoutCheck.Arguments(
            read1: "inputs/pair1_R1.fastq.gz", read2: "inputs/pair1_R2.fastq.gz", decompressor: "pigz",
            kit: UMIPlan.quartzSeq2X910.label, motif: "ATCAATC", umiLength: 16, umiRead: 1, pairs: 1000, choice: .even,
            bars: UMILayoutCheck.Bars(withinOneMismatchPass: 90, exactWarn: 90, distinctFail: 50, distinctWarn: 80),
            output: "umi-check/pair1-layout-check.json"))
        XCTAssertEqual(step.outputPolicy, ["umi-check/pair1-layout-check.json": .home])
        let settings = Dictionary(uniqueKeysWithValues: (plan.pipeline?.settings ?? []).map { ($0.id, $0) })
        XCTAssertEqual(settings["umiExtraction"]?.value,
                       "umi_tools extract --extract-method=regex --bc-pattern=^(?P<discard_1>ATCAATC)(?P<umi_1>.{16})")
        XCTAssertEqual(settings["umiGrouping"]?.value,
                       "umi_tools count --per-gene --gene-tag=XT --assigned-status-tag=XS --method=directional")
        XCTAssertEqual(settings["umiCheckPairs"]?.value, "1,000 pairs, spread evenly through the file after counting its reads (--choice even)")
        XCTAssertEqual(settings["trimming"]?.value, "Reads not trimmed")
        XCTAssertNil(settings["adapter"], "C9's preset carries no adapter")
        XCTAssertEqual(plan.pipeline?.preset, PlanPipelinePreset(id: "quartz-seq2-x910", name: UMIPlan.quartzSeq2X910.label))
    }

    /// EX-UMI-M1-BIO should-fix 3: the plan a person reads states every fail rule the check applies, the names rule among
    /// them (brief item 2, ADJ-BULK G1).
    func testCheckBarsSettingStatesTheNamesRule() async throws {
        let plan = try await made().plan
        let bars = try XCTUnwrap(plan.pipeline?.settings.first { $0.id == "umiCheckBars" })
        XCTAssertEqual(bars.value, "fails when a read name differs between the mates in any pair, when under 90% of the pairs read "
            + "start within one mismatch of ATCAATC, or when under 50% hold a distinct UMI, and warns when under 90% start with it "
            + "exactly or under 80% hold a distinct UMI")
    }

    /// EX-UMI-M1-BIO ruling 4 and S3: each value the kit's preset fixes enters the plan with source `preset`, `trimming`
    /// (which no preset fixes) keeps `default`, and the executor's decoder accepts the plan.
    func testPresetValuesEnterThePlanWithSourcePreset() async throws {
        XCTAssertEqual(ImportSettingSource(rawValue: "preset")?.rawValue, "preset")
        let plan = try await made().plan
        let settings = try XCTUnwrap(plan.pipeline?.settings)
        XCTAssertEqual(settings.map { "\($0.id) \($0.source.rawValue)" }, [
            "trimming default", "umiCheckBars preset", "umiCheckPairs preset", "umiExtraction preset", "umiGrouping preset",
            "umiKit preset", "umiLength preset", "umiMotif preset", "umiRead preset",
        ])
        let decoded = try ExecutionPlan.decode(try plan.encoded())
        XCTAssertEqual(decoded.pipeline?.settings.map(\.source.rawValue), settings.map(\.source.rawValue))
    }

    /// The kit column picks the preset by id, and an unknown kit is refused with the kits LGE knows.
    func testUnknownKitIsRefusedWithTheKnownKits() async throws {
        do {
            _ = try await made(kit: "10x-3prime-v3")
            XCTFail("an unknown kit wrote a plan")
        } catch let error as SalmonPlanError {
            XCTAssertEqual(error.message, "The sample sheet names the kit 10x-3prime-v3, which LGE has no UMI preset for. The kits "
                + "LGE knows are quartz-seq2-x910 (\(UMIPlan.quartzSeq2X910.label)).")
        }
    }
}
