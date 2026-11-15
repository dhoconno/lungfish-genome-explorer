// STARIndexPlanTests.swift - `rnaseq index-plan`, the plan that builds a STAR index on Linux (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// The plan of a STAR index build on a small set, its key and its refusals (BIO-COUNTING-GTF item 3,
/// ARCH-COUNTING-GTF items 1 and 3, `docs/formats/executor-plan.md` Reference entries).
final class STARIndexPlanTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("star-index-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The cynomolgus mitochondrion with the SARS-CoV-2 extra in LGE's layout, built with the stand-in deriver.
    func builtSet() async throws -> ReferenceSetOutcome {
        var request = ReferenceSetMitoFixture.request(.lge)
        request.extras = [ReferenceSetExtraInput(
            name: "sars-cov-2", kind: .virus,
            fasta: ReferenceSetMitoFixture.folder.appendingPathComponent("sars-cov-2.fa"), annotation: nil)]
        let owner = ReferenceSetOwner(
            storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(request)
    }

    /// The pins that come from outside the set: the executor, the image's manifest and its tools.
    func pins(star version: STARIndexVersion = .v2_7_11b) -> STARIndexPlanPins {
        let zeros = String(repeating: "0", count: 64)
        return STARIndexPlanPins(
            executor: ExecutorPlanSourceFile(
                url: root.appendingPathComponent("lungfish-executor"), sha256: String(repeating: "a", count: 64), size: 1000),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: String(repeating: "0", count: 40), targetTriple: "x86_64-swift-linux-musl",
                toolchainID: "test", toolchainSHA256: zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: zeros),
            imageManifest: PlanImageManifestPin(sha256: String(repeating: "b", count: 64), size: 4000),
            star: PlanToolPin(id: "STAR", version: version.rawValue, build: "h0_0"),
            decompressor: PlanToolPin(id: "pigz", version: "2.8", build: "h0_0"))
    }

    func request(_ set: URL, star: STARIndexVersion = .v2_7_11b) -> STARIndexPlanRequest {
        STARIndexPlanRequest(setFolder: set, star: star, pins: pins(star: star))
    }

    /// The script's rule (`scripts/repro/rnaseq/gse225770/star.sh:29`): `min(14, round(log2(bases) / 2 - 1))`.
    func saIndexNbases(forBases bases: Int) -> Int {
        min(14, Int((log2(Double(bases)) / 2 - 1).rounded()))
    }

    func baseCount(_ fasta: String) throws -> Int {
        let url = ReferenceSetMitoFixture.folder.appendingPathComponent(fasta)
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix(">") }.reduce(0) { $0 + $1.count }
    }

    // MARK: - The plan pins the counting GTF, never the annotation as given

    func testThePlanPinsTheCountingGTFTheGenomeAndTheExtraAndHasNoSampleOrInput() async throws {
        let set = try await builtSet()
        let id = set.manifest.id
        let plan = try STARIndexPlan.make(request(set.url)).plan
        XCTAssertNil(plan.sample, "an index build has no sample")
        XCTAssertFalse(plan.entries.contains { $0.role == .input }, "and no input entry")
        XCTAssertEqual(plan.pipeline?.referenceSet.id, id)
        XCTAssertNil(plan.pipeline?.route)
        XCTAssertNil(plan.pipeline?.modality)
        let references = plan.entries.filter { $0.role == .reference }
        XCTAssertEqual(references.map(\.relativePath), [
            "references/\(id)/derived/genes.gtf", "references/\(id)/extras/sars-cov-2.fa",
            "references/\(id)/genome/cynomolgus-mt.fa"], "in the order of relativePath, with no annotation as given")
        let gtf = try XCTUnwrap(references.first)
        XCTAssertEqual(gtf.sha256, set.manifest.derived.countingGTF?.sha256)
        XCTAssertEqual(gtf.size, set.manifest.derived.countingGTF?.size)
        XCTAssertEqual(gtf.reference?.setID, id)
        XCTAssertEqual(gtf.reference?.path, "derived/genes.gtf")
        XCTAssertFalse(plan.entries.contains { $0.relativePath.hasPrefix("references/\(id)/annotation/") })
    }

    // MARK: - The step runs the script's argv, and each index file is its own staged output

    func testTheStepRunsStarWithTheScriptsArgvAndStagesEachIndexFileWhileLogOutComesHome() async throws {
        let set = try await builtSet()
        let id = set.manifest.id
        let plan = try STARIndexPlan.make(request(set.url)).plan
        XCTAssertEqual(plan.steps.map(\.id), ["star-index"], "a plain FASTA needs no unpack step")
        let step = plan.steps[0]
        let bases = try baseCount("cynomolgus-mt.fa") + baseCount("sars-cov-2.fa")
        XCTAssertEqual(step.arguments, [
            "--runMode", "genomeGenerate", "--genomeDir", "star-index",
            "--genomeFastaFiles", "references/\(id)/genome/cynomolgus-mt.fa", "references/\(id)/extras/sars-cov-2.fa",
            "--sjdbGTFfile", "references/\(id)/derived/genes.gtf", "--runThreadN", "8",
            "--genomeSAindexNbases", "\(saIndexNbases(forBases: bases))", "--limitGenomeGenerateRAM", "32000000000",
            "--genomeSAsparseD", "2", "--outFileNamePrefix", "star-index.",
        ])
        XCTAssertEqual(step.tool, PlanToolPin(id: "STAR", version: "2.7.11b", build: "h0_0"))
        XCTAssertEqual(plan.tools.map(\.id), ["STAR"], "only the tools a step runs")
        let policy = try XCTUnwrap(step.outputPolicy)
        XCTAssertEqual(policy["star-index.Log.out"], .home)
        let staged = policy.filter { $0.value == .staged }.keys.sorted()
        XCTAssertEqual(staged, STARIndexPlan.indexFiles.map { "star-index/\($0)" }.sorted())
        XCTAssertEqual(staged.count, 15, "one staged output a file, never a folder (ARCH-M-IMAGE item 3)")
        XCTAssertEqual(Set(step.outputs), Set(policy.keys))
        XCTAssertEqual(step.deadlineSeconds, ExecutionPlan.maximumDeadlineSeconds, "no limit named, so the longest a plan allows")
        XCTAssertNoThrow(try ExecutionPlan.decode(try plan.encoded()), "the plan passes its own checks")
    }

    func testTheKeyNamesTheVersionTheArgumentsAndTheSHA256OfReferenceSetJSON() async throws {
        let set = try await builtSet()
        let key = try STARIndexPlan.make(request(set.url)).key
        let nbases = saIndexNbases(forBases: try baseCount("cynomolgus-mt.fa") + baseCount("sars-cov-2.fa"))
        XCTAssertEqual(key.folderName, "star-2.7.11b-sa\(nbases)-sparse2")
        XCTAssertEqual(key.setID, set.manifest.id)
        XCTAssertEqual(key.referenceSetSHA256, try ProvenanceFileHasher.sha256(of: set.url.appendingPathComponent("reference-set.json")))
        XCTAssertEqual(key.star, PlanToolPin(id: "STAR", version: "2.7.11b", build: "h0_0"))
        XCTAssertEqual(key.genomeSAindexNbases, nbases)
        XCTAssertEqual(key.genomeSAsparseD, 2)
        XCTAssertEqual(key.countingGTFSHA256, set.manifest.derived.countingGTF?.sha256)
        XCTAssertEqual(key.genomeFastaFiles, ["genome/cynomolgus-mt.fa", "extras/sars-cov-2.fa"], "the gentrome's order")
        let other = try STARIndexPlan.make(request(set.url, star: .v2_7_3a)).key
        XCTAssertEqual(other.folderName, "star-2.7.3a-sa\(nbases)-sparse2", "another STAR is another index")
    }

    // MARK: - A set of schema 1 is refused through RS-COUNTING-GTF's refusal, and the lane adds none of its own

    func refusal(_ body: () throws -> Void) -> String {
        do { try body() } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        return ""
    }

    func testASchema1SetIsRefusedInTheWordsOfTheRebuildWithItsThirteenGeneReason() throws {
        let set = try ReferenceSetV1Fixture.install(try ReferenceSetV1Fixture.mitoSet(), in: root)
        let id = "macaca_fascicularis-Macaca_fascicularis_5.0-refseq101-lge-3c71d550d4fa"
        let words = refusal { _ = try STARIndexPlan.make(request(set)) }
        XCTAssertTrue(words.hasPrefix("The set \(id) was built before LGE kept the GTF that STAR and featureCounts read."), words)
        XCTAssertTrue(words.contains("LGE gave 13 genes an exon from their CDS and stop codon (ND1, ND2, COX1 and 10 more)"), words)
        XCTAssertTrue(words.hasSuffix("Build the set again from the same files. It gets a new id, and \(id) stays for its salmon results."), words)
    }

    func installEnsembl107() throws -> URL {
        let set = root.appendingPathComponent("\(ReferenceSetV1Fixture.ensembl107ID).lungfishrefset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: ReferenceSetV1Fixture.ensembl107, to: set.appendingPathComponent(ReferenceSetManifest.filename))
        return set
    }

    func testTheSavedEnsembl107ManifestIsRefusedWithTheRebuildAndNoReason() throws {
        let set = try installEnsembl107()
        let id = ReferenceSetV1Fixture.ensembl107ID
        let words = refusal { _ = try STARIndexPlan.make(request(set)) }
        XCTAssertTrue(words.hasPrefix("The set \(id) was built before LGE kept the GTF that STAR and featureCounts read."), words)
        XCTAssertTrue(words.contains("Build the set again from the same files. It gets a new id, and \(id) stays"), words)
        XCTAssertFalse(words.contains("LGE gave"), "its derivation adds nothing, so there is no reason before the rebuild")
    }

    // MARK: - The submit values of the job (BIO-LINUX-HOST item 9)

    func testTheMeasuredFiguresOfMacacaFascicularis60AreEightCPUs40960MiBAnd120GiB() throws {
        let manifest = try ReferenceSetManifest.load(from: try installEnsembl107())
        XCTAssertEqual(manifest.assembly.name, "Macaca_fascicularis_6.0")
        let figures = try STARIndexSubmit.figures(for: manifest)
        XCTAssertEqual([figures.cpus, Int(figures.memoryMiB), figures.diskGiB], [8, 40_960, 120])
        XCTAssertEqual(try STARIndexSubmit.figures(for: manifest, memoryMiB: 49_152).memoryMiB, 49_152, "the person's value wins")
    }

    func testAnUnmeasuredGenomeIsRefusedWithoutTheFiguresFromThePersonAndTakesThemWithThem() async throws {
        let set = try await builtSet()
        let words = refusal { _ = try STARIndexSubmit.figures(for: set.manifest) }
        XCTAssertTrue(words.contains("needs its own SMOKE figures"), words)
        for option in ["--request-memory-mib", "--request-cpus", "--request-disk-gib"] { XCTAssertTrue(words.contains(option), words) }
        let given = try STARIndexSubmit.figures(for: set.manifest, memoryMiB: 8192, cpus: 4, diskGiB: 20)
        XCTAssertEqual([given.cpus, Int(given.memoryMiB), given.diskGiB], [4, 8192, 20])
    }

    // MARK: - The batch goes through EX-SUBMIT's core and remaps each staged file

    func testTheBatchRemapsEachIndexFileToTheStagedFolderOfItsJobAndPutsNoRequestInThePlan() async throws {
        let set = try await builtSet()
        let made = try STARIndexPlan.make(request(set.url))
        let image = ExecutorPlanImageRecord(
            sif: ExecutorPlanImageFile(fileName: "lge-tools-test.sif", sha256: String(repeating: "e", count: 64), size: 1000),
            imageManifest: pins().imageManifest)
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try STARIndexSubmit.write(
            made, figures: .init(memoryMiB: 8192, cpus: 4, diskGiB: 20), image: image,
            layout: ExecutorPlanStagingLayout(folder: "/staging/group/project", batch: "star-index"), into: folder)
        XCTAssertEqual(batch.samples, ["index"])
        let submit = try String(contentsOf: folder.appendingPathComponent("sample.sub"), encoding: .utf8)
        for file in STARIndexPlan.indexFiles {
            XCTAssertTrue(submit.contains("plan/star-index/\(file) = "), file)
            XCTAssertTrue(submit.contains("/staged/star-index/\(file)"), file)
        }
        XCTAssertTrue(submit.contains("plan/star-index.Log.out"), "the log comes home")
        XCTAssertFalse(String(decoding: try made.plan.encoded(), as: UTF8.self).contains("request_"), "no submit value in a plan byte")
    }
}
