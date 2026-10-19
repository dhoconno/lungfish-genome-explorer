// CLIEventContractCoverageTests.swift - Every leaf command declares what it writes for a machine reader
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// The per-leaf contract table of plan decision S18, checked in the unit tier.
///
/// A1 walks the command tree and compares it with the table. A2 reads the checked-in help
/// golden of each `.events` leaf. The legacy tests pin the private shapes that are left,
/// so the list can only fall when a lane deletes a row. The warning tests show that the
/// three `msa annotate` commands emit each warning they count. `CLIEventTranscriptCoverageTests`
/// holds check A3, which reads the transcripts of the `.events` leaves.
final class CLIEventContractCoverageTests: XCTestCase {

    // MARK: The command tree

    /// The path of every leaf, found the way `--experimental-dump-help` finds them. A leaf
    /// is a command with no subcommands, and a hidden one counts. ArgumentParser adds a
    /// `help` subcommand to the root only when it builds that dump, so the walk adds it.
    static func leafPaths() -> [String] {
        var paths: [String] = []
        func walk(_ command: ParsableCommand.Type, _ path: [String]) {
            let subcommands = command.configuration.subcommands
            if subcommands.isEmpty {
                paths.append(path.joined(separator: " "))
                return
            }
            for subcommand in subcommands {
                walk(subcommand, path + [subcommand._commandName])
            }
        }
        walk(LungfishCLI.self, [])
        paths.append("help")
        return paths
    }

    static var repositoryRoot: URL { ProvenanceCompatCorpus.repositoryRoot }

    // MARK: A1

    func testEveryLeafHasOneRowAndNoRowNamesAMissingLeaf() {
        let leaves = Self.leafPaths()
        XCTAssertEqual(leaves.count, Set(leaves).count, "Two leaves share one path, so the table cannot key them")
        let rows = Set(CLIEventContractTable.entries.keys)

        let withoutRow = Set(leaves).subtracting(rows).sorted()
        XCTAssertTrue(
            withoutRow.isEmpty,
            "Leaves with no row in CLIEventContractTable, add one for each of \(withoutRow)"
        )
        let withoutLeaf = rows.subtracting(leaves).sorted()
        XCTAssertTrue(
            withoutLeaf.isEmpty,
            "Rows in CLIEventContractTable that name no leaf, delete or rename \(withoutLeaf)"
        )
        XCTAssertEqual(CLIEventContractTable.entries.count, leaves.count)
    }

    func testTheWalkSeesTheHiddenLeafAndTheHelpSubcommand() {
        let leaves = Set(Self.leafPaths())
        XCTAssertTrue(leaves.contains("fastq ont-genotype"), "A hidden leaf counts")
        XCTAssertTrue(leaves.contains("help"))
        XCTAssertFalse(leaves.contains("fastq"), "A group is not a leaf")
        XCTAssertFalse(leaves.contains(""), "The root is not a leaf")
    }

    // MARK: A2

