// STARPlanTests.swift - The schema 2 plans of STAR GeneCounts and featureCounts on Linux, on a staged index (Phase 5.3
// lane EX-PLAN-STAR milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class STARPlanTests: XCTestCase {
    var root: URL!
    var storageRoot: URL!

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rnaseq/star-plan", isDirectory: true)
    static let staging = "/staging/groups/lab"
    static let layout = ExecutorPlanStagingLayout(folder: staging, batch: "star-counts")
    static let stars = ["2.7.11b": PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9"),
                        "2.7.3a": PlanToolPin(id: "STAR", version: "2.7.3a", build: "h5ca1c30_1")]

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "star-plan")
        storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The cynomolgus mitochondrion in LGE's layout, built with the stand-in deriver, whose `derived/genes.gtf` gives the
    /// 13 genes their CDS and stop codon as exons.
    func builtSet() async throws -> ReferenceSetOutcome {
        let owner = ReferenceSetOwner(
            storageRoot: storageRoot, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(ReferenceSetMitoFixture.request(.lge))
    }

    /// A stand-in index record as `rnaseq index-adopt` writes one, of three files the index batch `m-index` left, for the
    /// set's `derived/genes.gtf` unless `gtfSHA256` names another.
    func adoptIndex(_ set: ReferenceSetOutcome, star version: String, gtfSHA256: String? = nil) throws -> String {
        let star = try XCTUnwrap(Self.stars[version])
        let key = STARIndexKey.folderName(star: version, nbases: 7, sparseD: 2)
        let files = ["Genome", "SA", "chrName.txt"].map { name -> STARIndexRecord.File in
            let data = Data("\(name) of \(key)\n".utf8)
            return STARIndexRecord.File(
                path: name, planPath: "star-index/\(name)",
                stagingPath: "\(Self.staging)/batches/m-index-\(version)/index/staged/star-index/\(name)",
                bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let record = STARIndexRecord(setID: set.manifest.id, key: STARIndexKey(
            folderName: key, setID: set.manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: star,
            genomeSAindexNbases: 7, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: [set.manifest.genome.path],
            countingGTFSHA256: gtfSHA256 ?? set.manifest.derived.countingGTF?.sha256 ?? ""), tool: star, files: files)
        _ = try STARIndexRecordStore(storageRoot: storageRoot).write(record)
        return key
    }

    /// The pins from outside the set, with the image's builds of each tool.
    func pins(star version: String) throws -> STARPlanPins {
        let zeros = String(repeating: "0", count: 64)
        return STARPlanPins(
            executor: ExecutorPlanSourceFile(
                url: root.appendingPathComponent("lungfish-executor"), sha256: String(repeating: "a", count: 64), size: 1000),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros),
            imageManifest: PlanImageManifestPin(sha256: String(repeating: "b", count: 64), size: 4000),
            star: try XCTUnwrap(Self.stars[version]),
            trimGalore: PlanToolPin(id: "trim_galore", version: "2.3.0", build: "hf1b6044_0"),
            decompressor: PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_2"),
            featureCounts: PlanToolPin(id: "featureCounts", version: "2.1.1", build: "h577a1d6_0"))
    }

    /// A bundle of one pair of kept reads: its sidecar holds the import's metadata and no recipe, so no step removed
    /// duplicates.
    func keptPairBundle() throws -> URL {
        let bundle = root.appendingPathComponent("imports/sample1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for mate in [1, 2] {
            let text = (1...4).map { "@read\($0) \(mate):N:0:1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: bundle.appendingPathComponent("sample1_R\(mate).fastq"))
        }
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .pairedEnd, pairingSource: .detected, recipeApplied: nil)),
            for: bundle.appendingPathComponent("sample1_R1.fastq"))
        return bundle
    }

    /// Reads in the staging folder, gzip as an SRA run's are, `pairs` pairs or else one single read file.
    func stagedSample(pairs: Int, singles: Int = 0, size: Int64 = 700) -> SalmonPlanSample {
        func read(_ name: String) -> SalmonPlanStagedRead {
            SalmonPlanStagedRead(path: "\(Self.staging)/reads/\(name)", size: size, sha256: String(repeating: "e", count: 64))
        }
        return SalmonPlan.stagedSample(
            name: "SRR1", pairs: (0..<pairs).map { (read("SRR\($0 + 1)_1.fastq.gz"), read("SRR\($0 + 1)_2.fastq.gz")) },
            singles: (0..<singles).map { read("SE\($0 + 1).fastq.gz") })
    }

    /// The set, an adopted stand-in index at `star` and the plan of `chain` on `sample`, the kept bundle by default.
    func made(
        _ chain: STARPlanChain, star: String, sample: SalmonPlanSample? = nil, trim: SalmonQuantTrim = .trimGalore(polyG: false),
        multimapNmax: Int? = nil
    ) async throws -> (set: ReferenceSetOutcome, made: STARPlanOutcome) {
        let set = try await builtSet()
        let key = try adoptIndex(set, star: star)
        var reads = sample
        if reads == nil {
            reads = try await SalmonPlan.sample(bundle: try keptPairBundle(), scratch: root.appendingPathComponent("scratch"))
        }
        let request = STARPlanRequest(
            setFolder: set.url, sample: try XCTUnwrap(reads), pins: try pins(star: star), chain: chain,
            index: try pinIndex(set, key: key, star: star), trim: trim, multimapNmax: multimapNmax)
        return (set, try STARPlan.make(request))
    }

    func setting(_ plan: ExecutionPlan, _ id: String) -> PlanPipelineSetting? {
        plan.pipeline?.settings.first { $0.id == id }
    }

    func words(_ body: () throws -> Void) -> String {
        do { try body(); return "no refusal" } catch { return error.localizedDescription }
    }

    func pinIndex(_ set: ReferenceSetOutcome, key: String, star version: String) throws -> ExecutorPlanStagedIndex {
        try ExecutorPlanStagedIndex.pin(setID: set.manifest.id, key: key, store: STARIndexRecordStore(storageRoot: storageRoot),
                                        star: try XCTUnwrap(Self.stars[version]), layout: Self.layout)
    }

    /// The plan's bytes against `Fixtures/rnaseq/star-plan/<name>`. A run whose bytes differ writes them outside the
    /// test's folder, which tearDown removes, so they can be read after a failure.
    func assertPinned(_ plan: ExecutionPlan, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try plan.encoded()
        XCTAssertNoThrow(try ExecutionPlan.decode(bytes), file: file, line: line)
        let pinned = Self.fixtures.appendingPathComponent(name)
        guard bytes != ((try? Data(contentsOf: pinned)) ?? Data()) else { return }
        let written = FileManager.default.temporaryDirectory.appendingPathComponent("star-plan-actual-\(name)")
        try bytes.write(to: written)
        XCTFail("the plan's bytes differ from \(pinned.path), and this run's are at \(written.path)", file: file, line: line)
    }

    // MARK: - The pinned plans and their record lines (M2 item 3, red first)

    /// The 2.7.11b featureCounts plan and the 2.7.3a GeneCounts plan on the kept bundle: `--no_poly_g`, the `trimming`,
    /// `duplicates` and `adapter` entries (ADJ-ROUTE Q1 and Q3, BIO-PLAN-ADAPTER item 3), and the set id with the path
    /// and SHA-256 of `derived/genes.gtf` (BIO-COUNTING-GTF item 4), in bytes pinned on the fixture.
    func testThePinnedPlansHoldNoPolyGTheRecordLinesAndTheSetsGenesGTFByPathAndSHA256() async throws {
        for (chain, star, name) in [(STARPlanChain.featureCounts, "2.7.11b", "star-2.7.11b-featurecounts.json"),
                                    (.geneCounts, "2.7.3a", "star-2.7.3a-genecounts.json")] {
            let (set, made) = try await made(chain, star: star)
            let plan = made.plan
            let gtf = try XCTUnwrap(set.manifest.derived.countingGTF)
            XCTAssertEqual(gtf.path, "derived/genes.gtf")
            XCTAssertEqual(plan.steps.filter { $0.tool?.id == "trim_galore" }.map { $0.arguments.first }, ["--no_poly_g"])
            XCTAssertEqual(setting(plan, "trimming")?.value, "Poly-G trimming: off (LGE default)")
            XCTAssertEqual(setting(plan, "trimming")?.source, .default)
            XCTAssertEqual(setting(plan, "duplicates")?.value, "Duplicates: kept. LGE removes duplicates only with UMIs.")
            XCTAssertEqual(setting(plan, "adapter")?.value, "Adapter: chosen by Trim Galore 2.3.0 from read 1 (auto-detection)")
            XCTAssertEqual(setting(plan, "countingGTF")?.value,
                           "derived/genes.gtf of the set \(set.manifest.id), SHA-256 \(gtf.sha256)")
            XCTAssertEqual(plan.pipeline?.referenceSet.id, set.manifest.id)
            for entry in plan.pipeline?.settings ?? [] {
                XCTAssertEqual(plan.pipeline?.route?.settings[entry.id], entry.value, entry.id)
            }
            try assertPinned(plan, name)
        }
    }

    // MARK: - The STAR step (M2 item 1)

    /// After the frame's trim step, one STAR call with the 5.0 scripts' argv (`gse304256/star.sh:28-30`,
    /// `gse152418/star.sh:28-29`, `gse290671/run.sh:117-122`) on the pinned index, every path relative to the work root,
    /// fixed threads, and pigz, which `--readFilesCommand` starts, pinned in `tools`. The two reports come home and the
    /// BAM stays.
    func testTheSTARStepRunsTheScriptsArgvOnThePinnedIndexAndPinsTheDecompressor() async throws {
        let (set, made) = try await made(.geneCounts, star: "2.7.3a", sample: stagedSample(pairs: 1))
        let plan = made.plan
        XCTAssertEqual(plan.steps.map(\.id), ["trim-pair1", "star-align"])
        let index = "references/\(set.manifest.id)/indexes/star-2.7.3a-sa7-sparse2"
        let star = plan.steps[1]
        XCTAssertEqual(star.arguments, [
            "--runThreadN", "8", "--genomeDir", index,
            "--readFilesIn", "trim-pair1/pair1_R1_val_1.fq.gz", "trim-pair1/pair1_R2_val_2.fq.gz",
            "--readFilesCommand", "pigz", "-d", "-c", "--outSAMtype", "BAM", "Unsorted", "--quantMode", "GeneCounts",
            "--outFileNamePrefix", "star/",
        ])
        XCTAssertEqual(star.tool, Self.stars["2.7.3a"])
        XCTAssertEqual(star.outputPolicy, ["star/Log.final.out": .home, "star/ReadsPerGene.out.tab": .home,
                                           "star/Aligned.out.bam": .stays])
        XCTAssertEqual(plan.tools.map(\.id), ["STAR", "pigz", "trim_galore"])
        let references = plan.entries.filter { $0.role == .reference }
        XCTAssertEqual(references.map(\.relativePath), ["Genome", "SA", "chrName.txt"].map { "\(index)/\($0)" })
        XCTAssertEqual(made.stagedReferencePaths["\(index)/SA"],
                       "/staging/groups/lab/batches/m-index-2.7.3a/index/staged/star-index/SA")
        XCTAssertTrue(Set(star.inputs).isSuperset(of: references.map(\.relativePath)))
        let route = try XCTUnwrap(plan.pipeline?.route)
        XCTAssertEqual([route.id, route.tool, route.toolVersion], ["star-genecounts", "STAR", "2.7.3a"])
        XCTAssertEqual(setting(plan, "multimapNmax")?.value, "10 loci, STAR's default (no --outFilterMultimapNmax)")
        XCTAssertFalse(plan.entries.contains { $0.relativePath.hasSuffix("genes.gtf") }, "GeneCounts reads the GTF through the index")
    }

    /// `--outFilterMultimapNmax 1000` is an option with source `option`, whose record line names it as C6's undocumented
    /// step (reproduction plan row GE). The argv carries it after the scripts' own flags, where `STAR_ALIGN_EXTRA` put it.
    func testMultimapNmaxIsAnOptionAndItsRecordLineNamesC6sUndocumentedStep() async throws {
        let plan = try await made(.geneCounts, star: "2.7.3a", sample: stagedSample(pairs: 1), multimapNmax: 1000).made.plan
        XCTAssertEqual(Array(plan.steps[1].arguments.suffix(4)), ["--outFileNamePrefix", "star/", "--outFilterMultimapNmax", "1000"])
        let entry = try XCTUnwrap(setting(plan, "multimapNmax"))
        XCTAssertEqual(entry.source, .option)
        XCTAssertEqual(entry.value, "1000 loci, chosen with --outFilterMultimapNmax 1000, the undocumented step of GSE304256 (C6) "
            + "that its deposited ReadsPerGene files need")
        XCTAssertEqual(plan.pipeline?.route?.settings["multimapNmax"], entry.value)
    }

    // MARK: - featureCounts (M2 item 2)

    /// subread 2.1.1 `featureCounts -p --countReadPairs -M` on exons with no `-O` and no `--fraction` (`gf_truth.sh:43-44`),
    /// `-a` the set's `derived/genes.gtf` entry by SHA-256 and never the annotation as given (BIO-COUNTING-GTF item 4).
    func testFeatureCountsReadsTheSetsGenesGTFBySHA256AndNeverTheAnnotationAsGiven() async throws {
        let (set, made) = try await made(.featureCounts, star: "2.7.11b", sample: stagedSample(pairs: 1))
        let plan = made.plan, id = set.manifest.id
        let gtf = try XCTUnwrap(set.manifest.derived.countingGTF)
        XCTAssertEqual(plan.steps.map(\.id), ["trim-pair1", "star-align", "featurecounts"])
        let counts = plan.steps[2]
        XCTAssertEqual(counts.arguments, ["-p", "--countReadPairs", "-M", "-T", "8", "-a", "references/\(id)/derived/genes.gtf",
                                          "-o", "featurecounts/counts.txt", "star/Aligned.out.bam"])
        XCTAssertTrue(Set(counts.arguments).isDisjoint(with: ["-O", "--fraction"]))
        XCTAssertEqual(counts.outputPolicy, ["featurecounts/counts.txt": .home, "featurecounts/counts.txt.summary": .home])
        let entry = try XCTUnwrap(plan.entries.first { $0.relativePath == "references/\(id)/derived/genes.gtf" })
        XCTAssertEqual([entry.sha256, entry.reference?.path], [gtf.sha256, "derived/genes.gtf"])
        XCTAssertEqual(entry.size, gtf.size)
        XCTAssertEqual(made.sources[entry.relativePath], set.url.appendingPathComponent("derived/genes.gtf"))
        XCTAssertFalse(plan.entries.contains { $0.relativePath.contains("/annotation/") }, "never the annotation as given")
        XCTAssertNil(made.stagedReferencePaths[entry.relativePath], "the GTF goes from the Mac through shared/")
        XCTAssertEqual(plan.tools.map(\.id), ["STAR", "featureCounts", "pigz", "trim_galore"])
        let route = try XCTUnwrap(plan.pipeline?.route)
        XCTAssertEqual([route.id, route.tool, route.toolVersion], ["star-featurecounts-exon", "featureCounts", "2.1.1"])
        XCTAssertEqual(route.settings["mapping"], "STAR 2.7.11b on the genome, --outSAMtype BAM Unsorted --quantMode GeneCounts")
        XCTAssertEqual(route.settings.keys.sorted(), ["adapter", "countingGTF", "counts", "duplicates", "index", "mapping",
                                                      "multimapNmax", "trimming"])
    }

    /// Single reads drop `-p --countReadPairs` and the record says so, STAR maps one mate, and two pairs map as comma
    /// lists in pair order.
    func testSingleReadsDropThePairFlagsAndTwoPairsMapAsCommaLists() async throws {
        let single = try await made(.featureCounts, star: "2.7.11b", sample: stagedSample(pairs: 0, singles: 2)).made.plan
        XCTAssertEqual(Array(single.steps[1].arguments[4...5]),
                       ["--readFilesIn", "trim-singles/single1_trimmed.fq.gz,trim-singles/single2_trimmed.fq.gz"])
        XCTAssertEqual(Array(single.steps[1].arguments[6...7]), ["--readFilesCommand", "pigz"])
        XCTAssertEqual(Array(single.steps[2].arguments.prefix(3)), ["-M", "-T", "8"])
        XCTAssertTrue(setting(single, "counts")?.value.contains("single reads take no -p --countReadPairs") == true)
        let two = try await made(.geneCounts, star: "2.7.11b", sample: stagedSample(pairs: 2), trim: .none).made.plan
        XCTAssertEqual(two.steps.map(\.id), ["star-align"])
        XCTAssertEqual(Array(two.steps[0].arguments[4...6]), ["--readFilesIn", "inputs/pair1_R1.fastq.gz,inputs/pair2_R1.fastq.gz",
                                                              "inputs/pair1_R2.fastq.gz,inputs/pair2_R2.fastq.gz"])
        XCTAssertEqual(setting(two, "trimming")?.value, "Reads not trimmed")
        XCTAssertNil(setting(two, "adapter"))
    }

    // MARK: - Refusals

    /// An index of another STAR version or of another GTF, and a sample of gzip and plain reads, are refused in words.
    func testAnIndexOfAnotherSTAROrGTFAndMixedReadsAreRefusedInWords() async throws {
        let set = try await builtSet()
        let key = try adoptIndex(set, star: "2.7.11b")
        let index = try pinIndex(set, key: key, star: "2.7.11b")
        func plan(_ star: String, _ sample: SalmonPlanSample, index: ExecutorPlanStagedIndex) throws {
            _ = try STARPlan.make(STARPlanRequest(setFolder: set.url, sample: sample, pins: try pins(star: star),
                                                  chain: .geneCounts, index: index, trim: .none))
        }
        let other = words { try plan("2.7.3a", self.stagedSample(pairs: 1), index: index) }
        XCTAssertEqual(other, "The plan maps with STAR 2.7.3a, and the index star-2.7.11b-sa7-sparse2 was built by STAR 2.7.11b. "
            + "STAR maps only on an index of its own version, so map with STAR 2.7.11b.")
        var mixed = stagedSample(pairs: 1)
        mixed.pairs[0].r2.name = "SRR1_2.fastq"
        let both = words { try plan("2.7.11b", mixed, index: index) }
        XCTAssertTrue(both.contains("holds gzip reads and plain reads"), both)
        var oldGTF = index
        oldGTF.record.key.countingGTFSHA256 = String(repeating: "f", count: 64)
        let gtf = words { try plan("2.7.11b", self.stagedSample(pairs: 1), index: oldGTF) }
        XCTAssertTrue(gtf.contains("was built from a derived/genes.gtf of SHA-256 \(String(repeating: "f", count: 64))"), gtf)
        XCTAssertTrue(gtf.contains("lungfish-cli rnaseq index-plan --set \(set.manifest.id) --star 2.7.11b"), gtf)
        let none = words { _ = try ExecutorPlanStagedIndex.pin(setID: set.manifest.id, key: "star-2.7.3a-sa7-sparse2",
                                                               store: STARIndexRecordStore(storageRoot: self.storageRoot),
                                                               star: try XCTUnwrap(Self.stars["2.7.3a"]), layout: Self.layout) }
        XCTAssertTrue(none.contains("rnaseq index-plan") && none.contains("rnaseq index-adopt"), none)
    }

    // MARK: - The request rule and the batch (M2 item 3)

    /// 8 CPUs, 29,696 MiB and 60 GiB for a 50 M pair cynomolgus sample (BIO-LINUX-HOST item 9), 31,744 MiB and 100 GiB at
    /// 100 M, pairs estimated from the reads' bytes, and a genome with no measured figures takes the person's or is refused.
    func testTheRequestRuleAsksTheMeasuredFiguresAndAnUnmeasuredGenomeTakesThePersons() async throws {
        let (set, made) = try await made(.featureCounts, star: "2.7.11b", sample: stagedSample(pairs: 1))
        var macaque = set.manifest
        macaque.assembly.name = "Macaca_fascicularis_6.0"
        XCTAssertEqual(try STARPlanSubmit.figures(for: macaque, made: made, millionPairs: 50),
                       SalmonPlanSubmit.Figures(memoryMiB: 29_696, cpus: 8, diskGiB: 60))
        XCTAssertEqual(try STARPlanSubmit.figures(for: macaque, made: made, millionPairs: 100),
                       SalmonPlanSubmit.Figures(memoryMiB: 31_744, cpus: 8, diskGiB: 100))
        let big = try await self.made(.featureCounts, star: "2.7.11b", sample: stagedSample(pairs: 1, size: 3_500_000_000)).made
        XCTAssertEqual(STARPlanSubmit.estimatedMillionPairs(big.plan), 50, accuracy: 1e-9)
        XCTAssertEqual(try STARPlanSubmit.figures(for: macaque, made: big).memoryMiB, 29_696)
        let unmeasured = words { _ = try STARPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 9000) }
        XCTAssertTrue(unmeasured.contains("no measured figures for STAR on") && unmeasured.hasSuffix(
            "Give --request-cpus, --request-disk-gib."), unmeasured)
        XCTAssertEqual(try STARPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 9000, cpus: 8, diskGiB: 30),
                       SalmonPlanSubmit.Figures(memoryMiB: 9000, cpus: 8, diskGiB: 30))
        XCTAssertTrue(words { _ = try STARPlanSubmit.figures(for: macaque, made: made, cpus: 4) }.contains("--runThreadN 8"))
    }

    /// The batch reads each index file where the index run left it and copies the GTF from the Mac, and no plan byte
    /// holds a request figure or a staging path.
    func testTheBatchReadsTheIndexWhereItWasStagedAndNoPlanByteHoldsAFigure() async throws {
        let (_, made) = try await made(.featureCounts, star: "2.7.11b", sample: stagedSample(pairs: 1))
        let figures = SalmonPlanSubmit.Figures(memoryMiB: 29_696, cpus: 8, diskGiB: 60)
        XCTAssertEqual(STARPlanSubmit.job(made, figures: figures).stagedReferencePaths, made.stagedReferencePaths)
        let image = ExecutorPlanImageRecord(
            sif: ExecutorPlanImageFile(fileName: "lge-tools.sif", sha256: String(repeating: "d", count: 64), size: 100),
            imageManifest: made.plan.imageManifest)
        let folder = root.appendingPathComponent("star-counts", isDirectory: true)
        let batch = try STARPlanSubmit.write([(made, figures)], image: image, layout: Self.layout, into: folder)
        XCTAssertEqual(batch.samples, ["SRR1"])
        let files = try String(contentsOf: folder.appendingPathComponent("staging-files.json"), encoding: .utf8)
        XCTAssertTrue(files.contains("/staging/groups/lab/batches/m-index-2.7.11b/index/staged/star-index/Genome"), files)
        let planText = String(decoding: try made.plan.encoded(), as: UTF8.self)
        XCTAssertFalse(planText.contains("29696") || planText.contains("/staging/"), "no figure or staging path in a plan byte")
    }
}
