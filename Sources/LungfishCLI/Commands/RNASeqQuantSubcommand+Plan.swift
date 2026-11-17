// RNASeqQuantSubcommand+Plan.swift - `rnaseq quant --write-plan`: the submit folder of salmon counts on a Linux machine (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishPortable
import LungfishWorkflow

/// The options of `rnaseq quant --write-plan`, named as `rnaseq index-plan` and `import fastq --write-plan` name them. With
/// `--write-plan` the command writes the batch of one plan a sample in place of counting, starts no process and opens no
/// connection, so a person copies the files and submits.
struct RNASeqQuantPlanOptions: ParsableArguments {
    @Option(
        name: .customLong("write-plan"),
        help: ArgumentHelp(
            "Write a plan folder for a run on a Linux machine to this new folder in place of counting here",
            discussion: "The folder is the submit folder of one batch, as import fastq --write-plan writes it, with one plan a sample. "
                + "Each plan runs Trim Galore (with --trim) and then the chain --chain names. Each plan pins its index file by file "
                + "and never builds one. Nothing runs here and nothing is submitted, so --project is not used. A run you adopt as a "
                + "result takes the manifest of the executor you built with --executor-manifest, since the plan pins it.",
            valueName: "folder"))
    var writePlan: String?

    @Option(name: .customLong("chain"), help: ArgumentHelp(
        "With --write-plan, what each plan runs after trimming (default: salmon)",
        discussion: "salmon counts the reads with salmon on the index this Mac published for the set, so run lungfish-cli rnaseq "
            + "index first. star-salmon maps with STAR 2.7.11b --quantMode TranscriptomeSAM GeneCounts and counts STAR's "
            + "transcriptome alignments with salmon -a, and star-salmon-errormodel adds salmon's --errorModel. "
            + "star-2.7.11b-genecounts and star-2.7.3a-genecounts count genes with STAR's GeneCounts, and "
            + "star-2.7.11b-featurecounts counts exons with featureCounts on STAR's alignments. Each STAR chain pins the STAR "
            + "index of its version that an earlier run built on the Linux machine and left in the staging folder. Plan that "
            + "index with lungfish-cli rnaseq index-plan --star <version>, run it, and record it with lungfish-cli rnaseq "
            + "index-adopt. --k and --decoys pick a salmon index, so a STAR chain takes neither.",
        valueName: "chain"))
    var chain: RNASeqQuantPlanChain?

    @Option(name: .customLong("star-multimap-nmax"), help: ArgumentHelp(
        "With --write-plan and a STAR GeneCounts or featureCounts chain, the most loci a read may map to (default: STAR's 10)",
        discussion: "Sets STAR's --outFilterMultimapNmax, the most loci a read may map to. STAR counts a read with more loci as "
            + "mapped to too many loci. With no option the plan passes no flag and STAR keeps its default of 10. The deposited "
            + "ReadsPerGene files of GSE304256 (C6) need a limit at or above the most loci any of its read pairs maps to, which "
            + "its authors did not document, and 1000 matched the six runs measured. Only star-2.7.11b-genecounts, "
            + "star-2.7.3a-genecounts and star-2.7.11b-featurecounts take this option. On star-2.7.11b-featurecounts a larger "
            + "limit also changes the exon counts, since -M counts each alignment of a read that maps to more loci. The other "
            + "chains refuse this option, since salmon runs no STAR and star-salmon and star-salmon-errormodel map at the 20 of "
            + "nf-core/rnaseq's route.",
        valueName: "n"))
    var starMultimapNmax: Int?

    @Option(name: .customLong("staged-reads"), help: ArgumentHelp(
        "A tab-separated list of reads already in the staging folder, with each read's absolute path, size in bytes and SHA-256, "
            + "for --write-plan with --samplesheet",
        discussion: "The sample sheet's r1 and r2 name each read by its absolute path in the staging folder, and Lungfish reads none "
            + "of them. The list's first line names the columns file, bytes and sha256, separated by tabs. The sheet's optional "
            + "model column names the instrument.", valueName: "file"))
    var stagedReads: String?

    @Option(name: .customLong("samplesheet"), help: ArgumentHelp(
        "A comma-separated sample sheet with sample, r1 and r2 columns, for --staged-reads",
        discussion: "The optional kit column names the UMI kit of every sample by its preset, one of "
            + UMIPlan.presets.map { "\($0.id) for \($0.label)" }.joined(separator: ", ") + ". A sheet with a kit plans the UMI "
            + "branch, which runs each pair's layout check, umi_tools extract, STAR 2.7.11b on the kept read alone on the set's adopted "
            + "STAR 2.7.11b index, featureCounts' gene tags and umi_tools count per gene, so a count is molecules. The kit's "
            + "preset fixes that chain, so leave out --chain, --trim, --k and --decoys.",
        valueName: "file"))
    var samplesheet: String?

    @Option(name: .customLong("staging-folder"), help: ArgumentHelp(
        "The absolute path of the folder on the Linux machine that holds the image, the executor, the index and the reads",
        valueName: "path"))
    var stagingFolder: String?

