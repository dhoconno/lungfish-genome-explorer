// MappingRouteGoldenConformanceTests.swift - The Map Reads route's result on the mapping golden's fixture
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M1 (BIO 1). The Map Reads window runs ManagedMappingPipeline in the app
// today (census row p19), and the route moves onto `lungfish-cli map` behind a hidden key. This
// class maps the mapping golden's fixture (Tests/Fixtures/sarscov2 with minimap2, the sr preset,
// paired reads, two threads and sample sarscov2-test, as scripts/golden/captures.py runs it)
// through the window's steps and holds the result to the golden `lungfish-cli map` wrote
// (Tests/Fixtures/golden/mapping). The records line is compared byte for byte, the counts as
// JSON values, the header line by line with each path in an @PG command line cut to its last
// component (the run root and the reference staging folder differ per run, rule R8), and the
// run record by its mapper, versions, layout, threads, read group and steps.
//
// The real tools run, so the name holds Conformance and the class never runs in the unit tier.
// Run it against the golden storage, whose minimap2 and samtools wrote the golden:
//
//     LUNGFISH_STORAGE_ROOT=/Users/Shared/lungfish-golden/storage LUNGFISH_REQUIRE_TOOLS=1 \
//         swift test --skip-update --filter MappingRouteGoldenConformanceTests

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MappingRouteGoldenConformanceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "mapping-route-golden")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheInProcessRouteMapsTheGoldenFixtureToTheGoldenRecords() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixture = try MappingRouteGolden.Fixture(in: scratch)
        let request = fixture.windowRequest()

        // The begin helper records the command the row shows today.
        let reporter = RecordingOperationReporter()
        AppDelegate.beginManagedMappingOperation(request: request, routeContext: nil, reporter: reporter) { _ in }
        let recorded = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: MapCommand.self)
        XCTAssertTrue(recorded.pairedEnd)
        XCTAssertEqual(recorded.readLayout, .auto)
        XCTAssertEqual(recorded.globalOptions.threads, 2)
        XCTAssertEqual(recorded.sampleName, "sarscov2-test")

        // The steps runSingleManagedMappingAwaitingCompletion takes.
        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: request, progress: { _ in })
        let result = try await ManagedMappingPipeline().run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )
        let publication = try await MappingResultLayoutService.publishViewerBundle(result: result, request: resolved.request)
        XCTAssertNil(publication, "the fixture's reference is a plain FASTA, so no viewer bundle is published")

        try MappingRouteGolden.assertMatchesGolden(
            outputDirectory: request.outputDirectory,
            bam: result.bamURL,
            totalReads: result.totalReads,
            mappedReads: result.mappedReads,
            samtools: samtools
        )
    }
}

/// The mapping golden's fixture and its comparisons, shared by the Map Reads route classes.
enum MappingRouteGolden {
    static let sampleName = "sarscov2-test"

    static var goldenDirectory: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/golden/mapping", isDirectory: true)
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A project holding the golden capture's three input files, copied from Tests/Fixtures/sarscov2.
    struct Fixture {
        let project: URL
        let reference: URL
        let readOne: URL
        let readTwo: URL
        let analysisDirectory: URL

        init(in root: URL) throws {
            let fileManager = FileManager.default
            project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
            let inputs = project.appendingPathComponent("inputs", isDirectory: true)
            try fileManager.createDirectory(at: inputs, withIntermediateDirectories: true)
            let source = MappingRouteGolden.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
            for name in ["genome.fasta", "test_1.fastq.gz", "test_2.fastq.gz"] {
                try fileManager.copyItem(at: source.appendingPathComponent(name), to: inputs.appendingPathComponent(name))
            }
            reference = inputs.appendingPathComponent("genome.fasta")
            readOne = inputs.appendingPathComponent("test_1.fastq.gz")
            readTwo = inputs.appendingPathComponent("test_2.fastq.gz")
            analysisDirectory = try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: project)
        }

