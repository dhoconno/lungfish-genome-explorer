// SoloPlanTests.swift - The schema 2 plan of one library's STARsolo counts on Linux and its barcode list (Phase 5.3 lane
// SOLO-PLAN, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SoloPlanTests: XCTestCase {
    var root: URL!
    var storageRoot: URL!

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/rnaseq/solo-plan", isDirectory: true)
    static let staging = "/staging/groups/lge/solo-plan"
    static let indexFolder = "\(staging)/batches/solo-index/index/staged/star-index"
    static let star = PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9")
    static let pigz = PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_2")
    static let sha3M = "843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b"
    static let sha737K = "b0dda4b114d8fc7ea8def94fb472e6205c1831a72e3ac245ed13cc332d9f20d1"
    static let image3M = ImageDataFile(path: "/opt/lge/barcodes/3M-february-2018.txt", role: "barcodeList", sha256: sha3M, size: 115_512_960)
    static let image737K = ImageDataFile(path: "/opt/lge/barcodes/737K-august-2016.txt", role: "barcodeList", sha256: sha737K, size: 12_533_760)
    static let forbidden = ["matches", "equivalent", "compatible", "same counts as"]
    let layout = ExecutorPlanStagingLayout(folder: staging, batch: "solo-counts")

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "solo-plan")
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

    /// An adopted index record of the set as `rnaseq index-adopt` writes one, with stand-in files that a run left under
    /// ``indexFolder``. With `list` it is the 10x variant, whose `gtfFilter` holds what the rule made from the set, or
    /// `filter` when a test names other facts.
    func record(_ set: ReferenceSetOutcome, list: TenxGTFFilter.List? = .mkgtf300, filter: STARIndexKey.GTFFilter? = nil,
                setID: String? = nil, gtfSHA256: String? = nil, tool: PlanToolPin = star) throws -> STARIndexRecord {
        let gtf = try set.manifest.requireCountingGTF()
        let made = try list.map { try TenxGTFFilter.make(from: set.url, manifest: set.manifest, list: $0) }
        let files = ["Genome", "SA", "SAindex", "chrName.txt"].map { name in
            let data = Data("\(name) stand-in\n".utf8)
            return STARIndexRecord.File(path: name, planPath: "star-index/\(name)", stagingPath: "\(Self.indexFolder)/\(name)",
                                        bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let key = STARIndexKey(
            folderName: STARIndexKey.folderName(star: tool.version, nbases: 6, sparseD: 2, filter: list),
            setID: setID ?? set.manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: tool,
            genomeSAindexNbases: 6, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: ["genome/cynomolgus-mt.fa"],
            countingGTFSHA256: gtfSHA256 ?? gtf.sha256, gtfFilter: filter ?? made.map(STARIndexKey.GTFFilter.init))
        return STARIndexRecord(setID: setID ?? set.manifest.id, key: key, tool: tool, files: files)
    }

    /// The pins from outside the set, with the image's STAR 2.7.11b and pigz builds and the manifest's barcode lists.
    func pins(files: [ImageDataFile] = [image3M], star: PlanToolPin = star) -> SoloPlanPins {
        let zeros = String(repeating: "0", count: 64)
        return SoloPlanPins(
            executor: ExecutorPlanSourceFile(
                url: root.appendingPathComponent("lungfish-executor"), sha256: String(repeating: "a", count: 64), size: 1000),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros),
            imageManifest: PlanImageManifestPin(sha256: String(repeating: "b", count: 64), size: 4000),
            star: star, decompressor: Self.pigz, imageFiles: files)
    }

    /// The fixture's pair of `preset`, written by `scripts/repro/rnaseq/fixtures/solo_reads.py`, as reads staged under
    /// `<staging>/input/<folder>/`, so the plan pins each by its SHA-256 and size and copies none.
    static func sample(_ preset: SoloPlanPreset, gzip: Bool = false) throws -> SalmonPlanSample {
        let folder = preset == .fivePrimeV2 ? "5p-v2" : "3p-v3"
        let reads = try ["R1", "R2"].map { mate -> SalmonPlanStagedRead in
            let name = "S1_S1_L001_\(mate)_001.fastq"
            let data = try Data(contentsOf: fixtures.appendingPathComponent("reads/\(folder)/\(name)"))
            return SalmonPlanStagedRead(path: "\(staging)/input/\(folder)/\(name)\(gzip ? ".gz" : "")", size: Int64(data.count),
                                        sha256: PortableDigest.sha256Hex(of: data))
        }
        return SalmonPlan.stagedSample(name: "S1", pairs: [(reads[0], reads[1])])
    }

    func made(_ preset: SoloPlanPreset, set: ReferenceSetOutcome, record: STARIndexRecord? = nil, supplied: ExecutorPlanSourceFile? = nil,
              files: [ImageDataFile] = [image3M], sample: SalmonPlanSample? = nil, expectedCells: Int? = nil) throws -> SoloPlanOutcome {
        let pins = pins(files: files)
        let index = try ExecutorPlanStagedIndex.pin(try record ?? self.record(set), star: pins.star, layout: layout)
        return try SoloPlan.make(SoloPlanRequest(
            setFolder: set.url, sample: try sample ?? Self.sample(preset), pins: pins, preset: preset, index: index,
            suppliedList: supplied, expectedCells: expectedCells))
    }

    func supplied(_ sha256: String, size: Int64) -> ExecutorPlanSourceFile {
        ExecutorPlanSourceFile(url: root.appendingPathComponent("list.txt"), sha256: sha256, size: size)
    }

    func refusal(_ body: () throws -> Void) -> String {
        do {
            try body()
            XCTFail("no refusal")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func setting(_ plan: ExecutionPlan, _ id: String) -> PlanPipelineSetting? {
        plan.pipeline?.settings.first { $0.id == id }
    }

    // MARK: - Item 1, the plan

    /// Red first. The plan bytes of the three presets on `refset-mito`: 3' v3 and its introns preset on the image's 3M
    /// list, and 5' v2 on a supplied 737K list (BIO-SOLO-GTF item 10). With `LUNGFISH_SOLO_PLAN_PINS` naming a folder the
    /// test writes the bytes it made there, for a person to read before they are pinned.
    func testThePinnedPlansOfTheThreePresetsOnRefsetMito() async throws {
        let set = try await builtSet()
        for preset in SoloPlanPreset.allCases {
            let list = preset == .fivePrimeV2 ? supplied(Self.sha737K, size: 12_533_760) : nil
            let bytes = try made(preset, set: set, supplied: list).plan.encoded()
            let name = "plan-\(preset.rawValue).json"
            if let folder = ProcessInfo.processInfo.environment["LUNGFISH_SOLO_PLAN_PINS"], !folder.isEmpty {
                try bytes.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
            XCTAssertEqual(bytes, try Data(contentsOf: Self.fixtures.appendingPathComponent(name)), name)
            XCTAssertNoThrow(try ExecutionPlan.decode(bytes), name)
        }
    }

    /// One STARsolo step with the 5.0 argv of `tenx-controls/run.sh:188-196`, the preset's `solo_args` and
    /// `--readFilesIn R2 R1`, on the index by the variant's key, with no GTF entry and no `--soloCBwhitelist None`.
    func testTheStepRunsTheFiveZeroArgvOnReadTwoThenReadOneAndNamesNoGTF() async throws {
        let set = try await builtSet()
        let id = set.manifest.id, key = "star-2.7.11b-sa6-sparse2-tenx1-mkgtf-3.0.0"
        let tail = ["--soloCBmatchWLtype", "1MM_multi_Nbase_pseudocounts", "--soloUMIfiltering", "MultiGeneUMI_CR",
                    "--soloUMIdedup", "1MM_CR", "--soloCellFilter", "EmptyDrops_CR", "3000", "0.99", "10", "45000", "90000",
                    "500", "0.01", "20000", "0.01", "10000", "--soloFeatures", "Gene", "GeneFull", "GeneFull_Ex50pAS",
                    "--outSAMtype", "None", "--outFileNamePrefix", "solo/"]
        let clip = ["--clipAdapterType", "CellRanger4", "--outFilterScoreMin", "30"]
        let presets: [(SoloPlanPreset, String, [String])] = [
            (.threePrimeV3, "3M-february-2018", ["--soloUMIlen", "12", "--soloStrand", "Forward"]),
            (.fivePrimeV2, "737K-august-2016", ["--soloUMIlen", "10", "--soloStrand", "Reverse"] + clip),
            (.threePrimeV3Introns, "3M-february-2018", ["--soloUMIlen", "12", "--soloStrand", "Forward"] + clip),
        ]
        for (preset, list, args) in presets {
            let supplied = preset == .fivePrimeV2 ? supplied(Self.sha737K, size: 12_533_760) : nil
            let plan = try made(preset, set: set, supplied: supplied).plan
            XCTAssertEqual(plan.steps.count, 1)
            let step = try XCTUnwrap(plan.steps.first)
            XCTAssertEqual(step.tool, Self.star)
            XCTAssertEqual(step.arguments, ["--runThreadN", "8", "--genomeDir", "references/\(id)/indexes/\(key)", "--readFilesIn",
                                            "inputs/pair1_R2.fastq", "inputs/pair1_R1.fastq", "--soloType", "CB_UMI_Simple",
                                            "--soloCBstart", "1", "--soloCBlen", "16", "--soloUMIstart", "17",
                                            "--soloCBwhitelist", "barcodes/\(list).txt"] + args + tail)
            XCTAssertFalse(plan.entries.contains { $0.relativePath.hasSuffix(".gtf") }, "the step reads genes through the index")
            XCTAssertFalse(step.arguments.contains("--sjdbGTFfile"))
            XCTAssertEqual(plan.entries.last?.barcodeList?.name, list)
            XCTAssertEqual(plan.tools, [Self.star])
            XCTAssertEqual(plan.pipeline?.modality, .singleCell)
            XCTAssertEqual(plan.pipeline?.preset, PlanPipelinePreset(id: preset.rawValue, name: preset.name))
        }
        let cells = try made(.threePrimeV3, set: set, expectedCells: 1000).plan
        XCTAssertEqual(cells.steps.first?.arguments.firstIndex(of: "1000"), cells.steps.first?.arguments.firstIndex(of: "EmptyDrops_CR").map { $0 + 1 })
        XCTAssertEqual(setting(cells, "cellFilter")?.source, .option)
        let gzip = try made(.threePrimeV3, set: set, sample: try Self.sample(.threePrimeV3, gzip: true)).plan
        XCTAssertEqual(gzip.tools, [Self.star, Self.pigz])
        let at = try XCTUnwrap(gzip.steps.first?.arguments.firstIndex(of: "--readFilesCommand"))
        XCTAssertEqual(gzip.steps.first?.arguments[at...].prefix(4), ["--readFilesCommand", "pigz", "-d", "-c"])
    }

    /// The `home` outputs are `Log.final.out` and, for `Gene` and `GeneFull_Ex50pAS`, the raw and filtered matrix files
    /// and `Summary.csv`, which covers what `SingleCellFolderReader.read` reads below `solo/`.
    func testTheHomeOutputsCoverWhatTheReaderAndGXRead() async throws {
        let set = try await builtSet()
        let step = try XCTUnwrap(try made(.threePrimeV3, set: set).plan.steps.first)
        var expected = ["solo/Log.final.out"]
        for feature in ["Gene", "GeneFull_Ex50pAS"] {
            for matrix in ["raw", "filtered"] {
                expected += ["barcodes.tsv", "features.tsv", "matrix.mtx"].map { "solo/Solo.out/\(feature)/\(matrix)/\($0)" }
            }
            expected.append("solo/Solo.out/\(feature)/Summary.csv")
        }
        XCTAssertEqual(step.outputs, expected)
        XCTAssertEqual(step.outputPolicy, Dictionary(uniqueKeysWithValues: expected.map { ($0, PlanOutputPolicy.home) }))
    }

    /// BIO-SOLO-GTF item 4 from the index record (ARCH-SOLO-GTF item 5): the rule, its list, the made file's SHA-256 and
    /// size, the SHA-256 of `derived/genes.gtf`, the set id and the genes left out. A bulk index says no rule ran
    /// (SOLO-PLAN-M1-BIO R4).
    func testThePlanStatesTheFilterFactsFromTheIndexRecordAndABulkIndexNamesNoRule() async throws {
        let set = try await builtSet()
        let id = set.manifest.id, derived = try set.manifest.requireCountingGTF().sha256
        let facts = STARIndexKey.GTFFilter(rule: "tenx", ruleVersion: 1, list: "mkgtf-3.0.0", sha256: String(repeating: "e", count: 64),
                                           size: 999, genesLeftOut: 2)
        let plan = try made(.threePrimeV3, set: set, record: try record(set, filter: facts)).plan
        let key = "star-2.7.11b-sa6-sparse2-tenx1-mkgtf-3.0.0"
        XCTAssertEqual(plan.pipeline?.route?.settings["countingGTF"],
                       "made/tenx1-mkgtf-3.0.0/genes.gtf, which the 10x filter rule tenx version 1 made with the list mkgtf-3.0.0 "
                       + "from derived/genes.gtf (SHA-256 \(derived)) of the set \(id): SHA-256 \(facts.sha256), 999 bytes, 2 genes "
                       + "left out. STARsolo reads its genes through the index \(key).")
        let bulk = try made(.threePrimeV3, set: set, record: try record(set, list: nil)).plan
        XCTAssertEqual(bulk.pipeline?.route?.settings["countingGTF"],
                       "derived/genes.gtf (SHA-256 \(derived)) of the set \(id), with no 10x filter rule. STARsolo reads its genes "
                       + "through the index star-2.7.11b-sa6-sparse2.")
        XCTAssertEqual(plan.pipeline?.route?.settings["index"], key)
        XCTAssertEqual(plan.pipeline?.route?.settings["trimming"], "Reads not trimmed")
    }

    /// The introns preset's name and every word of its plan avoid the words the plan forbids (reproduction plan, :86).
    func testTheIntronsPresetsWordsNameNoAgreement() async throws {
        let set = try await builtSet()
        let plan = try made(.threePrimeV3Introns, set: set).plan
        XCTAssertEqual(SoloPlanPreset.threePrimeV3Introns.name, "Exons and introns (STARsolo GeneFull_Ex50pAS)")
        XCTAssertEqual(plan.pipeline?.route?.id, "starsolo-genefull-ex50pas")
        let text = String(decoding: try plan.encoded(), as: UTF8.self).lowercased()
        for word in Self.forbidden { XCTAssertFalse(text.contains(word), word) }
    }

    // MARK: - Item 2, the barcode list (each refusal red first)

    /// BIO item 8. A known list of the other chemistry is refused in words that name the preset and both lists.
    func testAKnownListOfTheOtherChemistryIsRefusedNamingThePresetAndBothLists() {
        let crossed: [(SoloPlanPreset, String, Int64)] = [(.fivePrimeV2, Self.sha3M, 115_512_960), (.threePrimeV3, Self.sha737K, 12_533_760)]
        for (preset, sha, size) in crossed {
            let words = refusal { _ = try SoloPlanBarcodes.choose(preset: preset, supplied: supplied(sha, size: size), imageFiles: [Self.image3M]) }
            for part in [preset.name, "3M-february-2018", "737K-august-2016", Self.sha3M, Self.sha737K, "with no error"] {
                XCTAssertTrue(words.contains(part), "\(part) in \(words)")
            }
        }
    }

    /// BIO item 7 and `executor-plan.md:148`. A list that is neither known list, a cut list included, is refused.
    func testAListThatIsNeitherKnownListACutListIncludedIsRefused() {
        let cut = String(repeating: "ab", count: 32)
        let words = refusal { _ = try SoloPlanBarcodes.choose(preset: .threePrimeV3, supplied: supplied(cut, size: 1_700_000), imageFiles: [Self.image3M]) }
        for part in [cut, "neither known list", "3M-february-2018", "737K-august-2016", "6,794,880", "737,280", "never a cut"] {
            XCTAssertTrue(words.contains(part), "\(part) in \(words)")
        }
    }

    /// BIO item 9. `image` when the pinned manifest's `files` holds the list by SHA-256, else `supplied`, and a supplied
    /// list equal to the image's keeps both facts.
    func testTheSourceIsImageWhenTheManifestHoldsTheListAndSuppliedOtherwise() throws {
        let fromImage = try SoloPlanBarcodes.choose(preset: .threePrimeV3, supplied: nil, imageFiles: [Self.image3M])
        XCTAssertEqual(fromImage.entry, PlanEntry(role: .barcodeList, relativePath: "barcodes/3M-february-2018.txt", sha256: Self.sha3M,
                                                  size: 115_512_960, barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: .image)))
        XCTAssertEqual(fromImage.words, "list in the tool image")
        let equal = try SoloPlanBarcodes.choose(preset: .threePrimeV3, supplied: supplied(Self.sha3M, size: 115_512_960), imageFiles: [Self.image3M])
        XCTAssertEqual(equal.entry.barcodeList?.source, .image)
        XCTAssertEqual(equal.words, "list supplied by the user, equal by SHA-256 to the list in the tool image")
        let own = try SoloPlanBarcodes.choose(preset: .threePrimeV3, supplied: supplied(Self.sha3M, size: 115_512_960), imageFiles: [])
        XCTAssertEqual(own.entry.barcodeList?.source, .supplied)
        XCTAssertEqual(own.words, "list supplied by the user")
        let none = refusal { _ = try SoloPlanBarcodes.choose(preset: .threePrimeV3, supplied: nil, imageFiles: []) }
        XCTAssertTrue(none.contains("--barcode-list") && none.contains("3M-february-2018"), none)
    }

    /// BIO item 10. Until the manifest lists 737K, 5' v2 takes only a supplied list of 737,280 lines with its SHA-256, and
    /// once the manifest lists it the source is `image` with no code change.
    func testFivePrimeV2TakesASuppliedListUntilTheManifestListsIt() async throws {
        let none = refusal { _ = try SoloPlanBarcodes.choose(preset: .fivePrimeV2, supplied: nil, imageFiles: [Self.image3M]) }
        for part in ["737K-august-2016", Self.sha737K, "737,280", "--barcode-list"] { XCTAssertTrue(none.contains(part), "\(part) in \(none)") }
        let given = try SoloPlanBarcodes.choose(preset: .fivePrimeV2, supplied: supplied(Self.sha737K, size: 12_533_760), imageFiles: [Self.image3M])
        XCTAssertEqual(given.entry.barcodeList, PlanBarcodeListIdentity(name: "737K-august-2016", source: .supplied))
        let later = try SoloPlanBarcodes.choose(preset: .fivePrimeV2, supplied: nil, imageFiles: [Self.image3M, Self.image737K])
        XCTAssertEqual(later.entry.barcodeList?.source, .image)
        let set = try await builtSet()
        let plan = try made(.fivePrimeV2, set: set, supplied: supplied(Self.sha737K, size: 12_533_760)).plan
        XCTAssertEqual(setting(plan, "barcodeListSource")?.value, "list supplied by the user")
        XCTAssertEqual(plan.pipeline?.route?.settings["barcodeList"], "737K-august-2016, SHA-256 \(Self.sha737K)")
    }

    // MARK: - Refusals and the batch

    /// An index of another set or of another `derived/genes.gtf`, a STAR that is not 2.7.11b, single reads and a mix of
    /// gzip and plain reads are refused in words before a plan is written.
    func testAnIndexOfAnotherSetOrGTFAnOlderSTARSingleReadsAndMixedReadsAreRefused() async throws {
        let set = try await builtSet()
        let other = refusal { _ = try made(.threePrimeV3, set: set, record: try record(set, setID: "other-set")) }
        XCTAssertTrue(other.contains("other-set") && other.contains(set.manifest.id), other)
        let gtf = refusal { _ = try made(.threePrimeV3, set: set, record: try record(set, gtfSHA256: String(repeating: "f", count: 64))) }
        XCTAssertTrue(gtf.contains("derived/genes.gtf") && gtf.contains("rnaseq index-plan"), gtf)
        let old = PlanToolPin(id: "STAR", version: "2.7.3a", build: "h5ca1c30_1")
        let older = refusal {
            let index = try ExecutorPlanStagedIndex.pin(try record(set, tool: old), star: old, layout: layout)
            _ = try SoloPlan.make(SoloPlanRequest(setFolder: set.url, sample: try Self.sample(.threePrimeV3), pins: pins(star: old),
                                                  preset: .threePrimeV3, index: index))
        }
        XCTAssertTrue(older.contains("STAR 2.7.11b") && older.contains("2.7.3a"), older)
        let reads = try Self.sample(.threePrimeV3)
        var single = reads
        (single.pairs, single.singles) = ([], [reads.pairs[0].r2])
        let one = refusal { _ = try made(.threePrimeV3, set: set, sample: single) }
        XCTAssertTrue(one.contains("read 1") && one.contains("read 2"), one)
        var mixed = try Self.sample(.threePrimeV3, gzip: true)
        mixed.pairs[0].r1 = reads.pairs[0].r1
        let both = refusal { _ = try made(.threePrimeV3, set: set, sample: mixed) }
        XCTAssertTrue(both.contains("gzip"), both)
    }

    /// The batch reads each index file where the index run left it, the job asks for the person's figures, which a plan
    /// byte never holds, and a set with no measured figures needs all three (`reference-set.md:117`).
    func testTheBatchReadsTheIndexWhereItWasStagedAndTakesThePersonsFigures() async throws {
        let set = try await builtSet()
        let made = try made(.threePrimeV3, set: set)
        let missing = refusal { _ = try SoloPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 4096) }
        for part in ["--request-cpus", "--request-disk-gib", set.manifest.assembly.name] { XCTAssertTrue(missing.contains(part), "\(part) in \(missing)") }
        let cpus = refusal { _ = try SoloPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 4096, cpus: 4, diskGiB: 5) }
        XCTAssertTrue(cpus.contains("--runThreadN 8"), cpus)
        let figures = try SoloPlanSubmit.figures(for: set.manifest, made: made, memoryMiB: 4096, cpus: 8, diskGiB: 5)
        let job = SoloPlanSubmit.job(made, figures: figures)
        XCTAssertEqual(job.stagedReferencePaths.count, made.plan.entries.filter { $0.role == .reference }.count)
        XCTAssertTrue(job.stagedReferencePaths.values.allSatisfy { $0.hasPrefix(Self.indexFolder + "/") })
        XCTAssertEqual(job.stagedPaths, made.sample.stagedPaths)
        XCTAssertEqual(job.submit.requestMemoryMiB, 4096)
        XCTAssertFalse(String(decoding: try made.plan.encoded(), as: UTF8.self).contains("4096"))
        // Four home folders each return barcodes.tsv, features.tsv and matrix.mtx. The submit template remaps each output by
        // its whole plan path, so the rule the batch writer meets takes the step's outputs (ruling ARCH-5-1-C-3 item 1), and
        // SoloPlanLauncherConformanceTests writes the batch for the launcher tier.
        let step = try XCTUnwrap(made.plan.steps.first)
        XCTAssertNoThrow(try HTCondorValueRules.checkOutputs(home: step.outputs, staged: []))
    }
}
