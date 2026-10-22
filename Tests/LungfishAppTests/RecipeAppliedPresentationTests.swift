// RecipeAppliedPresentationTests.swift - What the Inspector shows for a recipe run record, read as strings
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO

/// CHTC lane C2-MERGED fix 1 (UX 5, 6, 8, 9, 10). The Inspector draws what `RecipeAppliedPresentation` returns, so
/// these tests read its strings and never a view. An older record keeps its lines and gains rows that read Not
/// recorded, a step a switch turned off reads as not run, and nothing writes the sidecar.
final class RecipeAppliedPresentationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-applied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A record in the shape the builds before the merged recipe wrote: no switch field, no digest.
    private func legacyRecord(recipeName: String, recipeID: String) -> Data {
        Data("""
        {"appliedDate":782000000,"recipeID":"\(recipeID)","recipeName":"\(recipeName)","stepResults":[\
        {"commandArguments":["fastp","--dedup","-A","-G","-Q","-L","--detect_adapter_for_pe","-q","15","-W","5",\
        "--cut_right"],"durationSeconds":2.5,"inputReadCount":1000,"logicalComponents":[\
        {"displayName":"Remove PCR duplicates","typeID":"fastp-dedup"},\
        {"displayName":"Adapter + quality trim","typeID":"fastp-trim"}],"outputReadCount":880,\
        "stepName":"Remove PCR duplicates + Adapter + quality trim","tool":"fastp","toolVersion":"0.23.4"},\
        {"durationSeconds":1,"inputReadCount":880,"outputReadCount":860,"stepName":"Remove human reads",\
        "tool":"deacon","toolVersion":"0.5"}]}
        """.utf8)
    }

    /// The record of `RecipeAppliedInfoSummaryTests.test_gatedOffDedupReadsAsNotApplied`: duplicates kept, so the
    /// dedup result comes first, turned off by the option, and holds no counts.
    private func keptDuplicatesRecord() throws -> RecipeAppliedInfo {
        let json = Data("""
        {"appliedDate":782000000,"recipeFormatVersion":2,"recipeID":"illumina-paired-cleanup",\
        "recipeName":"Illumina paired-end cleanup","stepResults":[{"durationSeconds":0,\
        "stepName":"Remove duplicate reads","tool":"none","turnedOffBy":{"id":"removeDuplicates",\
        "label":"Remove duplicate reads","source":"option","value":false}},{"commandArguments":["fastp",\
        "--detect_adapter_for_pe","-g","--poly_g_min_len","10","-q","15","-u","40","-n","5","-l","15","-W","5",\
        "--cut_tail","-M","20"],"durationSeconds":2.5,"inputReadCount":1000,"outputReadCount":900,\
        "stepName":"Adapter + quality trim","tool":"fastp"}]}
        """.utf8)
        return try JSONDecoder().decode(RecipeAppliedInfo.self, from: json)
    }

    private func notRecordedRows() -> [RecipeAppliedPresentation.Row] {
        let notRecorded = RecipeAppliedPresentation.notRecorded
        return [
            .init(label: "Preset", value: notRecorded),
            .init(label: "Remove duplicate reads", value: notRecorded),
            .init(label: "Remove ribosomal RNA reads", value: notRecorded),
            .init(label: "Recipe digest", value: notRecorded),
        ]
    }

    /// (i) The three names an older record can carry keep their old lines, each new row reads Not recorded, and the
    /// sidecar is the same bytes after every presenter has run (UX 5, 6, 8).
    func testOlderRecordsKeepTheirLinesAndReadNotRecordedForTheNewRows() throws {
        let fixtures = [
            ("Illumina VSP2 Target Enrichment", "illuminaVSP2TargetEnrichment"),
            ("VSP2 Target Enrichment", "vsp2-target-enrichment"),
            ("Wastewater metagenomics", "wastewater-metagenomics"),
        ]
        for (name, id) in fixtures {
            let data = legacyRecord(recipeName: name, recipeID: id)
            let sidecar = folder.appendingPathComponent("\(id).json")
            try data.write(to: sidecar)
            let info = try JSONDecoder().decode(RecipeAppliedInfo.self, from: Data(contentsOf: sidecar))

            XCTAssertEqual(info.recipeName, name)
            XCTAssertEqual(RecipeAppliedPresentation.rows(for: info), notRecordedRows(), name)
            XCTAssertEqual(RecipeAppliedPresentation.netReadsRemoved(for: info), "140 (14.0%)", name)
            XCTAssertEqual(RecipeDeduplicationPresentation.presentation(for: info), .combinedPass, name)
            XCTAssertEqual(info.stepResults.map(RecipeAppliedPresentation.toolText), ["fastp 0.23.4", "deacon 0.5"], name)
            XCTAssertTrue(info.stepResults.allSatisfy {
                RecipeAppliedPresentation.notRunLine(for: $0) == nil && RecipeAppliedPresentation.durationText(for: $0) != nil
            }, name)

            let script = RecipeAppliedPresentation.reproducibilityScript(for: info, appliedDate: "Oct 22, 2026")
            let lines = script.components(separatedBy: "\n")
            XCTAssertTrue(lines.contains("# 2 step(s)"), name)
            XCTAssertTrue(lines.contains("# Step 1: Remove PCR duplicates + Adapter + quality trim"), name)
            XCTAssertTrue(lines.contains("# Tool: fastp 0.23.4"), name)
            XCTAssertTrue(lines.contains("# Step 2: Remove human reads"), name)

            XCTAssertEqual(try Data(contentsOf: sidecar), data, "\(name): rendering leaves the sidecar's bytes alone")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(info)) as? NSDictionary)
            XCTAssertEqual(before, after, "\(name): the new optional fields write nothing for an older record")
        }
    }

    /// (ii) A run that kept duplicates shows no Deduplication row (UX 9).
    func testKeptDuplicatesRecordHasNoDeduplicationRow() throws {
        let info = try keptDuplicatesRecord()
        XCTAssertNil(RecipeDeduplicationPresentation.presentation(for: info))
    }

    /// (iii) A turned-off result reads exactly "Not run, <label> is off", with no tool and no time (UX 10).
    func testTurnedOffResultReadsAsNotRunWithNoToolAndNoTime() throws {
        let off = RecipeSwitchSetting(
            id: "removeRibosomalRNA", label: "Remove ribosomal RNA reads", value: false, source: .recipeDefault
        )
        let step = RecipeStepResult.turnedOff(stepName: "Remove ribosomal RNA reads", by: off)
        XCTAssertEqual(RecipeAppliedPresentation.notRunLine(for: step), "Not run, Remove ribosomal RNA reads is off")
        XCTAssertNil(RecipeAppliedPresentation.toolText(for: step))
        XCTAssertNil(RecipeAppliedPresentation.durationText(for: step))
    }

    /// (iv) Net reads removed keeps its percentage when the first result is the turned-off dedup (UX 9, 10).
    func testKeptDuplicatesRecordKeepsThePercentageOnNetReadsRemoved() throws {
        let info = try keptDuplicatesRecord()
        XCTAssertEqual(RecipeAppliedPresentation.netReadsRemoved(for: info), "100 (10.0%)")
    }

    /// A record from this build shows the preset and each switch with where its value came from, in the words of
    /// the person (UX 8), and the digest.
    func testNewRecordRowsNameThePresetAndEachSwitchSource() {
        let info = RecipeAppliedInfo(
            recipeID: "illumina-paired-cleanup", recipeName: "Illumina paired-end cleanup", stepResults: [],
            recipeSHA256: "ab12cd", recipeFormatVersion: 2, requestedName: "wastewater-metagenomics",
            presetID: "wastewater-metagenomics", presetName: "Wastewater metagenomics",
            switchSettings: [
                RecipeSwitchSetting(id: "removeDuplicates", label: "Remove duplicate reads", value: false, source: .option),
                RecipeSwitchSetting(id: "removeRibosomalRNA", label: "Remove ribosomal RNA reads", value: true, source: .preset),
            ]
        )
        XCTAssertEqual(RecipeAppliedPresentation.rows(for: info), [
            .init(label: "Preset", value: "Wastewater metagenomics"),
            .init(label: "Remove duplicate reads", value: "Off (your choice)"),
            .init(label: "Remove ribosomal RNA reads", value: "On (preset)"),
            .init(label: "Recipe digest", value: "ab12cd"),
        ])

        let defaults = RecipeAppliedInfo(
            recipeID: "illumina-paired-cleanup", recipeName: "Illumina paired-end cleanup", stepResults: [],
            requestedName: "illumina-paired-cleanup",
            switchSettings: [
                RecipeSwitchSetting(id: "removeDuplicates", label: "Remove duplicate reads", value: true, source: .recipeDefault),
            ]
        )
        let rows = RecipeAppliedPresentation.rows(for: defaults)
        XCTAssertEqual(rows.first, .init(label: "Preset", value: "None (recipe defaults)"))
        XCTAssertEqual(rows[1], .init(label: "Remove duplicate reads", value: "On (recipe default)"))
        XCTAssertEqual(rows[2], .init(label: "Remove ribosomal RNA reads", value: RecipeAppliedPresentation.notRecorded))
    }

    /// Copy Pipeline as Script names a turned-off step as not run, counts only the steps that ran, and no longer
    /// calls it a lost command (UX 10).
    func testScriptNamesATurnedOffStepAndCountsOnlyTheStepsThatRan() {
        let off = RecipeSwitchSetting(id: "removeDuplicates", label: "Remove duplicate reads", value: false, source: .option)
        let info = RecipeAppliedInfo(
            recipeID: "illumina-paired-cleanup", recipeName: "Illumina paired-end cleanup",
            stepResults: [
                .turnedOff(stepName: "Remove duplicate reads", by: off),
                RecipeStepResult(
                    stepName: "Adapter + quality trim", tool: "fastp", toolVersion: "0.23.4",
                    commandLine: "fastp -i a.fq -o b.fq", inputReadCount: 1000, outputReadCount: 900, durationSeconds: 2
                ),
            ]
        )
        let lines = RecipeAppliedPresentation.reproducibilityScript(for: info, appliedDate: "Oct 22, 2026")
            .components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("# 1 step(s)"))
        XCTAssertTrue(lines.contains("# Step 1: Remove duplicate reads was not run, Remove duplicate reads is off"))
        XCTAssertTrue(lines.contains("# Step 2: Adapter + quality trim"))
        XCTAssertTrue(lines.contains("fastp -i a.fq -o b.fq"))
        XCTAssertFalse(lines.contains("# (no command recorded for this step)"))
    }
}
