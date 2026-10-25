// ExecutorRunAdoptionRecipeTests.swift - The adopted sidecar of a recipe run: classification, switched-off step, counts, platform (CHTC C4 lane A, AMV1 fix F2-2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// The fixes of `888bd9b27` (the adopt's steps, platform and read layout) and the logical step counts of `85440048b`,
/// each pinned through `ExecutorRunAdoption.adopt` and the sidecar it saves, on a plan of the builtin recipe
/// `vsp2-target-enrichment` with the rRNA switch off as the VSP2 parity case has it. The returned folder is built here
/// because the shared builder (`ExecutorReturnedFolder.make`) plans no recipe.
final class ExecutorRunAdoptionRecipeTests: XCTestCase {
    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
    }

    /// A returned folder of the recipe's plan with a record true to it, and the adopted bundle's sidecar.
    private struct Adopted {
        var plan: ExecutionPlan
        var record: ExecutorRunRecord
        var sidecar: PersistedFASTQMetadata
        var bundle: URL

        var envelope: ProvenanceEnvelope {
            get throws {
                try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(
                    fromSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
                ))
            }
        }

        /// The names of the report copies the bundle holds.
        var reportCopies: [String] {
            get throws {
                try FileManager.default.contentsOfDirectory(
                    atPath: bundle.appendingPathComponent("metadata/recipe-step-artifacts").path
                ).sorted()
            }
        }
    }

    /// Counts the fixture's record gives a recipe step by id: input and output reads.
    private typealias Counts = [String: (input: Int64, output: Int64)]

    private func repositoryRecipeFile() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Recipes/illumina-paired-cleanup.recipe.json")
    }

    private func json<T: Encodable>(_ value: T?) throws -> String {
        guard let value else { return "nil" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Emits the plan of `S` with the VSP2 recipe, writes the folder with a payload and a succeeded record, adopts it
    /// into a project of its own and returns the plan, the record and the saved sidecar. `layout` is the mixed layout the
    /// node counted at its `interleave` step, `counts` the reads the record gives named recipe steps, and `platform` the
    /// platform the plan's sample states. With `files`, each recipe step's record lists every file its plan step writes,
    /// which the folder holds, so the reports reach the bundle, and the storage step holds the writer's launch with the
    /// payload as its output, as the node records them. `sample` names the sample and `project` takes a shared project. With
    /// `peaks`, the record gives the first recipe step 4_690_345_984 peak resident bytes, the storage writer's launch
    /// 2_147_483_648 (it exists only with `files`) and the statistics step 1_073_741_824.
    private func adopt(
        layout: (merged: Int, pairs: Int, unpaired: Int)? = nil, counts: Counts = [:], platform: String? = nil,
        files: Bool = false, peaks: Bool = false, sample: String = "S", project shared: URL? = nil
    ) async throws -> Adopted {
        let root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionRecipe")
        scratch.append(root)
        let pair = try ExecutorPlanTestSupport.writePair(root: root, sample)

        let databaseFolder = root.appendingPathComponent("databases/test-panhuman", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseFolder, withIntermediateDirectories: true)
        let index = databaseFolder.appendingPathComponent("panhuman-1.k31w15.idx")
        try Data("deacon index test-panhuman".utf8).write(to: index)
        let database = try await RecipeDatabaseIdentity().record(databaseID: "test-panhuman", at: index)
        var recipe = try XCTUnwrap(RecipeResolver.resolve(
            "vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes(),
            switchOptions: ["removeDuplicates": true, "removeRibosomalRNA": false]
        ))
        for position in recipe.steps.indices where recipe.steps[position].type == "deacon-scrub" {
            recipe.steps[position].params?["database"] = .string("test-panhuman")
        }
        var request = try ExecutorPlanTestSupport.request(root: root, sample, inputs: pair, clumping: .bbtools, recipe: recipe)
        request.recipeFile = try ExecutorPlanSourceFile.measuring(repositoryRecipeFile())
        request.databases = ["test-panhuman": ExecutorPlanDatabaseFile(record: database)]
        if let platform { request.sample.platform = platform }
        let emission = try ExecutorPlanEmitter.emission(request, host: ExecutorPlanTestSupport.mac24)
        let folder = root.appendingPathComponent("returned", isDirectory: true)
        let planFile = try ExecutorPlanFolderWriter.write(emission, into: folder)
        let planBytes = try Data(contentsOf: planFile)

        let payloadBytes = Data("@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n".utf8)
        let payloadURL = folder.appendingPathComponent(ExecutorPlanEmitter.payloadPath)
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payloadBytes.write(to: payloadURL)
        let payload = ExecutorFileDigest(
            relativePath: ExecutorPlanEmitter.payloadPath, sha256: PortableDigest.sha256Hex(of: payloadBytes), size: Int64(payloadBytes.count)
        )
        let plan = emission.plan
        let time = "2026-10-24T12:00:00.000Z"
        let steps = try plan.steps.map { step -> ExecutorStepRecord in
            var details: ExecutorStorageDetails?
            if step.kind == .storage || step.kind == .interleave {
                details = ExecutorStorageDetails(
                    clumpingRan: step.kind == .storage && plan.clumping.resolved == .bbtools, qualityBinning: plan.storage.qualityBinning,
                    inputBytes: 200, outputBytes: payload.size
                )
                if step.kind == .interleave, let layout {
                    details?.mixedLayout = .init(mergedReads: layout.merged, pairs: layout.pairs, unpairedReads: layout.unpaired)
                }
            }
            var recorded = ExecutorStepRecord(
                id: step.id, kind: step.kind,
                tool: step.tool.map { ExecutorToolRecord(id: $0.id, version: $0.version, build: $0.build, path: "/opt/conda/bin/\($0.id)") },
                outcome: .succeeded, argv: step.arguments, environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30,
                deadlineSeconds: step.deadlineSeconds, toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 1,
                qualityCounts: step.kind == .qualityCount
                    ? ExecutorQualityCounts(baseCount: 20, q20Count: 20, q30Count: 20, recordCount: 2, file: payload) : nil,
                storage: details
            )
            if step.kind == .statistics {
                recorded.standardOutput = ExecutorReturnedFolder.seqkitOutput
                recorded.inputFile = payload
                if peaks { recorded.peakResidentBytes = 1_073_741_824 }
            }
            if peaks, step.id == plan.steps.first(where: { $0.kind == .recipe })?.id { recorded.peakResidentBytes = 4_690_345_984 }
            if files, step.kind == .recipe {
                recorded.outputs = try step.outputs.map { path in
                    let bytes = Data("\(step.id) \(path)\n".utf8)
                    let url = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url)
                    return .init(path: path, bytes: UInt64(bytes.count), sha256: PortableDigest.sha256Hex(of: bytes))
                }
            }
            if files, step.kind == .storage {
                let bgzip = "/opt/conda/envs/bbtools/bin/bgzip"
                var writer = ExecutorStorageLaunch(
                    tool: ExecutorToolRecord(id: "bgzip", version: "1.24", build: "h1", path: bgzip),
                    argv: [bgzip, "-@", "1", "-c", "work/combined.fastq"], environmentNames: ["PATH"], outcome: .succeeded,
                    toolExitCode: 0, wallSeconds: 1, stderrPath: "work/bgzip.stderr"
                )
                writer.inputs = [ExecutorFileDigest(relativePath: "work/combined.fastq", sha256: String(repeating: "c", count: 64), size: 9)]
                writer.outputs = [payload]
                if peaks { writer.peakResidentBytes = 2_147_483_648 }
                recorded.storage?.launches = [writer]
                recorded.outputs = [.init(path: payload.relativePath, bytes: UInt64(payload.size), sha256: payload.sha256)]
            }
            if let seen = counts[step.id] {
                recorded.inputReadCount = seen.input
                recorded.outputReadCount = seen.output
            }
            return recorded
        }
        let record = ExecutorRunRecord(
            outcome: .succeeded, executorArguments: ["run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: ExecutorPlanTestSupport.digest, size: 17, buildPin: plan.executor),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)),
            recipe: plan.recipe,
            imageManifest: ExecutorImageManifestRecord(sha256: plan.imageManifest.sha256, size: plan.imageManifest.size, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2, observedLimits: [],
                subreaper: ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "0", getterResult: 0, getterValue: 1),
                orphanSweep: .subreaper
            ),
            siteFacts: [], inputs: plan.entries.filter { $0.role != .executor },
            payloads: [ExecutorPayloadRecord(
                relativePath: payload.relativePath, sha256: payload.sha256, size: payload.size, recordCount: 2, recordCountFile: payload
            )],
            steps: steps, startedAt: time, endedAt: time, wallSeconds: 3
        )
        try record.encoded().write(to: folder.appendingPathComponent(ExecutorRunRecord.fileName))

        let project = shared ?? root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = try await ExecutorRunAdoption.adopt(resultFolder: folder, projectDirectory: project)
        let sidecar = try XCTUnwrap(FASTQMetadataStore.load(for: bundle.appendingPathComponent("\(sample).fastq.gz")))
        return Adopted(plan: plan, record: record, sidecar: sidecar, bundle: bundle)
    }

    /// Vote C4-4 D-3 (option 2; UX U4-4, CHTC CH-5, BIO B-D3-2): each report copy in the adopted bundle takes the sample's
    /// name in place of the plan's work stem, as an import's copy does, so two samples adopted into one project hold copies
    /// whose names differ. The step's argv keeps the node's `work/sample_...` name, each rewrite is keyed by that name and
    /// points at a copy the bundle holds, and the envelope's outputs name those copies.
    func testAdoptedReportCopiesNameTheSample() async throws {
        let project = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionRecipeProject")
        scratch.append(project)
        let work = ExecutorPlanEmitter.workStem
        var copies: [String: Set<String>] = [:]
        for sample in ["S", "T"] {
            let adopted = try await adopt(files: true, sample: sample, project: project)
            let names = try adopted.reportCopies
            XCTAssertFalse(names.isEmpty, "the bundle holds the recipe's reports")
            let results = try XCTUnwrap(adopted.sidecar.ingestion?.recipeApplied?.stepResults)
            let rewrites = results.flatMap { result in result.auxiliaryCommandPathRewrites.map { (result, $0.key, $0.value) } }
            XCTAssertEqual(rewrites.count, names.count, "one rewrite for each copy")
            XCTAssertEqual(
                Set(rewrites.map { URL(fileURLWithPath: $0.2).lastPathComponent }), Set(names), "the rewrites reach every copy the bundle holds"
            )
            for (result, key, value) in rewrites {
                XCTAssertTrue(key.hasPrefix("work/\(work)_"), "the rewrite is keyed by the node's path: \(key)")
                XCTAssertEqual(result.commandArguments?.contains(key), true, "the argv keeps the node's name \(key)")
                // A copy's name ends with the work file's name, the sample's name standing where the work stem led.
                let renamed = sample + String(URL(fileURLWithPath: key).lastPathComponent.dropFirst(work.count))
                XCTAssertTrue(
                    URL(fileURLWithPath: value).lastPathComponent.hasSuffix("-" + renamed), "\(value) names the sample \(sample), not the work stem"
                )
            }
            let recorded = try adopted.envelope.steps.flatMap(\.outputs).map(\.path)
                .filter { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent == "recipe-step-artifacts" }
            XCTAssertEqual(Set(recorded.map { URL(fileURLWithPath: $0).lastPathComponent }), Set(names), "the envelope names each copy")
            copies[sample] = Set(names)
        }
        XCTAssertEqual(copies["S"]?.isDisjoint(with: copies["T"] ?? []), true, "two samples' copies never share a name")
    }

    /// Vote C4-4 D-5 (option 2; ARCH A-D5-1 and A-D5-3, BIO B-D5-1 and B-D5-2, UX U4-3 and U4-7, CHTC CH-4 and CH-7): the
    /// storage writer and the statistics step keep the node's `out/<payload>` in their argv, and their replay argv, command
    /// and the writer's output name the published payload, the run's own output. The statistics step lists that payload as
    /// its input, so the envelope lists the payload once as an output and once as an input, as the Mac's does.
    func testAdoptedPayloadStepsNameThePublishedPayload() async throws {
        let adopted = try await adopt(files: true)
        let envelope = try adopted.envelope
        let node = ExecutorPlanEmitter.payloadPath
        let digest = try XCTUnwrap(adopted.record.payloads.first?.sha256)
        let payloadOutputs = envelope.outputs.filter { $0.checksumSHA256 == digest }
        XCTAssertEqual(payloadOutputs.count, 1, "the envelope's outputs hold the payload once: \(payloadOutputs.map(\.path))")
        let published = try XCTUnwrap(payloadOutputs.first?.path)
        XCTAssertTrue(published.hasSuffix("Imports/S.lungfishfastq/S.fastq.gz"), published)
        XCTAssertEqual(envelope.files.filter { $0.checksumSHA256 == digest }.map(\.role.rawValue).sorted(), ["input", "output"])
        XCTAssertFalse(envelope.files.contains { $0.path == node }, "no file entry keeps the node's payload path")

        let writer = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "bgzip" && $0.argv.dropLast().last == ">" }, "the storage writer"
        )
        XCTAssertEqual(writer.argv.last, node, "the argv stays as the node ran it")
        XCTAssertEqual(writer.durableReplayArgv?.last, published)
        XCTAssertTrue(writer.reproducibleCommand.hasSuffix(published), writer.reproducibleCommand)
        XCTAssertEqual(writer.outputs.map(\.path), [published])
        XCTAssertEqual(writer.outputs.map(\.checksumSHA256), [digest])

        let statistics = try XCTUnwrap(envelope.steps.first { $0.argv.first == "stats" }, "the statistics step")
        XCTAssertTrue(statistics.argv.contains(node), "the argv stays as the node ran it: \(statistics.argv)")
        XCTAssertEqual(statistics.durableReplayArgv?.contains(node), false)
        XCTAssertEqual(statistics.durableReplayArgv?.contains(published), true, "\(statistics.durableReplayArgv ?? [])")
        XCTAssertTrue(statistics.reproducibleCommand.contains(published), statistics.reproducibleCommand)
        XCTAssertEqual(statistics.inputs.map(\.path), [published])
        XCTAssertEqual(statistics.inputs.map(\.checksumSHA256), [digest])
    }

    /// Vote C4-4 D-1 (option 2; QA Q4-2, ARCH A-D1-1): the adopted record writes the node's peak resident bytes as the step's
    /// `peakMemoryBytes` for a recipe step, for the storage writer's launch and for the statistics step alike, so the adopted
    /// envelope is the one record that writes a peak memory. Without this test only the 345 s real-tool parity run notices the
    /// loss of the key.
    func testAdoptedStepsCarryTheRecordsPeakResidentBytes() async throws {
        let adopted = try await adopt(files: true, peaks: true)
        let envelope = try adopted.envelope
        let recipe = try XCTUnwrap(envelope.steps.first { $0.toolName == "fastp" }, "the first recipe step")
        XCTAssertEqual(recipe.peakMemoryBytes, 4_690_345_984)
        let writer = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "bgzip" && $0.argv.dropLast().last == ">" }, "the storage writer"
        )
        XCTAssertEqual(writer.peakMemoryBytes, 2_147_483_648)
        let statistics = try XCTUnwrap(envelope.steps.first { $0.argv.first == "stats" }, "the statistics step")
        XCTAssertEqual(statistics.peakMemoryBytes, 1_073_741_824)
    }

    /// The result whose command is the argv the record gives step `id`.
    private func result(_ id: String, in adopted: Adopted) throws -> RecipeStepResult {
        let argv = try XCTUnwrap(adopted.record.steps.first { $0.id == id }?.argv, id)
        let results = try XCTUnwrap(adopted.sidecar.ingestion?.recipeApplied?.stepResults)
        return try XCTUnwrap(results.first { $0.commandArguments == argv }, "no result runs \(id)")
    }

    /// BIO fix 1 and QA fix 2: the interleave step's layout becomes the sidecar's read classification and the recorded
    /// pairing, as the Mac's functions give them; with no layout the sidecar holds no classification and the import's own
    /// pairing.
    func testAdoptWritesReadClassificationFromInterleaveLayout() async throws {
        let mixed = try await adopt(layout: (merged: 7, pairs: 3, unpaired: 0))
        let expected = FASTQBatchImporter.readClassification(
            forMixedLayout: RecipeMixedLayoutCounts(mergedReads: 7, pairs: 3, unpairedReads: 0), bundleFASTQName: "S.fastq.gz"
        )
        XCTAssertNotNil(expected, "the Mac classifies a mixed file of 7 merged reads and 3 pairs")
        XCTAssertNotNil(mixed.sidecar.readClassification)
        XCTAssertEqual(try json(mixed.sidecar.readClassification), try json(expected))
        XCTAssertEqual(mixed.sidecar.ingestion?.pairingMode, .singleEnd)
        XCTAssertEqual(mixed.sidecar.ingestion?.pairingSource, .detected)

        let plain = try await adopt(layout: nil)
        XCTAssertNil(plain.sidecar.readClassification, "a run with no layout states no classification")
        XCTAssertEqual(plain.sidecar.ingestion?.pairingMode, .interleaved)
        XCTAssertEqual(plain.sidecar.ingestion?.pairingSource, .explicit)
    }

    /// BIO fix 1 and QA fix 2: a recipe step a switch turned off stays in the sidecar where the Mac lists it, with `tool`
    /// `none` and the switch that turned it off, and the list holds the recorded steps, that one and the storage result.
    func testAdoptKeepsSwitchedOffRRNAStep() async throws {
        let adopted = try await adopt()
        let results = try XCTUnwrap(adopted.sidecar.ingestion?.recipeApplied?.stepResults)
        let recorded = adopted.record.steps.filter { $0.kind == .recipe }.count
        XCTAssertEqual(results.count, recorded + 2, "the recorded recipe steps, the turned-off one and storage: \(results.map(\.tool))")
        let off = results.filter { $0.tool == "none" }
        XCTAssertEqual(off.count, 1)
        let step = try XCTUnwrap(off.first)
        let by = try XCTUnwrap(step.turnedOffBy)
        XCTAssertEqual(by.id, "removeRibosomalRNA")
        XCTAssertEqual(by.source, .option)
        XCTAssertEqual(by.value, false)
        XCTAssertNil(step.inputReadCount)
        XCTAssertNil(step.outputReadCount)
        let at = try XCTUnwrap(results.firstIndex { $0.tool == "none" })
        XCTAssertEqual(results[at - 1].tool, "deacon", "the turned-off step sits after the human-read scrub")
    }

    /// QA fix 2: the Mac's "Compute statistics" result never reaches its sidecar, so the adopt writes none, though the
    /// record holds the statistics step.
    func testAdoptWritesNoStatisticsResult() async throws {
        let adopted = try await adopt()
        XCTAssertTrue(adopted.record.steps.contains { $0.kind == .statistics }, "the record holds the statistics step")
        let results = try XCTUnwrap(adopted.sidecar.ingestion?.recipeApplied?.stepResults)
        XCTAssertEqual(results.filter { $0.stepName == "Compute statistics" }.count, 0, "\(results.map(\.stepName))")
        XCTAssertFalse(results.contains { $0.tool == "seqkit" && $0.commandArguments?.contains(where: { argument in argument == "stats" }) == true })
    }

    /// QA fix 2 (888bd9b27): the adopt takes the platform as the Mac decides it for the sample, from the plan's request and
    /// the plan's inputs. A plan that states `illumina` gives that platform and an assignment that says it was given; a
    /// plan that states none gives the Mac's automatic decision, an assignment that was not given.
    func testAdoptTakesPlatformFromPlanRequest() async throws {
        let given = try await adopt(platform: "illumina")
        XCTAssertEqual(given.sidecar.sequencingPlatform, .illumina)
        let assignment = try XCTUnwrap(given.sidecar.platformAssignment, "the adopt writes the Mac's platform assignment")
        XCTAssertEqual(assignment.platform, .illumina)
        XCTAssertEqual(assignment.source, .given)

        let automatic = try await adopt(platform: nil)
        let decided = try XCTUnwrap(automatic.sidecar.platformAssignment, "an empty platform is decided as the Mac decides it")
        XCTAssertNotEqual(decided.source, .given, "the plan stated no platform")
    }

    /// BIO fix 1 and QA fix 1: the Mac counts a logical step of two processes over its whole input on its first result,
    /// each mate of the paired process a read, and gives the second process none; a step of one process keeps its own.
    func testAdoptSumsLogicalStepOnFirstProcess() async throws {
        let probe = try await adopt()
        let second = try XCTUnwrap(
            probe.plan.steps.first { $0.kind == .recipe && $0.id.hasSuffix("-2") && $0.arguments.contains(where: { argument in argument == "-I" }) },
            "the plan holds no second process with a paired input: \(probe.plan.steps.map(\.id))"
        )
        let first = String(second.id.dropLast(2))
        let single = try XCTUnwrap(probe.plan.steps.first { $0.kind == .recipe && $0.id == "recipe-1" }, "the plan has no recipe-1").id
        let counts: Counts = [
            first: (input: 750015, output: 749927), second.id: (input: 100253, output: 100191),
            single: (input: 1_000_000, output: 869_933),
        ]
        let adopted = try await adopt(counts: counts)
        let logical = try result(first, in: adopted)
        XCTAssertEqual(logical.inputReadCount, 950521, "750015 + 2 x 100253")
        XCTAssertEqual(logical.outputReadCount, 950309, "749927 + 2 x 100191")
        let later = try result(second.id, in: adopted)
        XCTAssertNil(later.inputReadCount)
        XCTAssertNil(later.outputReadCount)
        let alone = try result(single, in: adopted)
        XCTAssertEqual(alone.inputReadCount, 1_000_000)
        XCTAssertEqual(alone.outputReadCount, 869_933)
    }

    /// The envelope of an adopted bundle, by its provenance file.
    private func envelope(of bundle: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(
            fromSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
    }

    /// A step's outputs by file name, digest and size: the folders differ between two adopts, the files do not.
    private func outputKeys(_ step: ProvenanceStep) -> [String] {
        step.outputs.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent)|\($0.checksumSHA256 ?? "nil")|\($0.fileSize.map { "\($0)" } ?? "nil")" }
    }

    /// Review R1-R2 fix 2 (ARCH-X3 R-2): a CHTC job returns none of its inputs, and the input records of every recipe step for
    /// R1 and R2 then hold the plan's SHA-256 and size, which the adopt hands to `recipeProvenanceFiles` as `inputRecords`;
    /// hashed from a missing file a record holds no digest. The step's outputs are those of the adopt that holds the
    /// inputs. The plan names the platform, since one that leaves it to inference is refused without R1 (fix 1). The second
    /// adopt reads the first one's returned folder, at `<root>/returned` beside `<root>/Project.lungfish` as `adopt` lays it out.
    func testAdoptedRecipeStepsTakeAbsentInputsFromRunRecord() async throws {
        let present = try await adopt(platform: "illumina", files: true)
        let root = present.bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("returned", isDirectory: true)
        let pins = present.plan.entries.filter { $0.role == .input }
        XCTAssertEqual(pins.count, 2)
        for pin in pins { try FileManager.default.removeItem(at: folder.appendingPathComponent(pin.relativePath)) }
        let bundle = try await ExecutorRunAdoption.adopt(
            resultFolder: folder, projectDirectory: root.appendingPathComponent("ProjectWithoutInputs.lungfish", isDirectory: true)
        )
        let steps = try envelope(of: bundle).steps
        let reference = try present.envelope.steps
        let recipeArgvs = present.record.steps.filter { $0.kind == .recipe }.map(\.argv)
        XCTAssertFalse(recipeArgvs.isEmpty, "the record holds recipe steps")
        for argv in recipeArgvs {
            let label = argv.joined(separator: " ")
            let step = try XCTUnwrap(steps.first { $0.argv == argv }, label)
            for pin in pins {
                let input = try XCTUnwrap(step.inputs.first { $0.path.hasSuffix("/" + pin.relativePath) }, "\(pin.relativePath) of \(label)")
                XCTAssertEqual(input.checksumSHA256, pin.sha256, "\(pin.relativePath) of \(label)")
                XCTAssertEqual(input.fileSize.map { Int64($0) }, pin.size, "\(pin.relativePath) of \(label)")
            }
            let before = try XCTUnwrap(reference.first { $0.argv == argv }, label)
            XCTAssertEqual(outputKeys(step), outputKeys(before), label)
        }
    }
}
