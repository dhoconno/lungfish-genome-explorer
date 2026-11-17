// UMIPlanTests.swift - The UMI branch's kit preset and its layout check step in the plan (Phase 5.3 lane EX-UMI,
// milestone 1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class UMIPlanTests: XCTestCase {
    var root: URL!
    var storageRoot: URL!

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rnaseq/umi-plan/plan.json")

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "umi-plan")
        storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    static let staging = "/staging/groups/lab"
    static let star = PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9")

    /// The image's builds of each tool the chain runs or starts (`Resources/CHTCImage/image-manifest.json`), and python3
    /// 3.11.18, the interpreter beside umi_tools.
    var pins: UMIPlanPins {
        let zeros = String(repeating: "0", count: 64)
        return UMIPlanPins(
            executor: ExecutorPlanSourceFile(
                url: root.appendingPathComponent("lungfish-executor"), sha256: String(repeating: "a", count: 64), size: 1000),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros),
            imageManifest: PlanImageManifestPin(sha256: String(repeating: "b", count: 64), size: 4000),
            pigz: PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_1"), star: Self.star,
            featureCounts: PlanToolPin(id: "featureCounts", version: "2.1.1", build: "h577a1d6_0"),
            samtools: PlanToolPin(id: "samtools", version: "1.24", build: "h9dcdb79_1"),
            umiTools: PlanToolPin(id: "umi_tools", version: "1.1.6", build: "py311haab0aaa_0"),
            python: PlanToolPin(id: "python3", version: "3.11.18", build: "h5f976f7_0_cpython"))
    }

    /// One C9 run in the staging folder, as `rnaseq quant --write-plan --samplesheet` names it.
    func c9Sample() -> SalmonPlanSample {
        func read(_ name: String, _ fill: String) -> SalmonPlanStagedRead {
            SalmonPlanStagedRead(path: "/staging/c9/\(name)", size: 1_234_567, sha256: String(repeating: fill, count: 64))
        }
        return SalmonPlan.stagedSample(
            name: "SRR28155077", pairs: [(read("SRR28155077_1.fastq.gz", "1"), read("SRR28155077_2.fastq.gz", "2"))],
            model: "HiSeq X Ten")
    }

    /// A stand-in record of STAR 2.7.11b's index of the set, as `rnaseq index-adopt` writes one, of three files.
    func pinnedIndex(_ set: ReferenceSetOutcome) throws -> ExecutorPlanStagedIndex {
        let key = STARIndexKey.folderName(star: "2.7.11b", nbases: 7, sparseD: 2)
        let files = ["Genome", "SA", "chrName.txt"].map { name -> STARIndexRecord.File in
            let data = Data("\(name) of \(key)\n".utf8)
            return STARIndexRecord.File(
                path: name, planPath: "star-index/\(name)",
                stagingPath: "\(Self.staging)/batches/m-index/index/staged/star-index/\(name)",
                bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let store = STARIndexRecordStore(storageRoot: storageRoot)
        _ = try store.write(STARIndexRecord(setID: set.manifest.id, key: STARIndexKey(
            folderName: key, setID: set.manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: Self.star,
            genomeSAindexNbases: 7, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: [set.manifest.genome.path],
            countingGTFSHA256: set.manifest.derived.countingGTF?.sha256 ?? ""), tool: Self.star, files: files))
        return try ExecutorPlanStagedIndex.pin(setID: set.manifest.id, key: key, store: store, star: Self.star,
                                               layout: ExecutorPlanStagingLayout(folder: Self.staging, batch: "umi-counts"))
    }

    /// The plan of `sample`, the C9 run by default, with the kit column's value, on the set and its pinned index.
    func made(kit: String = "quartz-seq2-x910", sample: SalmonPlanSample? = nil) async throws -> UMIPlanOutcome {
        let owner = ReferenceSetOwner(
            storageRoot: storageRoot, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let set = try await owner.build(ReferenceSetMitoFixture.request(.lge))
        return try UMIPlan.make(UMIPlanRequest(
            setFolder: set.url, sample: sample ?? c9Sample(), kit: kit, pins: pins, index: try pinnedIndex(set)))
    }

    /// Item 3: the plan's bytes with the check step and the preset's settings.
    func testPlanBytesHoldTheCheckStepAndThePresetSettings() async throws {
        let made = try await made()
        let bytes = try made.plan.encoded()
        let pinned = (try? Data(contentsOf: Self.fixture)) ?? Data()
        if bytes != pinned {
            let written = root.deletingLastPathComponent().appendingPathComponent("umi-plan-\(UUID().uuidString).json")
            try bytes.write(to: written)
            XCTFail("the plan's bytes differ from \(Self.fixture.path), and this run's are at \(written.path)")
        }
    }

    /// Items 1 and 2: the check is the first `tool` step, pinned to the plan's own executor build, before extraction,
    /// and its argv and `pipeline.settings` state the motif, the UMI's length and read, the pairs, their choice and the
    /// bars.
    func testCheckStepIsTheExecutorsOwnAndItsArgvStatesThePreset() async throws {
        let plan = try await made().plan
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.id, "umi-layout-check-pair1")
        XCTAssertEqual(step.kind, .tool)
        XCTAssertEqual(step.tool, PlanToolPin(id: "lungfish-executor", version: "test", build: String(repeating: "0", count: 40)))
        XCTAssertEqual(plan.tools.map(\.id), ["STAR", "featureCounts", "lungfish-executor", "pigz", "python3", "samtools", "umi_tools"])
        let check = try UMILayoutCheck.Arguments(argv: step.arguments)
        XCTAssertEqual(check, UMILayoutCheck.Arguments(
            read1: "inputs/pair1_R1.fastq.gz", read2: "inputs/pair1_R2.fastq.gz", decompressor: "pigz",
            kit: UMIPlan.quartzSeq2X910.label, motif: "ATCAATC", umiLength: 16, umiRead: 1, pairs: 1000, choice: .even,
            bars: UMILayoutCheck.Bars(withinOneMismatchPass: 90, exactWarn: 90, distinctFail: 50, distinctWarn: 80),
            output: "umi-check/pair1-layout-check.json"))
        XCTAssertEqual(step.outputPolicy, ["umi-check/pair1-layout-check.json": .home])
        let settings = Dictionary(uniqueKeysWithValues: (plan.pipeline?.settings ?? []).map { ($0.id, $0) })
        XCTAssertEqual(settings["umiExtraction"]?.value,
                       "umi_tools extract --extract-method=regex --bc-pattern=^(?P<discard_1>ATCAATC)(?P<umi_1>.{16})")
        XCTAssertEqual(settings["umiGrouping"]?.value,
                       "umi_tools count --per-gene --gene-tag=XT --assigned-status-tag=XS --method=directional")
        XCTAssertEqual(settings["umiCheckPairs"]?.value, "1,000 pairs, spread evenly through the file after counting its reads (--choice even)")
        XCTAssertEqual(settings["trimming"]?.value, "Reads not trimmed")
        XCTAssertNil(settings["adapter"], "C9's preset carries no adapter")
        XCTAssertEqual(plan.pipeline?.preset, PlanPipelinePreset(id: "quartz-seq2-x910", name: UMIPlan.quartzSeq2X910.label))
    }

    /// EX-UMI-M1-BIO should-fix 3: the plan a person reads states every fail rule the check applies, the names rule among
    /// them (brief item 2, ADJ-BULK G1).
    func testCheckBarsSettingStatesTheNamesRule() async throws {
        let plan = try await made().plan
        let bars = try XCTUnwrap(plan.pipeline?.settings.first { $0.id == "umiCheckBars" })
        XCTAssertEqual(bars.value, "fails when a read name differs between the mates in any pair, when under 90% of the pairs read "
            + "start within one mismatch of ATCAATC, or when under 50% hold a distinct UMI, and warns when under 90% start with it "
            + "exactly or under 80% hold a distinct UMI")
    }

    /// EX-UMI-M1-BIO ruling 4 and S3: each value the kit's preset fixes enters the plan with source `preset`, `trimming`
    /// (which no preset fixes) keeps `default`, and the executor's decoder accepts the plan.
    func testPresetValuesEnterThePlanWithSourcePreset() async throws {
        XCTAssertEqual(ImportSettingSource(rawValue: "preset")?.rawValue, "preset")
        let plan = try await made().plan
        let settings = try XCTUnwrap(plan.pipeline?.settings)
        XCTAssertEqual(settings.map { "\($0.id) \($0.source.rawValue)" }, [
            "countingGTF default", "counts default", "duplicates preset", "index default", "mapping default",
            "trimming default", "umiCheckBars preset", "umiCheckPairs preset", "umiExtraction preset", "umiGrouping preset",
            "umiKit preset", "umiLength preset", "umiMotif preset", "umiRead preset",
        ])
        let decoded = try ExecutionPlan.decode(try plan.encoded())
        XCTAssertEqual(decoded.pipeline?.settings.map(\.source.rawValue), settings.map(\.source.rawValue))
    }

    /// The kit column picks the preset by id, and an unknown kit is refused with the kits LGE knows.
    func testUnknownKitIsRefusedWithTheKnownKits() async throws {
        do {
            _ = try await made(kit: "10x-3prime-v3")
            XCTFail("an unknown kit wrote a plan")
        } catch let error as SalmonPlanError {
            XCTAssertEqual(error.message, "The sample sheet names the kit 10x-3prime-v3, which LGE has no UMI preset for. The kits "
                + "LGE knows are quartz-seq2-x910 (\(UMIPlan.quartzSeq2X910.label)).")
        }
    }

    /// M2 item 1: after each pair's check, umi_tools extract keeps Read 2 with the UMI in its name, STAR maps Read 2 alone
    /// with unique alignments into a coordinate-sorted BAM, featureCounts tags it by the set's genes (`-R BAM -s 0`),
    /// samtools sorts and indexes the tagged BAM and umi_tools counts per gene (`gse163196/sample.sh:32-67`). Reports
    /// come home, and reads and BAMs stay.
    func testChainRunsExtractSTARFeatureCountsSortIndexAndCountAfterTheCheck() async throws {
        let made = try await made()
        let plan = made.plan
        XCTAssertEqual(plan.steps.map(\.id), [
            "umi-layout-check-pair1", "umi-extract-pair1", "star-align", "featurecounts", "samtools-sort", "samtools-index", "umi-count",
        ])
        func step(_ id: String) throws -> PlanStep { try XCTUnwrap(plan.steps.first { $0.id == id }) }
        let set = try XCTUnwrap(plan.pipeline?.referenceSet.id)
        let extract = try step("umi-extract-pair1")
        XCTAssertEqual(extract.tool, pins.umiTools)
        XCTAssertEqual(extract.arguments, [
            "extract", "--extract-method=regex", "--bc-pattern=^(?P<discard_1>ATCAATC)(?P<umi_1>.{16})",
            "-I", "inputs/pair1_R1.fastq.gz", "--read2-in", "inputs/pair1_R2.fastq.gz", "--read2-stdout",
            "-S", "umi/pair1_R2.umi.fastq.gz", "-L", "umi/pair1-extract.log",
        ])
        XCTAssertEqual(extract.outputPolicy, ["umi/pair1_R2.umi.fastq.gz": .stays, "umi/pair1-extract.log": .home])
        let star = try step("star-align")
        XCTAssertEqual(star.tool, Self.star)
        XCTAssertEqual(star.arguments, [
            "--runThreadN", "8", "--genomeDir", "references/\(set)/indexes/\(made.index.folderName)",
            "--readFilesIn", "umi/pair1_R2.umi.fastq.gz", "--readFilesCommand", "pigz", "-d", "-c",
            "--outFilterMultimapNmax", "1", "--readNameSeparator", "-", "--outSAMtype", "BAM", "SortedByCoordinate",
            "--limitBAMsortRAM", "8000000000", "--outFileNamePrefix", "star/",
        ])
        XCTAssertEqual(star.outputPolicy, ["star/Log.final.out": .home, "star/Aligned.sortedByCoord.out.bam": .stays])
        // EX-UMI-M2-BIO ruling 1 (a): STAR keeps each read's whole first word, so a slash in it never cuts the UMI off, and
        // the mapping words name the flag, so the argv and the identity agree.
        XCTAssertEqual(plan.pipeline?.route?.settings["mapping"], "STAR 2.7.11b on the genome, Read 2 alone, uniquely mapped "
            + "reads only (--outFilterMultimapNmax 1), each read named by the whole first word of its name with the UMI at its "
            + "end (--readNameSeparator -), --outSAMtype BAM SortedByCoordinate")
        let featureCounts = try step("featurecounts")
        XCTAssertEqual(featureCounts.arguments, [
            "-T", "8", "-s", "0", "-a", "references/\(set)/derived/genes.gtf", "-o", "featurecounts/counts.txt",
            "-R", "BAM", "--Rpath", "featurecounts", "star/Aligned.sortedByCoord.out.bam",
        ])
        XCTAssertEqual(featureCounts.outputPolicy, [
            "featurecounts/counts.txt": .stays, "featurecounts/counts.txt.summary": .home,
            "featurecounts/Aligned.sortedByCoord.out.bam.featureCounts.bam": .stays,
        ])
        XCTAssertEqual(try step("samtools-sort").arguments, [
            "sort", "-@", "8", "-m", "768M", "-o", "umi/assigned.bam", "featurecounts/Aligned.sortedByCoord.out.bam.featureCounts.bam",
        ])
        XCTAssertEqual(try step("samtools-index").arguments, ["index", "umi/assigned.bam"])
        XCTAssertEqual(try step("samtools-index").outputPolicy, ["umi/assigned.bam.bai": .stays])
        let count = try step("umi-count")
        XCTAssertEqual(count.arguments, [
            "count", "--per-gene", "--gene-tag=XT", "--assigned-status-tag=XS", "--method=directional",
            "-I", "umi/assigned.bam", "-S", "umi/counts.tsv", "-L", "umi/count.log",
        ])
        XCTAssertEqual(count.inputs, ["umi/assigned.bam", "umi/assigned.bam.bai"])
        XCTAssertEqual(count.outputPolicy, ["umi/counts.tsv": .home, "umi/count.log": .stays])
        XCTAssertEqual(plan.pipeline?.modality, .bulk)
        let route = try XCTUnwrap(plan.pipeline?.route)
        XCTAssertEqual([route.id, route.tool, route.toolVersion], ["umi-counts", "umi_tools", "1.1.6"])
        XCTAssertEqual(route.settings.keys.sorted(), [
            "countingGTF", "counts", "duplicates", "index", "mapping", "trimming", "umiExtraction", "umiGrouping", "umiKit",
            "umiLength", "umiMotif", "umiRead",
        ], "the check's pairs and bars change no count, so they are no route key")
        XCTAssertEqual(made.stagedReferencePaths.count, 3, "each index file is read where the index batch left it")
        _ = try ExecutionPlan.decode(try plan.encoded())
    }

    static let umiWords = "Duplicates: removed with UMIs by umi_tools 1.1.6 count --per-gene --method=directional. The reads of one "
        + "gene that carry one UMI count as one molecule, and a UMI one base from a UMI of the gene with at least twice its "
        + "reads, less one, counts with that UMI. The UMI is the 16 bases after ATCAATC on Read 1 (kit preset quartz-seq2-x910)."

    /// M2 item 2: the entry names the UMI step in words set from the kit preset, with source `preset`, for staged reads,
    /// whose import is Not recorded, and for an import that kept duplicates. Reads the import deduplicated without UMIs
    /// are refused in words that say what to do (the lane's proposal, BIO reads it).
    func testDuplicatesEntryNamesTheUMIStepAndReadsDeduplicatedAtImportAreRefused() async throws {
        let plan = try await made().plan
        let entry = try XCTUnwrap(plan.pipeline?.settings.first { $0.id == "duplicates" })
        XCTAssertEqual(entry.source, .preset)
        XCTAssertEqual(entry.value, Self.umiWords + " Whether the reads lost duplicates before this step is Not recorded (the "
            + "bundle holds no import record that names its steps).")
        XCTAssertEqual(plan.pipeline?.route?.settings["duplicates"], entry.value, "the plan keeps the sample form")

        var kept = c9Sample()
        kept.duplicates = SalmonQuantRecordLines.duplicates
        let keptEntry = try await made(sample: kept).plan.pipeline?.settings.first { $0.id == "duplicates" }
        XCTAssertEqual(keptEntry?.value, Self.umiWords + " The import removed none.")
        XCTAssertEqual(keptEntry?.source, .preset)

        var removed = c9Sample()
        removed.duplicates = "Duplicates: removed at import by Deduplicate, without UMIs. This count removes none."
        removed.duplicatesSource = .recipe
        do {
            _ = try await made(sample: removed)
            XCTFail("reads deduplicated without UMIs wrote a UMI plan")
        } catch let error as SalmonPlanError {
            XCTAssertEqual(error.message, "The sample SRR28155077 lost duplicates at import without UMIs (Duplicates: removed at "
                + "import by Deduplicate, without UMIs. This count removes none.). The UMI step counts each molecule by its UMI "
                + "and needs every read the sequencer gave, so no plan was written. Import the reads again with duplicates kept, "
                + "then write the plan again.")
        }
    }

    /// M2 item 3 (gate G4): one row a sample from the `home` files of the Docker run of `umi_reads.py`'s reads. S1's check
    /// passed and its 13 genes count 24 UMIs each. S2's Read 1 holds no motif, so its check failed and no later step ran.
    func testPerSampleReportReadsTheHomeFilesOfTheDockerRun() throws {
        let home = Self.fixture.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)
        let rows = try ["S1", "S2"].map { try UMIPlanReport.row(sample: $0, result: home.appendingPathComponent($0)) }
        XCTAssertEqual(UMIPlanReport.tsv(rows), [
            "sample\tcheck\tpairs read\twithin one mismatch %\texact %\tdistinct UMIs %\textraction kept %\tSTAR too short %\tUMI counts\tgenes counted",
            "S1\tpassed\t364\t100.0\t100.0\t85.7\t100.0\t0.0\t312\t13",
            "S2\tfailed\t364\t0.0\t0.0\t0.0\tnot run\tnot run\tnot run\tnot run",
        ].joined(separator: "\n") + "\n")
        XCTAssertThrowsError(try UMIPlanReport.row(sample: "S3", result: home)) { error in
            XCTAssertEqual(error.localizedDescription, "The result of S3 holds no umi-check/pair1-layout-check.json, the UMI layout "
                + "check every sample of the UMI branch runs first, so the report has no row for it. Copy the sample's result folder whole.")
        }
    }

    /// EX-UMI-M2-BIO should-fix 1: a lane-split sample runs both checks, then both extractions, then one STAR run on both
    /// extracted files.
    func testTwoPairsRunBothChecksThenBothExtractionsAndOneSTARRun() async throws {
        func read(_ name: String, _ fill: String) -> SalmonPlanStagedRead {
            SalmonPlanStagedRead(path: "/staging/c9/\(name)", size: 1_234_567, sha256: String(repeating: fill, count: 64))
        }
        let sample = SalmonPlan.stagedSample(name: "SRR28155077", pairs: [
            (read("SRR28155077_L1_1.fastq.gz", "1"), read("SRR28155077_L1_2.fastq.gz", "2")),
            (read("SRR28155077_L2_1.fastq.gz", "3"), read("SRR28155077_L2_2.fastq.gz", "4")),
        ], model: "HiSeq X Ten")
        let plan = try await made(sample: sample).plan
        XCTAssertEqual(plan.steps.map(\.id), [
            "umi-layout-check-pair1", "umi-layout-check-pair2", "umi-extract-pair1", "umi-extract-pair2", "star-align",
            "featurecounts", "samtools-sort", "samtools-index", "umi-count",
        ])
        let extract = try XCTUnwrap(plan.steps.first { $0.id == "umi-extract-pair2" })
        XCTAssertEqual(Array(extract.arguments.suffix(9)), [
            "-I", "inputs/pair2_R1.fastq.gz", "--read2-in", "inputs/pair2_R2.fastq.gz", "--read2-stdout",
            "-S", "umi/pair2_R2.umi.fastq.gz", "-L", "umi/pair2-extract.log",
        ])
        let star = try XCTUnwrap(plan.steps.first { $0.id == "star-align" }?.arguments)
        XCTAssertEqual(star.firstIndex(of: "--readFilesIn").map { star[$0 + 1] }, "umi/pair1_R2.umi.fastq.gz,umi/pair2_R2.umi.fastq.gz")
    }

    /// A copy of the Docker run's S1 `home` files as a sample of two pairs, with pair 2's check and, when `extracted`, its
    /// extract log, each a copy of pair 1's.
    func twoPairResult(extracted: Bool) throws -> URL {
        let home = Self.fixture.deletingLastPathComponent().appendingPathComponent("home/S1", isDirectory: true)
        let copy = root.appendingPathComponent("two-pairs-\(extracted)/S1", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: home, to: copy)
        try FileManager.default.copyItem(at: copy.appendingPathComponent("umi-check/pair1-layout-check.json"),
                                         to: copy.appendingPathComponent("umi-check/pair2-layout-check.json"))
        if extracted {
            try FileManager.default.copyItem(at: copy.appendingPathComponent("umi/pair1-extract.log"),
                                             to: copy.appendingPathComponent("umi/pair2-extract.log"))
        }
        return copy
    }

    /// EX-UMI-M2-BIO should-fix 1: the row of a sample of two pairs gives each check's shares pair by pair and the share
    /// both extractions kept.
    func testTwoPairReportGivesBothChecksAndTheShareBothExtractionsKept() throws {
        let row = try UMIPlanReport.row(sample: "S1", result: try twoPairResult(extracted: true))
        XCTAssertEqual(row.pairsRead, "364 / 364")
        XCTAssertEqual(row.exact, "100.0 / 100.0")
        XCTAssertEqual(row.extractionKept, "100.0")
    }

    /// EX-UMI-M2-BIO should-fix 3: when pair 1's extraction ran and pair 2's did not, the share reads `not run`, never pair
    /// 1's share alone as the sample's.
    func testAPartialExtractionReadsNotRun() throws {
        let row = try UMIPlanReport.row(sample: "S1", result: try twoPairResult(extracted: false))
        XCTAssertEqual(row.pairsRead, "364 / 364")
        XCTAssertEqual(row.extractionKept, "not run")
    }

    /// M2 item 2 and ARCH-ADOPT-ROUTE item 2: the UMI state joins the one writer of the result's `duplicates`, in a form
    /// with no step name and no sample count when every sample shares it. The other forms do not move.
    func testDuplicatesSettingStatesTheUMIStateInTheResultsForm() {
        let umi = "Duplicates: removed with UMIs, so the reads of one gene that carry one UMI count as one molecule."
        XCTAssertEqual(SalmonQuantRecordLines.duplicatesSetting([.umi]), umi)
        XCTAssertEqual(SalmonQuantRecordLines.duplicatesSetting([.umi, .umi, .umi]), umi)
        XCTAssertEqual(SalmonQuantRecordLines.duplicatesSetting(removed: 0, unrecorded: 0, umi: 4, of: 4), umi)
        XCTAssertEqual(SalmonQuantRecordLines.duplicatesSetting([.umi, .kept]),
                       "Duplicates: removed with UMIs for 1 of 2 samples. For the other 1: kept. LGE removes duplicates only with UMIs.")
        XCTAssertEqual(SalmonQuantRecordLines.duplicatesSetting([.kept, .kept]), SalmonQuantRecordLines.duplicates)
        XCTAssertEqual(SalmonQuantRecordLines.duplicatesSetting(removed: 1, unrecorded: 0, of: 2),
                       "Duplicates: removed at import for 1 of 2 samples, without UMIs. This count removes none.")
    }
}
