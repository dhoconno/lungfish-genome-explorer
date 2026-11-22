// SalmonPlanTests.swift - The schema 2 plan of salmon counts on Linux, its chain and its request rule (Phase 5.3 lane
// EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SalmonPlanTests: XCTestCase {
    var root: URL!
    var storageRoot: URL!

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rnaseq/salmon-plan/plan.json")
    static let adapterFlags = ["-a", "-a2", "--illumina", "--nextera", "--small_rna", "--stranded_illumina", "--bgiseq",
                               "--consider_already_trimmed"]

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "salmon-plan")
        storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The cynomolgus mitochondrion in LGE's layout, built with the stand-in deriver.
    func builtSet() async throws -> ReferenceSetOutcome {
        let owner = ReferenceSetOwner(
            storageRoot: storageRoot, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(ReferenceSetMitoFixture.request(.lge))
    }

    /// A stand-in published index in the cache's layout: `index-key.json` and three files under `index/`.
    func publishIndex(setID: String, k: Int = 31, decoys: SalmonIndexDecoys = .genome) throws {
        let key = SalmonIndexKey(setID: setID, salmonVersion: "2.11.0", k: k, decoys: decoys)
        let folder = SalmonIndexCache(storageRoot: storageRoot, host: RunFitHostFacts(physicalMemoryBytes: 0)).folder(for: key)
        let index = folder.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        for (name, text) in [("info.json", "{\"k\": 31}\n"), ("refseq.bin", "refseq\n"), ("pos.bin", "pos\n")] {
            try Data(text.utf8).write(to: index.appendingPathComponent(name))
        }
        let file = SalmonIndexKeyFile(
            schemaVersion: 1, setID: setID, salmonVersion: "2.11.0", k: k, decoys: decoys,
            referenceSetSHA256: String(repeating: "c", count: 64), salmonBuild: "salmon-2.11.0-hfc06a8d_0",
            argv: ["index"], indexSeqHash: "seq1", indexNameHash: "name1", indexDecoySeqHash: "dseq1", indexDecoyNameHash: "dname1")
        try JSONEncoder().encode(file).write(to: folder.appendingPathComponent(SalmonIndexKeyFile.filename))
    }

    /// A bundle of two read files named as R1 and R2, whose sidecar holds the import's metadata and no recipe, so no step
    /// removed duplicates. With `sidecar` false the bundle holds no import record.
    func pairBundle(sidecar: Bool = true) throws -> URL {
        let bundle = root.appendingPathComponent("imports/sample1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for mate in [1, 2] {
            let text = (1...4).map { "@read\($0) \(mate):N:0:1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: bundle.appendingPathComponent("sample1_R\(mate).fastq"))
        }
        if sidecar {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .pairedEnd, pairingSource: .detected, recipeApplied: nil)),
                for: bundle.appendingPathComponent("sample1_R1.fastq"))
        }
        return bundle
    }

    /// The pins from outside the set, with the image's salmon and Trim Galore builds.
    var pins: SalmonPlanPins {
        let zeros = String(repeating: "0", count: 64)
        return SalmonPlanPins(
            executor: ExecutorPlanSourceFile(
                url: root.appendingPathComponent("lungfish-executor"), sha256: String(repeating: "a", count: 64), size: 1000),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros),
            imageManifest: PlanImageManifestPin(sha256: String(repeating: "b", count: 64), size: 4000),
            salmon: PlanToolPin(id: "salmon", version: "2.11.0", build: "hfa8f182_0"),
            trimGalore: PlanToolPin(id: "trim_galore", version: "2.3.0", build: "hf1b6044_0"))
    }

    /// The set, its stand-in index, the bundle's sample and the plan of `trim`.
    func made(_ trim: SalmonQuantTrim) async throws -> (set: ReferenceSetOutcome, made: SalmonPlanOutcome) {
        let set = try await builtSet()
        try publishIndex(setID: set.manifest.id)
        let sample = try await SalmonPlan.sample(bundle: try pairBundle(), scratch: root.appendingPathComponent("scratch"))
        let request = SalmonPlanRequest(setFolder: set.url, storageRoot: storageRoot, sample: sample, pins: pins, trim: trim)
        return (set, try SalmonPlan.make(request))
    }

    func setting(_ plan: ExecutionPlan, _ id: String) -> PlanPipelineSetting? {
        plan.pipeline?.settings.first { $0.id == id }
    }

    // MARK: - The pinned plan and the record line (item 3, red first)

    /// The pinned bytes of the kept state with trimming: `--no_poly_g` in each trim argv and the `trimming` entry that the
    /// record reads, `Poly-G trimming: off (LGE default)` with source `default` (ADJ-ROUTE items 1 and 2).
    func testThePinnedPlanPassesNoPolyGAndItsTrimmingEntryReadsTheLGEDefault() async throws {
        let plan = try await made(.trimGalore(polyG: false)).made.plan
        let trims = plan.steps.filter { $0.tool?.id == "trim_galore" }
        XCTAssertEqual(trims.map { $0.arguments.first }, ["--no_poly_g"])
        XCTAssertFalse(trims.contains { $0.arguments.contains("--poly_g") })
        let trimming = try XCTUnwrap(setting(plan, "trimming"))
        XCTAssertEqual(trimming.value, "Poly-G trimming: off (LGE default)")
        XCTAssertEqual(trimming.source, .default)
        XCTAssertEqual(plan.pipeline?.route?.settings["trimming"], trimming.value)
        XCTAssertEqual(setting(plan, "duplicates")?.value, "Duplicates: kept. LGE removes duplicates only with UMIs.")
        let bytes = try plan.encoded()
        XCTAssertNoThrow(try ExecutionPlan.decode(bytes))
        let pinned = (try? Data(contentsOf: Self.fixture)) ?? Data()
        if bytes != pinned {
            // Outside the test's folder, which tearDown removes, so the bytes can be read after a failure.
            let written = FileManager.default.temporaryDirectory.appendingPathComponent("salmon-plan-actual.json")
            try bytes.write(to: written)
            XCTFail("the plan's bytes differ from \(Self.fixture.path), and this run's are at \(written.path)")
        }
    }

    /// With poly-G trimming chosen the argv holds `--poly_g` and the entry names the choice and the trimmer's pin.
    func testPolyGTrimmingOnPassesPolyGAndTheEntryNamesTheChoice() async throws {
        let plan = try await made(.trimGalore(polyG: true)).made.plan
        let trims = plan.steps.filter { $0.tool?.id == "trim_galore" }
        XCTAssertEqual(trims.map { $0.arguments.first }, ["--poly_g"])
        XCTAssertFalse(trims.contains { $0.arguments.contains("--no_poly_g") })
        let trimming = try XCTUnwrap(setting(plan, "trimming"))
        XCTAssertEqual(trimming.value, "Poly-G trimming: on (chosen), Trim Galore 2.3.0 --poly_g")
        XCTAssertEqual(trimming.source, .option)
        XCTAssertNoThrow(try ExecutionPlan.decode(try plan.encoded()))
    }

    // MARK: - No published index (red first)

    func testASetWithNoPublishedIndexIsRefusedInWordsThatNameRnaseqIndex() async throws {
        let set = try await builtSet()
        let sample = try await SalmonPlan.sample(bundle: try pairBundle(), scratch: root.appendingPathComponent("scratch"))
        let request = SalmonPlanRequest(setFolder: set.url, storageRoot: storageRoot, sample: sample, pins: pins, trim: .none)
        XCTAssertThrowsError(try SalmonPlan.make(request)) { error in
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(words.contains("salmon-2.11.0-k31-genome-decoys"), words)
            XCTAssertTrue(words.contains("lungfish-cli rnaseq index --set \(set.manifest.id)"), words)
            XCTAssertTrue(words.contains("never builds one"), words)
        }
    }

    // MARK: - The chain (item 2)

    /// Trim Galore chooses the adapter, its JSON reports and its standard error come home, the trimmed reads stay, and
    /// salmon runs the Mac's argv on the pinned index with the reader's four files as `home` outputs.
    func testTheChainPassesNoAdapterFlagAndReturnsTheReportsTheDetectionLineAndSalmonsFourFiles() async throws {
        let (set, made) = try await made(.trimGalore(polyG: false))
        let plan = made.plan, id = set.manifest.id
        XCTAssertEqual(plan.steps.map(\.id), ["trim-pair1", "salmon-quant"])
        let trim = plan.steps[0], salmon = plan.steps[1]
        XCTAssertEqual(trim.arguments, ["--no_poly_g", "--paired", "-o", "trim-pair1", "inputs/pair1_R1.fastq", "inputs/pair1_R2.fastq"])
        XCTAssertTrue(Set(trim.arguments).isDisjoint(with: Self.adapterFlags), "Trim Galore chooses from read 1")
        XCTAssertEqual(trim.outputPolicy, [
            "trim-pair1/pair1_R1_val_1.fq": .stays, "trim-pair1/pair1_R2_val_2.fq": .stays,
            "trim-pair1/pair1_R1.fastq_trimming_report.json": .home, "trim-pair1/pair1_R2.fastq_trimming_report.json": .home,
            "logs/trim-pair1.stderr": .home,
        ])
        let index = "references/\(id)/indexes/salmon-2.11.0-k31-genome-decoys"
        XCTAssertEqual(salmon.arguments, ["quant", "-i", index, "-l", "A", "-1", "trim-pair1/pair1_R1_val_1.fq",
                                          "-2", "trim-pair1/pair1_R2_val_2.fq", "-p", "8", "-o", "quant"])
        XCTAssertEqual(salmon.outputs, ["quant/quant.sf", "quant/cmd_info.json", "quant/lib_format_counts.json",
                                        "quant/aux_info/meta_info.json"])
        XCTAssertEqual(Set(salmon.outputPolicy?.values.map { $0 } ?? []), [.home])
        XCTAssertEqual(plan.tools.map(\.id), ["salmon", "trim_galore"], "every program a step runs, and Trim Galore launches none")
        let references = plan.entries.filter { $0.role == .reference }
        XCTAssertEqual(references.map(\.relativePath), ["\(index)/info.json", "\(index)/pos.bin", "\(index)/refseq.bin"])
        XCTAssertEqual(references.first?.reference?.index, PlanReferenceIndex(
            key: "salmon-2.11.0-k31-genome-decoys", tool: PlanToolPin(id: "salmon", version: "2.11.0", build: "hfc06a8d_0")))
        let route = try XCTUnwrap(plan.pipeline?.route)
        XCTAssertEqual(route.id, SalmonQuantRoute.routeID)
        XCTAssertEqual([route.tool, route.toolVersion], ["salmon", "2.11.0"])
        XCTAssertEqual(route.settings.keys.sorted(), ["adapter", "counts", "decoys", "duplicates", "geneSums", "index", "k",
                                                      "libraryType", "mapping", "trimming"])
        XCTAssertEqual(setting(plan, "adapter")?.value, "Adapter: chosen by Trim Galore 2.3.0 from read 1 (auto-detection)")
        XCTAssertEqual(setting(plan, "adapter")?.source, .default)
        XCTAssertEqual(made.sources["inputs/pair1_R1.fastq"]?.lastPathComponent, "sample1_R1.fastq")
        XCTAssertEqual(made.sources["\(index)/refseq.bin"]?.lastPathComponent, "refseq.bin")
    }

    /// With no trimming the plan runs salmon on the reads as pinned, names no trimmer and states no adapter.
    func testAPlanWithNoTrimmingRunsSalmonOnTheReadsAndStatesReadsNotTrimmed() async throws {
        let plan = try await made(.none).made.plan
        XCTAssertEqual(plan.steps.map(\.id), ["salmon-quant"])
        XCTAssertEqual(Array(plan.steps[0].arguments[5...8]), ["-1", "inputs/pair1_R1.fastq", "-2", "inputs/pair1_R2.fastq"])
        XCTAssertEqual(plan.tools.map(\.id), ["salmon"])
        XCTAssertEqual(setting(plan, "trimming")?.value, "Reads not trimmed")
        XCTAssertNil(plan.pipeline?.route?.settings["adapter"])
    }

    // MARK: - The frame's reads and duplicates

    func testABundleWithNoImportRecordReadsNotRecordedAndADeduplicatedSampleTakesSourceRecipe() async throws {
        let sample = try await SalmonPlan.sample(bundle: try pairBundle(sidecar: false), scratch: root.appendingPathComponent("s"))
        XCTAssertEqual(sample.duplicates, "Duplicates: Not recorded (the bundle holds no import record that names its steps)")
        XCTAssertEqual(sample.duplicatesSource, .default)
        let set = try await builtSet()
        try publishIndex(setID: set.manifest.id)
        var removed = sample
        removed.duplicates = "Duplicates: removed at import by Deduplicate, without UMIs. This count removes none."
        removed.duplicatesSource = .recipe
        let plan = try SalmonPlan.make(SalmonPlanRequest(
            setFolder: set.url, storageRoot: storageRoot, sample: removed, pins: pins, trim: .none)).plan
        XCTAssertEqual(setting(plan, "duplicates")?.source, .recipe)
        XCTAssertEqual(plan.pipeline?.route?.settings["duplicates"], removed.duplicates)
    }

    func testAnInterleavedBundleIsRefusedInWordsThatNameTheForm() async throws {
        let fixtures = try ReadSetFixtures(in: root)
        do {
            _ = try await SalmonPlan.sample(bundle: fixtures.interleavedRoot, scratch: root.appendingPathComponent("s"))
            XCTFail("an interleaved bundle has no plan")
        } catch {
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(words.contains("interleaved in one file"), words)
            XCTAssertTrue(words.contains("lungfish-cli rnaseq quant"), words)
        }
    }

    // MARK: - Staged reads and the request rule (item 1)

    func stagedMade(threads: Int = 4) async throws -> (set: ReferenceSetOutcome, made: SalmonPlanOutcome) {
        let set = try await builtSet()
        try publishIndex(setID: set.manifest.id)
        let folder = "/staging/groups/lab/reads"
        let sample = SalmonPlan.stagedSample(
            name: "SRR1", pairs: [(SalmonPlanStagedRead(path: "\(folder)/SRR1_1.fastq.gz", size: 500, sha256: String(repeating: "1", count: 64)),
                                   SalmonPlanStagedRead(path: "\(folder)/SRR1_2.fastq.gz", size: 600, sha256: String(repeating: "2", count: 64)))],
            model: "NovaSeq 6000")
        let request = SalmonPlanRequest(setFolder: set.url, storageRoot: storageRoot, sample: sample, pins: pins,
                                        trim: .trimGalore(polyG: false), threads: threads)
        return (set, try SalmonPlan.make(request))
    }

    /// Staged reads have no Mac file, read Not recorded and the sheet's model, and the batch carries the person's three
    /// values for a set with no measured figure, which never reach a plan byte.
    func testStagedReadsGoThroughTheBatchWithThePersonsFiguresAndNoPlanByteHoldsThem() async throws {
        let (set, made) = try await stagedMade()
        let plan = made.plan
        XCTAssertEqual(plan.sampleValues?.instrument, PlanSampleInstrument(model: "NovaSeq 6000", inferred: false))
        XCTAssertNil(made.sources["inputs/pair1_R1.fastq.gz"], "LGE copies no staged read")
        XCTAssertEqual(setting(plan, "duplicates")?.value, SalmonPlan.duplicatesNotRecorded)
        XCTAssertThrowsError(try SalmonPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 9000)) { error in
            let words = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(words.contains("Give --request-cpus, --request-disk-gib."), words)
        }
        XCTAssertThrowsError(try SalmonPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 9000, cpus: 8, diskGiB: 30))
        let figures = try SalmonPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 9000, cpus: 4, diskGiB: 30)
        XCTAssertEqual(figures, SalmonPlanSubmit.Figures(memoryMiB: 9000, cpus: 4, diskGiB: 30))
        let layout = ExecutorPlanStagingLayout(folder: "/staging/groups/lab", batch: "salmon-batch")
        let image = ExecutorPlanImageRecord(
            sif: ExecutorPlanImageFile(fileName: "lge-tools.sif", sha256: String(repeating: "d", count: 64), size: 100),
            imageManifest: plan.imageManifest)
        let folder = root.appendingPathComponent("salmon-batch", isDirectory: true)
        let batch = try SalmonPlanSubmit.write([(made, figures)], image: image, layout: layout, into: folder)
        XCTAssertEqual(batch.samples, ["SRR1"])
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let vars = try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS SRR1 ") }, dag)
        XCTAssertTrue(vars.contains(#" request_disk="30GB" request_memory="9000MB" request_cpus="4" "#), String(vars))
        let sub = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(Set(["request_cpus = $(request_cpus)", "request_memory = $(request_memory)", "request_disk = $(request_disk)"])
            .isSubset(of: sub), sub.joined(separator: "\n"))
        let planText = String(decoding: try plan.encoded(), as: UTF8.self)
        XCTAssertFalse(planText.contains("9000"), "no request figure in a plan byte")
    }

    /// The macaque set's rule: 8 CPUs from `-p 8`, the peak plus 2 GiB rounded to 8 GiB, and disk from the bytes.
    func testTheMeasuredGenomeTakesTheRulesFigures() async throws {
        let (set, made) = try await stagedMade(threads: 8)
        var manifest = set.manifest
        manifest.assembly.name = "Macaca_fascicularis_6.0"
        let figures = try SalmonPlanSubmit.figures(for: manifest, made: made)
        XCTAssertEqual(figures.memoryMiB, 8192)
        XCTAssertEqual(figures.cpus, 8)
        // 1,100 bytes of reads, 2,200 trimmed, the index's bytes and 1,077,186,560 of salmon's, times 1.25, is 2 GiB, plus 8.
        XCTAssertEqual(figures.diskGiB, 10)
    }

    // MARK: - The frame a later chain builds on (FIX-SALMON-1 item 1, red first)

    /// A chain that counts with another tool, as EX-PLAN-STAR, EX-UMI and SOLO-PLAN add, takes the inputs, their Mac
    /// files and the trim steps from the frame, and the job builder takes that chain's own outcome. The salmon plan is
    /// the frame plus its one step, so every chain of one shape names the same `home` paths.
    func testALaterChainTakesTheReadsFrameAndTheJobBuilderTakesItsOwnOutcome() async throws {
        let (_, made) = try await made(.trimGalore(polyG: false))
        let frame = try SalmonPlan.readsFrame(
            sample: made.sample, trim: .trimGalore(polyG: false), trimTool: pins.trimGalore,
            deadline: ExecutionPlan.maximumDeadlineSeconds)
        XCTAssertEqual(frame.inputs.map(\.relativePath), ["inputs/pair1_R1.fastq", "inputs/pair1_R2.fastq"])
        XCTAssertEqual(frame.inputs, made.plan.entries.filter { $0.role == .input })
        XCTAssertEqual(frame.sources.keys.sorted(), ["inputs/pair1_R1.fastq", "inputs/pair1_R2.fastq"])
        XCTAssertEqual(frame.sources["inputs/pair1_R2.fastq"], made.sources["inputs/pair1_R2.fastq"])
        XCTAssertEqual(frame.trimSteps, Array(made.plan.steps.dropLast()))
        XCTAssertEqual([frame.r1s, frame.r2s, frame.singles], [["trim-pair1/pair1_R1_val_1.fq"], ["trim-pair1/pair1_R2_val_2.fq"], []])
        let untrimmed = try SalmonPlan.readsFrame(sample: made.sample, trim: .none, trimTool: pins.trimGalore, deadline: 60)
        XCTAssertEqual(untrimmed.trimSteps, [])
        XCTAssertEqual([untrimmed.r1s, untrimmed.r2s], [["inputs/pair1_R1.fastq"], ["inputs/pair1_R2.fastq"]])

        struct OtherChain: ReadsPlanOutcome {
            var plan: ExecutionPlan
            var sample: SalmonPlanSample
            var sources: [String: URL]
        }
        let other = OtherChain(plan: made.plan, sample: made.sample, sources: made.sources)
        let figures = SalmonPlanSubmit.Figures(memoryMiB: 4096, cpus: 8, diskGiB: 20)
        let job = SalmonPlanSubmit.job(other, figures: figures)
        XCTAssertEqual(job.emission.plan, made.plan)
        XCTAssertEqual(job.emission.sources, made.sources)
        XCTAssertEqual(job.submit, SalmonPlanSubmit.job(made, figures: figures).submit)
        XCTAssertEqual(job.submit.requestMemoryMiB, 4096)
        XCTAssertEqual(job.submit.requestCpus, 8)
    }

    // MARK: - One read of the index a command (FIX-SALMON-1 item 2, red first)

    /// The index is measured once and its pin serves each sample's plan, so a batch of N samples reads the published
    /// index once, not N times. The cache folder is gone before the two plans are made, so neither can read it again.
    func testAnIndexPinnedOnceServesEverySampleWithNoSecondRead() async throws {
        let set = try await builtSet()
        try publishIndex(setID: set.manifest.id)
        let pin = try SalmonPlan.pinIndex(setID: set.manifest.id, storageRoot: storageRoot, pins: pins)
        XCTAssertEqual(pin.key.folderName, "salmon-2.11.0-k31-genome-decoys")
        XCTAssertEqual(pin.entries.count, 3)
        try FileManager.default.removeItem(
            at: SalmonIndexCache(storageRoot: storageRoot, host: RunFitHostFacts(physicalMemoryBytes: 0)).folder(for: pin.key))
        func plan(_ name: String, index: SalmonPlanIndexPin?, k: Int = 31) throws -> SalmonPlanOutcome {
            let sample = SalmonPlan.stagedSample(name: name, pairs: [(
                SalmonPlanStagedRead(path: "/staging/r/\(name)_1.fastq.gz", size: 5, sha256: String(repeating: "1", count: 64)),
                SalmonPlanStagedRead(path: "/staging/r/\(name)_2.fastq.gz", size: 6, sha256: String(repeating: "2", count: 64)))])
            return try SalmonPlan.make(SalmonPlanRequest(
                setFolder: set.url, storageRoot: storageRoot, sample: sample, pins: pins, trim: .none, k: k, index: index))
        }
        let first = try plan("SRR1", index: pin), second = try plan("SRR2", index: pin)
        XCTAssertEqual(first.plan.entries.filter { $0.role == .reference }, pin.entries)
        XCTAssertEqual(second.plan.entries.filter { $0.role == .reference }, pin.entries)
        XCTAssertEqual(second.sources["\(pin.entries[0].relativePath)"], pin.sources[pin.entries[0].relativePath])
        XCTAssertThrowsError(try plan("SRR3", index: nil)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("never builds one"), error.localizedDescription)
        }
        XCTAssertThrowsError(try plan("SRR4", index: pin, k: 25)) { error in
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("The pinned index salmon-2.11.0-k31-genome-decoys is not the index of this plan, "
                + "salmon-2.11.0-k25-genome-decoys"), words)
        }
    }

    // MARK: - The instrument words (FIX-SALMON-1 item 3, red first)

    /// A read file whose sidecar holds the instrument ids and their models as the scan writes them.
    func instrumentPayload(_ name: String, ids: [String], models: [String]) throws -> URL {
        let url = root.appendingPathComponent("\(name).fastq")
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: url)
        let json = """
            {"nameForm": "casava18", "instrumentIDs": \(ids), "runNumbers": [1], "flowcells": ["F1"], "lanes": [1],
             "models": \(models), "modelsAreInferred": true, "modelSource": "table", "namedRecords": 1,
             "unnamedRecords": 0, "listsTruncated": false}
            """
        var metadata = PersistedFASTQMetadata()
        metadata.sequencerInstrument = try JSONDecoder().decode(SequencerInstrument.self, from: Data(json.utf8))
        FASTQMetadataStore.save(metadata, for: url)
        return url
    }

    /// Two instruments of one model name it once, and an id the table does not know names no model, so a sidecar of
    /// unknown ids leaves `sample.instrument` out, as the page says when none is known (SWIFT review should-fix 3).
    func testTheSidecarsInstrumentNamesEachModelOnceAndAnUnknownModelNone() throws {
        let twin = try instrumentPayload("twin", ids: ["A00001", "A00002"], models: ["NovaSeq 6000", "NovaSeq 6000"])
        XCTAssertEqual(SalmonPlan.instrument(payloads: [twin]), PlanSampleInstrument(model: "NovaSeq 6000", inferred: true))
        let mixed = try instrumentPayload(
            "mixed", ids: ["A00001", "XYZ", "NB501"], models: ["NovaSeq 6000", "Unknown", "NextSeq 550"])
        XCTAssertEqual(SalmonPlan.instrument(payloads: [mixed]),
                       PlanSampleInstrument(model: "NovaSeq 6000 and NextSeq 550", inferred: true))
        XCTAssertNil(SalmonPlan.instrument(payloads: [try instrumentPayload("unknown", ids: ["XYZ"], models: ["Unknown"])]))
    }

    // MARK: - The frame's other shapes and refusals (FIX-SALMON-1 item 3)

    func stagedPlan(
        _ set: ReferenceSetOutcome, pairs: [(String, String)], singles: [String] = []
    ) throws -> ExecutionPlan {
        func read(_ name: String) -> SalmonPlanStagedRead {
            SalmonPlanStagedRead(path: "/staging/groups/lab/reads/\(name)", size: 100, sha256: String(repeating: "e", count: 64))
        }
        let sample = SalmonPlan.stagedSample(name: "S", pairs: pairs.map { (read($0.0), read($0.1)) }, singles: singles.map(read))
        return try SalmonPlan.make(SalmonPlanRequest(
            setFolder: set.url, storageRoot: storageRoot, sample: sample, pins: pins, trim: .trimGalore(polyG: false))).plan
    }

    /// Single reads take one `trim-singles` call and `-r`, and two pairs take one call a pair and `-1` and `-2` in pair
    /// order, each the Mac's argv (`SalmonQuantRoute+Reads.swift`) at the request's default `-p 8` (BIO should-fix 2).
    func testASingleEndAndATwoPairSampleKeepTheMacsArgv() async throws {
        let set = try await builtSet()
        try publishIndex(setID: set.manifest.id)
        let index = "references/\(set.manifest.id)/indexes/salmon-2.11.0-k31-genome-decoys"
        let one = try stagedPlan(set, pairs: [], singles: ["SE1.fastq.gz"])
        XCTAssertEqual(one.steps.map(\.id), ["trim-singles", "salmon-quant"])
        XCTAssertEqual(one.steps[0].arguments, ["--no_poly_g", "-o", "trim-singles", "inputs/single1.fastq.gz"])
        XCTAssertEqual(one.steps[0].outputPolicy, [
            "trim-singles/single1_trimmed.fq.gz": .stays, "trim-singles/single1.fastq.gz_trimming_report.json": .home,
            "logs/trim-singles.stderr": .home,
        ])
        XCTAssertEqual(one.steps[1].arguments, ["quant", "-i", index, "-l", "A", "-r", "trim-singles/single1_trimmed.fq.gz",
                                                "-p", "8", "-o", "quant"])
        let two = try stagedPlan(set, pairs: [], singles: ["SE1.fastq.gz", "SE2.fastq.gz"])
        XCTAssertEqual(two.steps[0].arguments,
                       ["--no_poly_g", "-o", "trim-singles", "inputs/single1.fastq.gz", "inputs/single2.fastq.gz"])
        XCTAssertEqual(Array(two.steps[1].arguments[5...7]),
                       ["-r", "trim-singles/single1_trimmed.fq.gz", "trim-singles/single2_trimmed.fq.gz"])
        XCTAssertFalse(two.steps[1].arguments.contains("-1"))

        let pairs = try stagedPlan(set, pairs: [("SRR1_1.fastq.gz", "SRR1_2.fastq.gz"), ("SRR2_1.fastq.gz", "SRR2_2.fastq.gz")])
        XCTAssertEqual(pairs.steps.map(\.id), ["trim-pair1", "trim-pair2", "salmon-quant"])
        XCTAssertEqual(pairs.entries.filter { $0.role == .input }.map(\.relativePath), [
            "inputs/pair1_R1.fastq.gz", "inputs/pair1_R2.fastq.gz", "inputs/pair2_R1.fastq.gz", "inputs/pair2_R2.fastq.gz",
        ])
        XCTAssertEqual(pairs.steps[1].arguments,
                       ["--no_poly_g", "--paired", "-o", "trim-pair2", "inputs/pair2_R1.fastq.gz", "inputs/pair2_R2.fastq.gz"])
        XCTAssertEqual(pairs.steps[2].arguments, [
            "quant", "-i", index, "-l", "A", "-1", "trim-pair1/pair1_R1_val_1.fq.gz", "trim-pair2/pair2_R1_val_1.fq.gz",
            "-2", "trim-pair1/pair1_R2_val_2.fq.gz", "trim-pair2/pair2_R2_val_2.fq.gz", "-p", "8", "-o", "quant",
        ])
    }

    /// Pairs with single reads, a sample of no reads and CPUs that differ from `-p` are each refused in words that say
    /// what to do (SWIFT should-fix 3).
    func testMixedReadsNoReadsAndOtherCPUsAreRefusedInWords() async throws {
        func words(_ body: () throws -> Void) -> String {
            do { try body(); return "no refusal" } catch { return error.localizedDescription }
        }
        let (set, made) = try await stagedMade(threads: 4)
        let mixed = words { _ = try self.stagedPlan(set, pairs: [("A_1.fastq.gz", "A_2.fastq.gz")], singles: ["A.fastq.gz"]) }
        XCTAssertTrue(mixed.contains("holds read pairs and single reads, which one salmon run cannot count as one sample"), mixed)
        let none = words { _ = try self.stagedPlan(set, pairs: []) }
        XCTAssertEqual(none, "The sample S holds no reads, so no plan was written.")
        let cpus = words { _ = try SalmonPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 9000, cpus: 8, diskGiB: 30) }
        XCTAssertEqual(cpus, "The job asks for 8 CPUs and its plan runs salmon with -p 4. Write the plan with the CPUs the job asks for.")
    }
}
