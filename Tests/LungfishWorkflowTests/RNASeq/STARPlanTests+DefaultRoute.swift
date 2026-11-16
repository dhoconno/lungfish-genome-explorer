// STARPlanTests+DefaultRoute.swift - The default route on Linux, STAR 2.7.11b TranscriptomeSAM GeneCounts then salmon
// 2.11.0 on STAR's transcriptome alignments (Phase 5.3 lane EX-PLAN-STAR milestone 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

extension STARPlanTests {
    static let salmon = PlanToolPin(id: "salmon", version: "2.11.0", build: "hfa8f182_0")

    /// The set, an adopted stand-in index at `star` and the default route's plan at `scoring` on `sample`, the kept bundle by
    /// default.
    func madeDefaultRoute(
        scoring: STARPlanAlignmentScoring = .none, star: String = "2.7.11b", sample: SalmonPlanSample? = nil,
        trim: SalmonQuantTrim = .trimGalore(polyG: false), salmon: PlanToolPin? = STARPlanTests.salmon
    ) async throws -> (set: ReferenceSetOutcome, made: STARPlanOutcome) {
        let set = try await builtSet()
        let key = try adoptIndex(set, star: star)
        var reads = sample
        if reads == nil {
            reads = try await SalmonPlan.sample(bundle: try keptPairBundle(), scratch: root.appendingPathComponent("scratch"))
        }
        var pinned = try self.pins(star: star)
        pinned.salmon = salmon
        let request = STARPlanRequest(
            setFolder: set.url, sample: try XCTUnwrap(reads), pins: pinned, chain: .starSalmon,
            index: try pinIndex(set, key: key, star: star), trim: trim, alignmentScoring: scoring)
        return (set, try STARPlan.make(request))
    }

    // MARK: - The default route (M3 item 1, red first)

    /// STAR with the argv of `scripts/repro/rnaseq/gse225770/star.sh:42-46` and `--quantMode TranscriptomeSAM GeneCounts`
    /// (BIO-LINUX-HOST item 1), every path relative to the work root, then salmon `quant -a` on STAR's transcriptome BAM
    /// against the set's `derived/transcripts.fa`, whose four files that `SalmonQuantFolderReader` reads come home.
    func testTheDefaultRouteMapsWithTranscriptomeSAMGeneCountsThenCountsTheTranscriptomeBAMWithSalmon() async throws {
        let (set, made) = try await madeDefaultRoute(sample: stagedSample(pairs: 1))
        let (plan, id) = (made.plan, set.manifest.id)
        let index = "references/\(id)/indexes/star-2.7.11b-sa7-sparse2"
        XCTAssertEqual(plan.steps.map(\.id), ["trim-pair1", "star-align", "salmon-quant"])
        XCTAssertEqual(plan.steps[1].arguments, [
            "--genomeDir", index, "--readFilesIn", "trim-pair1/pair1_R1_val_1.fq.gz", "trim-pair1/pair1_R2_val_2.fq.gz",
            "--runThreadN", "8", "--outFileNamePrefix", "star/", "--outSAMtype", "BAM", "Unsorted",
            "--sjdbGTFfile", "references/\(id)/derived/genes.gtf", "--outSAMattrRGline", "ID:SRR1", "SM:SRR1",
            "--quantMode", "TranscriptomeSAM", "GeneCounts", "--twopassMode", "Basic", "--readFilesCommand", "pigz", "-d", "-c",
            "--runRNGseed", "0", "--outFilterMultimapNmax", "20", "--alignSJDBoverhangMin", "1",
            "--outSAMattributes", "NH", "HI", "AS", "NM", "MD", "--quantTranscriptomeSAMoutput", "BanSingleEnd",
        ])
        XCTAssertEqual(plan.steps[1].outputPolicy, [
            "star/Log.final.out": .home, "star/ReadsPerGene.out.tab": .home, "star/Aligned.out.bam": .stays,
            "star/Aligned.toTranscriptome.out.bam": .stays,
        ])
        let salmon = plan.steps[2]
        XCTAssertEqual(salmon.tool, Self.salmon)
        XCTAssertEqual(salmon.arguments, ["quant", "-l", "A", "-t", "references/\(id)/derived/transcripts.fa",
                                          "-a", "star/Aligned.toTranscriptome.out.bam", "-p", "8", "-o", "quant"])
        XCTAssertEqual(salmon.outputPolicy, Dictionary(uniqueKeysWithValues: SalmonQuantFolderReader.readFiles.map {
            ("quant/\($0)", PlanOutputPolicy.home) }))
        XCTAssertEqual(salmon.inputs, ["star/Aligned.toTranscriptome.out.bam", "references/\(id)/derived/transcripts.fa"])
        XCTAssertEqual(plan.tools.map(\.id), ["STAR", "pigz", "salmon", "trim_galore"])
        let derived: [(String, ReferenceSetManifest.DerivedFile?)] = [
            ("derived/genes.gtf", set.manifest.derived.countingGTF), ("derived/transcripts.fa", set.manifest.derived.transcripts)]
        for (path, file) in derived {
            let entry = try XCTUnwrap(plan.entries.first { $0.relativePath == "references/\(id)/\(path)" }, path)
            XCTAssertEqual([entry.sha256, entry.reference?.path], [file?.sha256, path])
            XCTAssertEqual(made.sources[entry.relativePath], set.url.appendingPathComponent(path))
        }
        XCTAssertFalse(plan.entries.contains { $0.relativePath.contains("/annotation/") }, "never the annotation as given")
        let route = try XCTUnwrap(plan.pipeline?.route)
        XCTAssertEqual([route.id, route.tool, route.toolVersion], ["star-salmon", "salmon", "2.11.0"])
        XCTAssertEqual(route.settings.keys.sorted(), ["adapter", "alignmentScores", "alignmentScoring", "countingGTF", "counts",
                                                      "duplicates", "geneSums", "index", "libraryType", "mapping", "multimapNmax",
                                                      "transcripts", "trimming"])
        XCTAssertEqual(route.settings["libraryType"], "A")
        XCTAssertEqual(made.stagedReferencePaths["\(index)/SA"],
                       "/staging/groups/lab/batches/m-index-2.7.11b/index/staged/star-index/SA")
    }

