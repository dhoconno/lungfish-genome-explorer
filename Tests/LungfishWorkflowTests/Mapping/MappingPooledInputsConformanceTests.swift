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
// bundles when the names coincided while the record said single reads. A
// pooled run maps every read as a single read, so the expectations below hold
// the read total, the absence of any mate flag and the record to the run. The
// pairs inside a bundle are lost in a pool and stay the Phase 3 row
// MAP-POOLED-PAIRS, so no test here expects a proper pair.

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
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 0, "\(tool): no read is flagged paired")
            XCTAssertEqual(mapped.record["inputLayout"] as? String, "single_end", "\(tool)")
            XCTAssertEqual(mapped.record["readLayoutHandling"] as? String, "as_single", "\(tool)")
        }
    }

    /// Bundle B renamed to bundle A's read names (C2 row C). minimap2 grouped the
    /// reads of both bundles into fragments of four segments (flags 65, 33, 49,
    /// 145) while the record said single reads. No record may have a mate now.
    func testPooledBundlesWithEqualReadNamesNeverPairAcrossBundles() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "a", starts: Fixture.bundleBStarts),
        ]
        for tool in [MappingTool.minimap2, .bwaMem2] {
            let mapped = try await map(tool, bundles)

            XCTAssertEqual(mapped.primaryFlags.count, 16, "\(tool) maps every read of both bundles")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 0, "\(tool): no read has a mate in the other bundle")
            XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBStarts), "\(tool)")
        }
    }

    /// Every mapper maps the two pooled bundles as 16 single reads, and the
    /// record names the files the mapper read (BIO 6). minimap2 and bowtie2 were
    /// already right with distinct names, so for them this is a guard that the
    /// join changes no record.
    func testPooledInterleavedBundlesMapAsSingleReadsOnEveryMapper() async throws {
        let bundles = [
            try bundle("poolA", prefix: "a", starts: Fixture.bundleAStarts),
            try bundle("poolB", prefix: "b", starts: Fixture.bundleBStarts),
        ]
        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            let mapped = try await map(tool, bundles)

            XCTAssertEqual(mapped.primaryFlags.count, 16, "\(tool) maps every read of both bundles")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x1 != 0 }.count, 0, "\(tool): every read maps as a single read")
            XCTAssertEqual(mapped.primaryFlags.filter { $0 & 0x10 != 0 }.count, 8, "\(tool): the R2 reads map on the reverse strand")
            XCTAssertEqual(mapped.primaryPositions, Fixture.expectedPositions(Fixture.bundleAStarts, Fixture.bundleBStarts), "\(tool)")
            XCTAssertEqual(mapped.record["inputLayout"] as? String, "single_end", "\(tool)")
            XCTAssertEqual(mapped.record["readLayoutHandling"] as? String, "as_single", "\(tool)")
            for path in mapped.recordedInputPaths {
                XCTAssertTrue(mapped.mapperArguments.contains { $0.contains(path) }, "\(tool): \(path) is in the recorded argv")
            }
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
    }

    private func bundle(_ name: String, prefix: String, starts: [Int]) throws -> URL {
        try Fixture.writeBundle(named: name, fastq: Fixture.interleavedFASTQ(prefix: prefix, starts: starts), in: imports)
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
            threads: 2
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

        let view = try ProcessRunner.run(samtools, ["view", result.bamURL.path], timeout: 120)
        XCTAssertEqual(view.status, 0, "samtools view: \(view.stderr)")
        let fields = view.stdout.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        let primary = fields.filter { (Int($0[1]) ?? 0) & 0x900 == 0 }
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
            recordedInputPaths: paths
        )
    }
}
