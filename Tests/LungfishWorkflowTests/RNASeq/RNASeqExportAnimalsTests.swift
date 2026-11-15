// RNASeqExportAnimalsTests.swift - The animals rule of a pseudobulk export (Phase 5.2 lane RS-SC-HANDOFF, slice A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A pseudobulk comparison counts animals and not cells (`docs/formats/rnaseq-bundle.md`, Pseudobulk). The export refuses a
// pseudobulk result whose tested factor has a level with columns of fewer than 3 animals, and a column that holds no animal,
// before any file is written, and both templates run the same rule before the fit. A bulk result is never held to it.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// One column of a result written for these tests: its id, its animal and its group (the label of a pseudobulk column).
struct RNASeqAnimalsColumn {
    var id: String
    var animal: String?
    var group: String?
}

extension RNASeqExportTestCase {
    /// The columns of the given animals in each group, named `<animal>_<group>`.
    func animalColumns(_ groups: [(group: String, animals: [String])]) -> [RNASeqAnimalsColumn] {
        groups.flatMap { entry in
            entry.animals.map { RNASeqAnimalsColumn(id: "\($0)_\(entry.group)", animal: $0, group: entry.group) }
        }
    }

    /// Writes one result of these columns into `analyses` with the one writer, as `RNASeqExportFixture.make` does. The default is
    /// a pseudobulk result, with its origin and the route setting the summing step adds, and `.quantified` makes a bulk result.
    func animalsResult(
        _ name: String, _ columns: [RNASeqAnimalsColumn], kind: RNASeqResultManifest.Origin.Kind = .pseudobulk
    ) throws -> URL {
        let scratch = analyses.deletingLastPathComponent().appendingPathComponent("inputs-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let genes = ["G1", "G2", "G3", "G4"]
        var genesText = "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\n"
        for id in genes { genesText += "\(id)\t\(id)\tprotein_coding\tchr1\t1000\tfalse\t\t\n" }
        let genesURL = scratch.appendingPathComponent("genes.tsv")
        try genesText.write(to: genesURL, atomically: true, encoding: .utf8)
        let ids = columns.map(\.id)
        let rows = genes.enumerated().map { gene, id in
            RNASeqCountTable.Row(id: id, counts: ids.indices.map { Double(10 * (gene + 1) + $0) })
        }
        var route = RNASeqExportFixture.salmonReads
        if kind == .pseudobulk { route.settings[RNASeqPseudobulk.routeSetting] = RNASeqPseudobulk.routeSettingValue }
        let request = RNASeqResultWriter.Request(
            name: name, modality: .bulk, origin: .init(kind: kind, tool: "STARsolo", toolVersion: "Not recorded"), route: route,
            referenceSet: RNASeqExportFixture.humanSet,
            samples: columns.map { RNASeqSampleRecord(id: $0.id, animal: $0.animal, group: $0.group, runs: [$0.id]) },
            genes: .referenceSetTable(url: genesURL, keeping: genes),
            counts: [.init(rows: .gene, column: .default, unit: kind == .pseudobulk ? .umis : .estimated, table: RNASeqCountTable(sampleIDs: ids, rows: rows))],
            sourceFiles: [], notHost: [])
        let url = analyses.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq pseudobulk", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
        return url
    }
}

final class RNASeqExportAnimalsTests: RNASeqExportTestCase {
    private let intro = "A pseudobulk comparison needs columns of at least 3 animals in each level of"
    private let because = "because tests on single cells give false discoveries, so LGE counts animals and not cells."

    private func byGroup(_ factor: String = "group", numerator: String = "T", denominator: String = "B") -> RNASeqExportSettings {
        RNASeqExportSettings(design: [factor], contrasts: [.init(factor: factor, numerator: numerator, denominator: denominator)])
    }

    @discardableResult
    private func export(_ results: [URL], sheet: URL? = nil, settings: RNASeqExportSettings? = nil, name: String = "out") throws -> URL {
        let out = root.appendingPathComponent(name, isDirectory: true)
        try RNASeqExport.run(
            results: results, sheet: sheet, settings: settings ?? byGroup(), output: out, argv: ["lungfish-cli", "rnaseq", "export"])
        return out
    }

