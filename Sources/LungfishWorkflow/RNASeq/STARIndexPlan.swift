// STARIndexPlan.swift - The schema 2 plan that builds a STAR index of a reference set on Linux (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// The plan of `lungfish-cli rnaseq index-plan`. It has no `sample` and no `input`, names the set in `pipeline`, and pins
/// `derived/genes.gtf`, the genome and each extra in the gentrome's order, never the annotation as given
/// (BIO-COUNTING-GTF item 3). A set of schema 1 is refused through ``ReferenceSetManifest/requireCountingGTF()``, and the
/// plan adds no refusal of its own. The index is staged file by file, never as a folder (ARCH-M-IMAGE item 3).
package enum STARIndexPlan {
    package static let sampleName = "index"
    package static let genomeDirectory = "star-index"
    package static let logOutput = "star-index/Log.out"
    package static let genomeSAsparseD = 2
    /// STAR's default, which is read length minus one for 101-base reads and the value of every script of
    /// `scripts/repro/rnaseq` that sets it. The argv names it so the plan and the key pin it.
    package static let sjdbOverhang = 100
    /// 8 threads, as `scripts/repro/rnaseq/gse225770/star.sh` runs the build.
    package static let threads = 8

    /// What `STAR --runMode genomeGenerate --sjdbGTFfile` writes into `--genomeDir`, each its own `staged` output.
    package static let indexFiles = [
        "Genome", "SA", "SAindex", "chrLength.txt", "chrName.txt", "chrNameLength.txt", "chrStart.txt", "exonGeTrInfo.tab",
        "exonInfo.tab", "geneInfo.tab", "genomeParameters.txt", "sjdbInfo.txt", "sjdbList.fromGTF.out.tab", "sjdbList.out.tab",
        "transcriptInfo.tab",
    ]

    package static func make(_ request: STARIndexPlanRequest) throws -> STARIndexPlanOutcome {
        let manifest = try ReferenceSetManifest.load(from: request.setFolder)
        let gtf = try manifest.requireCountingGTF()
        let (id, pins) = (manifest.id, request.pins)
        let deadline = request.deadlineSeconds ?? ExecutionPlan.maximumDeadlineSeconds
        let inputs = [("genome", manifest.genome.path, manifest.genome.sha256)] + manifest.extras.map { ($0.name, $0.path, $0.sha256) }
        var references: [PlanEntry] = []
        var sources = [ExecutorPlanEmitter.executorPath: pins.executor.url]
        var fasta: [String] = [], steps: [PlanStep] = []
        var bases = 0
        func reference(_ path: String, _ sha256: String, _ size: Int64) -> PlanEntry {
            sources["references/\(id)/\(path)"] = request.setFolder.appendingPathComponent(path)
            return PlanEntry(role: .reference, relativePath: "references/\(id)/\(path)", sha256: sha256, size: size,
                             reference: PlanReferenceIdentity(setID: id, path: path))
        }
        for (name, path, sha256) in inputs {
            let url = request.setFolder.appendingPathComponent(path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber else {
                throw STARIndexError("The set \(id) lacks \(path), so no plan can pin it.")
            }
            references.append(reference(path, sha256, size.int64Value))
            bases += try ReferenceSetAnnotationReader.fastaRecords(url).reduce(0) { $0 + $1.length }
            let planPath = "references/\(id)/\(path)"
            guard path.hasSuffix(".gz") else { fasta.append(planPath); continue }
            let plain = "unpacked-\(name).fa"
            fasta.append(plain)
            steps.append(PlanStep(
                id: "unpack-" + String(name.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? $0 : "-" }),
                title: "Decompress \(path)", kind: .tool, tool: pins.decompressor, arguments: ["-d", "-c", planPath],
                deadlineSeconds: deadline, inputs: [planPath], outputs: [plain], standardOutput: plain,
                outputPolicy: [plain: .stays]))
        }
        // The 10x variant pins the file the rule made from derived/genes.gtf under made/, copied from the plan folder
        // (ARCH-SOLO-GTF items 1 and 2), and STAR reads it in place of derived/genes.gtf.
        let made = try request.tenxFilter.map { list -> TenxGTFFilter.Made in
            guard let folder = request.planFolder else {
                throw STARIndexError("The 10x filter needs the plan folder that its GTF is written into, and no folder was named.")
            }
            let made = try TenxGTFFilter.make(from: request.setFolder, manifest: manifest, list: list)
            sources["references/\(id)/\(list.path)"] = folder.appendingPathComponent(list.path)
            return made
        }
        if let made {
            references.append(PlanEntry(role: .reference, relativePath: "references/\(id)/\(made.list.path)", sha256: made.sha256,
                                        size: made.size, reference: PlanReferenceIdentity(setID: id, path: made.list.path)))
        } else {
            references.append(reference(gtf.path, gtf.sha256, gtf.size))
        }
        let gtfPath = "references/\(id)/\(made?.list.path ?? gtf.path)"
        let nbases = STARIndexKey.nbases(forBases: bases)
        let staged = indexFiles.map { "\(genomeDirectory)/\($0)" }
        var policy = Dictionary(uniqueKeysWithValues: staged.map { ($0, PlanOutputPolicy.staged) })
        policy[logOutput] = .home
        steps.append(PlanStep(
            id: "star-index", title: "Build the STAR index, each file its own staged output", kind: .tool, tool: pins.star,
            arguments: ["--runMode", "genomeGenerate", "--genomeDir", genomeDirectory, "--genomeFastaFiles"] + fasta + [
                "--sjdbGTFfile", gtfPath, "--sjdbOverhang", "\(sjdbOverhang)", "--runThreadN", "\(threads)",
                "--genomeSAindexNbases", "\(nbases)",
                "--limitGenomeGenerateRAM", "32000000000", "--genomeSAsparseD", "\(genomeSAsparseD)",
                "--outFileNamePrefix", "star-index/"],
            deadlineSeconds: deadline, inputs: fasta + [gtfPath], outputs: staged + [logOutput], outputPolicy: policy))
        let used = [pins.star] + (steps.count > 1 ? [pins.decompressor] : [])
        let plan = ExecutionPlan(
            entries: [PlanEntry(role: .executor, relativePath: ExecutorPlanEmitter.executorPath, sha256: pins.executor.sha256,
                                size: pins.executor.size)] + references.sorted { $0.relativePath < $1.relativePath },
            executor: pins.executorBuild, imageManifest: pins.imageManifest,
            tools: used.sorted { ($0.id, $0.version, $0.build) < ($1.id, $1.version, $1.build) }, recipe: nil,
            pipeline: PlanPipeline(
                id: "star-index", version: 1, preset: PlanPipelinePreset(id: "star-index", name: "STAR index on Linux"),
                modality: nil, route: nil,
                referenceSet: PlanPipelineReferenceSet(id: id, layout: manifest.layout.kind == "deposit" ? .deposit : .lge),
                settings: made.map { [PlanPipelineSetting(
                    id: "tenxFilter", label: "10x filter rule", value: $0.list.folderName, source: .option)] } ?? []),
            sample: nil, storage: nil, clumping: nil, graceSeconds: 60, steps: steps)
        _ = try ExecutionPlan.decode(try plan.encoded())
        let key = STARIndexKey(
            folderName: STARIndexKey.folderName(
                star: request.star.rawValue, nbases: nbases, sparseD: genomeSAsparseD, filter: made?.list),
            setID: id, referenceSetSHA256: try ProvenanceFileHasher.sha256(of: request.setFolder.appendingPathComponent(ReferenceSetManifest.filename)),
            star: pins.star, genomeSAindexNbases: nbases, genomeSAsparseD: genomeSAsparseD, sjdbOverhang: sjdbOverhang,
            genomeFastaFiles: inputs.map(\.1),
            countingGTFSHA256: gtf.sha256, gtfFilter: made.map(STARIndexKey.GTFFilter.init))
        return STARIndexPlanOutcome(plan: plan, key: key, sources: sources, made: made)
    }
}