    func testEveryEventsLeafHelpListsTheDeclaredSwitch() throws {
        var checked = 0
        for (path, contract) in CLIEventContractTable.entries.sorted(by: { $0.key < $1.key }) {
            guard case let .events(flag, _) = contract, flag != CLIEventContractTable.alwaysOn else { continue }
            let help = try Self.helpText(forLeaf: path)
            let options = Self.optionBlocks(in: help)
            let parts = flag.split(separator: " ").map(String.init)
            let name = try XCTUnwrap(parts.first, "\(path) declares an empty switch")
            guard let block = options[name] else {
                XCTFail("The help of '\(path)' lists no \(name), though its row declares '\(flag)'")
                continue
            }
            if parts.count > 1 {
                XCTAssertTrue(
                    block.contains(parts[1]),
                    "The help of '\(path)' lists \(name) without the value \(parts[1])"
                )
            }
            checked += 1
        }
        let switchedRows = CLIEventContractTable.entries.values.filter {
            if case let .events(flag, _) = $0 { return flag != CLIEventContractTable.alwaysOn }
            return false
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertEqual(checked, switchedRows.count, "Every row that emits events behind a switch had its help read")
    }

    func testTheHelpCheckCanFail() throws {
        let help = try Self.helpText(forLeaf: "msa annotate add")
        let options = Self.optionBlocks(in: help)
        XCTAssertNotNil(options["--format"])
        XCTAssertTrue(options["--format"]?.contains("json") == true)
        XCTAssertNil(options["--json-events"], "No leaf lists --json-events")
        XCTAssertFalse(options["--format"]?.contains("yaml") == true)

        let wrapped = Self.optionBlocks(in: try Self.helpText(forLeaf: "bam primer-trim"))
        XCTAssertTrue(wrapped["--format"]?.contains("json") == true, "A value list that wraps onto the next line still counts")

        // `--json-events` is a hidden alias of `--format json` since 2.10 (lane A46, decision C7).
        let assemble = Self.optionBlocks(in: try Self.helpText(forLeaf: "assemble"))
        XCTAssertNil(assemble["--json-events"])
        XCTAssertTrue(assemble["--format"]?.contains("json") == true)
    }

    func testEveryEventsRowDeclaresAKnownSwitchAndChannel() {
        let known: Set<String> = ["--format json", "--json-events", CLIEventContractTable.alwaysOn]
        var alwaysOn: [String] = []
        for (path, contract) in CLIEventContractTable.entries {
            guard case let .events(flag, channel) = contract else { continue }
            XCTAssertTrue(known.contains(flag), "\(path) declares the unknown switch '\(flag)'")
            XCTAssertEqual(
                channel == .standardError,
                flag != "--format json",
                "Only the two ONT FASTQ commands keep their events on standard error, and assemble moved in 2.10"
            )
            if flag == CLIEventContractTable.alwaysOn { alwaysOn.append(path) }
        }
        XCTAssertEqual(
            alwaysOn.sorted(),
            ["fastq ont-fluidigm-samples", "fastq ont-pacbio-barcode-demux"],
            "The FASTQ operation family runs these two without --format json, so they print events on every run"
        )
    }

    // MARK: Legacy rows

    /// The private shapes that are left, as plan decision S18 counts them, with the leaves
    /// that still print each and the sub-phase that retires it. A lane that retires a shape
    /// deletes its rows in `CLIEventContractTable` and its entry here in the same commit.
    /// A lane that adds a private shape has to add both, which is what makes it a decision.
    /// `fastq genotype`, `genotype-cohort`, `ont-barcode-genotype` and `full-length-ont-mhc-genotype`
    /// also print R3 on standard error beside their document, so the lane that retires R3 converts
    /// all six leaves.
    private static let shapesLeft: [String: (removeBy: String, leaves: [String])] = [
        "s12-bam-annotate-best": ("2.9", ["bam annotate-best"]),
        "s13-bam-annotate-cds-best": ("2.9", ["bam annotate-cds-best"]),
        "r1-ont-barcode-genotyping": ("2.8", ["fastq ont-barcode-genotype"]),
        "r2-full-length-ont-mhc": ("2.8", ["fastq full-length-ont-mhc-genotype"]),
        "r3-twelve-s-progress-text": ("2.8", ["fastq 12s-match", "fastq 12s-reference-bundle"]),
        "r4-reference-bundle-path-line": ("2.9", ["extract contigs"]),
    ]

    func testLegacyRowsAreExactlyTheShapesLeft() {
        var found: [String: (removeBy: Set<String>, leaves: [String])] = [:]
        for (path, contract) in CLIEventContractTable.entries {
            guard case let .legacy(schemaID, removeBy) = contract else { continue }
            var shape = found[schemaID] ?? ([], [])
            shape.removeBy.insert(removeBy)
            shape.leaves.append(path)
            found[schemaID] = shape
        }

        XCTAssertEqual(
            Set(found.keys),
            Set(Self.shapesLeft.keys),
            "The private shapes in the table differ from the shapes left. A retired shape loses its rows and its entry in shapesLeft together"
        )
        for (schemaID, expected) in Self.shapesLeft {
            guard let shape = found[schemaID] else { continue }
            XCTAssertEqual(shape.removeBy, [expected.removeBy], "\(schemaID) names one sub-phase that retires it")
            XCTAssertEqual(shape.leaves.sorted(), expected.leaves.sorted(), "The leaves that print \(schemaID)")
        }

        let legacyRows = CLIEventContractTable.entries.values.filter {
            if case .legacy = $0 { return true }
            return false
        }
        XCTAssertEqual(found.count, 6, "Six private shapes are left")
        XCTAssertEqual(legacyRows.count, Self.shapesLeft.values.map(\.leaves.count).reduce(0, +))
        XCTAssertEqual(legacyRows.count, 7, "Seven leaves still print one of them")
    }

    func testEveryLegacyRowNamesAFutureSubPhase() {
        let subPhases: Set<String> = ["2.6", "2.7", "2.8", "2.9"]
        for (path, contract) in CLIEventContractTable.entries {
            guard case let .legacy(schemaID, removeBy) = contract else { continue }
            XCTAssertTrue(subPhases.contains(removeBy), "\(path) retires \(schemaID) in the unknown sub-phase '\(removeBy)'")
            XCTAssertEqual(schemaID, schemaID.lowercased(), "Schema ids are lower case")
            XCTAssertFalse(schemaID.contains(" "), "Schema ids have no spaces")
        }
    }

    // MARK: Row hygiene

    func testSchemaIDsAndReasonsAreStableStrings() {
        var resultIDs: [String: [String]] = [:]
        for (path, contract) in CLIEventContractTable.entries {
            switch contract {
            case let .result(schemaID):
                XCTAssertFalse(schemaID.isEmpty, "\(path) has an empty schema id")
                XCTAssertEqual(schemaID, schemaID.lowercased())
                XCTAssertFalse(schemaID.contains(" "))
                resultIDs[schemaID, default: []].append(path)
            case let .text(reason):
                XCTAssertFalse(reason.isEmpty, "\(path) has an empty reason")
            case .events, .legacy:
                break
            }
        }
        for (schemaID, paths) in resultIDs where paths.count > 1 {
            XCTAssertTrue(
                ["markdup-summary", "haplotypes-write", "r5-genotype-cohort-report"].contains(schemaID),
                "\(schemaID) is shared by \(paths.sorted()). Share an id only when one encoder writes the document"
            )
        }
    }

    func testTheRowCountsByCase() {
        var counts: [String: Int] = [:]
        for contract in CLIEventContractTable.entries.values {
            switch contract {
            case .events: counts["events", default: 0] += 1
            case .result: counts["result", default: 0] += 1
            case .legacy: counts["legacy", default: 0] += 1
            case .text: counts["text", default: 0] += 1
            }
        }
        XCTAssertEqual(
            counts["events"], 90,
            "taxtriage run emits events since 2.9 A2, sequence add-annotation and attach-track since 2.10 A42, fetch genome since 2.10 A44, variants delete and import-sample-metadata since 2.10 A43, bam remove-track, bam consensus and extract reads since 2.10 A51, workflow run since 2.10 A30, bam filter, bam annotate and the two duplicate leaves since A54, map since 2.10 A46, tools update, conda install and conda db update since 2.10 A52, fastq import-ont since 2.10 A53, and fastq ingest since 2.10 A47, fetch ncbi, fetch pathoplexus and fetch sra download since 2.10 A45, and demo fetch since 2.10 A45 M4, extract sequence since 2.11 A48 M2, and import fasta since 2.11 A48 M3, and bundle merge since 2.11 A49 M2, and import bam since 2.11 A63 M1, and extract taxa-collection since 2.11 A66 M2, and blast submit since 2.11 A65 M1, and import kraken2, import esviritu and import taxtriage since 2.12 lane 12.04, and import nao-mgs and import nvd since 2.12 lane 12.05, and import cz-id since 2.12 lane 12.06, and esviritu export detections since 2.12 12.31 M3, and import vcf since 2.12 lane 12.07, and nao-mgs export table since 2.12 12.31 M4, and nvd export contigs since 2.12 12.31 M4, and fastq export sample-barcodes since 2.12 lane 12.34 M2, and project copy-item since 2.12 lane 12.18, and variants export bookmarked and sample-template since 2.12 12.39, and primers design primer3, primalscheme3 and varvamp since 2.12 lane 12.17 M2, and genotype export-manual-definitions since 2.12 lane 12.35 M2, and taxtriage export organism-matrix and batch-report since 2.12 lane 12.32, and bundle export-gff3 since 2.12 12.39, and bundle export-annotation-table since 2.12 12.39, and fastq export reads since 2.12 lane 12.38 M2, and kraken2 export table since 2.12 lane 12.33 M2, and blast export table since 2.12 lane 12.33 A9"
        )
        XCTAssertEqual(counts["legacy"], 7)
        XCTAssertEqual(counts.values.reduce(0, +), CLIEventContractTable.entries.count)
    }

    /// 2.6 row 213, lane A55 (Phase 2.10 decision C6). A leaf that lists `--format json` and ignores it
    /// either honours the option or drops it. The count was 53 at the lane base, 18 after M3 and is 0 after
    /// M4, and the table keeps no reason for it. No lane adds a row with that reason back.
    func testTheLeavesThatListFormatJSONAndIgnoreItAreCounted() {
        let ignoring = CLIEventContractTable.entries.compactMap { path, contract -> String? in
            guard case let .text(reason) = contract, reason.hasPrefix("lists --format json and ignores it") else {
                return nil
            }
            return path
        }
        XCTAssertEqual(
            ignoring.count, 0,
            "No leaf lists --format json and ignores it after A55 M4 (53 at its base): \(ignoring.sorted())"
        )
    }

    // MARK: Counted warnings

    /// `msa annotate add`, `edit` and `project` put a `warningCount` on `complete`. Review of
    /// lane C1 found that they never emitted the warnings they counted, so a reader that takes
    /// warnings from events saw none. Each counted warning is now a `warning` log event in front
    /// of `complete`, which is what the version 2 warning rule asks for.

    /// `seq1` has a gap inside the selection, so the annotation splits when it projects onto `seq2`.
    private static let projectionRows = """
    >seq1
    A-CG-T
    >seq2
    ATCGGT

    """

    private final class Lines {
        private(set) var all: [String] = []

        func append(_ line: String) {
            all.append(line)
        }
    }

    private func makeScratch() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/CLIEventContract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An alignment with one annotation added to `seq1`, and the id of that annotation.
    private func annotatedBundle(in scratch: URL) throws -> (bundle: URL, sourceID: String) {
        let source = scratch.appendingPathComponent("aln.fasta")
        try Self.projectionRows.write(to: source, atomically: true, encoding: .utf8)
        let bundle = scratch.appendingPathComponent("aln.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle, options: .init(name: "aln"))
        try MSACommand.AddSubcommand.parse([
            bundle.path, "--row", "seq1", "--columns", "3-6",
            "--name", "selection-feature", "--type", "gene", "--strand", "+", "--format", "json",
        ]).executeForTesting { _ in }
        let store = try MultipleSequenceAlignmentBundle.load(from: bundle).loadAnnotationStore()
        return (bundle, try XCTUnwrap(store.sourceAnnotations.first).id)
    }

    /// What a run printed about warnings. The messages are those of its `warning` log events,
    /// the count is the `warningCount` key of its `complete` line, and the last flag says
    /// whether every warning came before that line.
    private struct WarningReport {
        let messages: [String]
        let countOnComplete: Int?
        let allBeforeComplete: Bool
    }

    private func warningReport(_ lines: [String]) throws -> WarningReport {
        let decoder = CLIEventLineDecoder()
        var messages: [String] = []
        var count: Int?
        var completeSeen = false
        var allBefore = true
        for line in lines {
            guard let event = try decoder.decode(line: line) else { continue }
            switch event {
            case .log(.warning, let message):
                messages.append(message)
                if completeSeen { allBefore = false }
            case .complete:
                completeSeen = true
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                count = object["warningCount"] as? Int
            default:
                break
            }
        }
        return WarningReport(messages: messages, countOnComplete: count, allBeforeComplete: allBefore)
    }

    func testAnnotateProjectEmitsOneWarningEventForEachWarningItCounts() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (bundle, sourceID) = try annotatedBundle(in: scratch)
        let lines = Lines()

        try MSACommand.ProjectSubcommand.parse([
            bundle.path, "--source-annotation", sourceID, "--target-rows", "seq2",
            "--conflict-policy", "append", "--format", "json",
        ]).executeForTesting { lines.append($0) }

        let report = try warningReport(lines.all)
        let stored = try MultipleSequenceAlignmentBundle.load(from: bundle).loadAnnotationStore()
            .projectedAnnotations.flatMap(\.warnings)
        XCTAssertEqual(report.countOnComplete, 1, "The fixture counts one warning, or this test proves nothing")
        XCTAssertEqual(report.messages.count, report.countOnComplete, "Warning log events against the warningCount of complete")
        XCTAssertEqual(report.messages, stored, "Each event carries the warning the bundle stored")
        XCTAssertTrue(report.allBeforeComplete, "A warning after complete would never reach the panel")
    }

    func testAnnotateEditEmitsOneWarningEventForEachWarningItCounts() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (bundle, sourceID) = try annotatedBundle(in: scratch)
        try MSACommand.ProjectSubcommand.parse([
            bundle.path, "--source-annotation", sourceID, "--target-rows", "seq2",
            "--conflict-policy", "append", "--format", "json",
        ]).executeForTesting { _ in }
        let projected = try XCTUnwrap(
            MultipleSequenceAlignmentBundle.load(from: bundle).loadAnnotationStore().projectedAnnotations.first
        )
        let lines = Lines()

        try MSACommand.EditSubcommand.parse([
            bundle.path, "--annotation", projected.id, "--name", "curated-projection", "--format", "json",
        ]).executeForTesting { lines.append($0) }

        let report = try warningReport(lines.all)
        XCTAssertEqual(report.countOnComplete, 1, "An edit keeps the warnings of the annotation it edits")
        XCTAssertEqual(report.messages.count, report.countOnComplete, "Warning log events against the warningCount of complete")
        XCTAssertEqual(report.messages, projected.warnings)
        XCTAssertTrue(report.allBeforeComplete)
    }

