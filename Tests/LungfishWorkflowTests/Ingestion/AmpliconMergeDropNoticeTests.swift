// AmpliconMergeDropNoticeTests.swift - The Illumina Amplicon Merge recipe says that it drops the pairs that do not merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// Row AMPLICON-MERGE-DROP-WORDS. `illumina-amplicon-merge` keeps only the reads fastp merged from overlapping pairs and
/// drops every pair that did not merge, 60,000 pairs in BIO's run, and a person was not told. The recipe's description now
/// says so, and an import whose merge dropped pairs logs one notice with the counts of the tool's own report. Words a
/// person reads are checked by meaning, so the notice is checked by its sentence and by the line the Operations row logs.
final class AmpliconMergeDropNoticeTests: XCTestCase {
    private static let recipeFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LungfishWorkflow/Resources/Recipes/illumina-amplicon-merge.recipe.json")

    // MARK: - The description

    /// The sheet's picker and the record show `description` as the recipe's file gives it, so the words live in the file.
    /// They hold only while the step drops the pairs that did not merge, which the second half checks.
    func testTheRecipeDescriptionSaysPairsThatDoNotOverlapAreDroppedAndNotStored() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.recipeFile)) as? [String: Any]
        )
        XCTAssertEqual(
            object["description"] as? String,
            "Prepare paired-end Illumina amplicon reads for exact-match genotyping by keeping only reads merged from "
                + "overlapping pairs. Pairs that do not overlap are dropped and are not stored. The normal FASTQ import "
                + "finalization step then clumpifies and compresses each sample bundle."
        )
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        let params = try XCTUnwrap(steps.first?["params"] as? [String: Any])
        XCTAssertEqual(params["keepUnmerged"] as? Bool, false,
                       "the description says the pairs that do not merge are dropped, so the step must drop them")
    }

    // MARK: - The notice

    private func mergeStep(dropped: Int?, input: Int? = 80_000, output: Int? = 20_000) throws -> RecipeStepResult {
        var json: [String: Any] = ["stepName": "Merge overlapping pairs", "tool": "fastp", "durationSeconds": 1.0]
        json["inputReadCount"] = input
        json["outputReadCount"] = output
        json["droppedUnmergedPairs"] = dropped
        return try JSONDecoder().decode(RecipeStepResult.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func events(for step: RecipeStepResult) -> [ImportLogEvent] {
        let info = RecipeAppliedInfo(
            recipeID: "illumina-amplicon-merge",
            recipeName: "Illumina Amplicon Merge",
            appliedDate: Date(timeIntervalSince1970: 0),
            stepResults: [step]
        )
        return FASTQBatchImporter.recipeReadDeltaEvents(sample: "S1", recipeApplied: info)
    }

    /// BIO's words: the merged reads kept and the pairs dropped, both as the tool's report gave them.
    func testAMergeThatDroppedPairsLogsOneNoticeWithTheCountsOfTheReport() throws {
        let logged = events(for: try mergeStep(dropped: 60_000))
        XCTAssertEqual(logged.count, 1, "\(logged)")
        guard case let .notice(sample, message)? = logged.first else {
            return XCTFail("expected a notice, got \(logged)")
        }
        let sentence = "Illumina Amplicon Merge kept 20,000 merged reads and dropped 60,000 pairs that did not merge."
        XCTAssertEqual(sample, "S1")
        XCTAssertEqual(message, sentence)

        // The Operations row logs it at the warning level, so it is not read as one more progress line.
        var stream = FASTQImportEventStream(projectDirectory: URL(fileURLWithPath: "/tmp/AmpliconMergeDropNotice"))
        guard case let .log(level, line)? = stream.events(for: logged[0]).first else {
            return XCTFail("the notice became no log event")
        }
        XCTAssertEqual(level, .warning)
        XCTAssertEqual(line, "S1 \u{2014} \(sentence)")
    }

    func testOneAndOnePairReadSingular() throws {
        let logged = events(for: try mergeStep(dropped: 1, input: 2, output: 1))
        guard case let .notice(_, message)? = logged.first else { return XCTFail("expected a notice, got \(logged)") }
        XCTAssertEqual(message, "Illumina Amplicon Merge kept 1 merged read and dropped 1 pair that did not merge.")
    }

    /// No notice names a count that the tool's report did not give, and none when nothing was dropped.
    func testNoNoticeWhenNothingWasDroppedOrTheReportGaveNoCount() throws {
        XCTAssertTrue(events(for: try mergeStep(dropped: 0)).isEmpty, "every pair merged")
        XCTAssertTrue(events(for: try mergeStep(dropped: nil)).isEmpty,
                      "the report gave no unmerged pairs, and 80,000 less 20,000 is not a count that it gave")
        XCTAssertTrue(events(for: try mergeStep(dropped: 60_000, output: nil)).isEmpty,
                      "the kept merged reads are part of the sentence, so a step that holds none says nothing")
    }
}
