# CHTC preprocessing study, panel decisions (2026-10-21)

This record holds the panel's decisions on running Lungfish Genome Explorer (LGE) FASTQ preprocessing recipes on CHTC
HTCondor execute nodes. It is a design study, and no code has been written. The briefs, the six inventories
`inv/<FIELD>.md` and the six memos `memos/<FIELD>.md` are kept in
`~/Documents/lungfish-branch-archive/chtc-preprocessing-study-2026-10-21/` on the owner's laptop, with the published
report. Code facts in them cite `path:line` at `ab548cd878a51c7c3643538700dc293ba3a5061a`, plus the four import commits
on branch `claude/lungfish-fastq-import-failure-58c429` (`d2dfb0770`, `f276c7ed0`, `453a98a8c`, `f1ac4f6b2`).

## Owner direction

The owner asked on 2026-10-21 whether the VSP2 and metagenomics import recipes could run on CHTC with the same
databases, tool versions and data, writing `.lungfishfastq` bundles ready to import with full provenance, or plain
FASTQ. Reads already land in `/staging/groups/oconnor_group`, and one VSP2 sample took nearly 3 hours on the laptop on
2026-10-20. The owner added a CHTC seat to the panel for this study.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O1 | Where should the output live? | "Both - I expect that the bundles could be copied back to Mac and then loaded so users can use LGE for subsequent analyses, but some others might want to keep the files on Linux as FASTQ files and use it for other workflows that aren't in LGE." | Every shape must give a bundle for the Mac and plain FASTQ on Linux |

## The panel

The five seats of `docs/contracts/EXPERT-PANEL.md` (SWIFT, ARCH, BIO, UX, QA) and a sixth seat, CHTC (letter C), for the
execute pool, `/staging`, containers, job shape, quotas, data policy and transfer. The CHTC seat ran as a
`general-purpose` agent so that it could read CHTC and HTCondor documentation on the web. Every seat ran on opus at
effort xhigh, first an inventory and then a memo with votes after reading all six inventories.

## Shapes weighed

| Id | Shape | Outcome |
|---|---|---|
| A | Port `lungfish-cli` to Linux | Rejected. Core, IO, Workflow and CLI are 1,792 files and about 484,000 lines, 602 of which import a module Linux lacks (SWIFT inv 1) |
| B | The Mac compiles a plan, a small runner replays the tool argv on CHTC, and the Mac adopts the outputs | Chosen |
| B′ | B plus a small portable Swift executor that holds the post-recipe byte work on both platforms | The fallback, if M1 shows the Mac tail is too slow |
| C | A separate Snakemake or Nextflow pipeline | Rejected by all six. A second implementation drifts, and a workflow head on the access point needs CHTC's prior agreement |
| D | A portable kernel of Core, IO and Workflow, running the same `import fastq` on Linux | Withdrawn by ARCH in its memo once the tail moved to the adopt |

## Panel decisions

A vote passes by a majority of the seats that vote, and an abstention does not count.

| Id | Decision | Vote |
|---|---|---|
| V1 | Feasible, with conditions. No HIPAA, CUI or export-controlled read set goes to CHTC. Deacon removes the same reads on x86-64 as on arm64. Every host-read choice (threads, clumpify heap, clumping on or off, compressor) is fixed in the plan. Database and image digests are pinned. The adopt re-hashes every payload against the run record | 6 to 0 |
| V2 | Build only after the stage 0 measurements of V7 pass | 6 to 0 |
| V3 | Shape B. Move to B′ if M1 shows the Swift tail is too slow at adopt (SWIFT puts the line near a tenth of tool time) | 4 to 2, SWIFT and UX voted B′ |
| V4 | The post-recipe tail (mixed layout writer, the storage step and clumpify, statistics, the metadata sidecar, provenance) runs at adopt on the Mac, entered at `FASTQBatchImporter.swift:689` | 4 to 2, SWIFT and UX voted for CHTC through shared Swift |
| V5 | The Mac writes one plan template per recipe per LGE release. A command on the access point fills it per sample from the sample sheet with paths, names and input digests only, never a parameter. A fill golden proves the fill equals the Mac's own per-sample plan | 6 to 0 |
| V6 | E0 (equal plans) and E1 to E3 (counts, sorted sequences, sorted records) are required, E4 (the decompressed stream) is reported, and compressed bytes never count. CHTC may differ from the Mac only where the Mac differs from itself, judged against a committed Mac determinism table | 6 to 0 |
| V7 | Before any CHTC code, freeze the Mac determinism table on 1,000,000 pairs at threads 1 and 8, run M1 (time the tools, the Swift tail and a one-thread dedup on the full 2026-10-20 sample), take a node census with `condor_status`, and run slice 0 (replay the recorded Mac argv with linux-64 builds on two node classes, the deacon check included) | 6 to 0 |
| V8 | The first fix is the copy import's payload check against the source record | 5 to 1, CHTC ranked pinned host choices first |
| V9 | The panel recommends fixing VSP2 adapter trimming first, with a golden prediction, after the recipe digest lands. The owner decides | 5 to 0, SWIFT abstained |
| V10 | Measure the cost of a one-thread dedup before choosing. Until then VSP2 is held to E1 and E2 with the degradation recorded | 6 to 0 |
| V11 | Linux users get the step outputs as plain gzipped FASTQ (merged, R1, R2), unclumped, with a `samples.tsv` and the run record | 6 to 0 |
| V12 | An adopted bundle's record names the CHTC run as the run, with the adopt as its last step, and each CHTC step keeps its Linux runtime identity | 5 to 1, ARCH made the adopt the run |
| V13 | The Apptainer image may be built on either site. It is pinned by SHA-256 in a reviewed commit with a committed package list from its `conda-meta`, and it is not signed with `apptainer sign` | 5 to 0, UX abstained |
| V14 | Version 1 is launched by the owner by hand on the access point. Lab members follow with their own accounts once the slice passes. No launch from LGE over SSH without CHTC's agreement | 5 to 1, UX would open it to lab members at once |
| V15 | The first deliverable is one VSP2 sample, steps 1 to 4 on CHTC from a pinned image and a Mac plan, adopted on the Mac and equal to a Mac import at E0 to E3, with a cut-short copy refused and the Inspector differing only in the CHTC site lines | 6 to 0 |