    /// The words of the refusal, and a failure when the export was written.
    private func words(_ results: [URL], sheet: URL? = nil, settings: RNASeqExportSettings? = nil, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            try export(results, sheet: sheet, settings: settings)
            XCTFail("the export was written", file: file, line: line)
            return ""
        } catch {
            XCTAssertTrue(error is RNASeqExportRefusal, "\(error)", file: file, line: line)
            return error.localizedDescription
        }
    }

    private func nothingWritten(file: StaticString = #filePath, line: UInt = #line) throws {
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") || $0 == "out" }
        XCTAssertEqual(left, [], "a refused export leaves no stage and no folder", file: file, line: line)
    }

    private func script(_ name: String, in out: URL) throws -> String {
        try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)
    }

    func testTwoAnimalsInOneLevelAreRefusedWithTheLevelTheAnimalsAndTheReasonAndNothingIsWritten() throws {
        let result = try animalsResult("pb", animalColumns([("B", ["A1", "A2"]), ("T", ["A1", "A2", "A3"])]))
        let text = words([result])
        XCTAssertTrue(text.hasPrefix("\(intro) group, \(because) Here the level B holds columns of 2 animals (A1, A2)."), text)
        XCTAssertFalse(text.contains("level T"), "a level of 3 animals is not named: \(text)")
        XCTAssertTrue(text.hasSuffix("Add animals so that each level holds 3 or more, or compare levels that already do."), text)
        try nothingWritten()
    }

    func testEachLevelUnderThreeAnimalsIsNamedInCodePointOrder() throws {
        let result = try animalsResult("pb", animalColumns([("T", ["A1", "A2", "A3"]), ("B", ["A1"]), ("C", ["A2", "A3"])]))
        let text = words([result])
        XCTAssertTrue(text.contains("Here the level B holds columns of 1 animal (A1), and the level C holds columns of 2 animals (A2, A3). Add animals"), text)
    }

    func testThreeAnimalsInEachLevelPassAndBothScriptsHoldTheRuleBeforeTheFit() throws {
        let result = try animalsResult("pb", animalColumns([("B", ["A1", "A2", "A3"]), ("T", ["A1", "A2", "A3"])]))
        let out = try export([result])
        for (name, fit) in [("deseq2.R", "DESeqDataSetFromMatrix("), ("edger-limma-dream.R", "DGEList(counts)")] {
            let text = try script(name, in: out)
            XCTAssertTrue(text.contains("min_animals <- 3"), "\(name) holds the minimum")
            let check = try XCTUnwrap(text.range(of: "check_animals(coldata, design_terms, min_animals)"), "\(name) calls the check")
            let fitted = try XCTUnwrap(text.range(of: fit), "\(name) fits")
            XCTAssertTrue(check.lowerBound < fitted.lowerBound, "\(name) checks the animals before the fit")
        }
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
        XCTAssertEqual(record.options.resolvedDefaults["minimumAnimals"], .integer(3))
    }

    func testAColumnWithNoAnimalIsRefusedWithTheSheetAndTheSameCallPassesWhenTheSheetGivesTheAnimal() throws {
        var columns = animalColumns([("B", ["A1", "A2", "A3"]), ("T", ["A1", "A2", "A3"])])
        columns[2].animal = nil
        let result = try animalsResult("pb", columns)
        let text = words([result])
        XCTAssertTrue(text.hasPrefix("The pseudobulk column A3_B holds no animal. LGE counts animals and not cells in a pseudobulk comparison, "
            + "because tests on single cells give false discoveries, so each column needs its animal."), text)
        XCTAssertTrue(text.hasSuffix("Give the animal of each column in the animal column of --sample-sheet."), text)
        try nothingWritten()
        let lines = columns.map { column in "\(column.id)\t\(column.id.prefix { $0 != "_" })" }
        let sheet = root.appendingPathComponent("sheet.tsv")
        try (["sample\tanimal"] + lines).joined(separator: "\n").appending("\n").write(to: sheet, atomically: true, encoding: .utf8)
        let out = try export([result], sheet: sheet)
        let table = try script("samples.tsv", in: out).split(separator: "\n").map { $0.components(separatedBy: "\t") }
        XCTAssertEqual(table.first(where: { $0.first == "A3_B" })?[1], "A3", "the sheet's animal fills the empty cell")
    }

    func testManyColumnsWithNoAnimalNameTheFirstTenAndCountTheRest() throws {
        let columns = (1...12).map { RNASeqAnimalsColumn(id: String(format: "c%02d", $0), animal: nil, group: $0 % 2 == 0 ? "T" : "B") }
        let text = words([try animalsResult("pb", columns)])
        XCTAssertTrue(text.hasPrefix("The pseudobulk columns c01, c02, c03, c04, c05, c06, c07, c08, c09, c10 and 2 more hold no animal."), text)
    }

    func testABulkResultWithTwoAnimalsAGroupPassesWithNoRuleInTheScriptsOrTheRecord() throws {
        let result = try animalsResult("bulk", animalColumns([("B", ["A1", "A2"]), ("T", ["A1", "A2"])]), kind: .quantified)
        let out = try export([result])
        for name in ["deseq2.R", "edger-limma-dream.R"] {
            let text = try script(name, in: out)
            XCTAssertFalse(text.contains("check_animals") || text.contains("min_animals"), "\(name) of a bulk result has no animals rule")
        }
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
        XCTAssertNil(record.options.resolvedDefaults["minimumAnimals"], "a bulk record is as it was")
    }

    func testTheLastDesignTermIsTheTestedFactorAndNoDesignIsNotRefused() throws {
        let result = try animalsResult("pb", animalColumns([("B", ["A1", "A2", "A3"]), ("T", ["A1", "A2", "A3"])]))
        // Day D1 holds two animals and day D2 one, so the rule bites when day is the tested factor and not when group is.
        let days = ["A1_B": "D1", "A2_B": "D1", "A3_B": "D2", "A1_T": "D1", "A2_T": "D1", "A3_T": "D2"]
        let sheet = root.appendingPathComponent("sheet.tsv")
        try (["sample\tday"] + days.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }).joined(separator: "\n").appending("\n")
            .write(to: sheet, atomically: true, encoding: .utf8)
        let day = RNASeqExportSettings(design: ["group", "day"], contrasts: [.init(factor: "day", numerator: "D2", denominator: "D1")])
        let text = words([result], sheet: sheet, settings: day)
        XCTAssertTrue(text.hasPrefix("\(intro) day, "), text)
        XCTAssertTrue(text.contains("the level D1 holds columns of 2 animals (A1, A2), and the level D2 holds columns of 1 animal (A3)."), text)
        try nothingWritten()
        let group = RNASeqExportSettings(design: ["day", "group"], contrasts: [.init(factor: "group", numerator: "T", denominator: "B")])
        XCTAssertNoThrow(try export([result], sheet: sheet, settings: group, name: "group-last"))
        let none = try animalsResult("one", animalColumns([("B", ["A1"]), ("T", ["A1"])]))
        XCTAssertNoThrow(try export([none], settings: RNASeqExportSettings(), name: "no-design"), "no design, no tested factor, nothing to count")
    }

    func testARealPseudobulkOfTheStarsoloCutHoldsOneAnimalAndIsRefused() throws {
        let single = try RNASeqPseudobulkTests.singleCellResult([RNASeqPseudobulkTests.starsolo], name: "solo", in: root)
        let labels = RNASeqPseudobulkTests.fixture.appendingPathComponent("labels-starsolo.tsv")
        let outcome = try RNASeqPseudobulk.sum(result: single, labels: labels, name: "pb")
        let url = analyses.appendingPathComponent("pb.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq pseudobulk", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(outcome.request, to: url, envelope: envelope)
        let text = words([url])
        for level in ["B", "T", "ten"] { XCTAssertTrue(text.contains("the level \(level) holds columns of 1 animal (A1)"), text) }
        try nothingWritten()
    }
}
