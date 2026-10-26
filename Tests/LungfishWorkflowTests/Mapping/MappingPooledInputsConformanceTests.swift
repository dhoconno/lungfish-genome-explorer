// MappingPooledInputsConformanceTests.swift - Pooled bundles on the real mappers, every read of every bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane MAPPOOL (obs-13, BIO-C2 tests 2 to 5 and 7). The real tools
// run, so the name holds Conformance and the class never runs in the unit tier.
// Run it with the managed tools (minimap2 2.31, bwa-mem2, bowtie2, BBMap 40.02
// and samtools from ~/.lungfish/conda/envs):
//
//     LUNGFISH_REQUIRE_TOOLS=1 swift test --skip-update --filter MappingPooledInputsConformanceTests
//
// Check C2 mapped two bundles of 4 interleaved pairs. BBMap mapped 8 of the 16
// reads, bwa-mem2 stopped on its name check, and minimap2 paired reads across
// bundles when the names coincided while the record said single reads. Since
// Phase 3.0 lane MAP (MAP-POOLED-PAIRS) a pool of paired bundles keeps each
// bundle's pairs, so the expectations below hold the read total, every read
// paired with its own mate inside its bundle, the flagstat counts of the
// bundles mapped alone and the record to the run.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MappingPooledInputsConformanceTests: XCTestCase {
    private typealias Fixture = MappingPooledInputsFixture

    private var root: URL!
    private var imports: URL!
    private var reference: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-pooled-conformance")
        imports = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        reference = try Fixture.writeReference(in: root)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// BBMap mapped 8 of the 16 reads of two pooled bundles and dropped bundle B.
    func testTwoPooledBundlesBBMapMapsEveryRead() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts),
        ]

        let mapped = try await map(.bbmap, bundles)

        XCTAssertEqual(mapped.primaryFlags.count, 16, "BBMap maps every read of both bundles")
        XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBStarts))
        let joined = try XCTUnwrap(mapped.request.inputFASTQURLs.first)
        XCTAssertEqual(mapped.request.inputFASTQURLs.count, 1)
        XCTAssertTrue(mapped.mapperArguments.contains { $0.contains("in=\(joined.path)") }, "in= names the joined file")
    }

    /// Three pooled bundles failed on minimap2 ("please specify no more than
    /// two query files"). Each bundle holds four pairs, so 24 reads map.
    func testThreePooledInterleavedBundlesComplete() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts),
            try bundle("poolC", prefix: "c", starts: Fixture.bundleCStarts),
        ]
        for tool in [MappingTool.minimap2, .bwaMem2] {
            let mapped = try await map(tool, bundles)

            XCTAssertEqual(mapped.primaryFlags.count, 24, "\(tool) maps every read of three bundles")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 24, "\(tool): every read keeps its mate")
            XCTAssertEqual(Set(mapped.primaryTemplateLengths.map(abs)), [Fixture.fragmentLength], "\(tool): every mate is in its own bundle")
            XCTAssertEqual(mapped.record["inputLayout"] as? String, "strictly_interleaved", "\(tool)")
            XCTAssertEqual(mapped.record["readLayoutHandling"] as? String, "as_pairs", "\(tool)")
        }
    }

    /// Bundle B renamed to bundle A's read names (C2 row C). Before 2.14 minimap2
    /// grouped the reads of both bundles into fragments of four segments (flags
    /// 65, 33, 49, 145). Each read now pairs with its own mate inside its bundle,
    /// 250 bp away, never with a read of the other bundle about 1900 bp away.
    func testPooledBundlesWithEqualReadNamesPairOnlyInsideTheirBundle() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "a", starts: Fixture.bundleBStarts),
        ]
        for tool in [MappingTool.minimap2, .bwaMem2] {
            let mapped = try await map(tool, bundles)

            XCTAssertEqual(mapped.primaryFlags.count, 16, "\(tool) maps every read of both bundles")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 16, "\(tool): every read keeps its mate")
            XCTAssertEqual(Set(mapped.primaryTemplateLengths.map(abs)), [Fixture.fragmentLength], "\(tool): no read has a mate in the other bundle")
            XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBStarts), "\(tool)")
        }
    }

    /// Every mapper maps the two pooled bundles as 8 pairs of 16 reads, each
    /// read with its own mate, and the record names the files the mapper read
    /// (BIO 6) and says interleaved pairs (MAP-POOLED-PAIRS).
    func testPooledInterleavedBundlesMapAsPairsOnEveryMapper() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts),
        ]
        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            let mapped = try await map(tool, bundles)

            XCTAssertEqual(mapped.primaryFlags.count, 16, "\(tool) maps every read of both bundles")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 16, "\(tool): every read keeps its mate")
            XCTAssertEqual(Set(mapped.primaryTemplateLengths.map(abs)), [Fixture.fragmentLength], "\(tool): every mate is in its own bundle")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x10 != 0 }.count, 8, "\(tool): the R2 reads map on the reverse strand")
            XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBStarts), "\(tool)")
            XCTAssertEqual(mapped.record["inputLayout"] as? String, "strictly_interleaved", "\(tool)")
            XCTAssertEqual(mapped.record["readLayoutHandling"] as? String, "as_pairs", "\(tool)")
            for path in mapped.recordedInputPaths {
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(tool): the record names \(path), which must exist after the run")
                XCTAssertTrue(mapped.mapperArguments.contains { $0.contains(path) }, "\(tool): \(path) is in the recorded argv")
            }
            XCTAssertEqual(mapped.recordedInputPaths.count, 1, "\(tool): a pool is recorded as the one joined file")
        }
    }

    /// Lead L1 of BIO-C2. Bundles of 4 and 6 pairs give 20 reads, so no mapper
    /// skips the surplus records of the longer bundle.
    func testTwoPooledBundlesOfUnequalSizeKeepEveryRead() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBLongStarts),
        ]

        let mapped = try await map(.minimap2, bundles)

        XCTAssertEqual(mapped.primaryFlags.count, 20, "bundles of 4 and 6 pairs give 20 primary records")
        XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBLongStarts))
    }

    /// BIO 1. The usual bundle holds a gzip file, so the join writes
    /// `pooled-<UUID>.fastq.gz`, a multi-member gzip stream. Every mapper must read
    /// both members. A mapper that stopped after the first member would map 8 of
    /// the 16 reads with exit 0, as BBMap did with two separate files.
    func testTwoPooledGzipBundlesMapEveryReadOnEveryMapper() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts, gzipped: true),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts, gzipped: true),
        ]
        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            let mapped = try await map(tool, bundles)

            XCTAssertEqual(mapped.request.inputFASTQURLs.count, 1, "\(tool): a pool is one file")
            let joined = try XCTUnwrap(mapped.request.inputFASTQURLs.first)
            XCTAssertEqual(joined.pathExtension, "gz", "\(tool): the joined file is a gzip stream")
            XCTAssertEqual(mapped.primaryFlags.count, 16, "\(tool) maps every read of both gzip bundles")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 16, "\(tool): every read keeps its mate")
            XCTAssertEqual(Set(mapped.primaryTemplateLengths.map(abs)), [Fixture.fragmentLength], "\(tool): every mate is in its own bundle")
            XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBStarts), "\(tool)")
            let text = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", joined.path], timeout: 30)
            XCTAssertEqual(text.status, 0, "gzip -dc: \(text.stderr)")
            XCTAssertEqual(text.stdout.split(separator: "\n").count, 64, "\(tool): the joined file holds 16 reads of 4 lines")
        }
    }

    /// BIO 2 and 6, ARCH 5. The record of a pooled run names every bundle and the
    /// join. The payload file of each bundle is an input with its sha256, one `cat`
    /// step reads both payload files and writes the joined file alone, the mapper
    /// step reads that file, and every input the record names exists after the run.
    func testPooledRunRecordNamesEveryBundleAndTheJoinStep() async throws {
        let a = try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)
        let payloads = [a, b].map { Self.canonical(Fixture.fastqURL(in: $0).path) }

        let mapped = try await map(.minimap2, [a, b])

        let joined = Self.canonical(try XCTUnwrap(mapped.request.inputFASTQURLs.first).path)
        let inputs = recordedFiles(mapped.record["inputFiles"])
        for payload in payloads {
            let entry = inputs.first { $0.path == payload }
            XCTAssertNotNil(entry, "the record lists \(payload) as an input")
            XCTAssertNotNil(entry?.sha256, "\(payload) is recorded with its sha256")
        }
        let steps = mapped.record["steps"] as? [[String: Any]] ?? []
        let joins = steps.filter { $0["toolName"] as? String == SequenceInputConcatenation.toolName }
        XCTAssertEqual(joins.count, 1, "the join is one cat step")
        let join = try XCTUnwrap(joins.first)
        XCTAssertEqual(recordedFiles(join["inputs"]).map(\.path), payloads, "the cat step reads both payload files in order")
        let joinOutputs = recordedFiles(join["outputs"])
        XCTAssertEqual(joinOutputs.map(\.path), [joined], "the cat step writes the joined file alone")
        XCTAssertNotNil(joinOutputs.first?.sha256, "the joined file is recorded with its sha256")
        let mapper = try XCTUnwrap(steps.first { $0["toolName"] as? String == "minimap2" })
        XCTAssertTrue(recordedFiles(mapper["inputs"]).contains { $0.path == joined }, "the mapper step reads the joined file")
        for file in inputs + recordedFiles(join["inputs"]) + joinOutputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the record names \(file.path), which must exist after the run")
        }
    }

    /// MAP-POOLED-PAIRS science pin. Two paired bundles mapped pooled give the
    /// `samtools flagstat` counts of the two mapped alone, summed, for both forms
    /// of a paired bundle (one interleaved file, and an R1 and an R2 file) on
    /// every mapper. minimap2 and bowtie2 also mark all 16 reads properly paired.
    /// Before the lane a pool mapped every read single (0 paired in sequencing).
    func testPooledPairedBundlesGiveTheFlagstatOfTheBundlesMappedAlone() async throws {
        let interleaved = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts),
        ]
        let mateFiles = try [("mateA", "a", Fixture.bundleAStarts), ("mateB", "b", Fixture.bundleBStarts)].map { name, prefix, starts in
            try Fixture.writeMateFileBundle(
                named: name,
                interleaved: Fixture.interleavedFASTQ(prefix: prefix, starts: starts),
                in: imports,
                platform: .illumina
            ).bundle
        }
        let labels = ["in total", "mapped", "paired in sequencing", "properly paired", "with itself and mate mapped", "singletons"]
        for (form, bundles) in [("interleaved", interleaved), ("R1 and R2 files", mateFiles)] {
            for tool in [MappingTool.minimap2, .bowtie2, .bwaMem2, .bbmap] {
                let pooled = try await map(tool, bundles)
                let alone = [try await map(tool, [bundles[0]]), try await map(tool, [bundles[1]])]
                for label in labels {
                    XCTAssertEqual(
                        pooled.flagstat[label],
                        alone.reduce(0) { $0 + ($1.flagstat[label] ?? -1_000) },
                        "\(tool), \(form): \(label) pooled equals the two bundles mapped alone"
                    )
                }
                XCTAssertEqual(pooled.flagstat["paired in sequencing"], 16, "\(tool), \(form): every read keeps its mate")
                XCTAssertEqual(pooled.flagstat["with itself and mate mapped"], 16, "\(tool), \(form)")
                if tool == .minimap2 || tool == .bowtie2 {
                    XCTAssertEqual(pooled.flagstat["properly paired"], 16, "\(tool), \(form): every pair is proper")
                }
                print("MAP-FLAGSTAT \(tool.rawValue) | \(form) | pooled \(labels.map { "\($0)=\(pooled.flagstat[$0] ?? -1)" }.joined(separator: " "))"
                    + " | alone \(alone.map { a in labels.map { "\(a.flagstat[$0] ?? -1)" }.joined(separator: "/") }.joined(separator: " + "))")
            }
        }
    }

    // MARK: - Running a pooled mapping

    private struct MappedPool {
        let request: MappingRunRequest
        /// The flag of each primary record.
        let primaryFlags: [Int]
        /// The leftmost position of each primary record, sorted.
        let primaryPositions: [Int]
        /// The run's `mapping-provenance.json`.
        let record: [String: Any]
        /// The recorded mapper command line.
        let mapperArguments: [String]
        /// Each `inputFASTQPaths` entry of the record as an absolute path.
        let recordedInputPaths: [String]
        /// The template length (TLEN) of each primary record, as written.
        let primaryTemplateLengths: [Int]
        /// `samtools flagstat` of the BAM, the passing count by line label
        /// (`paired in sequencing`, `properly paired` and so on).
        let flagstat: [String: Int]
        /// The flagstat text, for the report.
        let flagstatText: String
    }

    /// The passing count of each `samtools flagstat` line, keyed by its label
    /// without the percentages, so `16 + 0 properly paired (100.00% : N/A)` gives
    /// `properly paired` 16.
    private static func flagstatCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 3)
            guard words.count == 4, words[1] == "+", let passed = Int(words[0]) else { continue }
            let label = words[3].split(separator: "(", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
            counts[label] = passed
        }
        return counts
    }

    private func bundle(_ name: String, prefix: String, starts: [Int], gzipped: Bool = false) throws -> URL {
        try Fixture.writeBundle(
            named: name,
            fastq: Fixture.interleavedFASTQ(prefix: prefix, starts: starts),
            in: imports,
            gzipped: gzipped
        )
    }

    private struct RecordedFile {
        let path: String
        let sha256: String?
    }

    /// The path and sha256 of each entry of a list of file records in the run's JSON,
    /// the path resolved so that `/var` and `/private/var` compare equal.
    private func recordedFiles(_ value: Any?) -> [RecordedFile] {
        (value as? [[String: Any]] ?? []).map { entry in
            RecordedFile(path: Self.canonical(entry["path"] as? String ?? ""), sha256: entry["sha256"] as? String)
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func map(_ tool: MappingTool, _ bundles: [URL]) async throws -> MappedPool {
        switch tool {
        case .minimap2: _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        case .bwaMem2: _ = try await ToolAvailability.require("bwa-mem2", environment: "bwa-mem2")
        case .bowtie2: _ = try await ToolAvailability.require("bowtie2", environment: "bowtie2")
        case .bbmap: _ = try await ToolAvailability.require("bbmap.sh", environment: "bbtools")
        }
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let outputDirectory = root.appendingPathComponent("out-\(tool.rawValue)-\(UUID().uuidString)", isDirectory: true)
        let request = MappingRunRequest(
            tool: tool,
            modeID: tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id,
            inputFASTQURLs: bundles,
            referenceFASTAURL: reference,
            outputDirectory: outputDirectory,
            sampleName: "pooled-\(bundles.count)-bundles",
            threads: 1
        )
        let resolved = try await MappingInputResolver.resolve(
            request: request,
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
        )
        let result = try await ManagedMappingPipeline().run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )

        let view = try ProcessRunner.run(samtools, ["view", result.bamURL.path], timeout: 30)
        XCTAssertEqual(view.status, 0, "samtools view: \(view.stderr)")
        let fields = view.stdout.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        let primary = fields.filter { (Int($0[1]) ?? 0) & 0x900 == 0 }
        let flagstat = try ProcessRunner.run(samtools, ["flagstat", result.bamURL.path], timeout: 30)
        XCTAssertEqual(flagstat.status, 0, "samtools flagstat: \(flagstat.stderr)")
        let recordURL = outputDirectory.appendingPathComponent(MappingProvenance.filename)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        let invocation = record["mapperInvocation"] as? [String: Any]
        let paths = (record["inputFASTQPaths"] as? [String] ?? []).map { path in
            path.hasPrefix("/") ? path : outputDirectory.appendingPathComponent(path).standardizedFileURL.path
        }
        return MappedPool(
            request: resolved.request,
            primaryFlags: primary.map { Int($0[1]) ?? -1 },
            primaryPositions: primary.map { Int($0[3]) ?? -1 }.sorted(),
            record: record,
            mapperArguments: invocation?["argv"] as? [String] ?? [],
            recordedInputPaths: paths,
            primaryTemplateLengths: primary.map { Int($0[8]) ?? 0 },
            flagstat: Self.flagstatCounts(flagstat.stdout),
            flagstatText: flagstat.stdout
        )
    }
}
