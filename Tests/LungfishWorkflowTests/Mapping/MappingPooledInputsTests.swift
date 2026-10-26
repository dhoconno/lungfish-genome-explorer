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
//
// Phase 3.0 lane MAP (MAP-POOLED-PAIRS, BIO-C2 Q2). Each pooled input is
// planned on its own. A pool of single-read inputs is the one file above. A
// pool of paired inputs keeps every input's pairs, as one interleaved file or
// as one pooled R1 and one pooled R2 file. A pool that mixes pairs and single
// reads, long and short reads, or interleaved and R1 and R2 inputs stops
// before anything is written, with words that name the inputs.

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

    /// Two bundles of single reads reach minimap2 as one query file that holds
    /// bundle A's bytes then bundle B's. minimap2 `-x sr` reads at most two
    /// query files and groups reads by equal name, so a pool of single reads
    /// arrives as one stream that `--frag=no` keeps from pairing.
    func testTwoPooledBundlesReachMinimap2AsOneQueryFile() async throws {
        let a = try singleBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try singleBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)

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

    /// MAP-POOLED-PAIRS. Two bundles that each hold an R1 and an R2 file pool
    /// into one R1 file (A's R1 then B's) and one R2 file (A's R2 then B's),
    /// bound as a pair, so record i of the pooled R1 is still the mate of
    /// record i of the pooled R2. Every mapper reads them as R1 and R2.
    func testTwoPooledBundlesOfR1AndR2FilesKeepTheirPairsInPooledR1AndR2Files() async throws {
        let a = try mateFileBundle("mateA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try mateFileBundle("mateB", prefix: "b", starts: Fixture.bundleBStarts)

        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            let resolved = try await resolve([a.bundle, b.bundle], tool: tool)
            let request = resolved.request

            XCTAssertEqual(request.inputFASTQURLs.count, 2, "\(tool): one pooled R1 file and one pooled R2 file")
            XCTAssertTrue(request.pairedEnd, "\(tool): the pooled files are bound as R1 and R2")
            XCTAssertEqual(request.inputLayout, .pairedFiles, "\(tool)")
            XCTAssertEqual(request.readLayoutPlan.handling, .asPairs, "\(tool): the record says pairs")
            let pooled = try XCTUnwrap(request.inputFASTQURLs.count == 2 ? request.inputFASTQURLs : nil)
            XCTAssertEqual(
                try ReadSetFixtures.readNames(in: pooled[0]),
                ["a1/1", "a2/1", "a3/1", "a4/1", "b1/1", "b2/1", "b3/1", "b4/1"],
                "\(tool): A's R1 records then B's"
            )
            XCTAssertEqual(
                try ReadSetFixtures.readNames(in: pooled[1]),
                ["a1/2", "a2/2", "a3/2", "a4/2", "b1/2", "b2/2", "b3/2", "b4/2"],
                "\(tool): A's R2 records then B's, in step with the R1 file"
            )
            XCTAssertEqual(request.originalInputFASTQURLs, [a.bundle.standardizedFileURL, b.bundle.standardizedFileURL])
            let arguments = try MappingCommandBuilder.buildCommand(for: request).arguments
            switch tool {
            case .minimap2, .bwaMem2:
                XCTAssertEqual(Array(arguments.suffix(2)), pooled.map(\.path), "\(tool) reads the two files as mates")
                XCTAssertFalse(arguments.contains("--frag=no"), "\(tool)")
                XCTAssertFalse(arguments.contains("-p"), "\(tool)")
            case .bowtie2:
                let r1 = try XCTUnwrap(arguments.firstIndex(of: "-1"))
                XCTAssertEqual(Array(arguments[r1...].prefix(4)), ["-1", pooled[0].path, "-2", pooled[1].path])
            case .bbmap:
                XCTAssertTrue(arguments.contains("in=\(pooled[0].path)"))
                XCTAssertTrue(arguments.contains("in2=\(pooled[1].path)"))
            }
        }
    }

    /// MAP-POOLED-PAIRS. Two interleaved bundles pool into one interleaved file,
    /// A's pairs then B's, and every mapper pairs it: minimap2 by adjacent names
    /// without `--frag=no`, bwa-mem2 with `-p`, bowtie2 with `--interleaved` and
    /// BBMap with `interleaved=t`. The record says interleaved pairs.
    func testPooledInterleavedBundlesKeepTheirPairsOnEveryMapper() async throws {
        let a = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try pairBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)
        for tool in [MappingTool.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            let resolved = try await resolve([a, b], tool: tool)
            let request = resolved.request

            XCTAssertEqual(request.inputLayout, .strictlyInterleaved, "\(tool): the record says interleaved pairs")
            XCTAssertEqual(request.readLayoutPlan.handling, .asPairs, "\(tool)")
            XCTAssertFalse(request.pairedEnd, "\(tool): one interleaved file")
            XCTAssertEqual(request.inputFASTQURLs.count, 1, "\(tool)")
            let joined = try XCTUnwrap(request.inputFASTQURLs.first)
            let expectedBytes = try Data(contentsOf: Fixture.fastqURL(in: a)) + Data(contentsOf: Fixture.fastqURL(in: b))
            XCTAssertEqual(try? Data(contentsOf: joined), expectedBytes, "\(tool): bundle A's pairs then bundle B's")
            XCTAssertEqual(request.originalInputFASTQURLs, [a.standardizedFileURL, b.standardizedFileURL])
            let arguments = try MappingCommandBuilder.buildCommand(for: request).arguments
            switch tool {
            case .minimap2:
                XCTAssertFalse(arguments.contains("--frag=no"), "minimap2 pairs adjacent mates of a pool of pairs")
            case .bwaMem2:
                XCTAssertTrue(arguments.contains("-p"), "bwa-mem2 pairs adjacent mates with -p")
            case .bowtie2:
                XCTAssertTrue(arguments.contains("--interleaved"))
            case .bbmap:
                XCTAssertTrue(arguments.contains("interleaved=t"))
            }
        }
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

    /// The record's `inputLayout` names what the argv makes each mapper do with
    /// a pool of single reads: one stream, with no flag that pairs records (BIO 4).
    func testPooledRecordLayoutMatchesTheMapperArgv() async throws {
        let a = try singleBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try singleBundle("poolB", prefix: "b", starts: Fixture.bundleBStarts)
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

    // MARK: - MAP-POOLED-PAIRS, the pools that stop

    /// A pool of an interleaved bundle and a single-read bundle cannot keep the
    /// pairs of one without pairing the reads of the other, and a bundle of
    /// pairs and single reads is both. Such a pool stops before anything is
    /// written, in either order and on every mapper, and the words name each
    /// bundle and say to map them apart. It used to map every read single.
    func testAPoolOfPairedAndSingleReadBundlesIsRefusedWithTheirNames() async throws {
        let interleaved = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let single = try singleBundle("poolS", prefix: "s", starts: Fixture.bundleBStarts)
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let pools = [[interleaved, single], [single, interleaved], [interleaved, fixtures.mixedRoot]]
        for (inputs, tool) in zip(pools, [MappingTool.bbmap, .minimap2, .bowtie2]) {
            let request = request(inputs, tool: tool)
            await assertRefused(request, naming: inputs.map(\.lastPathComponent), saying: "apart")
        }
    }

    /// An Oxford Nanopore or PacBio bundle pooled with a short-read bundle stops
    /// before anything is written, even when both hold single reads, and the
    /// words name the bundles by platform.
    func testAPoolOfLongAndShortReadBundlesIsRefusedWithTheirNames() async throws {
        let long = try Fixture.writeBundle(
            named: "nanopore",
            fastq: Fixture.singleReadsFASTQ(prefix: "n", starts: Fixture.bundleAStarts),
            in: imports,
            platform: .oxfordNanopore
        )
        let short = try Fixture.writeBundle(
            named: "illumina",
            fastq: Fixture.singleReadsFASTQ(prefix: "i", starts: Fixture.bundleBStarts),
            in: imports,
            platform: .illumina
        )
        for (inputs, tool) in [([long, short], MappingTool.minimap2), ([short, long], .bbmap)] {
            await assertRefused(request(inputs, tool: tool), naming: inputs.map(\.lastPathComponent), saying: "long reads")
        }
    }

    /// A pool of paired bundles keeps its pairs in one form, so an interleaved
    /// bundle and a bundle of R1 and R2 files stop with words that name both.
    func testAPoolOfInterleavedAndMateFileBundlesIsRefusedWithTheirNames() async throws {
        let interleaved = try pairBundle("poolA", prefix: "a", starts: Fixture.bundleAStarts)
        let mates = try mateFileBundle("mateB", prefix: "b", starts: Fixture.bundleBStarts)
        let inputs = [interleaved, mates.bundle]
        await assertRefused(request(inputs, tool: .minimap2), naming: inputs.map(\.lastPathComponent), saying: "interleaved")
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

    /// MAP-POOLED-PAIRS, BIO 6. A pool of bundles that each hold an R1 and an R2
    /// file is joined as two files, one pooled R1 and one pooled R2 in the same
    /// input order, and the record holds one `cat` step for each. The R1 step
    /// reads every bundle's R1 file and the R2 step every bundle's R2 file, each
    /// member with its sha256, so a pooled mate file traces back to the bundles
    /// that made it. Before this lane the same pool was one `cat` step that read
    /// all four files into one file of single reads.
    func testAPooledMateFileRunRecordsOneCatStepForEachPooledFile() async throws {
        let a = try mateFileBundle("mateA", prefix: "a", starts: Fixture.bundleAStarts)
        let b = try mateFileBundle("mateB", prefix: "b", starts: Fixture.bundleBStarts)

        let resolved = try await resolve([a.bundle, b.bundle], tool: .minimap2)
        let pooled = resolved.request.inputFASTQURLs
        XCTAssertEqual(pooled.count, 2, "one pooled R1 file and one pooled R2 file")
        let steps = try ManagedMappingPipeline().mappingInputMaterializationSteps(for: resolved.request)

        let joins = steps.filter { $0.toolName == SequenceInputConcatenation.toolName }
        XCTAssertEqual(joins.count, 2, "each pooled file is recorded as its own cat step")
        guard joins.count == 2, pooled.count == 2 else { return }
        for (index, label) in ["R1", "R2"].enumerated() {
            let join = joins[index]
            XCTAssertEqual(
                join.inputs.map(\.path),
                [a.files[index], b.files[index]].map { $0.standardizedFileURL.path },
                "the \(label) step reads bundle A's \(label) file then bundle B's"
            )
            XCTAssertTrue(join.inputs.allSatisfy { $0.sha256 != nil }, "every \(label) member is recorded with its sha256")
            XCTAssertEqual(
                join.outputs.map(\.path),
                [pooled[index].standardizedFileURL.path],
                "the \(label) step writes the pooled \(label) file"
            )
        }
    }

    /// BIO 2 and 6. A pool of virtual bundles had one `fastq materialize` step
    /// before the join, which says which bundle made which file. The record keeps
    /// that step, with both bundles as inputs and both materialized files as
    /// outputs, and then the `cat` step that reads those two files. Both bundles
    /// hold only pairs, so the pool keeps them (MAP-POOLED-PAIRS).
    func testPooledVirtualBundlesKeepOneMaterializationStepEach() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let virtual = [fixtures.subsetOfInterleaved, fixtures.subsetOfRepair]

        let resolved = try await MappingInputResolver.resolve(
            request: request(virtual, tool: .minimap2),
            materializer: fixtures.materializer
        )
        XCTAssertEqual(resolved.request.inputLayout, .strictlyInterleaved, "two virtual bundles of pairs keep their pairs")
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

    /// `ReadFileWriters.append` stops a cancelled task between chunks only when
    /// asked, so every other caller of the helper keeps its behavior (QA 1). A
    /// 5 MiB source holds two chunks of the helper's 4 MiB.
    func testAppendChecksCancellationBetweenChunksOnlyWhenAsked() async throws {
        let size = 5 * 1024 * 1024
        let source = root.appendingPathComponent("large.fastq")
        try Data(repeating: UInt8(ascii: "A"), count: size).write(to: source)
        let asked = root.appendingPathComponent("asked.fastq")
        let notAsked = root.appendingPathComponent("not-asked.fastq")

        let stopping = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try ReadFileWriters.publish(asked) { stage in
                try ReadFileWriters.append(source, to: stage, checkingCancellation: true)
            }
        }
        do {
            try await stopping.value
            XCTFail("a cancelled task must stop between chunks when asked")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: asked.path), "a stopped join publishes nothing")

        let ignoring = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try ReadFileWriters.publish(notAsked) { stage in
                try ReadFileWriters.append(source, to: stage, checkingCancellation: false)
            }
        }
        try await ignoring.value
        XCTAssertEqual(try Data(contentsOf: notAsked).count, size, "without the flag the helper writes every byte as before")
    }

    // MARK: - Helpers

    private func pairBundle(_ name: String, prefix: String, starts: [Int]) throws -> URL {
        try Fixture.writeBundle(named: name, fastq: Fixture.interleavedFASTQ(prefix: prefix, starts: starts), in: imports)
    }

    private func singleBundle(_ name: String, prefix: String, starts: [Int]) throws -> URL {
        try Fixture.writeBundle(named: name, fastq: Fixture.singleReadsFASTQ(prefix: prefix, starts: starts), in: imports)
    }

    /// A bundle of an R1 and an R2 file from an Illumina import.
    private func mateFileBundle(_ name: String, prefix: String, starts: [Int]) throws -> (bundle: URL, files: [URL]) {
        try Fixture.writeMateFileBundle(
            named: name,
            interleaved: Fixture.interleavedFASTQ(prefix: prefix, starts: starts),
            in: imports,
            platform: .illumina
        )
    }

    /// `request` stops with an input refusal whose words name every one of
    /// `names` and hold `phrase`, and the run's input folder is not written.
    private func assertRefused(
        _ request: MappingRunRequest,
        naming names: [String],
        saying phrase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let label = "\(request.tool) on \(names.joined(separator: ", "))"
        do {
            let resolved = try await MappingInputResolver.resolve(
                request: request,
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
            XCTFail("\(label): the pool must stop, it mapped \(resolved.request.inputLayout?.rawValue ?? "an unknown layout")", file: file, line: line)
        } catch {
            XCTAssertTrue(error is MappingInputResolverError, "\(label): an input refusal, got \(error)", file: file, line: line)
            let message = error.localizedDescription
            for name in names {
                XCTAssertTrue(message.contains(name), "\(label): the refusal names \(name): \(message)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(phrase), "\(label): the refusal says \(phrase): \(message)", file: file, line: line)
        }
        let folder = MappingResultLayoutService.inputMaterializationDirectory(in: request.outputDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "\(label): nothing is written", file: file, line: line)
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