    /// `alignmentScoring` `none` passes no flag and `errorModel` passes `--errorModel` to salmon, in the argv, in
    /// `route.settings` and in the record line of ADJ-ROUTE item 5, and both plans' bytes are pinned on the fixture.
    func testAlignmentScoringNonePassesNoFlagAndErrorModelPassesErrorModelInThePlanAndTheRecord() async throws {
        let cases: [(STARPlanAlignmentScoring, String, ImportSettingSource, String)] = [
            (.none, "off", .default, "star-2.7.11b-salmon-none.json"),
            (.errorModel, "on", .option, "star-2.7.11b-salmon-errormodel.json"),
        ]
        for (scoring, model, source, name) in cases {
            let (set, made) = try await madeDefaultRoute(scoring: scoring)
            let plan = made.plan
            let salmon = try XCTUnwrap(plan.steps.last)
            XCTAssertEqual(salmon.arguments.contains("--errorModel"), scoring == .errorModel, name)
            XCTAssertEqual(salmon.arguments.filter { $0 == "--errorModel" }.count, scoring == .errorModel ? 1 : 0, name)
            XCTAssertFalse(plan.steps.dropLast().contains { $0.arguments.contains("--errorModel") }, name)
            let entry = try XCTUnwrap(setting(plan, "alignmentScoring"))
            XCTAssertEqual([entry.value, entry.label], [scoring.rawValue, "Alignment scoring"])
            XCTAssertEqual(entry.source, source)
            XCTAssertEqual(setting(plan, "alignmentScores")?.value,
                           "Alignment scores: none in the BAM (STAR writes no AS tag to the transcriptome BAM); salmon error model: \(model)")
            XCTAssertEqual(setting(plan, "trimming")?.value, "Poly-G trimming: off (LGE default)")
            XCTAssertEqual(setting(plan, "duplicates")?.value, "Duplicates: kept. LGE removes duplicates only with UMIs.")
            XCTAssertEqual(setting(plan, "adapter")?.value, "Adapter: chosen by Trim Galore 2.3.0 from read 1 (auto-detection)")
            let transcripts = set.manifest.derived.transcripts
            XCTAssertEqual(setting(plan, "transcripts")?.value,
                           "\(transcripts.path) of the set \(set.manifest.id), SHA-256 \(transcripts.sha256)")
            for entry in plan.pipeline?.settings ?? [] {
                XCTAssertEqual(plan.pipeline?.route?.settings[entry.id], entry.value, entry.id)
            }
            try assertPinned(plan, name)
        }
    }

    /// The route maps only with STAR 2.7.11b, counts only with a salmon the image lists, keeps the scripts'
    /// `--outFilterMultimapNmax 20`, and `alignmentScoring` belongs to this route alone.
    func testTheDefaultRouteRefusesAnotherSTARNoSalmonAnotherMultimapAndScoringOnAnotherChain() async throws {
        func asyncWords(_ body: () async throws -> Void) async -> String {
            do { try await body(); return "no refusal" } catch { return error.localizedDescription }
        }
        let star273 = await asyncWords { _ = try await self.madeDefaultRoute(star: "2.7.3a", sample: self.stagedSample(pairs: 1)) }
        XCTAssertTrue(star273.contains("maps with STAR 2.7.11b") && star273.contains("--star 2.7.11b")
                      && star273.contains("rnaseq index-adopt"), star273)
        let noSalmon = await asyncWords { _ = try await self.madeDefaultRoute(sample: self.stagedSample(pairs: 1), salmon: nil) }
        XCTAssertTrue(noSalmon.contains("lists no single salmon"), noSalmon)
        let set = try await builtSet()
        let index = try pinIndex(set, key: try adoptIndex(set, star: "2.7.11b"), star: "2.7.11b")
        var pinned = try pins(star: "2.7.11b")
        pinned.salmon = Self.salmon
        func plan(_ chain: STARPlanChain, nmax: Int?, scoring: STARPlanAlignmentScoring) throws {
            _ = try STARPlan.make(STARPlanRequest(setFolder: set.url, sample: stagedSample(pairs: 1), pins: pinned, chain: chain,
                                                  index: index, trim: .none, multimapNmax: nmax, alignmentScoring: scoring))
        }
        let nmax = words { try plan(.starSalmon, nmax: 1000, scoring: .none) }
        XCTAssertTrue(nmax.contains("--outFilterMultimapNmax 20"), nmax)
        let scoring = words { try plan(.geneCounts, nmax: nil, scoring: .errorModel) }
        XCTAssertTrue(scoring.contains("STAR then salmon"), scoring)
    }
}
