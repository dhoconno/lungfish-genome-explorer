// ClassifierReadSetParityTests.swift - The GUI and CLI classifier routes hand Kraken2 and EsViritu the same reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, the freeze of today's classifier behaviour (panel
// decisions T2 and T9, docs/plans/2026-10-11-phase-2-7.md). One table, one row
// per fixture bundle, one column per route. A route takes the sample the
// wizard groups from the bundle and returns what the tool is handed: its argv
// with the scratch, output, database and project paths masked, the read names
// of each input file in argv order, and the read-set plan the run records.
//
// - `gui` builds the wizard's config and runs the app's launch resolution,
//   `resolvedKraken2Config` and `resolvedEsVirituConfig` with their planners.
// - `cli` records the command the Operations panel shows for that config,
//   parses it with the shipped parser and runs the read-set code of
//   `conda classify` and `esviritu detect`.
//
// Every route must give the row's frozen value. The executor of lanes A8 and
// A9 joins as a third `Route` case and must give the same values, so any
// change it makes shows here against this base. A row whose routes differ
// today names the difference and the lane that removes it in `knownDifferences`.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
import LungfishKitTestSupport
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ClassifierReadSetParityTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var derived: DerivedFASTQBundleFixture!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-read-set-parity")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        derived = try DerivedFASTQBundleFixture.make(in: root.appendingPathComponent("derived", isDirectory: true))
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The table

    func testKraken2RoutesHandKraken2TheSameReads() async throws {
        try await assertTable(.kraken2)
    }

    func testEsVirituRoutesHandEsVirituTheSameReads() async throws {
        try await assertTable(.esviritu)
    }

    /// Every row has a frozen value for both tools, and every known difference names a row and a route.
    func testTheTableCoversEveryFixtureBundle() {
        // Every bundle ReadSetFixtures holds, read from its stored properties, so a bundle a later lane adds
        // fails here until it has a row. The project folder and its Imports folder are not bundles.
        let fixtureBundles = Set(
            Mirror(reflecting: fixtures!).children
                .filter { $0.label != "projectURL" && $0.label != "importsURL" }
                .compactMap { $0.value as? URL }
        )
        XCTAssertEqual(
            Set(rows.map(\.bundle).filter { $0 != derived.derivedBundleURL }),
            fixtureBundles,
            "the rows are the ReadSetFixtures bundles and the oriented DerivedFASTQBundleFixture bundle"
        )
        XCTAssertEqual(Set(rows.map(\.name)).count, rows.count, "row names are unique")
        for tool in Tool.allCases {
            XCTAssertEqual(Set(ClassifierReadSetParityTable.frozen[tool]?.keys.map { $0 } ?? []), Set(rows.map(\.name)), "\(tool)")
        }
        for difference in ClassifierReadSetParityTable.knownDifferences {
            XCTAssertTrue(rows.contains { $0.name == difference.row }, difference.row)
        }
    }

    private func assertTable(_ tool: Tool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for row in rows {
            let expected = ClassifierReadSetParityTable.frozen[tool]?[row.name]
            for route in Route.allCases {
                let actual = await handoff(of: row, to: tool, through: route)
                let difference = ClassifierReadSetParityTable.knownDifferences.first {
                    $0.tool == tool && $0.row == row.name && $0.route == route.rawValue
                }
                XCTAssertEqual(
                    actual,
                    difference?.value ?? expected,
                    "\(tool) \(row.name) through \(route)",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - Rows

    private struct Row {
        let name: String
        let bundle: URL
        /// True for a ReadSetFixtures virtual subset, whose reads only the
        /// fixtures' stub materializer writes. Every other bundle is resolved
        /// with the launch's own materializer, which reads it without a tool.
        let usesStubMaterializer: Bool
    }

    private var rows: [Row] {
        let physical: [(String, URL)] = [
            ("L1 single", fixtures.singleRoot),
            ("L2 interleaved", fixtures.interleavedRoot),
            ("L3 mixed root", fixtures.mixedRoot),
            ("L4 chunked", fixtures.chunkedRoot),
            ("L4 Nanopore chunks named as mates", fixtures.nanoporeChunkedRoot),
            ("L4 Illumina chunks named R1 and R2", fixtures.namedPairChunkedRoot),
            ("L4 unknown platform chunks", fixtures.unknownPlatformChunkedRoot),
            ("L5a full", fixtures.fullDerivative),
            ("L5a full merge output", fixtures.fullMergeOutput),
            ("L5a full unlabelled", fixtures.fullUnlabelled),
            ("L5b paired", fixtures.pairedDerivative),
            ("L5c merge", fixtures.mergeDerivative),
            ("L5d repair", fixtures.repairDerivative),
            ("L5e FASTA", fixtures.fastaDerivative),
            ("L6e demultiplex group", fixtures.demuxGroup),
            ("L6 oriented derivative", derived.derivedBundleURL),
        ]
        let virtual: [(String, URL)] = [
            ("L6a subset of single", fixtures.subsetOfSingle),
            ("L6a subset of interleaved", fixtures.subsetOfInterleaved),
            ("L6a subset of merge", fixtures.subsetOfMerge),
            ("L6a subset of repair", fixtures.subsetOfRepair),
        ]
        return physical.map { Row(name: $0.0, bundle: $0.1, usesStubMaterializer: false) }
            + virtual.map { Row(name: $0.0, bundle: $0.1, usesStubMaterializer: true) }
    }

    // MARK: - Routes

    enum Tool: String, CaseIterable {
        case kraken2
        case esviritu
    }

    /// The columns. The executor joins as a third case.
    enum Route: String, CaseIterable {
        case gui
        case cli
    }

    private var databaseURL: URL { root.appendingPathComponent("db", isDirectory: true) }

    /// What `route` hands `tool` for the sample of `row`, rendered with paths masked.
    private func handoff(of row: Row, to tool: Tool, through route: Route) async -> String {
        let run = root.appendingPathComponent("runs/\(route.rawValue)-\(tool.rawValue)-\(UUID().uuidString)", isDirectory: true)
        let mask = PathMask(
            run: run,
            database: databaseURL,
            projects: [fixtures.projectURL, derived.projectURL]
        )
        do {
            guard let sample = MetagenomicsSampleGrouper.group([row.bundle]).first else {
                return "no sample"
            }
            switch (tool, route) {
            case (.kraken2, .gui):
                return try render(kraken2: try await guiKraken2(sample, row: row, run: run), mask: mask)
            case (.kraken2, .cli):
                return try render(kraken2: try await cliKraken2(sample, row: row, run: run), mask: mask)
            case (.esviritu, .gui):
                return try render(esviritu: try await guiEsViritu(sample, row: row, run: run), mask: mask)
            case (.esviritu, .cli):
                return try render(esviritu: try await cliEsViritu(sample, row: row, run: run), mask: mask)
            }
        } catch {
            return "refused: \(String(describing: type(of: error))) \(mask(error.localizedDescription))"
        }
    }

    private func materializer(for row: Row) -> any CLISequenceInputMaterializing & Sendable {
        row.usesStubMaterializer ? fixtures.materializer : FASTQCLIMaterializer(runner: .shared)
    }

    // MARK: Kraken2

    private func kraken2WizardConfig(_ sample: MetagenomicsSampleInput, run: URL) async -> ClassificationConfig {
        let database = MetagenomicsDatabaseInfo(
            name: "Viral", tool: "kraken2", version: "1", sizeBytes: 1, catalogID: "kraken2-viral",
            installationRecipe: nil, payloadDigest: nil, description: "", path: databaseURL,
            status: .ready, recommendedRAM: 1
        )
        return ClassificationWizardSheet.makeProfileConfig(
            sample: sample,
            readPlan: await ClassificationSampleReadPlan.planned(for: sample),
            database: database,
            databasePath: databaseURL,
            outputDirectory: run.appendingPathComponent("out", isDirectory: true),
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: false,
            extraArguments: []
        )
    }

    /// The app's Kraken2 launch. `resolvedKraken2Config` takes no materializer
    /// (`resolveInputFiles` builds the launch's own), so a virtual subset whose
    /// reads only the stub writes runs the resolver's two steps with the stub,
    /// `ResolvedSequenceInputs.resolve` and then `AppDelegate.planKraken2ReadSet`,
    /// as `BundleResolutionCLIParityTests` does.
    private func guiKraken2(_ sample: MetagenomicsSampleInput, row: Row, run: URL) async throws -> ClassificationConfig {
        let config = await kraken2WizardConfig(sample, run: run)
        let scratch = run.appendingPathComponent("scratch", isDirectory: true)
        guard row.usesStubMaterializer else {
            return try await AppDelegate().resolvedKraken2Config(config, tempDirectory: scratch)
        }
        let resolvedFiles = try await ResolvedSequenceInputs.resolve(
            inputURLs: config.inputFiles,
            materializationDirectory: scratch,
            materializer: materializer(for: row)
        ).executionInputURLs
        var resolved = config
        resolved.sampleDisplayName = resolved.sampleDisplayName ?? config.inputFiles.first?.deletingPathExtension().lastPathComponent
        resolved.originalInputFiles = resolved.originalInputFiles ?? config.inputFiles
        resolved.inputFiles = resolvedFiles
        return try await AppDelegate.planKraken2ReadSet(resolved, materializedInputs: resolvedFiles)
    }

    /// The command the Operations panel records, parsed by the shipped parser
    /// and resolved, configured and planned in the order `ClassifyCommand.run`
    /// does. The database is the path the registry name resolves to.
    private func cliKraken2(_ sample: MetagenomicsSampleInput, row: Row, run: URL) async throws -> ClassificationConfig {
        let recorded = AppDelegate.classificationCLICommand(for: await kraken2WizardConfig(sample, run: run))
        let command = try RecordedCLICommand.parse(recorded, as: ClassifyCommand.self)
        let inputs = try CLIClassificationFolderResolver.expandInputArguments(command.fastqFiles, recursive: command.recursive)
        let outputDirectory = URL(fileURLWithPath: try XCTUnwrap(command.outputDir), isDirectory: true)
        let inputsDirectory = outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: inputs, tempDirectory: inputsDirectory, materializer: materializer(for: row)
        )
        var config = try command.makeConfigForTesting(
            inputURLs: inputs,
            databasePath: databaseURL,
            inputFormat: try ClassifyCommand.inferInputFormat(from: inputs),
            outputDirectory: outputDirectory
        )
        config.inputFiles = resolved.executionInputURLs
        config.confidence = command.confidence ?? config.confidence
        config.minimumHitGroups = command.minHitGroups ?? config.minimumHitGroups
        config.originalInputFiles = inputs.map(\.standardizedFileURL)
        config.sampleDisplayName = inputs.first?.deletingPathExtension().lastPathComponent
        _ = try await command.planReadSet(
            inputURLs: inputs,
            executionInputURLs: resolved.executionInputURLs,
            config: &config,
            materializationDirectory: inputsDirectory
        )
        return config
    }

    // MARK: EsViritu

    private func esVirituWizardConfig(_ sample: MetagenomicsSampleInput, run: URL) async -> EsVirituConfig {
        let plan = await EsVirituSampleReadPlan.planned(for: sample)
        var config = EsVirituConfig(
            inputFiles: sample.inputFiles,
            isPairedEnd: sample.isPairedEnd,
            sampleName: "sample",
            outputDirectory: run.appendingPathComponent("out", isDirectory: true),
            databasePath: databaseURL,
            threads: 4,
            readFormat: plan.format,
            inputLayout: plan.layout
        )
        config.plansReadSet = plan.plansReadSet
        return config
    }

    /// The app's EsViritu launch. A bundle that needs no stub runs with the
    /// launch's own materializer (`materializer: nil`).
    private func guiEsViritu(_ sample: MetagenomicsSampleInput, row: Row, run: URL) async throws -> EsVirituConfig {
        try await AppDelegate().resolvedEsVirituConfig(
            await esVirituWizardConfig(sample, run: run),
            tempDirectory: run.appendingPathComponent("scratch", isDirectory: true),
            materializer: row.usesStubMaterializer ? fixtures.materializer : nil
        )
    }

    /// The command the Operations panel records, parsed by the shipped parser
    /// and resolved, configured and planned in the order
    /// `EsVirituCommand.DetectSubcommand.execute` does.
    private func cliEsViritu(_ sample: MetagenomicsSampleInput, row: Row, run: URL) async throws -> EsVirituConfig {
        let reporter = RecordingOperationReporter()
        AppDelegate.beginEsVirituOperation(
            config: await esVirituWizardConfig(sample, run: run), routeContext: nil, reporter: reporter
        ) { _ in }
        let command = try RecordedCLICommand.parse(
            try XCTUnwrap(reporter.items.first?.cliCommand), as: EsVirituCommand.DetectSubcommand.self
        )
        let inputs = try CLIClassificationFolderResolver.expandInputArguments(command.inputFiles, recursive: command.recursive)
        let outputDirectory = URL(fileURLWithPath: try XCTUnwrap(command.outputDir), isDirectory: true)
        let inputsDirectory = outputDirectory.appendingPathComponent(
            EsVirituCommand.DetectSubcommand.materializationDirectoryName, isDirectory: true
        )
        let resolved = try await EsVirituCommand.DetectSubcommand.resolveExecutionInputs(
            for: inputs, materializationDirectory: inputsDirectory, materializer: materializer(for: row)
        )
        var config = try command.makeConfigForTesting(
            databaseURL: URL(fileURLWithPath: try XCTUnwrap(command.databasePath), isDirectory: true),
            outputDirectory: outputDirectory
        )
        config.inputFiles = resolved.executionInputURLs
        config.recordInputLineage(resolved)
        _ = try await command.planReadSet(
            inputURLs: inputs,
            executionInputURLs: resolved.executionInputURLs,
            config: &config,
            materializationDirectory: inputsDirectory
        )
        return config
    }

    // MARK: - Rendering

    /// kraken2's argv, then the reads of each input after `--report-minimizer-data`, then the plan.
    private func render(kraken2 config: ClassificationConfig, mask: PathMask) throws -> String {
        let argv = config.kraken2Arguments()
        let start = (argv.firstIndex(of: "--report-minimizer-data") ?? argv.endIndex - 1) + 1
        return try render(argv: argv, inputs: Array(argv[start...]), plan: config.readSetPlan, mask: mask)
    }

    /// EsViritu's argv as the pipeline builds it, then the reads of each file after `-r`, then the plan.
    private func render(esviritu config: EsVirituConfig, mask: PathMask) throws -> String {
        let argv = config.verifyingInterleavedInput().esVirituArguments()
        let start = (argv.firstIndex(of: "-r") ?? argv.endIndex - 1) + 1
        return try render(argv: argv, inputs: Array(argv[start...].prefix { !$0.hasPrefix("-") }), plan: config.readSetPlan, mask: mask)
    }

    private func render(argv: [String], inputs: [String], plan: ReadSetPlan?, mask: PathMask) throws -> String {
        let reads = try inputs.map { path -> String in
            guard FileManager.default.fileExists(atPath: path) else { return "absent" }
            return try Self.recordNames(in: URL(fileURLWithPath: path)).joined(separator: " ")
        }
        let planText: String
        if let plan {
            let parameters = plan.provenanceParameters
            planText = parameters.isEmpty ? "records nothing" : Self.render(.dictionary(parameters), mask: mask)
        } else {
            planText = "none"
        }
        return "argv: \(argv.map { mask($0) }.joined(separator: " ")) | reads: \(reads.joined(separator: " / ")) | plan: \(planText)"
    }

    private static func render(_ value: ParameterValue, mask: PathMask) -> String {
        switch value {
        case .string(let text): return mask(text)
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        case .boolean(let flag): return String(flag)
        case .file(let url): return mask(url.path)
        case .null: return "null"
        case .array(let items): return "[" + items.map { render($0, mask: mask) }.joined(separator: ", ") + "]"
        case .dictionary(let members):
            return "{" + members.keys.sorted().map { "\($0)=\(render(members[$0] ?? .null, mask: mask))" }.joined(separator: " ") + "}"
        }
    }

    /// The record names of a FASTQ or FASTA file, in file order.
    private static func recordNames(in url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.hasPrefix(">") == true {
            return lines.filter { $0.hasPrefix(">") }.map { String($0.dropFirst()) }
        }
        return lines.enumerated().compactMap { index, line in
            index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil
        }
    }
}

/// Replaces the paths of one route's run with tokens: its scratch folders
/// with `<scratch>`, its output folder with `<out>`, the database with `<db>`,
/// the fixture projects with `<project>`, and any UUID with `<uuid>`.
private struct PathMask {
    private let anchors: [(path: String, token: String)]

    init(run: URL, database: URL, projects: [URL]) {
        let out = run.appendingPathComponent("out", isDirectory: true)
        var pairs: [(URL, String)] = [
            (out.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true), "<scratch>"),
            (out.appendingPathComponent(EsVirituCommand.DetectSubcommand.materializationDirectoryName, isDirectory: true), "<scratch>"),
            (run.appendingPathComponent("scratch", isDirectory: true), "<scratch>"),
            (out, "<out>"),
            (database, "<db>"),
        ]
        pairs += projects.map { ($0, "<project>") }
        var anchors: [(String, String)] = []
        for (url, token) in pairs {
            for spelling in Self.spellings(of: url) where !anchors.contains(where: { $0.0 == spelling }) {
                anchors.append((spelling, token))
            }
        }
        self.anchors = anchors.sorted { $0.0.count > $1.0.count }
    }

    /// Also replaces the random 8-digit token `KrakenReadSetPlanner` puts in
    /// the name of each file it splits, `reads-<token>.R1.fastq`.
    func callAsFunction(_ text: String) -> String {
        var result = text
        for anchor in anchors {
            result = result.replacingOccurrences(of: anchor.path, with: anchor.token)
        }
        result = result.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<uuid>",
            options: .regularExpression
        )
        return result.replacingOccurrences(
            of: "(?<=-)[0-9a-f]{8}(?=\\.(R1|R2|single)\\.)",
            with: "<token>",
            options: .regularExpression
        )
    }

    /// The path as given, standardized and with symlinks resolved, with and without `/private`.
    private static func spellings(of url: URL) -> [String] {
        var forms = Set([url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
        for form in forms {
            if form.hasPrefix("/private/") {
                forms.insert(String(form.dropFirst("/private".count)))
            } else {
                forms.insert("/private" + form)
            }
        }
        return forms.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }
}

/// The frozen values of the table, captured on the base of Phase 2.7 lane F1
/// (`18e422c4f`). A value is the tool's argv, then the read names of each
/// input file (`absent` for the header-only mate the pipeline stages at run
/// time), then the read-set plan: `none` when the run plans nothing, `records
/// nothing` for a plan of pairs only or single reads only, else the
/// `readSetPlan` parameters the run records. The Kraken2 argv is
/// `kraken2Arguments()` of the config handed to `ClassificationPipeline`,
/// and the EsViritu argv is the one `EsVirituPipeline` builds.
enum ClassifierReadSetParityTable {
    /// A route that gives another value than the row's today, with the lane that removes the difference.
    struct KnownDifference {
        let tool: ClassifierReadSetParityTests.Tool
        let row: String
        let route: String
        let value: String
        let lane: String
    }

    /// D9 of the 2.7 inventory. The legacy GUI resolver has no preflight, so
    /// it tries to materialize a demultiplex group and fails on its missing
    /// root file, where the CLI refuses the group before writing anything. The
    /// GUI route of lane A10 runs through the CLI, and lane A12 deletes this
    /// legacy column with the legacy path.
    static let knownDifferences: [KnownDifference] = [
        KnownDifference(
            tool: .kraken2, row: "L6e demultiplex group", route: "gui",
            value: "refused: FASTQCLIMaterializerError Root FASTQ file referenced in manifest does not exist",
            lane: "A10, A12"
        ),
        KnownDifference(
            tool: .esviritu, row: "L6e demultiplex group", route: "gui",
            value: "refused: FASTQCLIMaterializerError Root FASTQ file referenced in manifest does not exist",
            lane: "A10, A12"
        ),
    ]

    private static let imports = "<project>/Imports"
    private static let materialized = "<scratch>/materialized-<uuid>.fastq"
    private static let concatenated = "<scratch>/concatenated-<uuid>.fastq"
    private static let unplanned = "none"
    private static let recordsNothing = "records nothing"
    private static let singleReadReason = "The sample holds read pairs and single reads, and this tool cannot pair part "
        + "of a sample, so every read runs as a single read. No read is left out."

    static let frozen: [ClassifierReadSetParityTests.Tool: [String: String]] = [
        .kraken2: [
            "L1 single": kraken2(files: "\(imports)/single.lungfishfastq/single.fastq", reads: "s1 s2 s3"),
            "L2 interleaved": kraken2(files: "\(imports)/interleaved.lungfishfastq/reads.fastq", reads: "i1/1 i1/2 i2/1 i2/2"),
            "L3 mixed root": kraken2(
                paired: true, files: split("reads-<token>"), reads: "p1/1 p2/1 / p1/2 p2/2 / m1 m2 m3 / absent",
                plan: plan("both_in_one_run/separate_files", "mixed_file", pairs: 2, merged: 3)
            ),
            "L4 chunked": kraken2(
                files: "\(imports)/chunked.lungfishfastq/chunks/run_0.fastq \(imports)/chunked.lungfishfastq/chunks/run_1.fastq",
                reads: "c1 c2 / c3"
            ),
            "L4 Nanopore chunks named as mates": kraken2(
                files: "\(imports)/nanopore.lungfishfastq/chunks/x_1.fastq \(imports)/nanopore.lungfishfastq/chunks/x_2.fastq",
                reads: "o-a o-b / o-c"
            ),
            "L4 Illumina chunks named R1 and R2": kraken2(
                paired: true,
                files: "\(imports)/named-pair.lungfishfastq/chunks/sample_R1.fastq \(imports)/named-pair.lungfishfastq/chunks/sample_R2.fastq",
                reads: "q1/1 / q1/2", plan: recordsNothing
            ),
            "L4 unknown platform chunks": kraken2(
                files: "\(imports)/unknown-platform.lungfishfastq/chunks/x_1.fastq \(imports)/unknown-platform.lungfishfastq/chunks/x_2.fastq",
                reads: "v1 / v2"
            ),
            "L5a full": kraken2(files: "\(imports)/full.lungfishfastq/reads.fastq", reads: "g1 g2"),
            "L5a full merge output": kraken2(
                paired: true, files: split("reads-<token>"), reads: "p1/1 / p1/2 / m1 m2 / absent",
                plan: plan("both_in_one_run/separate_files", "mixed_file", pairs: 1, merged: 2)
            ),
            "L5a full unlabelled": kraken2(files: "\(imports)/unlabelled.lungfishfastq/reads.fastq", reads: "k1/1 k1/2 k2/1 k2/2"),
            "L5b paired": kraken2(
                paired: true,
                files: "\(imports)/paired.lungfishfastq/sample_R1.fastq \(imports)/paired.lungfishfastq/sample_R2.fastq",
                reads: "p1/1 p2/1 / p1/2 p2/2", plan: recordsNothing
            ),
            "L5c merge": kraken2(
                paired: true,
                files: "\(imports)/merge.lungfishfastq/unmerged_R1.fastq \(imports)/merge.lungfishfastq/unmerged_R2.fastq "
                    + "\(imports)/merge.lungfishfastq/merged.fastq <scratch>/merged.emptymate.fastq",
                reads: "u1/1 / u1/2 / x1 x2 x3 / absent",
                plan: plan("both_in_one_run/separate_files", "mixed_derivative", pairs: 1, merged: 3)
            ),
            "L5d repair": kraken2(
                paired: true,
                files: "\(imports)/repair.lungfishfastq/repaired_R1.fastq \(imports)/repair.lungfishfastq/repaired_R2.fastq "
                    + "\(imports)/repair.lungfishfastq/singletons.fastq <scratch>/singletons.emptymate.fastq",
                reads: "r1/1 r2/1 / r1/2 r2/2 / o1 / absent",
                plan: plan("both_in_one_run/separate_files", "mixed_derivative", pairs: 2, orphans: 1)
            ),
            "L5e FASTA": kraken2(files: "\(imports)/converted.lungfishfastq/converted.fasta", reads: "f1 f2"),
            "L6e demultiplex group": "refused: CLISequenceInputMaterializationError Demultiplexed group bundles are "
                + "container-only; select an individual demultiplexed FASTQ bundle for classification.",
            "L6 oriented derivative": kraken2(files: materialized, reads: "read1 read3"),
            "L6a subset of single": kraken2(files: materialized, reads: "s1 s3"),
            "L6a subset of interleaved": kraken2(files: materialized, reads: "i1/1 i1/2", plan: recordsNothing),
            "L6a subset of merge": kraken2(
                paired: true, files: split("materialized-<uuid>-<token>"), reads: "u1/1 / u1/2 / x1 / absent",
                plan: plan("both_in_one_run/separate_files", "mixed_file", pairs: 1, merged: 1)
            ),
            "L6a subset of repair": kraken2(files: materialized, reads: "r1/1 r1/2 r2/1 r2/2", plan: recordsNothing),
        ],
        .esviritu: [
            "L1 single": esviritu(files: "\(imports)/single.lungfishfastq/single.fastq", format: "unpaired", reads: "s1 s2 s3"),
            "L2 interleaved": esviritu(
                files: "\(imports)/interleaved.lungfishfastq/reads.fastq", format: "interleaved", reads: "i1/1 i1/2 i2/1 i2/2"
            ),
            "L3 mixed root": esviritu(
                files: "\(imports)/mixed-root.lungfishfastq/reads.fastq", format: "unpaired", reads: "m1 m2 m3 p1/1 p1/2 p2/1 p2/2",
                plan: plan("pairs_only_when_all_paired", "mixed_file", pairs: 2, merged: 3, reason: singleReadReason)
            ),
            "L4 chunked": esviritu(files: concatenated, format: "unpaired", reads: "c1 c2 c3", plan: recordsNothing),
            "L4 Nanopore chunks named as mates": esviritu(
                files: concatenated, format: "unpaired", reads: "o-a o-b o-c", plan: recordsNothing
            ),
            "L4 Illumina chunks named R1 and R2": esviritu(
                files: "\(imports)/named-pair.lungfishfastq/chunks/sample_R1.fastq \(imports)/named-pair.lungfishfastq/chunks/sample_R2.fastq",
                format: "paired", reads: "q1/1 / q1/2", plan: recordsNothing
            ),
            "L4 unknown platform chunks": esviritu(files: concatenated, format: "unpaired", reads: "v1 v2", plan: recordsNothing),
            "L5a full": esviritu(files: "\(imports)/full.lungfishfastq/reads.fastq", format: "unpaired", reads: "g1 g2"),
            "L5a full merge output": esviritu(
                files: "\(imports)/merge-output.lungfishfastq/reads.fastq", format: "unpaired", reads: "m1 m2 p1/1 p1/2",
                plan: plan("pairs_only_when_all_paired", "mixed_file", pairs: 1, merged: 2, reason: singleReadReason)
            ),
            "L5a full unlabelled": esviritu(
                files: "\(imports)/unlabelled.lungfishfastq/reads.fastq", format: "interleaved", reads: "k1/1 k1/2 k2/1 k2/2"
            ),
            "L5b paired": esviritu(
                files: "\(imports)/paired.lungfishfastq/sample_R1.fastq \(imports)/paired.lungfishfastq/sample_R2.fastq",
                format: "paired", reads: "p1/1 p2/1 / p1/2 p2/2", plan: recordsNothing
            ),
            "L5c merge": esviritu(
                files: concatenated, format: "unpaired", reads: "x1 x2 x3 u1/1 u1/2",
                plan: plan("pairs_only_when_all_paired", "mixed_derivative", pairs: 1, merged: 3, reason: singleReadReason)
            ),
            "L5d repair": esviritu(
                files: concatenated, format: "unpaired", reads: "r1/1 r2/1 r1/2 r2/2 o1",
                plan: plan("pairs_only_when_all_paired", "mixed_derivative", pairs: 2, orphans: 1, reason: singleReadReason)
            ),
            "L5e FASTA": esviritu(files: "\(imports)/converted.lungfishfastq/converted.fasta", format: "unpaired", reads: "f1 f2"),
            "L6e demultiplex group": "refused: CLISequenceInputMaterializationError Demultiplexed group bundles are "
                + "container-only; select an individual demultiplexed FASTQ bundle for EsViritu detection.",
            "L6 oriented derivative": esviritu(files: materialized, format: "unpaired", reads: "read1 read3"),
            "L6a subset of single": esviritu(files: materialized, format: "unpaired", reads: "s1 s3"),
            "L6a subset of interleaved": esviritu(
                files: materialized, format: "interleaved", reads: "i1/1 i1/2", plan: recordsNothing
            ),
            "L6a subset of merge": esviritu(
                files: materialized, format: "unpaired", reads: "u1/1 u1/2 x1",
                plan: plan("pairs_only_when_all_paired", "mixed_file", pairs: 1, merged: 1, reason: singleReadReason)
            ),
            "L6a subset of repair": esviritu(
                files: materialized, format: "interleaved", reads: "r1/1 r1/2 r2/1 r2/2", plan: recordsNothing
            ),
        ],
    ]

    private static func kraken2(paired: Bool = false, files: String, reads: String, plan: String = unplanned) -> String {
        "argv: --db <db> --threads 4 --confidence 0.2 --minimum-hit-groups 2 --output <out>/classification.kraken "
            + "--report <out>/classification.kreport\(paired ? " --paired" : "") --report-minimizer-data \(files)"
            + " | reads: \(reads) | plan: \(plan)"
    }

    private static func esviritu(files: String, format: String, reads: String, plan: String = unplanned) -> String {
        "argv: -r \(files) -s sample -o <out> -p \(format) -t 4 -q True --db <db> --keep True | reads: \(reads) | plan: \(plan)"
    }

    /// The four files `KrakenReadSetPlanner` splits a mixed file into, the
    /// pair, the single reads and the header-only mate staged beside them.
    private static func split(_ stem: String) -> String {
        ["R1", "R2", "single", "single.emptymate"].map { "<scratch>/\(stem).\($0).fastq" }.joined(separator: " ")
    }

    private static func plan(
        _ capability: String,
        _ sourceLayout: String,
        pairs: Int,
        merged: Int = 0,
        orphans: Int = 0,
        reason: String? = nil
    ) -> String {
        "{readSetPlan={capability=\(capability) mergedOrOrphanReads=0 mergedReads=\(merged) orphanReads=\(orphans) "
            + "pairedFragments=\(pairs) runs=1 singleEndReads=0 singleReadReason=\(reason ?? "null") sourceLayout=\(sourceLayout)}}"
    }
}
