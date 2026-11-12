// DemultiplexDrawerPlanRunTests.swift - The Demux tab's plan reaches the run as a custom definition (D1b, L8)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN. The Demux tab built a plan that no run read (DEMUX-PLAN-NO-RUN). Demultiplex… now writes
// the plan's table into the project as a custom definition that keeps the plan kit's platform, and opens the FASTQ
// operations dialog on it with the plan's location and error rate, where the person presses Run. The tests drive that
// launch, the dialog's request and argv, and the CLI run the argv starts, as the dialog's Run does.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class DemultiplexDrawerPlanRunTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-drawer-plan")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let d701 = "ATTACTCG"
    private static let d702 = "TCCGGAGA"

    /// 1,000 names carry D701, 100 D702 and 10 an index of N, on bases that hold no barcode of the kit.
    private func writeHeaderIndexedReads(inFolder folder: String? = nil) throws -> URL {
        let indexes = Array(repeating: Self.d701, count: 1_000) + Array(repeating: Self.d702, count: 100)
            + Array(repeating: "NNNNNNNN", count: 10)
        let sequence = String(repeating: "GATTACA", count: 21)
        let quality = String(repeating: "I", count: sequence.count)
        let base: URL = project
        let directory = folder.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("mixed.fastq")
        try indexes.enumerated().map { "@r\($0.offset) 1:N:0:\($0.element)\n\(sequence)\n+\n\(quality)\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        return input
    }

    private func assignment(_ barcode: String, _ sequence: String, name: String?) -> FASTQSampleBarcodeAssignment {
        // The shape Detect's Proceed writes for a single-index kit (`ViewerViewController+FASTQDrawer.swift`).
        FASTQSampleBarcodeAssignment(
            sampleID: barcode, sampleName: name,
            forwardBarcodeID: barcode, forwardSequence: sequence,
            reverseBarcodeID: barcode, reverseSequence: sequence
        )
    }

    private func plan(_ names: [String?], location: BarcodeLocation = .bothEnds, errorRate: Double = 0.15) -> DemultiplexPlan {
        let rows = zip([("D701", Self.d701), ("D702", Self.d702)], names).map { assignment($0.0.0, $0.0.1, name: $0.1) }
        return DemultiplexPlan(steps: [DemultiplexStep(
            label: "Plan", barcodeKitID: "truseq-single-a", barcodeLocation: location, errorRate: errorRate,
            sampleAssignments: rows
        )])
    }

    private func launch(_ plan: DemultiplexPlan, input: URL) throws -> FASTQDemultiplexPlanLaunch {
        try FASTQDemultiplexPlanLaunch.make(
            plan: plan, kits: BarcodeKitRegistry.builtinKits(), datasetURL: input, projectURL: project
        )
    }

    /// The dialog as Demultiplex… opens it, after the person presses Run. The state comes from the presenter's own
    /// builder, so the test drives the presenter's order of `selectTool` and `configure` (ruling ARCH-DEMUX-PLAN-CONTROL
    /// item 2).
    private func dialogRequest(_ launch: FASTQDemultiplexPlanLaunch) throws -> FASTQOperationLaunchRequest {
        let state = FASTQOperationsDialogPresenter.makeState(
            selectedInputURLs: launch.inputURLs,
            initialCategory: FASTQOperationToolID.demultiplexBarcodes.categoryID,
            initialToolID: .demultiplexBarcodes,
            projectURL: project,
            configure: launch.configure
        )
        state.prepareForRun()
        return try XCTUnwrap(state.pendingLaunchRequest, "the dialog made no request from the plan")
    }

    private func runDialog(_ launch: FASTQDemultiplexPlanLaunch, into output: URL) async throws -> [String] {
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: try dialogRequest(launch), outputTargetPath: output.path
        )
        var command = try FastqDemultiplexSubcommand.parse(Array(invocation.arguments.dropFirst()))
        try await command.run()
        return invocation.arguments
    }

    private func counts(_ output: URL) throws -> [String: Int] {
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "no manifest in \(output.path)")
        return Dictionary(uniqueKeysWithValues: manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) })
    }

    private func value(after option: String, in argv: [String]) -> String? {
        argv.firstIndex(of: option).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - L8 red tests

    /// BIO's pin (`S2-R1-BIO.md:81`): the names typed in the drawer name the outputs and reach the record.
    func testDrawerPlanSampleNamesReachOutputsAndRecord() async throws {
        let input = try writeHeaderIndexedReads()
        let launch = try launch(plan(["Water (blank)", "NTC, 1"]), input: input)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)
        _ = try await runDialog(launch, into: output)

        XCTAssertEqual(try counts(output), ["Water_blank": 1_000, "NTC_1": 100])
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        let names = Dictionary(uniqueKeysWithValues: manifest.barcodes.map { ($0.barcodeID, $0.sampleName) })
        XCTAssertEqual(names["Water_blank"], "Water (blank)")
        XCTAssertEqual(names["NTC_1"], "NTC, 1")
        for bundle in ["Water_blank", "NTC_1"] {
            let url = output.appendingPathComponent("\(bundle).\(FASTQBundle.directoryExtension)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "no output named \(bundle)")
        }
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        let recordedKit = try XCTUnwrap(value(after: "--kit", in: envelope.argv), "\(envelope.argv)")
        XCTAssertEqual(canonical(URL(fileURLWithPath: recordedKit).deletingLastPathComponent().path), canonical(output.path),
                       "the record names a definition outside the result folder")
        let copy = try String(contentsOfFile: recordedKit, encoding: .utf8)
        XCTAssertTrue(copy.contains("\"NTC, 1\""), copy)
        XCTAssertTrue(copy.contains("Water (blank)"), copy)
    }

    /// BIO pin 1 and ARCH's L8 line: a plan of the default Illumina kit keeps the kit's platform, so the route owner
    /// reads the read names, and the run splits by them and records the header route.
    func testDrawerPlanOfAnIlluminaKitSplitsByTheReadNameIndex() async throws {
        let input = try writeHeaderIndexedReads()
        let launch = try launch(plan(["S1", "S2"]), input: input)
        let definition = try String(contentsOf: launch.definitionURL, encoding: .utf8)
        XCTAssertTrue(definition.hasPrefix("# kit: truseq-single-a\n"), definition)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)
        let argv = try await runDialog(launch, into: output)

        XCTAssertNil(value(after: "--engine", in: argv), "the dialog chose the route for the route owner: \(argv)")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertEqual(value(after: "--engine", in: envelope.argv), "header-index", "\(envelope.argv)")
        XCTAssertEqual(try counts(output), ["S1": 1_000, "S2": 100])
        XCTAssertEqual(try XCTUnwrap(DemultiplexManifest.load(from: output)).unassigned.readCount, 10)
    }

    /// Demultiplex… opens the dialog on the plan's definition, written in the project, with the plan's location and
    /// error rate, and leaves the engine to the route owner.
    func testDrawerRunOpensTheDialogWithThePlansDefinition() throws {
        let input = try writeHeaderIndexedReads()
        let launch = try launch(plan(["S1", "S2"], location: .fivePrime, errorRate: 0.10), input: input)
        XCTAssertEqual(launch.inputURLs.map(\.standardizedFileURL), [input.standardizedFileURL])
        XCTAssertEqual(
            canonical(launch.definitionURL.deletingLastPathComponent().path),
            canonical(project.appendingPathComponent("Barcode Definitions").path),
            "the definition is not in the project's Barcode Definitions folder"
        )
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: try dialogRequest(launch), outputTargetPath: project.appendingPathComponent("Analyses/out").path
        )
        let argv = invocation.arguments
        XCTAssertEqual(argv.first, "demultiplex")
        XCTAssertEqual(value(after: "--kit", in: argv).map(canonical), canonical(launch.definitionURL.path), "\(argv)")
        XCTAssertTrue(["5prime", "fiveprime", "five-prime"].contains(value(after: "--location", in: argv) ?? ""), "\(argv)")
        XCTAssertEqual(value(after: "--error-rate", in: argv), "0.10", "\(argv)")
        XCTAssertNil(value(after: "--engine", in: argv), "\(argv)")
    }

    /// QA's round 2 line: a replay of the recorded command reads the definition the run copied, so a plan changed after
    /// the run gives the same outputs and the same digest.
    func testReplayAfterThePlanChangesGivesTheSameOutputs() async throws {
        let input = try writeHeaderIndexedReads()
        let first = project.appendingPathComponent("Analyses/first", isDirectory: true)
        _ = try await runDialog(try launch(plan(["S1", "S2"]), input: input), into: first)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: first))

        // The person changes the plan, and the next Demultiplex… rewrites the project's definition.
        let changed = try launch(plan(["Other 1", "Other 2"]), input: input)
        XCTAssertTrue(try String(contentsOf: changed.definitionURL, encoding: .utf8).contains("Other 1"))

        let replayed = project.appendingPathComponent("Analyses/replay", isDirectory: true)
        var words = Array(envelope.argv.drop { $0 != "demultiplex" }.dropFirst())
        let outputIndex = try XCTUnwrap(words.firstIndex(of: "--output"), "\(envelope.argv)")
        words[outputIndex + 1] = replayed.path
        var command = try FastqDemultiplexSubcommand.parse(words)
        try await command.run()

        XCTAssertEqual(try counts(replayed), try counts(first), "the replay read the changed plan")
        func digest(_ output: URL) throws -> String? {
            try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output)).files
                .first { $0.path.hasSuffix(".csv") }?.checksumSHA256
        }
        XCTAssertNotNil(try digest(first))
        XCTAssertEqual(try digest(replayed), try digest(first))
    }

    /// BIO's round 2 line: two typed names that the one sanitizer turns into one output name refuse in words before the
    /// dialog opens, and so does a name that would be the unassigned output, so two samples never share an output.
    func testDrawerPlanRefusesTwoNamesThatSanitizeToOneOutput() throws {
        let input = try writeHeaderIndexedReads()
        XCTAssertThrowsError(try launch(plan(["NTC 1", "NTC/1"]), input: input)) { error in
            let words = error.localizedDescription
            for part in ["NTC 1", "NTC/1", "NTC_1"] { XCTAssertTrue(words.contains(part), words) }
        }
        XCTAssertThrowsError(try launch(plan(["unassigned", "S2"]), input: input)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unassigned"), error.localizedDescription)
        }
        let definitions = project.appendingPathComponent("Barcode Definitions")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: definitions.path)) ?? []
        XCTAssertEqual(written, [], "a refused plan wrote a definition")
    }

    /// IDT-UD-SEQUENCES (FIX-IDT): the table of the IDT UD kit is not the kit's, so every definition the button wrote
    /// from it held false pairs. A plan on the kit refuses in the run's own words and writes no definition.
    func testDrawerPlanOnTheIDTUDKitRefusesInTheRunsWordsAndWritesNoDefinition() throws {
        let input = try writeHeaderIndexedReads()
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "idt-ud-indexes"))
        let rows = kit.barcodes.prefix(2).map { assignment($0.id, $0.i7Sequence, name: nil) }
        let plan = DemultiplexPlan(steps: [DemultiplexStep(label: "Plan", barcodeKitID: kit.id, sampleAssignments: rows)])
        XCTAssertThrowsError(try launch(plan, input: input)) { error in
            XCTAssertEqual(
                error.localizedDescription, DemultiplexError.kitSequencesUnderCheck(kitName: kit.displayName).errorDescription,
                "the button refuses in the words the CLI prints for the kit id"
            )
        }
        let definitions = project.appendingPathComponent("Barcode Definitions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: definitions.path), "a refused plan wrote a definition")
    }

    /// SWIFT 6: the definition quotes a name with a comma or a quote and reads back every awkward name whole, and a
    /// name with a line break refuses in words.
    func testDrawerPlanDefinitionRoundTripsAwkwardNames() throws {
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "truseq-single-a"))
        let names = ["Water (blank)", "NTC, 1", "O'Brien \"A\"", "plate/A1"]
        let rows = zip(kit.barcodes.prefix(4), names).map { assignment($0.0.id, $0.0.i7Sequence, name: $0.1) }
        let step = DemultiplexStep(label: "Plan", barcodeKitID: kit.id, sampleAssignments: rows)
        let url = root.appendingPathComponent("round-trip.csv")
        try DemultiplexPlanDefinition(step: step, kit: kit).csvText.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try BarcodeKitRegistry.loadCustomKit(from: url, name: "round-trip")
        XCTAssertEqual(loaded.barcodes.map(\.sampleName), names)
        XCTAssertEqual(loaded.barcodes.map(\.id), ["Water_blank", "NTC_1", "O_Brien_A", "plate_A1"])
        XCTAssertEqual(loaded.platform, kit.platform)

        let broken = DemultiplexStep(label: "Plan", barcodeKitID: kit.id, sampleAssignments: [
            assignment("D701", Self.d701, name: "two\nlines"),
        ])
        XCTAssertThrowsError(try DemultiplexPlanDefinition(step: broken, kit: kit))
    }

    /// UX's round 2 line: a name the sanitizer changes shows its output name in the drawer's table before the run. The
    /// names are typed through the table's own edit path (review DEMUXPLAN, UX should-fix 1). No unit test sees a stale
    /// cell: the table's invalidation is not observable outside a displayed window, so the closing walk reads it.
    func testDrawerPlanShowsTheOutputNameOfAChangedSampleName() throws {
        XCTAssertEqual(DemultiplexPlanDefinition.outputName(for: assignment("D701", Self.d701, name: "NTC, 1")), "NTC_1")
        XCTAssertEqual(DemultiplexPlanDefinition.outputName(for: assignment("D702", Self.d702, name: "plate/A1")), "plate_A1")
        XCTAssertEqual(DemultiplexPlanDefinition.outputName(for: assignment("D703", "CGCTCATT", name: nil)), "D703")

        let drawer = FASTQMetadataDrawerView()
        drawer.selectDemuxTab()
        drawer.applySampleAssignmentsToCurrentStep([
            assignment("D701", Self.d701, name: nil), assignment("D702", Self.d702, name: nil),
        ])
        func tables(in view: NSView) -> [NSTableView] {
            ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables(in: $0) }
        }
        let table = try XCTUnwrap(tables(in: drawer).first { $0.tableColumn(withIdentifier: .init("sampleName")) != nil })
        let nameColumn = try XCTUnwrap(table.tableColumn(withIdentifier: .init("sampleName")))
        let column = try XCTUnwrap(table.tableColumn(withIdentifier: .init("outputName")), "the table shows no output name")
        XCTAssertEqual(drawer.tableView(table, objectValueFor: column, row: 0) as? String, "D701")

        drawer.tableView(table, setObjectValue: "NTC, 1", for: nameColumn, row: 0)
        drawer.tableView(table, setObjectValue: "plate/A1", for: nameColumn, row: 1)
        XCTAssertEqual(drawer.tableView(table, objectValueFor: column, row: 0) as? String, "NTC_1")
        XCTAssertEqual(drawer.tableView(table, objectValueFor: column, row: 1) as? String, "plate_A1")
    }

    // MARK: - Ruling ARCH-DEMUX-PLAN-CONTROL, C1 to C4

    /// C1, route parity: a plan of one sample of the default Illumina kit splits by the read names, as the kit's own
    /// run on the same file does, and the reads of the kit's other barcodes go to Unassigned.
    func testDrawerPlanOfOneSampleRoutesAsItsKitDoes() async throws {
        let input = try writeHeaderIndexedReads()
        let output = project.appendingPathComponent("Analyses/one", isDirectory: true)
        let argv = try await runDialog(try launch(plan(["S1"]), input: input), into: output)

        XCTAssertNil(value(after: "--engine", in: argv), "the dialog chose the route for the route owner: \(argv)")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertEqual(value(after: "--engine", in: envelope.argv), "header-index", "\(envelope.argv)")
        XCTAssertEqual(try counts(output), ["S1": 1_000])
        XCTAssertEqual(try XCTUnwrap(DemultiplexManifest.load(from: output)).unassigned.readCount, 110)
    }

    /// C2: a definition is never rewritten. Two datasets with one file name get two definitions, and a second
    /// Demultiplex… of the same plan reuses the first file.
    func testPlansOfTwoDatasetsWithOneNameNeverShareADefinition() throws {
        let a = try writeHeaderIndexedReads(inFolder: "a")
        let b = try writeHeaderIndexedReads(inFolder: "b")
        let first = try launch(plan(["S1", "S2"]), input: a)
        let second = try launch(plan(["T1", "T2"]), input: b)

        XCTAssertNotEqual(canonical(first.definitionURL.path), canonical(second.definitionURL.path),
                          "two datasets with one name share one definition")
        XCTAssertTrue(try String(contentsOf: first.definitionURL, encoding: .utf8).contains("S1"),
                      "the second plan rewrote the first plan's definition")
        let again = try launch(plan(["S1", "S2"]), input: a)
        XCTAssertEqual(canonical(again.definitionURL.path), canonical(first.definitionURL.path))
        let folder = project.appendingPathComponent("Barcode Definitions")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files.count, 2, "\(files)")
    }

    /// C3: Demultiplex… runs a plan of one step. A plan of two steps, or one that names samples across steps, refuses
    /// in words that name the count, before any file is written.
    func testDrawerPlanOfTwoStepsRefusesInWords() throws {
        let input = try writeHeaderIndexedReads()
        var twoSteps = plan(["S1", "S2"])
        twoSteps.steps.append(DemultiplexStep(
            label: "Inner", barcodeKitID: "truseq-single-a", sampleAssignments: twoSteps.steps[0].sampleAssignments,
            ordinal: 1
        ))
        XCTAssertThrowsError(try launch(twoSteps, input: input)) { error in
            XCTAssertTrue(error.localizedDescription.contains("2 steps"), error.localizedDescription)
        }
        var composite = plan(["S1", "S2"])
        composite.compositeSampleNames = ["D701/D702": "Patient 42"]
        XCTAssertThrowsError(try launch(composite, input: input))
        let definitions = project.appendingPathComponent("Barcode Definitions")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: definitions.path)) ?? []
        XCTAssertEqual(written, [], "a refused plan wrote a definition")
    }

    /// C4: output names collide over every row. A typed name equal to another row's barcode ID, which names that row's
    /// output, refuses in words that name it, and a name cleared to spaces counts as no name.
    func testDrawerPlanRefusesATypedNameThatIsAnotherRowsBarcode() throws {
        let input = try writeHeaderIndexedReads()
        XCTAssertThrowsError(try launch(plan(["D702", nil]), input: input)) { error in
            XCTAssertTrue(error.localizedDescription.contains("D702"), error.localizedDescription)
        }
        XCTAssertEqual(DemultiplexPlanDefinition.outputName(for: assignment("D701", Self.d701, name: "  ")), "D701")
    }

    // MARK: - Review DEMUXPLAN-UX, should-fix 3: the refusals of the launch

    /// A row that pairs two barcodes refuses in words that name both, and do not send the person to run the plan from
    /// Demultiplex Barcodes, which cannot read the plan's table.
    func testDrawerPlanOfAPairedRowRefusesNamingBothBarcodes() throws {
        let input = try writeHeaderIndexedReads()
        let paired = FASTQSampleBarcodeAssignment(
            sampleID: "P1", sampleName: "Pair 1",
            forwardBarcodeID: "D701", forwardSequence: Self.d701,
            reverseBarcodeID: "D702", reverseSequence: Self.d702
        )
        let pairedPlan = DemultiplexPlan(steps: [DemultiplexStep(
            label: "Plan", barcodeKitID: "truseq-single-a", sampleAssignments: [paired]
        )])
        XCTAssertThrowsError(try launch(pairedPlan, input: input)) { error in
            let words = error.localizedDescription
            for part in ["D701", "D702"] { XCTAssertTrue(words.contains(part), words) }
            XCTAssertFalse(words.contains("run this plan from"), words)
        }
        let definitions = project.appendingPathComponent("Barcode Definitions")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: definitions.path)) ?? []
        XCTAssertEqual(written, [], "a refused plan wrote a definition")
    }

    /// A dataset outside a project has no folder to keep the definition in. The words name the project, and nothing is
    /// written.
    func testDrawerPlanOutsideAProjectRefusesAndWritesNothing() throws {
        let input = try writeHeaderIndexedReads()
        XCTAssertThrowsError(try FASTQDemultiplexPlanLaunch.make(
            plan: plan(["S1", "S2"]), kits: BarcodeKitRegistry.builtinKits(), datasetURL: input, projectURL: nil
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("project"), error.localizedDescription)
        }
        let definitions = project.appendingPathComponent("Barcode Definitions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: definitions.path), "a refused plan made the definitions folder")
    }

    /// A name with a line break cannot be a field of a line-based file, and the words say to type it on one line.
    func testDrawerPlanWithALineBreakInANameRefuses() throws {
        let input = try writeHeaderIndexedReads()
        XCTAssertThrowsError(try launch(plan(["two\nlines", "S2"]), input: input)) { error in
            XCTAssertTrue(error.localizedDescription.contains("line break"), error.localizedDescription)
        }
    }
}