        /// The request the Map Reads window builds for the golden's run, bound to the run's folder.
        /// `referenceFASTA` replaces the fixture's plain FASTA, such as the FASTA of a `.lungfishref`.
        func windowRequest(referenceFASTA: URL? = nil) -> MappingRunRequest {
            let modeID = MappingMode.defaultShortRead.id
            return MappingRunRequest(
                tool: .minimap2,
                modeID: modeID,
                inputFASTQURLs: [readOne, readTwo],
                referenceFASTAURL: referenceFASTA ?? reference,
                projectURL: project,
                outputDirectory: analysisDirectory,
                sampleName: MappingRouteGolden.sampleName,
                readGroup: MappingReadGroup.resolved(
                    sampleName: MappingRouteGolden.sampleName,
                    id: nil,
                    readGroupSampleName: nil,
                    library: nil,
                    platform: nil,
                    platformUnit: nil,
                    defaultPlatform: MappingReadGroup.defaultPlatform(forModeID: modeID)
                ),
                pairedEnd: true,
                threads: 2,
                includeSecondary: false,
                includeSupplementary: true,
                minimumMappingQuality: 0,
                advancedArguments: []
            )
        }
    }

    /// The run record keys that hold no path, clock or host, compared as JSON values.
    static let recordKeys = [
        "exitStatus", "includeSecondary", "includeSupplementary", "inputLayout", "inputLayoutReason",
        "mapper", "mapperVersion", "minimumMappingQuality", "modeID", "pairedEnd", "readGroup",
        "readLayoutHandling", "sampleName", "samtoolsVersion", "threads", "workflowName",
    ]

    /// Holds a finished run in `outputDirectory` to the golden: the records line, the counts, the
    /// header, the totals the row's completion detail shows and the run record.
    static func assertMatchesGolden(
        outputDirectory: URL,
        bam: URL,
        totalReads: Int,
        mappedReads: Int,
        samtools: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let golden = goldenDirectory
        XCTAssertEqual(
            try recordsLine(bam: bam, samtools: samtools),
            try String(contentsOf: golden.appendingPathComponent("records.sha256"), encoding: .utf8),
            "the alignment records differ from the golden's",
            file: file, line: line
        )
        let counts = try counts(bam: bam, samtools: samtools)
        let goldenCounts = try jsonObject(golden.appendingPathComponent("counts.json"))
        XCTAssertTrue(
            NSDictionary(dictionary: counts).isEqual(to: goldenCounts),
            "the counts differ from the golden's:\n\(counts)",
            file: file, line: line
        )
        XCTAssertEqual(
            try headerLines(bam: bam, samtools: samtools).map(cutCommandLinePaths),
            try String(contentsOf: golden.appendingPathComponent("header.sam"), encoding: .utf8)
                .split(separator: "\n").map(String.init).map(cutCommandLinePaths),
            "the header differs from the golden's",
            file: file, line: line
        )
        let report = try jsonObject(golden.appendingPathComponent("cli-report.json"))
        XCTAssertEqual(totalReads, report["totalReads"] as? Int, file: file, line: line)
        XCTAssertEqual(mappedReads, report["mappedReads"] as? Int, file: file, line: line)

        let record = try jsonObject(outputDirectory.appendingPathComponent("mapping-provenance.json"))
        let goldenRecord = try jsonObject(golden.appendingPathComponent("mapping-provenance.json"))
        for key in recordKeys {
            XCTAssertEqual(
                record[key].map { NSDictionary(dictionary: ["value": $0]) },
                goldenRecord[key].map { NSDictionary(dictionary: ["value": $0]) },
                "the run record's \(key) differs from the golden's",
                file: file, line: line
            )
        }
        XCTAssertEqual(stepLabels(record), stepLabels(goldenRecord), "the run record's steps differ", file: file, line: line)
    }

    /// `<sha256>  samtools view --no-PG (<n> records)`, as captures.py writes records.sha256.
    static func recordsLine(bam: URL, samtools: URL) throws -> String {
        let records = try run(samtools, ["view", "--no-PG", bam.path])
        let digest = SHA256.hash(data: Data(records.utf8)).map { String(format: "%02x", $0) }.joined()
        let count = records.filter { $0 == "\n" }.count
        return "\(digest)  samtools view --no-PG (\(count) records)\n"
    }

    /// The counts captures.py writes to counts.json, from `flagstat -O json` and `idxstats`.
    static func counts(bam: URL, samtools: URL) throws -> [String: Any] {
        let flagstat = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(try run(samtools, ["flagstat", "-O", "json", bam.path]).utf8)) as? [String: Any]
        )
        let passed = try XCTUnwrap(flagstat["QC-passed reads"] as? [String: Any])
        let perContig: [[String: Any]] = try run(samtools, ["idxstats", bam.path])
            .split(separator: "\n").map { row in
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return [
                    "contig": fields[0], "length": Int(fields[1]) ?? -1,
                    "mapped": Int(fields[2]) ?? -1, "unmapped": Int(fields[3]) ?? -1,
                ]
            }
        let total = passed["total"] as? Int ?? -1
        let mapped = passed["mapped"] as? Int ?? -1
        return [
            "total": total, "primary": passed["primary"] ?? NSNull(), "mapped": mapped, "unmapped": total - mapped,
            "primaryMapped": passed["primary mapped"] ?? NSNull(), "secondary": passed["secondary"] ?? NSNull(),
            "supplementary": passed["supplementary"] ?? NSNull(), "perContig": perContig, "flagstat": flagstat,
        ]
    }

    /// The header without samtools' own @PG line, one entry per line.
    static func headerLines(bam: URL, samtools: URL) throws -> [String] {
        try run(samtools, ["view", "-H", "--no-PG", bam.path]).split(separator: "\n").map(String.init)
    }

    /// Cuts every path in an @PG line's CL field to its last component, since the run root, the
    /// reference staging folder and the managed tool folder differ from run to run (rule R8).
    static func cutCommandLinePaths(_ line: String) -> String {
        guard line.hasPrefix("@PG") else { return line }
        return line.split(separator: "\t", omittingEmptySubsequences: false).map { field -> String in
            guard field.hasPrefix("CL:") else { return String(field) }
            let words = field.dropFirst(3).split(separator: " ", omittingEmptySubsequences: false).map { word in
                word.contains("/") ? URL(fileURLWithPath: String(word)).lastPathComponent : String(word)
            }
            return "CL:" + words.joined(separator: " ")
        }.joined(separator: "\t")
    }

    static func stepLabels(_ record: [String: Any]) -> [String] {
        let mapper = (record["mapperInvocation"] as? [String: Any])?["label"] as? String ?? "none"
        let steps = (record["normalizationInvocations"] as? [[String: Any]] ?? []).map { $0["label"] as? String ?? "none" }
        return [mapper] + steps
    }

    static func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], url.path)
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let result = try ProcessRunner.run(executable, arguments, timeout: 120)
        XCTAssertEqual(result.status, 0, "\(executable.lastPathComponent) \(arguments.joined(separator: " ")): \(result.stderr)")
        return result.stdout
    }
}
