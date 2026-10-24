// MappingPooledInputsTests.swift - Pooled bundles reach every mapper as one stream of single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane MAPPOOL (obs-13, BIO-C2 fixes 1 to 3, SWIFT 4 and 5). The Map
// Reads window and `lungfish-cli map` pool several chosen inputs into one run
// without mate binding. Before this lane each mapper got one file per bundle,
// so BBMap read only the first, bwa-mem2 read two files as mates and minimap2
// refused three. The resolver now joins the execution files of an unbound pool
// into one FASTQ in the run's input folder, and the record and the argv both
// say single reads. The check C2 fixture is built in MappingPooledInputsFixture.
// The pairs of each bundle are lost in a pooled run and stay the Phase 3 row
// MAP-POOLED-PAIRS, so no test here claims that a pool keeps its pairs.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class MappingPooledInputsTests: XCTestCase {
    private typealias Fixture = MappingPooledInputsFixture

    private var root: URL!
    private var imports: URL!
    private var reference: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-pooled-inputs")
        imports = root.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        reference = try Fixture.writeReference(in: root)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fix 1, the join

    /// Two interleaved bundles reach minimap2 as one query file that holds
    /// bundle A's bytes then bundle B's. minimap2 `-x sr` reads at most two
    /// query files and groups reads by equal name, so a pool must arrive as one
    /// stream that `--frag=no` keeps from pairing. Nothing here claims that the
    /// two bundles' samples would pair, since with distinct names they do not.
    func testTwoPooledBundlesReachMinimap2AsOneQueryFile() async throws {
        let a = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try pairBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)

        let resolved = try await resolve([a, b], tool: .minimap2)
        let command = try MappingCommandBuilder.buildCommand(for: resolved.request)

        let queries = try queryFiles(in: command)
        XCTAssertEqual(queries.count, 1, "a pool reaches minimap2 as one query file, not one per bundle")
        let joined = URL(fileURLWithPath: try XCTUnwrap(queries.first)).standardizedFileURL
        let folder = MappingResultLayoutService.inputMaterializationDirectory(in: resolved.request.outputDirectory)
        XCTAssertEqual(joined.deletingLastPathComponent().path, folder.standardizedFileURL.path, "the join is written in the run's input folder")
        let expectedBytes = try Data(contentsOf: Fixture.fastqURL(in: a)) + Data(contentsOf: Fixture.fastqURL(in: b))
        XCTAssertEqual(try? Data(contentsOf: joined), expectedBytes, "bundle A's bytes then bundle B's")
        let members = resolved.sequenceInputs.inputs.flatMap(\.concatenatedFrom)
        XCTAssertEqual(members, [Fixture.fastqURL(in: a).standardizedFileURL, Fixture.fastqURL(in: b).standardizedFileURL])
        XCTAssertEqual(resolved.layoutResolution.reason, "2 input files are pooled as single reads.")
        XCTAssertEqual(resolved.request.inputLayout, .singleEnd)
        // The name cannot collide with the join of one bundle, and the sidecar records the step.
        XCTAssertTrue(joined.lastPathComponent.hasPrefix("pooled-"), joined.lastPathComponent)
        XCTAssertEqual(SequenceInputConcatenation.load(for: joined)?.memberURLs, members)
        // Every bundle the user chose stays in the lineage, not only the first.
        XCTAssertEqual(resolved.request.originalInputFASTQURLs, [a.standardizedFileURL, b.standardizedFileURL])
        // `--frag=no` follows `-x sr`, which ends minimap2's pairing of equal read names.
        let preset = try XCTUnwrap(command.arguments.firstIndex(of: "-x"))
        XCTAssertEqual(Array(command.arguments[(preset + 1)...].prefix(2)), ["sr", "--frag=no"])
    }

    /// A bundle that holds R1 and R2 files gives two execution files, so two
    /// such bundles pooled give four members and one query file.
    func testTwoPooledBundlesThatEachHoldR1AndR2FilesJoinAllFourMembers() async throws {
        let a = try Fixture.writeMateFileBundle(
            named: "mateA",
            interleaved: Fixture.interleavedFASTQ(prefix: "a", starts: Fixture.bundleAStarts),
            in: imports
        )
        let b = try Fixture.writeMateFileBundle(
            named: "mateB",
            interleaved: Fixture.interleavedFASTQ(prefix: "b", starts: Fixture.bundleBStarts),
            in: imports
        )

        let resolved = try await resolve([a.bundle, b.bundle], tool: .minimap2)
        let command = try MappingCommandBuilder.buildCommand(for: resolved.request)

        XCTAssertEqual(try queryFiles(in: command).count, 1, "four files of two bundles reach minimap2 as one query file")
        let members = resolved.sequenceInputs.inputs.flatMap(\.concatenatedFrom)
        XCTAssertEqual(members, (a.files + b.files).map(\.standardizedFileURL))
        XCTAssertEqual(resolved.layoutResolution.reason, "4 input files are pooled as single reads.")
    }

    /// Only a pooled short-read run gets `--frag=no`. The argv of a run on one
    /// single-end bundle and of a bound pair stays as it was.
    func testOnlyAPooledMinimap2RunGetsTheFragmentFlag() async throws {
        let solo = try Fixture.writeBundle(
            named: "solo",
            fastq: Fixture.singleReadsFASTQ(prefix: "s", starts: Fixture.bundleAStarts),
            in: imports
        )
        let single = try await resolve([solo], tool: .minimap2)
        let singleCommand = try MappingCommandBuilder.buildCommand(for: single.request)
        XCTAssertFalse(singleCommand.arguments.contains { $0.hasPrefix("--frag") }, "a single-end bundle keeps its argv")

        let bound = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [root.appendingPathComponent("s_R1.fastq"), root.appendingPathComponent("s_R2.fastq")],
            referenceFASTAURL: reference,
            outputDirectory: root.appendingPathComponent("out-bound", isDirectory: true),
            sampleName: "bound",
            pairedEnd: true,
            threads: 1
        )
        let boundCommand = try MappingCommandBuilder.buildCommand(for: bound)
        XCTAssertFalse(boundCommand.arguments.contains { $0.hasPrefix("--frag") }, "a bound pair keeps its argv")
    }

    // MARK: - Fix 3, BBMap refuses what it would drop

    /// BBMap takes one input or one bound pair. Several inputs that are neither
    /// a bound pair nor a read set used to build `in=` of the first input and
    /// drop the rest while the record listed them all (C2 section 6, 8 of 16).
    func testBBMapBuilderRefusesMoreThanOneUnboundInput() throws {
        let unbound = bbmapRequest(count: 2, pairedEnd: false)

        XCTAssertThrowsError(try MappingCommandBuilder.buildCommand(for: unbound)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("2"), "the refusal names the number of inputs: \(message)")
            XCTAssertTrue(message.contains("BBMap"), "the refusal names the mapper: \(message)")
        }
        XCTAssertThrowsError(try MappingCommandBuilder.buildCommand(for: bbmapRequest(count: 3, pairedEnd: true))) { error in
            XCTAssertTrue(error.localizedDescription.contains("3"), "three inputs are never a bound pair")
        }

        // A bound pair and one input still build, as before.
        let pair = try MappingCommandBuilder.buildCommand(for: bbmapRequest(count: 2, pairedEnd: true))
        XCTAssertTrue(pair.arguments.contains { $0.hasPrefix("in2=") })
        let single = try MappingCommandBuilder.buildCommand(for: bbmapRequest(count: 1, pairedEnd: false))
        XCTAssertTrue(single.arguments.contains("interleaved=f"))
    }

    // MARK: - The record and the argv agree

    /// The record's `inputLayout` names what the argv makes each mapper do: one
    /// stream of single reads, with no flag that pairs records (BIO 4).
    func testPooledRecordLayoutMatchesTheMapperArgv() async throws {
        let a = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try pairBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)
        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            let request = try await resolve([a, b], tool: tool).request
            XCTAssertEqual(request.inputLayout, .singleEnd, "\(tool): the record says single reads")
            XCTAssertEqual(request.readLayoutPlan.handling, .asSingle, "\(tool): the record says single reads")
            XCTAssertEqual(request.inputFASTQURLs.count, 1, "\(tool): the argv gets one stream")
            let arguments = try MappingCommandBuilder.buildCommand(for: request).arguments
            switch tool {
            case .minimap2:
                XCTAssertTrue(arguments.contains("--frag=no"), "minimap2 pairs adjacent equal names unless told not to")
            case .bwaMem2:
                XCTAssertFalse(arguments.contains("-p"), "bwa-mem2 -p pairs adjacent equal names")
            case .bowtie2:
                XCTAssertTrue(Set(["-1", "-2", "--interleaved"]).isDisjoint(with: arguments), "bowtie2 gets the stream as -U")
                let unpaired = try XCTUnwrap(arguments.firstIndex(of: "-U"))
                XCTAssertFalse(arguments[unpaired + 1].contains(","), "-U names one file")
            case .bbmap:
                XCTAssertTrue(arguments.contains("interleaved=f"))
                XCTAssertFalse(arguments.contains { $0.hasPrefix("in2=") })
            }
        }
    }

    /// A pool of one interleaved bundle and one single-end bundle never reaches
    /// BBMap as `interleaved=t`, which pairs a mixed file blindly by position
    /// (MappingTool+ReadLayout), whichever bundle comes first.
    func testMixedLayoutPoolNeverReachesBBMapAsInterleaved() async throws {
        let interleaved = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let single = try Fixture.writeBundle(
            named: "poolS",
            fastq: Fixture.singleReadsFASTQ(prefix: "s", starts: Fixture.bundleBStarts),
            in: imports
        )
        for inputs in [[interleaved, single], [single, interleaved]] {
            let resolved = try await resolve(inputs, tool: .bbmap)
            let arguments = try MappingCommandBuilder.buildCommand(for: resolved.request).arguments
            XCTAssertFalse(arguments.contains("interleaved=t"), "\(inputs.map(\.lastPathComponent))")
            XCTAssertTrue(arguments.contains("interleaved=f"), "\(inputs.map(\.lastPathComponent))")
            XCTAssertEqual(resolved.request.inputLayout, .singleEnd)
        }
    }

    // MARK: - SWIFT 4 and 5, the join in the run's scratch

    /// A member that ends without a line break gets one, so its last record and
    /// the first record of the next bundle stay apart in the joined file.
    func testAPooledJoinKeepsTheLastRecordOfAMemberApartFromTheNextOne() async throws {
        var text = Fixture.interleavedFASTQ(prefix: "a", starts: Fixture.bundleAStarts)
        text.removeLast()
        let a = try Fixture.writeBundle(named: "poolA", fastq: text, in: imports)
        let b = try pairBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)

        let resolved = try await resolve([a, b], tool: .minimap2)

        XCTAssertEqual(resolved.request.inputFASTQURLs.count, 1)
        let joined = try XCTUnwrap(resolved.request.inputFASTQURLs.first)
        let expected = ["a", "b"].flatMap { prefix in (1...4).flatMap { ["\(prefix)\($0)/1", "\(prefix)\($0)/2"] } }
        XCTAssertEqual(try ReadSetFixtures.readNames(in: joined), expected)
    }

    /// A cancelled join stops between chunks and throws, and it leaves neither
    /// the joined file nor its sidecar nor a folder it created, while a folder
    /// that was there before keeps what it held. (SWIFT 4, removed on cancel.)
    /// The join is called directly, since an earlier step of the resolution
    /// already throws on a cancelled task and would hide the join's own check.
    func testAPooledJoinThatIsCancelledLeavesNoFileBehind() async throws {
        let a = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try pairBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)
        let resolved = try await ResolvedSequenceInputs.resolve(
            inputURLs: [a, b],
            materializationDirectory: root.appendingPathComponent("unused/.lungfish-map-inputs", isDirectory: true),
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
            concatenateUnpairedFiles: true
        )
        let created = root.appendingPathComponent("created/.lungfish-map-inputs", isDirectory: true)
        let existing = root.appendingPathComponent("existing/.lungfish-map-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "kept".write(to: existing.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        for folder in [created, existing] {
            let task = Task { () throws -> ResolvedSequenceInputs in
                withUnsafeCurrentTask { $0?.cancel() }
                return try MappingPooledInputs.join(resolved, into: folder)
            }
            do {
                _ = try await task.value
                XCTFail("a cancelled join must throw")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path), "a folder the join created is removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["keep.txt"], "no joined file or sidecar remains")
    }

    /// Members of both kinds cannot be one stream, so the join stops before it
    /// writes anything.
    func testAPoolOfCompressedAndPlainFilesIsRefusedBeforeAnythingIsWritten() throws {
        let compressed = root.appendingPathComponent("a.fastq.gz")
        let plain = root.appendingPathComponent("b.fastq")
        let resolved = ResolvedSequenceInputs(
            inputs: [
                .init(originalURL: compressed, executionURLs: [compressed], wasMaterialized: false),
                .init(originalURL: plain, executionURLs: [plain], wasMaterialized: false),
            ],
            materializationStartedAt: nil,
            materializationEndedAt: nil
        )
        let folder = root.appendingPathComponent("refused/.lungfish-map-inputs", isDirectory: true)

        XCTAssertThrowsError(try MappingPooledInputs.join(resolved, into: folder)) { error in
            XCTAssertEqual(
                error as? MappingPooledInputsError,
                .mixedCompression(compressed: ["a.fastq.gz"], uncompressed: ["b.fastq"])
            )
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("a.fastq.gz"), "the refusal names the compressed input: \(message)")
            XCTAssertTrue(message.contains("b.fastq"), "the refusal names the uncompressed input: \(message)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// The join is a recorded `cat` step. Its inputs are the members in input
    /// order and its only output is the joined file, so the record shows how the
    /// one file the mapper read was made (ARCH 5).
    func testAPooledRunRecordsTheJoinAsOneCatStepWithEveryMember() async throws {
        let a = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try pairBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)

        let resolved = try await resolve([a, b], tool: .minimap2)
        let steps = try ManagedMappingPipeline().mappingInputMaterializationSteps(for: resolved.request)

        let joins = steps.filter { $0.toolName == SequenceInputConcatenation.toolName }
        XCTAssertEqual(joins.count, 1, "a pool is recorded as one cat step")
        let join = try XCTUnwrap(joins.first)
        XCTAssertEqual(join.inputs.map(\.path), [Fixture.fastqURL(in: a), Fixture.fastqURL(in: b)].map { $0.standardizedFileURL.path })
        XCTAssertTrue(join.inputs.allSatisfy { $0.sha256 != nil }, "every member is recorded with its sha256")
        XCTAssertEqual(join.outputs.map(\.path), [resolved.request.inputFASTQURLs[0].standardizedFileURL.path])
    }

    /// BIO 2 and 6. A pool of virtual bundles had one `fastq materialize` step
    /// before the join, which says which bundle made which file. The record keeps
    /// that step, with both bundles as inputs and both materialized files as
    /// outputs, and then the `cat` step that reads those two files.
    func testPooledVirtualBundlesKeepOneMaterializationStepEach() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let virtual = [fixtures.subsetOfSingle, fixtures.subsetOfInterleaved]

        let resolved = try await MappingInputResolver.resolve(
            request: request(virtual, tool: .minimap2),
            materializer: fixtures.materializer
        )
        let members = resolved.sequenceInputs.inputs.flatMap(\.concatenatedFrom).map { $0.standardizedFileURL.path }
        XCTAssertEqual(members.count, 2, "the pool joins the two materialized files")
        let steps = try ManagedMappingPipeline().mappingInputMaterializationSteps(for: resolved.request)

        let materializations = steps.filter { $0.toolName == CLISequenceInputMaterialization.materializationToolName }
        XCTAssertEqual(materializations.count, 1, "one materialization step covers the two virtual bundles")
        let materialization = try XCTUnwrap(materializations.first)
        for bundle in virtual {
            XCTAssertTrue(
                materialization.inputs.contains { $0.path == bundle.standardizedFileURL.path },
                "the materialization step names \(bundle.lastPathComponent) as an input"
            )
        }
        XCTAssertEqual(materialization.outputs.map(\.path), members, "the materialization step writes both members")
        let joins = steps.filter { $0.toolName == SequenceInputConcatenation.toolName }
        XCTAssertEqual(joins.count, 1, "the join is one cat step")
        XCTAssertEqual(joins.first?.inputs.map(\.path), members, "the cat step reads the files the materialization wrote")
    }

    // MARK: - Helpers

    private func pairBundle(_ name: String, prefix: String, starts: [Int]) throws -> URL {
        try Fixture.writeBundle(named: name, fastq: Fixture.interleavedFASTQ(prefix: prefix, starts: starts), in: imports)
    }

    private func resolve(_ inputs: [URL], tool: MappingTool) async throws -> MappingResolvedInputs {
        try await MappingInputResolver.resolve(
            request: request(inputs, tool: tool),
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
        )
    }

    private func request(_ inputs: [URL], tool: MappingTool) -> MappingRunRequest {
        MappingRunRequest(
            tool: tool,
            modeID: tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id,
            inputFASTQURLs: inputs,
            referenceFASTAURL: reference,
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            sampleName: "pooled",
            threads: 1
        )
    }

    private func bbmapRequest(count: Int, pairedEnd: Bool) -> MappingRunRequest {
        MappingRunRequest(
            tool: .bbmap,
            modeID: MappingMode.bbmapStandard.id,
            inputFASTQURLs: (1...count).map { root.appendingPathComponent("in\($0).fastq") },
            referenceFASTAURL: reference,
            outputDirectory: root.appendingPathComponent("out-bbmap", isDirectory: true),
            sampleName: "pooled",
            pairedEnd: pairedEnd,
            threads: 1
        )
    }

    /// The query files that follow the reference in a minimap2 argv.
    private func queryFiles(in command: ManagedMappingCommand) throws -> [String] {
        let index = try XCTUnwrap(command.arguments.firstIndex(of: reference.path))
        return Array(command.arguments[(index + 1)...])
    }
}
