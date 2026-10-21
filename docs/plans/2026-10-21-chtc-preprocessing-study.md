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

## Owner answers of 2026-10-21, second round

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O2 | Is any read set restricted? | "Yes, we would not use human data, so HIPAA is not an issue." | V1's data-policy condition holds for this program. Check CHTC 1 still runs per batch |
| O3 | How large is a batch? | "Yes, the purpose here would be many samples at the same time." | V2 commits to building after stage 0, and the design is sized for batches |
| O4 | Where does the post-recipe tail run? | "Why wouldn't we run clumpify and write the relevant metadata from CHTC?" | Amends V3 and V4, see below |
| O5 | What counts as the same? | "If the results aren't byte-identical, this is OK as long as the tools aren't deterministic and we have commands/versions that we can use to describe HOW we generated the outputs." | V6 stands. A difference is allowed only where a tool is nondeterministic, and every record carries the argv and versions that made it |
| O6 | How does this fit Phase 2.13? | "Note that we are already running Phase 2.13 on the Mac Studio so all of this work should co-exist with that so we can merge this in after 2.13 lands. This includes the work from last night, as well as fixes where we noticed that there were excessive provenance reads after statistics were computed." | The program branch merges after 2.13 lands. It carries in `d2dfb0770`, `f276c7ed0`, `453a98a8c` and `f1ac4f6b2` and the fix of the provenance reads after statistics |
| O7 | Recipe scope | "We should also enable an option to include deduplication with the wastewater metagenomics recipe, even though the current recipe doesn't support this. We should also fix the merged/unmerged handling for TrimGalore so it matches the approach we use for Clumpify." | Two Mac-side lanes. The second replaces the refusal of `453a98a8c` with the split, store and join that clumpify gets (`FASTQIngestionPipeline.swift:646-690` at `ab548cd87`) |
| O8 | Testing on CHTC | "You can also do the testing by logging into ssh oconnor-ap4000 and using the existing keys. Then you can add this work to experiment 32748." | Agents may log in to `oconnor-ap4000` with the owner's keys, run read-only commands and submit test jobs, and keep test files in `/staging/groups/oconnor_group/32748`. No heavy work runs on the access point and no polling loop runs, under CHTC's rules (CHTC inv S3) |
| O9 | How to run it | "We can use the LGE contracts for this, including orchestration and implementation agents." | The program runs under `docs/contracts/EXPERT-PANEL.md` and `docs/contracts/RUNNING-A-PHASE-SESSION.md`, with the CHTC seat kept for the whole program |

## Decisions amended by the owner

| Id | Amended decision | Basis |
|---|---|---|
| V3 | Shape B′. The Mac plans, and CHTC runs the tools and the post-recipe tail through a small portable Swift executor. The executor's byte code (layout writer, pair split and join, storage plan, record and Q20/Q30 counts, statistics, sidecar) moves into one target that the Mac import also calls, with no copies, as ARCH's memo set for B′ | O3 and O4. With many samples, the Mac running clumpify and statistics on every 100 GB payload at adopt is the bottleneck (UX memo V4). SWIFT and UX voted B′, and BIO, QA, CHTC and ARCH named it the fallback |
| V4 | The tail runs on CHTC, with heap, clumping choice, threads and compressor fixed in the plan. The adopt on the Mac verifies every digest and writes the bundle's records | O4 |
| V4a | Open for the panel. Whether the provenance envelope is written on CHTC by a portable writer or at adopt on the Mac from the run record. Signing stays on the Mac either way (SWIFT inv 8) | New question from O4 |

## Facts measured on 2026-10-21