    func testAnnotateAddEmitsOneWarningEventForEachWarningItCounts() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("aln.fasta")
        try Self.projectionRows.write(to: source, atomically: true, encoding: .utf8)
        let bundle = scratch.appendingPathComponent("aln.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle, options: .init(name: "aln"))
        let lines = Lines()

        try MSACommand.AddSubcommand.parse([
            bundle.path, "--row", "seq1", "--columns", "3-6",
            "--name", "selection-feature", "--type", "gene", "--format", "json",
        ]).executeForTesting { lines.append($0) }

        // A new annotation carries no warnings today, so this pins zero against zero. The command
        // emits whatever its annotation counts, and the count and the events cannot part.
        let report = try warningReport(lines.all)
        XCTAssertEqual(report.countOnComplete, 0)
        XCTAssertEqual(report.messages.count, report.countOnComplete)
    }

    func testAnnotateProjectInTextModeStillPrintsItsWarningsLineAndNoEvent() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (bundle, sourceID) = try annotatedBundle(in: scratch)
        let lines = Lines()

        try MSACommand.ProjectSubcommand.parse([
            bundle.path, "--source-annotation", sourceID, "--target-rows", "seq2",
        ]).executeForTesting { lines.append($0) }

        XCTAssertTrue(
            lines.all.contains { $0.hasPrefix("Warnings: Projection split into 2 intervals") },
            "Text mode keeps its one Warnings line: \(lines.all)"
        )
        XCTAssertFalse(lines.all.contains { $0.hasPrefix("{") }, "Text mode prints no event line")
    }

    // MARK: A4 result schemas

    /// Decodes a document as `T` and writes it again with sorted keys, so that two decodes compare.
    private static func decodedAgain<T: Codable>(_ type: T.Type) -> @Sendable (Data) throws -> Data {
        { data in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(try JSONDecoder().decode(T.self, from: data))
        }
    }

    /// For a type that only decodes. Decodes a document as `T` and describes what the type read, so that two
    /// decodes compare.
    private static func decodedOnly<T: Decodable>(_ type: T.Type) -> @Sendable (Data) throws -> Data {
        { data in Data(String(reflecting: try JSONDecoder().decode(T.self, from: data)).utf8) }
    }

    /// The `.result` schemas that a type in CLI, Workflow, IO or Core decodes and whose document a
    /// real run of the built `lungfish-cli` gave a fixture under `Tests/Fixtures/cli-events/results`.
    /// The genotype cohort document is the exception. A real run needs a reference and reads, so its fixture
    /// holds the keys of the payload that `fastq genotype-cohort` encodes.
    private static let decodedFixtures: [String: @Sendable (Data) throws -> Data] = [
        "analyze-stats": decodedAgain(SequenceStats.self),
        "analyze-composition": decodedAgain(CompositionData.self),
        "analyze-validate": decodedAgain(ValidationResult.self),
        "convert": decodedAgain(ConvertResult.self),
        "translate": decodedAgain(TranslateResult.self),
        "search": decodedAgain(PatternSearchResult.self),
        "bundle-info": decodedAgain(BundleInfoOutput.self),
        "bundle-validate": decodedAgain(BundleValidationOutput.self),
        "bundle-list": decodedAgain(BundleListOutput.self),
        "msa-actions": decodedAgain(MSACommand.ActionsPayload.self),
        "msa-describe": decodedAgain(MultipleSequenceAlignmentActionDescriptor.self),
        "r5-genotype-cohort-report": decodedOnly(ONTGenotypingCLIPayload.self),
    ]

    /// The `.legacy` shapes whose document a Workflow type decodes, with a fixture of it in the results
    /// folder. `WorkflowOperationExecutionService` reads the standard output of the genotyping commands
    /// through these types, and `ONTGenotypingCLIPayload` reads the one payload that `fastq genotype`,
    /// `fastq genotype-cohort` and the deprecated `fastq ont-barcode-genotype` print. The service falls
    /// back to the paths of its request when a key goes missing, so its tests do not fail on one, and this
    /// decode with `JSONDecoder` does. The shapes leave the table of `shapesLeft` when their commands
    /// become `.result` rows, and these entries move to `decodedFixtures` with them.
    private static let decodedLegacyFixtures: [String: @Sendable (Data) throws -> Data] = [
        "r1-ont-barcode-genotyping": decodedOnly(ONTGenotypingCLIPayload.self),
        "r2-full-length-ont-mhc": decodedOnly(FullLengthONTMHCGenotypingCLIPayload.self),
    ]

    /// The `.result` schemas that A4 does not decode here, and why. A new `.result` row has to join
    /// one of these groups or `decodedFixtures`, so a schema is never left out without a reason.
    private static let resultsNotDecodedHere: [(reason: String, schemas: [String])] = [
        (
            "No Swift type decodes the document. The CLI builds it as a dictionary, or its type is private or only encodes",
            [
                "blast-verify", "bundle-create",
                "markdup-summary", "debug-fastq-ingest", "fastq-ont-genotype", "fastq-pbaa-cluster",
                "fastq-savont-cluster", "genotype-apply-annotations", "genotype-export",
                "genotype-export-labkey", "genotype-export-pivot-xlsx", "genotype-export-xlsx",
                "haplotypes-bundle-create", "haplotypes-bundle-install", "haplotypes-bundle-replace-reference",
                "haplotypes-delete", "haplotypes-export", "haplotypes-list", "haplotypes-validate",
                "haplotypes-write", "import-sample-metadata", "metadata-import", "metadata-set",
                "project-migrate", "project-unlock", "universal-search", "workflow-validate",
            ]
        ),
        (
            "A real run needs the network",
            [
                "fetch-ena-fasta", "fetch-ena-reads", "fetch-ena-search",
                "fetch-search", "fetch-sra-info", "fetch-sra-search",
            ]
        ),
        (
            "A real run needs inputs that this suite does not build, such as a result bundle or a model, or writes the user, the machine or a storage path into the document",
            [
                "cz-id-summary", "debug-container", "debug-env", "demo-info", "demo-list",
                "genotype-ai-haplotyping", "metadata-export", "metadata-get", "nao-mgs-summary",
                "nvd-summary", "primers-analysis-inspect", "project-lock", "storage-dedupe", "storage-info",
            ]
        ),
    ]

    private static var resultsFolder: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/cli-events/results", isDirectory: true)
    }

    private var resultSchemaIDs: Set<String> {
        Set(CLIEventContractTable.entries.values.compactMap { contract -> String? in
            if case let .result(schemaID) = contract { return schemaID }
            return nil
        })
    }

    /// The same document with one key that no reader knows, as a later version might add.
    private static func withOneExtraKey(_ data: Data) throws -> Data {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "A result fixture is one JSON object"
        )
        object["keyFromALaterVersion"] = "unknown"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testEveryResultFixtureDecodesWithOneExtraKey() throws {
        let everyFixture = Self.decodedFixtures.merging(Self.decodedLegacyFixtures) { result, _ in result }
        for (schema, decode) in everyFixture.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: Self.resultsFolder.appendingPathComponent("\(schema).json"))
            let baseline = try decode(data)
            XCTAssertEqual(
                try decode(Self.withOneExtraKey(data)),
                baseline,
                "\(schema) changes when its document gains a key it does not know"
            )
        }
    }

    /// A reader that rejects a key it does not know, which is the fault A4 exists to catch.
    private struct StrictDocument: Codable {
        let name: String

        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys where key.stringValue != "name" {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "unknown key")
            }
            name = try container.decode(String.self, forKey: Key(stringValue: "name")!)
        }
    }

    func testTheExtraKeyCheckCatchesAReaderThatRejectsUnknownKeys() throws {
        let data = Data(#"{"name":"fixture"}"#.utf8)
        let strict = Self.decodedAgain(StrictDocument.self)
        XCTAssertNoThrow(try strict(data), "The reader accepts its own document")
        XCTAssertThrowsError(try strict(Self.withOneExtraKey(data)), "The check must fail for a reader that rejects a new key")
    }

    func testEveryResultSchemaIsDecodedHereOrNamedWithItsReason() {
        let decoded = Set(Self.decodedFixtures.keys)
        let listed = Self.resultsNotDecodedHere.flatMap(\.schemas)
        XCTAssertEqual(listed.count, Set(listed).count, "A schema is listed under two reasons")

        let accounted = decoded.union(listed)
        let results = resultSchemaIDs
        XCTAssertEqual(
            results.subtracting(accounted).sorted(),
            [],
            "These .result schemas have no fixture check and no reason. Add a fixture or name the reason"
        )
        XCTAssertEqual(
            accounted.subtracting(results).sorted(),
            [],
            "These names are not .result schemas of the table any more"
        )
        XCTAssertTrue(decoded.isDisjoint(with: Set(listed)))
        // `map` prints events since 2.10 (lane A46), so r5-map-report left the decoded schemas, and
        // `extract sequence` since 2.11 (lane A48 M2), so extract-sequence left them too.
        XCTAssertEqual(decoded.count, 12)
    }

    func testTheLegacyDocumentsDecodedHereAreShapesLeft() {
        XCTAssertEqual(
            Set(Self.decodedLegacyFixtures.keys).subtracting(Self.shapesLeft.keys).sorted(),
            [],
            "These fixtures name a shape that is no longer left. Move the entry to decodedFixtures"
        )
        XCTAssertTrue(
            Set(Self.decodedLegacyFixtures.keys).isDisjoint(with: Set(Self.decodedFixtures.keys)),
            "A schema is decoded under one table"
        )
    }

    func testResultFixturesAreTheFilesOfTheDecodedSchemasAndHoldNoPersonalPath() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.resultsFolder.path)
            .filter { $0.hasSuffix(".json") }
        let fixtureSchemas = Set(Self.decodedFixtures.keys).union(Self.decodedLegacyFixtures.keys)
        XCTAssertEqual(
            Set(files),
            Set(fixtureSchemas.map { "\($0).json" }),
            "The results folder holds one fixture for each decoded schema and nothing else"
        )
        for file in files {
            let text = try String(contentsOf: Self.resultsFolder.appendingPathComponent(file), encoding: .utf8)
                .replacingOccurrences(of: "\\/", with: "/")
            for marker in ["/Users/", "/private/", "/var/folders", "/Volumes/"] {
                XCTAssertFalse(text.contains(marker), "\(file) names a path outside /work ('\(marker)')")
            }
        }
    }

    // MARK: Help golden helpers

    static var helpFolder: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/golden/cli-help", isDirectory: true)
    }

    /// `Tests/Fixtures/golden/cli-help/lungfish-cli.<path with dots>.txt`.
    static func helpText(forLeaf path: String) throws -> String {
        let name = "lungfish-cli." + path.split(separator: " ").joined(separator: ".") + ".txt"
        return try String(contentsOf: helpFolder.appendingPathComponent(name), encoding: .utf8)
    }

    /// Each option the OPTIONS section lists, by its long name, with the text of its entry.
    /// An entry runs from its first line to the next option, so a value list that wraps onto
    /// the next line belongs to the option that started it.
    static func optionBlocks(in help: String) -> [String: String] {
        var blocks: [String: String] = [:]
        var current: String?
        var inOptions = false
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("OPTIONS:") {
                inOptions = true
                continue
            }
            guard inOptions else { continue }
            if let first = line.first, first != " " {
                inOptions = false
                current = nil
                continue
            }
            if let name = optionName(in: line) {
                current = name
                blocks[name] = line
            } else if let current, line.hasPrefix("   ") {
                blocks[current, default: ""] += "\n" + line
            }
        }
        return blocks
    }

    /// The long name that starts an option entry, such as `--format` in
    /// `  --format <format>       Output format`, or nil for a continuation line.
    private static func optionName(in line: String) -> String? {
        guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return nil }
        var rest = line.dropFirst(2)
        if rest.hasPrefix("-"), !rest.hasPrefix("--"), let comma = rest.firstIndex(of: ",") {
            rest = rest[rest.index(after: comma)...].drop(while: { $0 == " " })
        }
        guard rest.hasPrefix("--") else { return nil }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.count > 2 ? String(name) : nil
    }
}