    @Option(name: .customLong("executor-manifest"), help: ArgumentHelp(
        "The manifest.json beside the Linux lungfish-executor (default: the app's). A run you adopt as a result takes the one you built",
        valueName: "file"))
    var executorManifest: String?

    @Option(name: .customLong("image"), help: ArgumentHelp(
        "The image.json of the container image the jobs run in (default: the app's)", valueName: "file"))
    var image: String?

    @Option(name: .customLong("image-tool-manifest"), help: ArgumentHelp(
        "The image's tool manifest, the file image.json pins (default: the app's)", valueName: "file"))
    var imageToolManifest: String?

    @Option(name: .customLong("request-memory-mib"), help: "Memory each job asks for, in MiB. Optional for Macaca_fascicularis_6.0")
    var requestMemoryMiB: Int64?

    @Option(name: .customLong("request-cpus"), help: "CPUs each job asks for, and the threads of salmon and STAR (default: 8). Optional for Macaca_fascicularis_6.0")
    var requestCPUs: Int?

    @Option(name: .customLong("request-disk-gib"), help: "Disk each job asks for, in GiB. Optional for Macaca_fascicularis_6.0")
    var requestDiskGiB: Int?

    @Option(name: .customLong("job-requirements"), help: "The machines the jobs may run on, as one HTCondor requirements expression")
    var jobRequirements: String?

    @Flag(name: .customLong("dry-run"), help: "With --write-plan, make every refusal of the run and write no folder")
    var dryRun: Bool = false

    var isOn: Bool { writePlan != nil }

    /// The options of a plan that were given, by name, for the refusal of a plan option with no `--write-plan`.
    var given: [String] {
        let named: [(String, Bool)] = [
            ("--chain", chain != nil), ("--star-multimap-nmax", starMultimapNmax != nil), ("--staged-reads", stagedReads != nil), ("--samplesheet", samplesheet != nil), ("--staging-folder", stagingFolder != nil),
            ("--executor-manifest", executorManifest != nil), ("--image", image != nil),
            ("--image-tool-manifest", imageToolManifest != nil), ("--request-memory-mib", requestMemoryMiB != nil),
            ("--request-cpus", requestCPUs != nil), ("--request-disk-gib", requestDiskGiB != nil),
            ("--job-requirements", jobRequirements != nil), ("--dry-run", dryRun),
        ]
        return named.filter(\.1).map(\.0)
    }

    /// The refusals the arguments alone decide. Without `--write-plan` the command counts, so it needs a project and bundles.
    func check(project: String?, bundles: [String], threads: Int?) throws {
        guard isOn else {
            if let first = given.first { throw ValidationError("\(first) is an option of --write-plan, so add --write-plan or leave it out.") }
            guard project != nil else { throw ValidationError("Missing expected argument '--project <project>'") }
            guard !bundles.isEmpty else { throw ValidationError("Missing expected argument '<bundles>'") }
            return
        }
        guard project == nil else { throw ValidationError("--write-plan writes no result in a project, so leave out --project.") }
        guard threads == nil else {
            throw ValidationError("A plan runs its tools with the threads of --request-cpus, 8 when you name none, so --threads does not apply. Leave it out.")
        }
        try checkMultimapNmax()
        guard stagingFolder?.hasPrefix("/") == true else {
            throw ValidationError("--write-plan needs --staging-folder, the absolute path of the folder on the Linux machine.")
        }
        if stagedReads != nil || samplesheet != nil {
            guard stagedReads != nil, samplesheet != nil, bundles.isEmpty else {
                throw ValidationError("Reads in the staging folder take --staged-reads with --samplesheet and no bundles, and bundles take neither.")
            }
        } else {
            guard !bundles.isEmpty else { throw ValidationError("Name FASTQ bundles, or --staged-reads with --samplesheet.") }
        }
    }

    /// `--star-multimap-nmax` is a whole number of loci from 1 up, and goes only to the chains whose STAR maps at the number
    /// the person names. `salmon` runs no STAR and the two `star-salmon` chains map at nf-core/rnaseq's 20, so each refuses it
    /// in words that name the option and the chains that take it, before any file is read.
    private func checkMultimapNmax() throws {
        guard let loci = starMultimapNmax else { return }
        guard loci >= 1 else {
            throw ValidationError("--star-multimap-nmax is a whole number of loci from 1 up, and \(loci) is not.")
        }
        switch chain?.star?.chain {
        case .geneCounts?, .featureCounts?:
            return
        case .starSalmon?:
            throw ValidationError(STARPlan.defaultRouteMultimapRefusal)
        case nil:
            throw ValidationError("The chain salmon, the default, counts the reads with salmon and runs no STAR, so --star-multimap-nmax "
                + "does not apply to it. Choose --chain star-2.7.11b-genecounts, star-2.7.3a-genecounts or "
                + "star-2.7.11b-featurecounts to set the number of loci, or leave the option out.")
        }
    }
}
