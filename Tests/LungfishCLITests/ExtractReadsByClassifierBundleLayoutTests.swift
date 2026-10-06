// ExtractReadsByClassifierBundleLayoutTests.swift - extract reads --by-classifier --bundle records the layout the app records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 1.5 lane A3, D7d. The app's Kraken2 extraction to a bundle records
// the output's layout: interleaved when it holds only pairs, and single-end
// with read roles when it mixes pairs with single reads. The row records
// `lungfish-cli extract reads --by-classifier ... --bundle`, which wrapped
// the same reads as a single-end bundle with no roles.

import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ExtractReadsByClassifierBundleLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cli-kraken2-bundle-layout")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// What a bundle records about its reads: the pairing, the read roles
    /// as role and count, and the record names in order.
    struct RecordedLayout: Equatable {
        let pairing: IngestionMetadata.PairingMode?
        let roles: [String]
        let records: [String]
    }

    /// A paired source and a merged source, with mates named `/1` and `/2`,
    /// and named the same, the BBTools and SRA form, where only the recorded
    /// layout says which records are mates. Every difference is collected,
    /// so one failure lists them all.
    func testACLIBundleRecordsTheAppsLayoutAndIsPlannedAsPairs() async throws {
        var differences: [String] = []
        for identicalNames in [false, true] {
            for shape in try shapes(identicalNames: identicalNames) {
                differences += try await differencesOfCLIBundle(shape)
            }
        }
        XCTAssertEqual(differences, [], "a CLI bundle records the app's layout and read roles, and is planned as pairs")
    }

    typealias Shape = (name: String, result: URL, pairing: IngestionMetadata.PairingMode, roles: [String], layout: ReadSetSourceLayout)

    private func shapes(identicalNames: Bool) throws -> [Shape] {
        let names = identicalNames ? "identical names" : "slash names"
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent(identicalNames ? "identical" : "slash", isDirectory: true))
        if identicalNames {
            try Self.dropMateSuffixes(in: fixtures.pairedDerivative)
            try Self.dropMateSuffixes(in: fixtures.mergeDerivative)
        }
        let analyses = fixtures.projectURL.appendingPathComponent("Analyses", isDirectory: true)
        return [
            (
                "paired derivative, \(names)",
                try Self.result("paired", in: analyses, input: fixtures.pairedDerivative, lines: [Self.pair("p1", 100), Self.pair("p2", 200)]),
                .interleaved, [], .interleavedFile
            ),
            (
                "merge derivative, \(names)",
                try Self.result("merge", in: analyses, input: fixtures.mergeDerivative, lines: [
                    Self.pair("u1", 100), Self.staged("x1", 100), Self.staged("x2", 200), Self.staged("x3", 200),
                ]),
                .singleEnd, ["paired_r1 1", "paired_r2 1", "merged 1"], .mixedFile
            ),
        ]
    }

    /// How the CLI's bundle of `shape` differs from the app's bundle and
    /// from a plan of pairs, one line per difference.
    private func differencesOfCLIBundle(_ shape: Shape) async throws -> [String] {
        let app = try Self.recordedLayout(of: try await appBundle(shape.result, name: "app-\(shape.name)"))
        let cliBundle = try await cliBundle(shape.result, name: "cli-\(shape.name)")
        let cli = try Self.recordedLayout(of: cliBundle)
        var differences: [String] = []
        func check<Value: Equatable>(_ what: String, _ actual: Value, _ expected: Value) {
            if actual != expected { differences.append("\(shape.name): \(what) \(actual), expected \(expected)") }
        }
        check("the app's pairing", app.pairing, shape.pairing)
        check("the app's roles", app.roles, shape.roles)
        check("the CLI's pairing", cli.pairing, app.pairing)
        check("the CLI's roles", cli.roles, app.roles)
        check("the CLI's records", cli.records, app.records)

        let plan = try await ReadSetResolver(
            materializationDirectory: root.appendingPathComponent("plan-\(UUID().uuidString)", isDirectory: true),
            countReads: true
        ).plan(for: cliBundle, capability: .bothInOneRunAsSeparateFiles)
        check("the plan's layout", plan.sourceLayout, shape.layout)
        check("the plan's pairs", plan.composition.pairedFragments, 1)
        check("the plan's single-read reason", plan.singleReadReason, nil)
        return differences
    }

    /// Renames `X/1` and `X/2` to `X` in every FASTQ file of `bundle`.
    static func dropMateSuffixes(in bundle: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fastq" }
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            let renamed = lines.enumerated().map { index, line -> String in
                index % 4 == 0 && (line.hasSuffix("/1") || line.hasSuffix("/2")) ? String(line.dropLast(2)) : String(line)
            }
            try renamed.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - The two paths

    /// The app's path: the resolver's bundle destination.
    private func appBundle(_ result: URL, name: String) async throws -> URL {
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: result,
            selections: [ClassifierRowSelector(taxIds: [100])],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: ClassifierReadResolver.resolveProjectRoot(from: result),
                displayName: name,
                metadata: ExtractionMetadata(sourceDescription: name, toolName: "Kraken2", parameters: [:])
            )
        )
        // Another outcome is a dispatch regression, so it fails the test
        // rather than skip it (final review B note 11).
        let url: URL? = if case .bundle(let url, _) = outcome { url } else { nil }
        return try XCTUnwrap(url, "expected a bundle, got \(outcome)")
    }

    /// The command the app's row records for a bundle.
    private func cliBundle(_ result: URL, name: String) async throws -> URL {
        let outputDirectory = root.appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        let argv = [
            "--by-classifier",
            "--tool", "kraken2",
            "--result", result.path,
            "--taxon", "100",
            "--read-format", "fastq",
            "--bundle",
            "--bundle-name", name,
            "-o", outputDirectory.appendingPathComponent("\(name).fastq").path,
        ]
        var command = try ExtractReadsSubcommand.parse(argv)
        command.testingRawArgs = argv
        try command.validate()
        try await command.run()
        let bundles = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == FASTQBundle.directoryExtension }
        return try XCTUnwrap(bundles.first, "the CLI wrote no bundle in \(outputDirectory.path)")
    }

    // MARK: - Fixture

    static func recordedLayout(of bundle: URL) throws -> RecordedLayout {
        let payload = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fastq" },
            "no FASTQ in \(bundle.lastPathComponent)"
        )
        let metadata = FASTQMetadataStore.load(for: payload)
        let roles = metadata?.readClassification?.files ?? []
        XCTAssertTrue(roles.allSatisfy { $0.filename == payload.lastPathComponent }, "every role names the payload")
        return RecordedLayout(
            pairing: metadata?.ingestion?.pairingMode,
            roles: roles.map { "\($0.role.rawValue) \($0.readCount)" },
            records: try ReadSetFixtures.readNames(in: payload)
        )
    }

    static func pair(_ fragment: String, _ taxId: Int) -> String {
        "C\t\(fragment)\t\(taxId)\t10|10\t\(taxId):3 |:| \(taxId):3"
    }

    static func staged(_ fragment: String, _ taxId: Int) -> String {
        "C\t\(fragment)\t\(taxId)\t10|0\t\(taxId):3 |:| "
    }

    static func result(_ name: String, in analyses: URL, input: URL, lines: [String]) throws -> URL {
        let directory = analyses.appendingPathComponent("kraken2-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = ClassificationConfig(
            inputFiles: [input],
            isPairedEnd: true,
            databaseName: "Viral",
            databasePath: directory,
            outputDirectory: directory
        )
        config.originalInputFiles = [input]
        let kreport = directory.appendingPathComponent("classification.kreport")
        try """
         25.00\t1\t1\tU\t0\tunclassified
         75.00\t3\t0\tR\t1\troot
         50.00\t2\t2\tS\t100\t  Target virus
         25.00\t1\t1\tS\t200\t  Other virus

        """.write(to: kreport, atomically: true, encoding: .utf8)
        let kraken = directory.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: kraken, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: kreport),
            reportURL: kreport,
            outputURL: kraken,
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.17.1",
            provenanceId: nil
        ).save(to: directory)
        return directory
    }
}