## Findings that stand without CHTC

| Finding | Evidence |
|---|---|
| The VSP2 fused fastp call trims no adapters and filters no quality, because the dedup step adds `--dedup -A -G -Q -L` | `Sources/LungfishWorkflow/Recipes/Steps/FastpDedupStep.swift:28`, read by the manager. BIO inv 1.1 measured 41,173 of 179,932 R1 reads keeping `AGATCGGAAGAGC` on a 200,000-pair synthetic slice |
| Bundle copy import hashes each copied file and never compares it with the source record, so a cut-short transfer imports as complete | `Sources/LungfishWorkflow/Ingestion/FASTQBundleCopyImportWorkflow.swift:248` |
| Import records state false defaults, quality binning `illumina4` and threads 4, while the CLI runs `none` and every core | `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift:1842`, `:1846`, `Sources/LungfishCLI/Commands/ImportFastqOptions.swift:60`, `ImportFastqRun.swift:283` |
| Neither deacon index has a pinned digest, and the ribokmers index was built by deacon 0.15.0 from an unversioned file | `third-party-tools-lock.json:83-84`, `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift:880-887` |
| Threads, the clumpify heap and the clumping choice are read from the host | `ClumpingTool.swift:58-68`, `Sources/LungfishCore/Services/ManagedJavaHeapPolicy.swift:53-71` |
| The Import Center copies and hashes a bundle on the main actor with no Operations row | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:254-303` |
| Several sites launch `/usr/bin/gzip` through Foundation `Process`, outside `ToolProcess` | `Sources/LungfishIO/Compression/GzipSupport.swift`, `Sources/LungfishWorkflow/Ingestion/FastpPairedRunner.swift:424-431` |

## CHTC facts the design rests on

Read on 2026-10-21 from chtc.cs.wisc.edu and htcondor.readthedocs.io (CHTC inv sources S1 to S20, CHTC memo W1 to W9).

- CHTC is not HIPAA compliant and takes no export-controlled or CUI data.
- Jobs copy `/staging` files into scratch with `file:///` under `requirements = (HasCHTCStaging == true)`. Group
  folders cannot use `osdf:///`. Jobs run at most 72 hours.
- Eviction, `condor_rm` and hold all send SIGTERM, then a hard kill after 600 s by default, so job status comes from the
  HTCondor job event log.
- A slot's memory is a hard cgroup limit, while cores are shares that cap only under contention. The provisioned counts
  are in `$_CONDOR_MACHINE_AD`.
- Automated submission from cron or a workflow manager needs prior discussion with CHTC, and accounts are not shared.

## Open owner questions

| Id | Question |
|---|---|
| Q1 | Is any read set HIPAA, CUI, export-controlled or under an agreement that forbids CHTC? (Q-C1, Q-Q6, Q-A3) |
| Q2 | About how many samples does a typical batch hold? (Q-A2, Q-C5, Q-U2) |
| Q3 | Fix VSP2 adapter trimming before CHTC work, or reproduce today's output? (V9, Q-B1) |
| Q4 | Should VSP2 imports bin qualities as the recipe says, or keep the CLI's `none`? (Q-B3) |
| Q5 | For CHTC staff. May LGE submit over a reused SSH session, does the CHTC Staging Globus collection reach the group folder, and what is the group's `/staging` quota? (Q-C3, Q-C10, Q-C5) |

## Next step

Stage 0 of V7, which writes no product code. M1 runs on the Mac. Slice 0 and the node census need the owner on the CHTC
access point.