| Fact | Source |
|---|---|
| `oconnor-ap4000` answers to the owner's keys with no prompt. It runs HTCondor 26.1.0 and has 32 cores, 250 GB of memory and a 182 TB `/home` | `ssh -o BatchMode=yes oconnor-ap4000`, `condor_version`, `nproc`, `free -g`, `df -h` |
| The pool reports 17,339 `x86_64-v3` slots, 1,226 `x86_64-v4` slots and 7 undefined | `condor_status -af Microarch` |
| `/staging/groups/oconnor_group/32748` holds only `nvd-results` (9.2 GB). No `C079876*` file sits within four levels of the group folder | `ls`, `du -sh`, `find -maxdepth 4` |
| The 2026-10-20 import read `/Volumes/sandbox/32748/C079876_S1_R1_001.fastq.gz` (30,574,724,682 bytes, SHA-256 `41c8f375…13b47`) and its R2 (30,985,730,296 bytes, `e8bffe53…de1df`) from the owner's external SSD | last night's session transcript, `shasum -a 256` |
| The C0 test slice is the first 1,000,000 pairs of C079876_S1 (279,439,307 bases, every mate name matched), written by pinned pigz 2.8 at level 6 with no name or time in the header. Its decompressed content equals the slice that `f276c7ed0` and `f1ac4f6b2` benchmarked. Copies with `C079876_S1_1M.provenance.json` and the two scripts that made and checked it sit in `/Users/dho/Documents/lungfish-chtc-testing/32748/` and `/staging/groups/oconnor_group/32748/lge-chtc-test/input/`, checked by SHA-256 on arrival | `make_1m_slice.sh`, `verify_slice.py` |
| `transfer.chtc.wisc.edu` timed out on port 22 from the owner's network, so the slice went up through `oconnor-ap4000`, the access point the owner named | `ssh -o BatchMode=yes` |
| `origin/main` is 1,229 commits past local `main`. Since `ab548cd87`, 2.13 changed 60 files (2,329 lines in, 684 out) under Recipes, Ingestion, the import commands, IO FASTQ and Compression, the tool lock, Provenance and Core Process | `git diff --stat ab548cd87 origin/main` at `934305361` |
| The account's weekly quota read 82% on 2026-10-21 at 16:58 CDT and resets on 2026-10-25. 2.13 starts no new row past 87% (2.13 O19) | `get_usage` |

## Program

Sub-phases of at most about six lanes each, one session each, on one program branch cut from `origin/main` after 2.13
lands and rebased onto it until then. The first agent round waits for the quota reset of 2026-10-25 so that it does not
take 2.13's share, which is the manager's call under 2.13 O19.

| Sub-phase | Scope | Ends with |
|---|---|---|
| C0 measure | The Mac determinism table on 1,000,000 pairs of C079876 at threads 1 and 8, two runs each. M1 timing of the tools and the tail on the full sample. Slice 0 on one `x86_64-v3` and one `x86_64-v4` node with linux-64 builds, the deacon check included. No product code | Go or stop on the deacon check, and the measured tail cost |
| C1 Mac fixes | Carry in last night's four commits. Copy import checks payload digests. True recorded defaults. Recipe and database digests in records. Deacon index digests in the lock. Host choices pinned and recorded. The provenance reads after statistics. VSP2 adapter trimming if the owner says fix | Targeted tests and the golden compare on the program branch |
| C2 recipe options | An opt-in dedup step for the wastewater recipe. Trim Galore storage with the clumpify split and join | The same |
| C3 portable kernel | The shared portable target, a Linux `ToolProcess` subset, a static musl `lungfish-htc`, the linux-64 lock and a Linux build tier in a container on a Mac | The executor replays a VSP2 plan on the Mac and matches the in-process import |
| C4 CHTC runner and adopt | Plan template and fill, the Apptainer image pinned by digest, the submit file and DAG, status from the job event log, the run record, and the adopt mode of `import fastq` | One C079876 sample run on CHTC and adopted, equal at E0 to E3 |
| C5 batch and lab | A batch of 32748, then a wastewater batch, the lab's documented commands, plain FASTQ with `samples.tsv` for Linux users | The owner check list for the merge after 2.13 |

## Open owner questions

| Id | Question |
|---|---|
| Q3 | Fix VSP2 adapter trimming before CHTC work, or reproduce today's output? (V9, Q-B1) |
| Q4 | Should VSP2 imports bin qualities as the recipe says, or keep the CLI's `none`? (Q-B3) |
| Q5 | For CHTC staff. May LGE submit over a reused SSH session, does the CHTC Staging Globus collection reach the group folder, and what is the group's `/staging` quota? (Q-C3, Q-C10, Q-C5) |
| Q6 | Where did the excessive provenance reads after statistics show up? No commit or branch names them |

The owner settled Q7 on 2026-10-21 ("Sure I plugged in the SSD so you can copy the 1m reads to the internal SSD for testing"). The slice row above records where it went. The full sample stays on the external SSD for M1.

## Next step

C0 after the quota reset. The manager already took the node census and staged the test slice.
