import XCTest
@testable import LungfishIO

final class RecipeAppliedInfoSummaryTests: XCTestCase {
    private func step(_ name: String, tool: String, input: Int?, output: Int?) -> RecipeStepResult {
        RecipeStepResult(
            stepName: name,
            tool: tool,
            toolVersion: nil,
            commandLine: nil,
            commandArguments: nil,
            inputReadCount: input,
            outputReadCount: output,
            durationSeconds: 0
        )
    }

    private func step(
        _ name: String,
        tool: String,
        input: Int?,
        output: Int?,
        commandArguments: [String]? = nil,
        logicalComponents: [RecipeLogicalComponent] = []
    ) -> RecipeStepResult {
        RecipeStepResult(
            stepName: name,
            tool: tool,
            commandArguments: commandArguments,
            inputReadCount: input,
            outputReadCount: output,
            durationSeconds: 0,
            logicalComponents: logicalComponents
        )
    }

    /// A record written before the merged recipe (C2-MERGED) keeps every field it holds, gains none when written
    /// again, and still reads as deduplicated in one fused fastp pass.
    func test_baseWrittenRecordReadsUnchanged() throws {
        let json = Data("""
        {"appliedDate":782000000,"recipeFormatVersion":1,"recipeID":"vsp2-target-enrichment",\
        "recipeName":"VSP2 Target Enrichment","recipeSHA256":"0f0e","stepResults":[{"commandArguments":\
        ["fastp","--dedup","-A","-G","-Q","-L","--detect_adapter_for_pe","-q","15","-W","5","--cut_right"],\
        "durationSeconds":2.5,"inputReadCount":1000,"logicalComponents":[{"displayName":"Remove PCR duplicates",\
        "typeID":"fastp-dedup"},{"displayName":"Adapter + quality trim","typeID":"fastp-trim"}],\
        "outputReadCount":880,"stepName":"Remove PCR duplicates + Adapter + quality trim","tool":"fastp"}]}
        """.utf8)
        let info = try JSONDecoder().decode(RecipeAppliedInfo.self, from: json)
        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertTrue(info.deduplicationPerformedInCombinedPass)
        XCTAssertEqual(info.totalReadsRemoved, 120)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rewritten = try encoder.encode(info)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? NSDictionary)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? NSDictionary)
        XCTAssertEqual(before, after)
    }

    func testDeduplicationSummaryUsesDedupStepCounts() throws {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step("Remove PCR duplicates", tool: "fastp", input: 1_000_000, output: 720_000),
                step("Remove human reads", tool: "deacon", input: 720_000, output: 700_000),
            ]
        )

        let summary = try XCTUnwrap(info.deduplicationSummary)
        XCTAssertEqual(summary.inputReads, 1_000_000)
        XCTAssertEqual(summary.outputReads, 720_000)
        XCTAssertEqual(summary.readsRemoved, 280_000)
        XCTAssertEqual(summary.percentRemoved, 28.0, accuracy: 0.001)
        XCTAssertEqual(RecipeAppliedInfo.readDeltaLogLine("Deduplication", summary), "Deduplication removed 28.0% of reads (1,000,000 -> 720,000)")
    }

    func testHumanScrubSummaryUsesScrubStepCounts() throws {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step("Remove PCR duplicates", tool: "fastp", input: 1_000_000, output: 720_000),
                step("Remove human reads", tool: "deacon", input: 720_000, output: 700_000),
            ]
        )

        let summary = try XCTUnwrap(info.humanScrubSummary)
        XCTAssertEqual(summary.inputReads, 720_000)
        XCTAssertEqual(summary.outputReads, 700_000)
        XCTAssertEqual(summary.readsRemoved, 20_000)
        XCTAssertEqual(summary.percentRemoved, 2.777, accuracy: 0.001)
    }

    func testReadDeltaSummaryNilWhenCountsAreMissing() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step("Remove PCR duplicates", tool: "fastp", input: nil, output: nil),
            ]
        )

        XCTAssertNil(info.deduplicationSummary)
    }

    func testStructuredFusedDeduplicationReportsCombinedPassWithoutDedupOnlySummary() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step(
                    "Remove PCR duplicates + Adapter + quality trim",
                    tool: "fastp",
                    input: 1_000_000,
                    output: 720_000,
                    logicalComponents: [
                        RecipeLogicalComponent(typeID: "fastp-dedup", displayName: "Remove PCR duplicates"),
                        RecipeLogicalComponent(typeID: "fastp-trim", displayName: "Adapter + quality trim"),
                    ]
                ),
            ]
        )

        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertTrue(info.deduplicationPerformedInCombinedPass)
        XCTAssertNil(info.deduplicationSummary)
        XCTAssertEqual(info.totalReadsRemoved, 280_000)
    }

    func testStructuredTrimComponentIDsOverrideStaleDeduplicationMetadata() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step(
                    "Remove PCR duplicates + Adapter + quality trim",
                    tool: "fastp",
                    input: 1_000_000,
                    output: 720_000,
                    commandArguments: ["fastp", "--dedup", "--cut_front"],
                    logicalComponents: [
                        RecipeLogicalComponent(typeID: "fastp-trim", displayName: "Remove PCR duplicates"),
                    ]
                ),
            ]
        )

        XCTAssertFalse(info.didApplyDeduplication)
        XCTAssertFalse(info.deduplicationPerformedInCombinedPass)
        XCTAssertNil(info.deduplicationSummary)
    }

    func testStructuredDedupComponentIDOverridesStaleTrimmingMetadata() throws {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step(
                    "Remove PCR duplicates + Adapter + quality trim",
                    tool: "fastp",
                    input: 1_000_000,
                    output: 720_000,
                    commandArguments: ["fastp", "--dedup", "--cut_front"],
                    logicalComponents: [
                        RecipeLogicalComponent(typeID: "fastp-dedup", displayName: "Adapter + quality trim"),
                    ]
                ),
            ]
        )

        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertFalse(info.deduplicationPerformedInCombinedPass)
        XCTAssertEqual(try XCTUnwrap(info.deduplicationSummary).readsRemoved, 280_000)
    }

    func testLegacyFusedDeduplicationIsRecognizedFromKnownFastpCombinedNameOnly() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step(
                    "Remove PCR duplicates + Adapter + quality trim",
                    tool: "fastp",
                    input: 1_000_000,
                    output: 720_000
                ),
            ]
        )

        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertTrue(info.deduplicationPerformedInCombinedPass)
        XCTAssertNil(info.deduplicationSummary)
    }

    func testLegacyFusedDeduplicationIsRecognizedFromArgvOnly() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2-target-enrichment",
            recipeName: "VSP2 Target Enrichment",
            stepResults: [
                step(
                    "Legacy fastp processing",
                    tool: "fastp",
                    input: 1_000_000,
                    output: 720_000,
                    commandArguments: ["fastp", "--dedup", "--cut_front", "--length_required", "20"]
                ),
            ]
        )

        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertTrue(info.deduplicationPerformedInCombinedPass)
        XCTAssertNil(info.deduplicationSummary)
    }

    func testLegacyQualityAwareDuplicateRemovalNameIsNotTreatedAsCombinedPass() throws {
        let info = RecipeAppliedInfo(
            recipeID: "legacy-recipe",
            recipeName: "Legacy Recipe",
            stepResults: [
                step(
                    "Quality-aware duplicate removal",
                    tool: "fastp",
                    input: 1_000_000,
                    output: 850_000
                ),
            ]
        )

        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertFalse(info.deduplicationPerformedInCombinedPass)
        XCTAssertEqual(try XCTUnwrap(info.deduplicationSummary).readsRemoved, 150_000)
    }

    func testLegacyCombinedNameRequiresFastpTool() throws {
        let info = RecipeAppliedInfo(
            recipeID: "legacy-recipe",
            recipeName: "Legacy Recipe",
            stepResults: [
                step(
                    "Remove PCR duplicates + Adapter + quality trim",
                    tool: "other-tool",
                    input: 1_000_000,
                    output: 850_000
                ),
            ]
        )

        XCTAssertTrue(info.didApplyDeduplication)
        XCTAssertFalse(info.deduplicationPerformedInCombinedPass)
        XCTAssertEqual(try XCTUnwrap(info.deduplicationSummary).readsRemoved, 150_000)
    }
}
