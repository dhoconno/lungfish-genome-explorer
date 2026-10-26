# CHTC preprocessing study, panel decisions (2026-10-21)

Status: complete. C0 to C6 are complete. The program closed on 2026-10-26 with C6 (session 7 on the Mac Studio). Its open rows are Phase 3 rows or Known limits in "Carry-in from the CHTC program" of docs/plans/2026-10-02-architecture-program.md.

This record holds the panel's decisions on running Lungfish Genome Explorer (LGE) FASTQ preprocessing recipes on CHTC
HTCondor execute nodes. It began as a design study. The program's code landed on branch `chtc-program` and reached `main` with C3 on 2026-10-23. The briefs, the six inventories
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
| C1 Mac fixes | Carry in last night's four commits. Copy import checks payload digests. True recorded defaults. Recipe and database digests in records. Deacon index digests in the lock. Host choices pinned and recorded. A measured check of the provenance reads after statistics (O10) | Targeted tests and the golden compare on the program branch |
| C2 recipes | The VSP2 adapter fix (O11), wastewater dedup on by default (O12) and, if the panel and owner agree, the merged recipe of R1. Trim Galore storage with the clumpify split and join | The same, with every moved golden key predicted |
| C3 portable kernel | The shared portable target, a Linux `ToolProcess` subset, a static musl `lungfish-htc`, the linux-64 lock and a Linux build tier in a container on a Mac | The executor replays a VSP2 plan on the Mac and matches the in-process import |
| C4 CHTC runner and adopt | Plan template and fill, the Apptainer image pinned by digest, the submit file and DAG, status from the job event log, the run record, and the adopt mode of `import fastq` | One C079876 sample run on CHTC and adopted, equal at E0 to E3 |
| C5 batch and lab | A batch of 32748, then a wastewater batch, the lab's documented commands, plain FASTQ with `samples.tsv` for Linux users | The owner check list for the merge after 2.13 |

## Open owner questions

| Id | Question |
|---|---|
| Q4 | Should VSP2 imports bin qualities as the recipe says, or keep the CLI's `none`? (Q-B3) |
| Q5 | For CHTC staff. May LGE submit over a reused SSH session, does the CHTC Staging Globus collection reach the group folder, and what is the group's `/staging` quota? (Q-C3, Q-C10, Q-C5) |
| Q8 | In the merged recipe of R1, is rRNA removal on or off by default? |
| Q9 | Did the recipes' `quality: 15` mean fastp's read filter (`-q`, as it does today) or the trim threshold of `--cut_right` (`-M`, which stays at its default of 20)? (BIO memo V9) |

The owner settled Q7 on 2026-10-21 ("Sure I plugged in the SSD so you can copy the 1m reads to the internal SSD for testing"). The slice row above records where it went. The full sample stays on the external SSD for M1.

## Owner answers of 2026-10-21, third round

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O10 | Q6, where the excessive provenance reads showed up | "Excessive provenance records were last night after statistics were computed and before the bundles became availbal ein LGE." | The records stage of the import, after statistics and before the publish rename (`FASTQBatchImporter.swift:1154-1292` and `:838-849` at `ab548cd87`). 2.13 lane 13.34 PROV-SIDECAR-WALK (landing 7, module map `dc1f05c25`) bounded the provenance lookup that walked the folders above an input outside the project, which MD31 of the 2.13 plan found every sampled CLI sitting in (`ProvenanceRecorder.findProvenanceEnvelope`). The 2026-10-20 inputs sat outside the project in `/Volumes/sandbox/32748/`. C1 samples a slice import from such an input on the program branch and fixes only what remains, counting the hashing passes of SWIFT 5 as well |
| O11 | Q3, the VSP2 adapters | "Yes, VSP2 should trim adapters." | The fused fastp call keeps `--dedup` and drops the dedup step's `-A -G -Q -L`. Adapter trimming, polyG trimming, the Q15 read filter and the length-15 filter then all turn on for VSP2, so its output changes in four ways, each predicted key by key (BIO 7) |
| O12 | Wastewater dedup | "I think we should also change the wastewater recipe default to also deduplicate." | Amends O7. Dedup is on by default in the wastewater recipe and can be turned off |
| O13 | The two recipes | "Maybe these two recipes should collapse into one, with the option to retain or discard rRNA reads?" | Proposal R1 below |

## Proposal R1, one recipe for VSP2 and wastewater

After O11 and O12 the two recipes run the same steps with the same parameters (fastp dedup and trim with adapter detection, quality 15, window 5 and `--cut_right`, the deacon `deacon-panhuman` scrub, the fastp merge with a 15-base overlap, the 50-base length filter, `illumina4` binning, paired input). The only difference is the deacon `deacon-ribokmers` rRNA filter (`vsp2.recipe.json:12-16`, `wastewater-metagenomics.recipe.json` steps at `ab548cd87`). The manager recommends one recipe with two switches, remove duplicates (on by default) and remove rRNA (default Q8). The ids `vsp2-target-enrichment` and `wastewater-metagenomics` stay readable as names for that recipe with the rRNA switch set, so older records, the Inspector and scripts that pass `--recipe vsp2` keep working (ARCH 4, UX 5). Every record names the recipe digest and both switch values.

Dedup lowers the counts of the most abundant organisms in a wastewater sample, where identical pairs arise by chance at high depth, so relative abundance shifts against the no-dedup run of today. The switch stays so that abundance work can turn it off. The panel votes on R1 in C2 with the owner's answer to Q8.

## C0 results (2026-10-21)

The owner said on 2026-10-21 "Go ahead and start the agent work. Use the expert team to determine the most general
appropriate quality preset." The C0 records are in `~/lungfish-phase-records/chtc-program/c0/` on the owner's laptop
(briefs, lane reports `lanes/C0-DET/` and `lanes/C0-SLICE0/`, the ruling `rulings/BIO-preset.md`, its reviews
`reviews/BIO-preset-UX.md` and `reviews/BIO-preset-QA.md`, the scripts `fastq_levels.py` and `compare_platforms.py`,
and `platform-compare.md`).

| Result | Evidence |
|---|---|
| At one thread, every tool step from S1 to S5 (fastp dedup and trim, both deacon filters, fastp merge, the length filter) writes the same bytes, gzip included, on the Mac (arm64), on CHTC `x86_64-v3` (AMD EPYC 7763) and on CHTC `x86_64-v4` (Intel Xeon Gold 5218R and Silver 4114), in both modes. The deacon check passes, so the program goes on | `platform-compare.md` |
| At eight threads the platforms differ only where the Mac differs from itself. fastp dedup keeps 3 to 5 more pairs than at one thread and varies run to run, and deacon reorders its records (E3) | `lanes/C0-DET/determinism.md` |
| The clumpify storage step agrees across platforms at E2 only, because the CHTC chain passed `quantize=0,8,13,22,27,32,37` (the recipe's `illumina4`) and the Mac chain passed none (the CLI default). CHTC v3 and v4 agree at E4. This is open question Q4, an argv difference and not a platform one | the two lanes' S6 argv |
| clumpify rewrites the quality of N bases from `#` to `!` on both platforms, so its records differ from its input's | `lanes/C0-DET/determinism.md` |
| On this sample the rRNA filter (`-a 1 -r 0`) removed 78% of the pairs left after the human scrub (816,119 to 182,696) | the S2 and S3 counts |
| The linux-64 lock holds 87 packages with the Mac's versions, openjdk 25.0.2 included. The Apptainer image `lge-c0-tools-c42530259944.sif` (SHA-256 `c4253025…7c`) sits in `/staging/groups/oconnor_group/32748/lge-chtc-test/images/`. A batch build job cannot build from a definition file, so the image was built through a sandbox from the same pinned base and lock | `lanes/C0-SLICE0/C0-SLICE0.md` |
| Each job started 40 s after submit, and 3.4 GB of inputs and index arrived by `file:///` in about 40 s. Jobs see every host core and all host memory, and only `$_CONDOR_MACHINE_AD` names the slot. HTCondor's measured memory (35 to 74 MB) misses deacon's mapped 3.3 GB index. All four `x86_64-v4` jobs ran on the group's own `oconnor2001` to `oconnor2004` | the same |
| SIGTERM through Apptainer (check CHTC 5) is still untested, since no job was evicted | the same |

## Quality preset decisions (2026-10-21)

BIO ruled and UX and QA reviewed, so each row is BIO's ruling with the two reviews counted as votes.

| Id | Decision | Vote |
|---|---|---|
| P1 | The merged recipe's trim is fastp `--detect_adapter_for_pe -g --poly_g_min_len 10 -q 15 -u 40 -n 5 -l 15 -W 5 --cut_tail -M 20`, every value written out, with `--dedup --dup_calc_accuracy 3` when duplicates are removed. Tail cutting keeps 869,933 pairs on the slice against 834,778 for `--cut_right` | 3 to 0. QA agreed with changes, which were to freeze exact one-thread values and to time the exact argv |
| P2 | rRNA removal is off by default, since removed reads come back only by a reimport and the filter took 78% of this sample's pairs. The wastewater preset turns it on | 3 to 0. UX agreed with changes, which were to show the switch states in the sheet and correct the wastewater description |
| P3 | One recipe file at `formatVersion` 2 with `removeDuplicates` (default on) and `removeRibosomalRNA` (default off) switches, and presets `vsp2-target-enrichment` and `wastewater-metagenomics`. A build refuses a version it does not know. Records hold the name passed, the preset, the recipe digest, each switch's value and source, and a step result for each step a switch turned off | 3 to 0. UX and QA agreed with changes on words, display and tests |
| P4 | Settled by M1. The extra cost of P1 is a fixed 20.5 s per fastp call from adapter detection, not a cost per read. On 1, 3 and 5 million pairs the ruled argv fits 20.5 s plus 0.70 microseconds a pair (R² 0.99992), and the cost vanishes with `-A` or without `--detect_adapter_for_pe`. Threads above 8 do not pay | `lanes/C0-M1/C0-M1.md` |

Q8 is settled by P2 and Q9 by P1. Q4 stays open, with the manager's note that the sample's qualities already hold four values (Q2, Q9, Q24 and Q41), so `illumina4` binning saves little here and still rewrites them.

## M1 results and corrections (2026-10-21)

M1 ran `import fastq --recipe vsp2 --threads 14 --clumping-tool bbtools` on the full C079876_S1 sample (217,928,172 pairs) with a release `lungfish-cli` built by `swift build -c release` from `f1ac4f6b2`. Its report is `lanes/C0-M1/C0-M1.md`.

| Finding | Evidence |
|---|---|
| The import failed after 5,677.9 s with exit 64, "Tool 'pigz' timed out after 300 seconds", in the human scrub step. The pigz compress calls of the legacy import path run under `NativeToolRunner`'s 300 s default (`NativeToolRunner.swift:137`, called from `FASTQBatchImporter.swift:2299` and `:2346` at `f1ac4f6b2`), and that path also left 479 GB of uncompressed temporary FASTQ. Any sample above about 100 GB uncompressed fails this way | `C0-M1.md`, `status.json` |
| The bare release build loads none of the recipe files. Its `import fastq --help` lists only `vsp2, wgs, hifi`, while the debug build and the shipped Preview 2026.10.21 CLI list all three recipe files. With no file to match, the alias `vsp2` fell through to the legacy `ProcessingRecipe` "Illumina VSP2 Target Enrichment" (`ImportFastqCommand.swift:199-214`, `FASTQBatchImporter.swift:289`) and said nothing. M1 therefore timed the legacy six-pass chain (BBTools dedupe, fastp adapter trim, fastp Q15 trim, deacon, a BBTools merge, length filter), not the recipe file | `--help` of the three binaries, the slice bundle's `recipeApplied` |
| The correction to earlier statements. The shipped app and CLI run the recipe file `vsp2-target-enrichment`, whose fused fastp call trims no adapters, so O11 stands. The legacy chain does trim adapters. The 2026-10-20 import that took nearly three hours ran `--recipe wastewater-metagenomics`, not VSP2 | `/Volumes/sandbox/32748/32748.lungfish/Imports/C079876_S1.lungfishfastq/.lungfish-provenance.json` |
| At full scale the work outside the tools is about as large as the tools. The 2026-10-20 record has 8,890.8 s of wall time, 4,338.9 s in tools and 4,551.8 s outside them (2,223.3 s inside the storage step and 2,328.6 s in stages the record does not itemize). On the 5M-pair slice the share was 7.7% of tool CPU, so the slice understates it. This supports O4, the tail on CHTC | the same record, `C0-M1.md` |
| The records stage took 2.4 s on the 5M slice and was 86% SHA-256 hashing. The full-sample records stage of O10 is still unmeasured, and C1 measures it on the program branch, which holds 2.13's lookup fix | `records.sample.txt` |

New rows for C1. The legacy path's compress timeout. Refusing a recipe name that matches no recipe file instead of falling back to another recipe. The recipe files' resource lookup in a bare release build, which the Linux executor of C3 must not repeat.

## C1 and the start of C2 (2026-10-21 to 22)

The owner said on 2026-10-21 "Keep going until 97% then give a prompt to continue in another account", so C1 ran at
once and C2 began in the same session. The manager's records are `c1/notes.md` and `c2/notes.md` in
`~/lungfish-phase-records/chtc-program/`, beside the briefs, lane reports, reviews and landing reports. The program
branch is `chtc-program`, cut from `origin/main` at `8190b9000` and not pushed. Each lane got one review of the fields
it touches, a fix agent for the numbered fixes, and a landing. The fix rounds got no separate re-review, to save quota,
and the landings' test runs stand in for it.

| Lane | What it does | State |
|---|---|---|
| L1-CARRY | Last night's four import commits, carried over 2.13's ToolProcess routing in `GzipSupport.swift` and `FASTQPairInterleaver.swift`, plus cancel of the step count and lean cancel tests | Landed |
| L2-COPYCHECK | A bundle copy refuses a FASTQ payload whose SHA-256 or size differs from the source record, or that is missing, and publishes nothing | Landed |
| L3-RECIPEREF | A recipe name that matches no recipe file is refused (exit 3), never run as a legacy recipe. A bare CLI finds recipe files only through a debug `#filePath` fallback, and `RuntimeResourceLocator` trusts only an app bundle, which C3's Linux executor must solve | Landed |
| L4-PIGZ | Whole-sample tool calls on the import paths take the recipe engine's size rule instead of the 300 s default | Landed |
| L5-RECORDS | Records state the true defaults, the recipe file's SHA-256, each deacon database's id, version, index format, SHA-256 and size, and each host choice with its source. `--clumpify-heap-gb` pins the heap, and the recorded heap is the one that ran. The lock pins panhuman (a fresh deacon 0.16.0 fetch matched), and no existing install is refused | Landed |
| L6-O10 | The full-sample measurement of owner answer O10. The records stage took 660.7 s, opened no provenance file (2.13's lookup fix holds), and hashed R1 and R2 8 times each and the payload 6 times, 506.9 GB read for 64 GB. The import took 5,541 s against 8,890.8 s on 2026-10-20 | Measured |
| L7-HASHONCE | One digest per file per import through a cache keyed by path, size, inode and modification date, with recorded digests unchanged | Landed |
| C2-MERGED | One recipe file at `formatVersion` 2 with `removeDuplicates` and `removeRibosomalRNA` switches and the two old ids as presets, preset P1 (869,933 pairs and 242,843,520 bases on the slice at one thread), records of the name, preset, switches and turned-off steps, the Inspector's "Not run" rows, help goldens with predictions | Landed, review fix 3 open |

After the C2-SHEET fixes the program branch `chtc-program` is at `fc6576f39`, 51 commits past `8190b9000`, and the
sheet's 31 test classes passed (341 tests). After landing 3 it was at `e4574e5a7`, 45 commits past `8190b9000`. Landing 3 ran 2,270
XCTest cases and 453 Swift Testing tests. The only failures were three cases in `ConformanceFixtures.swift:81` that
need a deacon-panhuman install receipt this laptop lacks. The seven ratchets, the module map check and
`predictions.py check` passed.
| C2-TRIMGALORE | Trim Galore storage with the clumpify split and join, and the refusal of `453a98a8c` removed | Held for Q12 |
| C2-SHEET | The Import FASTQ sheet lists the two presets and shows a checkbox for each switch, passes an option only when a box differs from the preset, keeps the Tab order and layout, and the description follows the boxes | Landed, GUI walk with Computer Use still owed |

The review of C2-TRIMGALORE ran Trim Galore 2.3.0 with LGE's storage arguments and found the storage route lossy
before this lane too. It adapter- and quality-trims and drops reads under 20 bp after trimming, a pair as a unit, and
no 2.3.0 option set makes it lossless. The plain paired and single-end branches have no count check.

## Open owner questions (2026-10-22)

| Id | Question |
|---|---|
| Q4 | Should imports bin qualities as a recipe says, or keep the CLI's `none`? |
| Q5 | For CHTC staff. May LGE submit over a reused SSH session, does the CHTC Staging Globus collection reach the group folder, and what is the group's `/staging` quota? |
| Q10 | Host one pinned ribokmers index (on the LGE large-files folder) so every install and CHTC use the same bytes, or pin a deacon 0.16.0 build and reinstall? A 0.16.0 rebuild gives `3a7b6728…0d11`, while the installed 0.15.0-built index is `1c9eb9f6…68c3` |
| Q11 | Allow `lungfish-cli conda db update kraken2-viral --yes` with `LUNGFISH_STORAGE_ROOT=/Users/Shared/lungfish-golden/storage` on this laptop, so the golden compare can run here, or leave the compare to the Mac Studio's Golden workflow at merge? The owner's rule reserves writes there to `provision` |
| Q12 | Keep Trim Galore as a storage choice with exact read accounting and a plain warning that it trims, or remove it as a storage tool so that storage stays lossless? |

The SWIFT and ARCH design inventory for C3 is `~/lungfish-phase-records/chtc-program/c3/inv/C3-design.md`. It moves
the tail's byte code by pure moves into a new bottom target, `LungfishPortable`, has the storage step call tools through
a launcher protocol, and gives a static musl `lungfish-htc` its own POSIX launcher, so no Core, IO or Workflow file has
to build on Linux. It plans six lanes, K0 to K5, and leaves nine open questions, two for the owner. Q-C3-3 asks whether
agents may install the swift.org toolchain and Static Linux SDK on both Macs. Q-C3-4 asks whether swift-crypto may join
`Package.swift`, or a pure-Swift SHA-256 should be used.

## Owner answers of 2026-10-22

The owner answered Q4, Q10, Q11, Q12, Q-C3-3 and Q-C3-4 when session 2 began, and answered the questions that the session
raised as it went. The manager's log `c2/events.log` in `~/lungfish-phase-records/chtc-program/` keeps most answers as
one-line notes. A cell below puts quotation marks only around words that the log or a lane brief quotes from the owner, so
a cell without them is the manager's note of the answer. These answers close Q4, Q10, Q11, Q12, Q-C3-3 and Q-C3-4 in the
open questions above, and they release C2-TRIMGALORE from its hold for Q12.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O14 | Q4, should imports bin qualities as a recipe says, or keep the CLI's `none`? | "I think we should still offer binning with iillumina4 as the default. ONT and other platforms don't bin, and binning does save space." Asked whether that covers every route, the owner chose "Every route, ONT too" | `illumina4` becomes the default on every import route, ONT included, unless the user picks `none` or `eightLevel`. Lane C2-BINNING |
| O15 | OQ1 of the C2-BINNING review. The ONT run folder import stores chunked payloads by default and bins them only when Optimize Storage runs, so should it bin them | The owner chose "Bin chunked ONT payloads" | New lane C2-ONTBIN, which runs the `illumina4` quantize pass on chunked ONT payloads by default |
| O16 | Q10, host one pinned ribokmers index or pin a deacon 0.16.0 build and reinstall | The owner chose "Build it once with the pinned deacon 0.16.0, put it on the LGE large-files folder on LabKey, pin its SHA-256 in the lock. Every install and CHTC download those exact bytes." | One hosted index in the tool lock, and the one upload of lane C2-RIBOPIN to the public LGE folder is approved |
| O17 | The first hosted index came from a build whose record order is not stable. The review of C2-RIBOPIN offered option B, to re-host a one-thread build, and asked to upload its `NOTICE.txt` too | The owner chose "Re-host 1-thread build" and answered "Yes, upload it" for `NOTICE.txt`. Later the owner approved deleting the first hosted folder | The one-thread build `f88286f6…ede6` and its `NOTICE.txt` sit in one new versioned folder, the first folder is deleted, and the lock, the records and the hosted databases table follow the new folder |
| O18 | Q11, may the golden compare run on this laptop, with the Viral database installed into the golden root | Recorded as allowed. The manager installed the Viral database between 07:38 and 07:41, and `provision` matches the lock | The golden compare ran here at landings 4 to 7 and matched in all four groups |
| O19 | Q12, keep Trim Galore as a storage choice with a plain warning that it trims, or remove it as a storage tool | "I don't want to remove it because it is the most laptop-safe option. Check if there is a new version that might have fixed this issue. If not, keep the current version and just make note of the issue in provenance." | Trim Galore 2.3.0 stays. Each Trim Galore storage step, the import notice and the record say that it removes reads (C2-TGFIX fix 7) |
| O20 | Q-C3-3, may agents install the swift.org toolchain and the Static Linux SDK on both Macs | Recorded as yes | K0 pins Swift 6.4.0 and the Static Linux SDK 0.1.0 in `scripts/linux/toolchain.json`. The Linux tier runs on demand and at each landing and never in the pre-push hook |
| O21 | Q-C3-4, may swift-crypto join `Package.swift`, or should the portable target use a pure-Swift SHA-256 | Recorded as swift-crypto | swift-crypto may join the package for the portable target's digests |
| O22 | N1 of the C3 tally, where each release's executor binary lives, which Mac builds it and how the plan writer learns its digest | "It should be included but should be generic to run on Linux. We should handle orchestration of individual jobs on chtc but this tool should handle the data preprocessing on any x86 ljbux machine." | The executor ships inside the app bundle and runs on any x86-64 Linux machine, and HTCondor orchestration is a separate layer. ARCH renamed the executor `lungfish-executor` and placed it at `Contents/Resources/LinuxExecutor/x86_64/` (ARCH A2 to A4) |
| O23 | Cf-8 and the tally's flag F6, may a CHTC plan name Trim Galore, which a UX condition would have the Mac refuse until a lane makes it run there | "Offer it on CHTC too" | ARCH A5 withdraws the refusal. Trim Galore storage moves behind the same seam as clumpify in K2, and the linux-64 lock and the image gain Trim Galore 2.3.0 in K5 |
| O24 | The tally's flag F5, is O4 met by CHTC running every full pass (counts, Q20 and Q30, statistics) while the Mac writes the sidecar and the envelope from the run record at adopt | Recorded as yes | O4 is read that way. Q-C3-1 A carries it, and V3 gets a revisit row below |
| O25 | The OOM fact-check found that clumpify without `-eoom` hung idle in 7 of 27 runs that ran out of memory at one group, so should every clumpify call add `-eoom` | "Yes, add -eoom now", whose option text reads "A small C2 lane adds `-eoom` to every clumpify call, so an out-of-memory run fails at once with a plain message. The argv in new import records changes, with each moved golden key predicted." | New lane C2-EOOM, run after landing 4 |
| O26 | May the GUI walk click Update in the Debug app's Update tools sheet | Recorded as yes. The sheet installs or updates managed tools only in the Debug app's own storage `~/.lungfish-debug`. The owner also said full-screen control is fine | Walk 2 ran hands off, and the manager drove walk 3 with full-screen control |
| O27 | Disk on this Mac | The owner approved deleting `lungfish-fastq-import-failure-58c429/.build` (13:23), asked the manager to quit an old Lungfish Debug that ran from that worktree (14:29), and approved thinning local snapshots (17:34) | Free disk rose from 80 GB to 332 GB, which keeps room for four agents' builds |

## C2 results (2026-10-22)

Session 2 finished C2 in four landings, 4 to 7, after landings 1 to 3 of session 1. Each lane got one review of the fields
it touches, a fix agent for the numbered fixes and a landing. The fix rounds got no separate re-review, except the fixes
of C2-RIBOPIN, which a second review read. A landing agent (sonnet at effort max) cherry-picks the lane commits with `-x`
in an isolation worktree, runs the build, the targeted tests, the seven ratchets and the golden compare, and the manager
fast-forwards `chtc-program`. Nothing is pushed. The lane reports are in `c2/lanes/`, the reviews in `c2/reviews/` and the
landing records in `c2/land/`. C2-FIX3 closes review fix 3 of the merged recipe, C2-TGFIX closes the hold on
C2-TRIMGALORE, and the GUI walk below pays the sheet's walk.

| Lane | What it does | Review verdict | Landing |
|---|---|---|---|
| C2-TGFIX | The fixes of the C2-TRIMGALORE review. Trim Galore storage counts every read it removes from its trimming reports (fix 1) and counts the stored file in the sidecar (fix 2). It stores a run with a joined third file (fix 3), keeps the Import sheet enabled for a merging recipe with Trim Galore (fix 4) and leaves no scratch and no process after a cancel in the mixed route (fix 5). Each storage step and the import notice say that Trim Galore removes reads (fix 7, O19) | Merge after fixes, 6 numbered fixes (`reviews/C2-TRIMGALORE.md`) | Landing 4, 8 commits |
| C2-BINNING | `illumina4` becomes the default quality binning on every import route (O14). It moves the tests and the help goldens that pinned the old default, keeps the sheet's binning choice when the platform changes, says that BBTools is missing when binning cannot find `reformat`, and names the binning in the app's in-place ingestion command | Merge after fixes, 9 numbered fixes and the owner question OQ1 | Landing 4, 9 commits |
| C2-RIBOPIN | Pins one hosted ribokmers index, the one-thread build `f88286f6…ede6` with its `NOTICE.txt`, in the tool lock and installs it by download (O16, O17). A pinned download publishes through DurableReplace, managed `db update` gets a cancel contract, a full record and a command test, and a sibling clone cannot replace an installed ribokmers index. The lock, the status and the records say that a rebuild is not a changed database | Merge after fixes, 9 numbered fixes, then Merge after fixes, 3 numbered fixes for the fix round | Landing 4, 13 commits |
| C2-ONTBIN | Bins chunked ONT payloads with `illumina4` by default (O15). It adds contract row M-6, a narrow named mask for BBTools run time and rates in a provenance stderr, so that the chunked parity replay compares equal. It keeps an ONT import's progress in order, says which imports bin quality scores, says that the Fluidigm sample split does not bin scores, tests that a SIGTERM during chunk binning cancels the import, and recaptures the `import-ont` help golden | Merge after fixes, 4 numbered fixes | Landing 5, 10 commits |
| C2-FIX3 | Runs the merged recipe's full-chain tests with real databases on a scratch storage root (`LUNGFISH_STORAGE_ROOT` and `LUNGFISH_CONDA_ROOT`), which needed no new seam. Four classes ran 88 tests with no skip. The two failures were stale expectations from before the tests moved to the merged recipe, and a test-only commit brings them to the recipe's values | Merge, no fixes | Landing 6, 1 commit |
| C2-EOOM | Starts every import `clumpify` with `-eoom`, so a full heap fails at once with a plain message (O25). It gives the recipe dedupe argvs and the status 3 check one place each, records every BBTools launch beside the out-of-memory contract, and says that the sample was not imported and which command has `--clumpify-heap-gb` | Merge after fixes, 4 numbered fixes | Landing 6, 5 commits |
| C2-PROVPATH | Keys an ONT import's tool steps by one spelling of the output path that outlives the staging folder, so an output spelled `/private/tmp/...` keeps its `reformat.sh` and `clumpify.sh` steps. It relocates a record from a staged folder in every spelling the record may hold. The gap predates C2, and landing 5 found it | Merge after fixes, 4 numbered fixes | Landing 6, 4 commits |
| C2-SHEETFIX | Fixes the three defects of the GUI walk below. The Import sheet keeps the detected Paired-end pairing after the platform changes to Oxford Nanopore and back, its pop-ups carry accessibility titles, and the durable command states the platform and pairing an import ran with while old records replay unchanged | Merge after fixes, 2 numbered fixes that change no behaviour | Landing 7, 2 commits |

| Landing | New head of `chtc-program` | What it holds | Results |
|---|---|---|---|
| 4 | `6bb2a3154a4fbda82ea197dd7dbf472b638f5e08` | C2-TGFIX, C2-BINNING, C2-RIBOPIN and K0 of C3 on the base `fc6576f39216fd3a75b5afb5d9003608f8ab6540`. 37 cherry-picks and 1 module map commit change 97 files (4,071 lines in, 1,101 out) | 741 tests, 1 failure and 1 skip. The seven ratchets sit at baseline, the Linux tier passes, and the golden compare matches in all four groups (cli-help 321 files, mapping 9, classifiers 24, genotype 133) |
| 5 | `9a070a76f38172388b3449f425b9f3ac5caab13b` | C2-ONTBIN (10 cherry-picks) and 3 folds, 26 files (858 in, 37 out). The folds remove the deleted ribokmers folder's row from the hosted databases table, note that a hosted file is checked with GET and never HEAD, and point the deacon-panhuman source URL at `bede/deacon` | 470 tests in 52 classes, 0 failures and 1 skip. Ratchets at baseline and the golden compare matches. The landing found the `/private/tmp` gap that became C2-PROVPATH |
| 6 | `12c931b14d621b160cfd1dc0262ad2a381f23760` | C2-FIX3, C2-EOOM and C2-PROVPATH (10 cherry-picks), 2 folds and 1 module map commit, 20 files (996 in, 151 out). The folds move the in-place ingest conformance test to the import default binning, since it still expected `none`, and add the scratch database root recipe to `docs/development.md` | 265 tests in 32 classes, 1 failure and 1 skip. On a scratch database root `RecipeIntegrationTests` passes 15 of 15 and `FASTQBatchImporterRecipeIntegrationTests` 4 of 4. The golden compare matches. The landing found a stale ribokmers `lockPinned` expectation in `ImportFastqE2ETests+RecordTruth.swift`, folded into landing 7 |
| 7 | `beec05eea45a0a53fc8aed634c43ca346758bebe` | C2-SHEETFIX (2 cherry-picks), 2 folds and 1 module map commit, 7 files (274 in, 49 out). The folds pin the old-record replay test to a literal command as the earlier builder wrote it, and make the ribokmers `lockPinned` expectation follow the index digest so that it holds for any install | 110 tests in 10 XCTest classes with 1 failure and 1 skip, plus 28 Swift Testing tests. On a scratch root with a fresh ribokmers install `ImportFastqE2ETests` runs 21 tests with 1 skip and 0 failures, and `FASTQBatchImporterRecipeIntegrationTests` passes 4 of 4. Ratchets at baseline and the golden compare matches. C2 is complete |

The one failure in landings 4, 6 and 7 is `ConformanceFixtures.swift:81`, which needs a deacon-panhuman install record that
the Stable install on this laptop lacks. It does not occur on a scratch root (`docs/development.md`), and it did not occur
in landing 5, whose classes never read that fixture. The skip is the documented `testSIGTERMEscalationChild` helper.
After landing 7 the program branch is 120 commits past `8190b9000` and its module map is current.

## The GUI walk of the Import FASTQ sheet (2026-10-22)

The sheet's walk with Computer Use was owed after C2-SHEET. Walk 1, by an agent, was blocked by the missing scratch
project, the Update tools sheet and user interruptions. The owner allowed the sheet's Update button (O26), an agent
launched walk 2 hands off, and the manager drove walk 3 itself, whose report is the record,
`c2/lanes/C2-GUIWALK2/C2-GUIWALK-manager.md`. The Debug app came from `chtc-program` at `9a070a76f`. It ran with
`LUNGFISH_UI_TEST_MODE=1`, the live-smoke backend and a scratch project, and the route was File, Import Center, Sequencing
Read Files, Import. The inputs were an Illumina pair and an ONT FASTQ copied from `Tests/Fixtures/`.

| # | Check | Result | What was seen |
|---|---|---|---|
| 1 | The sheet opens for Illumina paired input | Pass | The sheet shows R1 `test_1` and R2 `test_2`, detects Illumina and Paired-end |
| 2 | The presets and their switch defaults | Pass | The recipe pop-up lists Illumina Amplicon Merge, VSP2 target enrichment and Wastewater metagenomics. VSP2 sets Remove duplicate reads on and Remove ribosomal RNA reads off. Wastewater sets both on |
| 3 | The description and the Workflow line follow the boxes, the Tab order, the labels | Partly | Clearing Remove duplicate reads gives "VSP2 target enrichment, with Remove duplicate reads off." and drops the dedup step from the Workflow line. The wastewater Workflow line includes "Remove ribosomal RNA reads". The Tab order was not walked. Checkboxes and buttons carry titles in the accessibility tree, and the four pop-up buttons show no title to the Computer Use reader |
| 4 | The binning default and a kept choice | Pass | Illumina starts at "Illumina (7-level)". After choosing None and changing the platform to Oxford Nanopore and back, binning stays "None (preserve original)". ONT input detected as Oxford Nanopore also starts at "Illumina (7-level)". The ONT barcode recipe pop-up was not reached, since it needs an ONT run folder |
| 5 | Trim Galore with a merging preset | Pass | No refusal and the Import button stays enabled. The note reads "Trim Galore also performs adapter detection/removal, quality trimming, and short-read filtering." |
| 6 | The import records | Pass | VSP2 with BBTools gave 116 reads, 17 pairs and 82 merged. The Inspector shows Quality Binning Illumina (7-level), Preset VSP2 target enrichment, Remove duplicate reads On (preset), Remove ribosomal RNA reads Off (preset), the recipe digest, and step 3 as "Not run" because the switch is off. The Operations command ends `--recipe vsp2-target-enrichment --clumping-tool bbtools`. VSP2 with Trim Galore finished as Completed with Warnings, and the warning says Trim Galore 2.3.0 trimmed adapters and bases under quality 20, removed the reads left shorter than 20 bases (0 of 17 pairs and 0 of 82 unpaired reads, each pair as a unit), and that no Trim Galore 2.3.0 option turns this off |

| # | Finding | What was done |
|---|---|---|
| 1 | Pairing resets. With R1 and R2 detected as Paired-end, changing Platform to Oxford Nanopore and back to Illumina leaves Pairing at Single-end, so a user who touches the platform pop-up imports a pair as single-end. A change through Ultima Genomics and back kept Paired-end. The defect is likely older than C2 | C2-SHEETFIX task 1 gives the pairing back (landing 7) |
| 2 | The recorded command of an import that keeps the detected platform says `--platform auto` and names no `--pairing`, while an import with a changed platform names both. Replay re-detects, but the record does not state the platform and pairing the run used | The manager ruled that the bundle record states the resolved platform and pairing, the Operations row keeps the launched argv, and old records replay unchanged. C2-SHEETFIX task 2 does it (landing 7) |
| 3 | The sheet's four pop-up buttons show no accessibility title to the Computer Use reader | C2-SHEETFIX task 3 labels the pop-ups (landing 7). The walk asks for a check of the labels with Accessibility Inspector |

The Wispr Flow overlay refuses clicks in a band near the screen centre, so a sheet or button there needs the Return key or
a moved window. The debug app was quit through its app menu item at the end of the walk.

## C3 votes (2026-10-22)

C3 began from the SWIFT and ARCH design inventory `c3/inv/C3-design.md` of session 1. Six seats (SWIFT, ARCH, BIO, UX, QA
and CHTC) wrote memos with votes and conditions on the inventory's questions, and a tally by `lge-expert` (sonnet at effort
max) merged them without ruling. Round 1 voted five questions. The questions that the memos raised afterwards went to a
ruling by one field, to a fact-check, or to a second round of six memos (opus at effort xhigh) and a second tally. The
records are in `~/lungfish-phase-records/chtc-program/c3/` (`memos/`, `votes/tally.md`, `votes/tally-r2.md`, `rulings/` and
`reviews/`). The rule of the panel decisions above still holds, so a vote passes by a majority of the seats that vote and an
abstention does not count. The executor was named `lungfish-htc` when round 1 voted, and ruling A2 renamed it
`lungfish-executor`, so the texts below say "the executor".

| Id | Decision | Vote |
|---|---|---|
| Q-C3-1 | A. CHTC runs every full pass (record counts, the Q20 and Q30 counts, `seqkit stats`) and its run record carries the values. The adopt on the Mac writes the sidecar and the envelope from them with today's IO code, and adds a 100,000-read head sample for the charts. Signing stays on the Mac. This also settles V4a | 6 to 0 |
| Q-C3-5 | A. The executor is sent beside the Apptainer image with its own SHA-256 in the plan and is not baked into the image | 6 to 0 |
| Q-C3-7 | A. A plan refuses `auto` for the clumping tool and the compressor outright, and the Mac resolves them when it writes the plan | 6 to 0 |
| Q-C3-9 | A. The portable reader on Linux decompresses gzip through a pinned `pigz -dc` child from the image, with no in-process zlib and no new C dependency | 6 to 0 |
| Q-C3-10 | A. The Linux test container is Apple `container` when installed and else `docker`, with one image pinned by digest | 3 to 0, BIO, UX and CHTC abstained |
| N2 | A. The plan writer names `bbtools` at the plan's pinned heap for every sample, so the template stays per recipe and V5 holds. The user may name `trim-galore` or `none` instead | 5 to 1, UX voted C, which offers no Automatic for a run off the Mac |
| N9-V15 | A. The lines that may differ between a bundle adopted from an executor run and a Mac import of the same sample are the lines that name where or with what binary a step ran, plus the steps only the executor route runs. Every count, digest and relative argv must be equal | 6 to 0, and BIO's vote reads A amended by its V15-R, under which no compressed digest is compared |
| Q-S-R1 | A. One C target, the repository's first, holds a non-variadic wrapper of `prctl(PR_SET_CHILD_SUBREAPER)` and its getter, with a Linux-only body and no external library. K3 adopts orphans as SWIFT's N4 ruling sets | 6 to 0 |

The first five rows are round 1 and the last three are round 2. No seat voted against a winning option in round 1. BIO
abstained on Q-C3-10 because its condition B-C20 applies to either option, CHTC because no local container result can
stand in for the CHTC signal check under either runtime, and UX because the choice touches no label, record or view. The
second tally merges the seats' lists for V15 into 25 lines, names 27 conflicts between the memos and 13 open rows, and
settles none of the conflicts, which the lane briefs carry.

The first tally's flags F1 and F2 ask this record to revisit V3 and to settle V4a. SWIFT and QA asked for a revisit row
under the old id and ARCH asked to reword the row, so this record takes the revisit row.

| Id | Amended decision | Basis |
|---|---|---|
| V3 (revisit) | Shape B′ stands, narrowed. The byte code that moves into the one shared target is the layout writer, the pair split and join, the storage plan, and the passes that produce the record counts, the Q20 and Q30 counts and the statistics values, which are "the counts and statistics values" and no longer "statistics, sidecar". The sidecar and envelope writers stay on the Mac and run at adopt from the run record, with today's IO code and with signing on the Mac | Q-C3-1 A (6 to 0), the tally's flag F1, and the owner's confirmation of the O4 reading (O24) |
| V4a | Settled. The provenance envelope is written at adopt on the Mac from the run record, and no portable envelope writer is built for CHTC | Q-C3-1 A, the tally's flag F2 and O24 |

The flags F4, F5, F6 and F8 are settled by N2, by O24, by O23 with ruling A5 and by the V15 vote.

## C3 rulings and fact-checks (2026-10-22)

A question that the tally routes to one field went to a ruling by an `lge-expert` at opus and effort xhigh, kept in
`c3/rulings/`, and a claim that the memos lean on went to a `manual-fidelity-reviewer` at sonnet and effort max, kept in
`c3/reviews/`. A ruling or a fact-check replaces the memos where they differ, and each binds the lane briefs.

| Id | Ruling | By |
|---|---|---|
| Q-C3-8 | Granted, the amendment of `docs/contracts/RUNNING-A-TOOL.md` that makes the executor's POSIX launcher the one stated exception to `ToolProcess`. Refused, an exempt-list entry for the executor's folder. A third count in the process-spawn ratchet, `raw_posix_spawn_calls` with baseline 0, is exempt only under `Sources/LungfishCore/Process/` and the executor's process folder | ARCH, not voted |
| N3 | Clumpify's compressor. Neither option is taken. The Mac puts no pigz on clumpify's `PATH` and no argv changes to `pigz=f`, because at every level LGE passes (1, 4 and 9) BBTools 40.02 never reaches its pigz branch. Every argv keeps `pigz=t` and `zl=` byte for byte, a plan names `bgzip` for the BBTools storage steps, and every record states the writer and the level | BIO |
| N6 | The exact Q20 and Q30 count is a recorded step on the CHTC route, in the run record and in the adopted envelope as a child of the executor's step. The 100,000-read head sample is no step in C3. The counter step, the `seqkit head` step and a failed-statistics warning for the Mac route wait for a later lane (MO-B1) | BIO |
| N4 | On Linux the executor marks itself a child subreaper with `prctl(PR_SET_CHILD_SUBREAPER, 1)` before it starts any child, so every orphaned descendant, a `setsid` double fork included, re-parents to the executor whatever PID 1 is and whether or not the job has a PID namespace. K3 keeps the parent walk beside it | SWIFT |
| N8 | Each step's child runs with its working directory at the work root and names its files by the plan's relative paths, so the argv in the run record is the argv the executor passed and holds no node path. The work root is the real path of the folder that holds the plan file. The executor reads no `_CONDOR_` variable | SWIFT |
| A1 (N5) | `ImportSettingSource` gains a case, `plan`, and moves to `LungfishPortable`. An adopted record says `plan` in the sources of the values the plan fixed, and the plan keeps the user's own source | ARCH |
| A2 | The product is `lungfish-executor`, the executable target `LungfishExecutor` and its tests `LungfishExecutorTests`, renamed before K1 lands, since HTC now names the separate orchestration layer | ARCH |
| A3 | The x86-64 executor ships stripped as a sealed resource, never as code, at `Contents/Resources/LinuxExecutor/x86_64/lungfish-executor` beside a `manifest.json`, from C4 on. This settles N1 and the text of QC18 | ARCH |
| A4 | The executor is a generic x86-64 Linux program. Its whole input is the plan, the files the plan pins in the plan's folder and the image's tool manifest, and its whole output is the payloads and the run record in that folder. It holds no HTCondor code. In round 2 ARCH replaced the site files with `--site-fact KEY=VALUE` arguments that fill `siteFacts` | ARCH |
| A5 | Trim Galore is offered on CHTC (O23). The Mac plan writer's refusal of `trim-galore` (K4.9) and UX's condition U-8 are withdrawn. K2 moves the whole Trim Galore storage route behind the same seam as clumpify, and K5 adds Trim Galore 2.3.0 to the linux-64 lock and the image | ARCH |
| A6 | F-A1 is false, so the K1 check in `portable-imports.sh` must itself fail when a target other than the executor's test target lists the executor among its dependencies | ARCH |
| OQ-7 | How the C target of Q-S-R1 enters the ratchets. Two counts guard two things, `c_targets` with baseline 1 and `c_target_dependents` with baseline 0, which counts the Swift files that import the target. The ruling gives the K1 brief a 21-row table (`c3/briefs/lane-K1.md`) | ARCH |

| Fact-check | Verdict | What it changes |
|---|---|---|
| F-A1, SwiftPM refuses a library target that depends on an executable target | False | SwiftPM 6.4 accepts it in both build engines, and a library that also imports the executable builds under `--build-system native`. K1's check cannot lean on SwiftPM (A6) |
| F-A2, `pigz -dc` decodes concatenated gzip members, BGZF included, as `/usr/bin/gzip -dc` does | True | The output was byte-identical on six inputs. The error cases differ, so K3's equality test compares the exit status for failures and leaves out partial output, stderr text and a trailing-garbage file |
| F-A3, clumpify with `pigz=t` looks for pigz on `PATH`, and `groups=auto` splits an input to fit `-Xmx` | Partly | The pigz half is false. With `zl=4` BBTools returns a BGZF writer first, which is the external `bgzip` when it is on `PATH` and BBTools' own Java writer otherwise. The `groups=auto` half is true. This answers Q-S1 and feeds N3 |
| An Apptainer rebuild is not byte-reproducible | Partly | True by default. Apptainer 1.5.0 added `SOURCE_DATE_EPOCH` and `--reproducible`, so the result depends on pinned inputs. Q-C3-5 stands, and the plan says a rebuild is not promised to reproduce the bytes |
| Apple `container` PID 1, and a test binary as PID 1 having to reap an orphan | Partly | The reaping is true, since Docker 28.3.2 without `--init` held a zombie. `container` is not installed on this Mac, so its PID 1 is unverified, and K0's tier script passes the init flag to both runtimes |
| The `PATH` that a GUI launch of the Mac app finds | True for a Finder, Dock or Spotlight launch | The `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, with none of `pigz`, `bgzip`, `brew` and `conda`. `open` run from a shell forwards the shell's environment, which hides this. Lanes say "a Finder or Dock launch" and never "a GUI launch" |
| EL7 and EL8 boot cgroup v1 by default, `-C` gives the container its own `/proc`, HTCondor 26.1 still passes `-C` | Partly | The cgroup v1 claim is true, so C4 requires `OpSysMajorVer >= 9`. The other two claims are left to K3's CHTC jobs |
| FC-B1, who writes the gzip of Trim Galore 2.3.0 under `--clumpify` | 3 true, 4 false, 1 unverifiable | Trim Galore writes the gzip itself through the Rust crate `flate2`, one gzip member per clumpify bin, at the `--compression` level (1, 4 or 9), and never looks at `PATH`. The output is not BGZF. The managed osx-arm64 build compresses through the environment's `libz` 1.3.2 and not the `zlib-rs` that `Cargo.toml` names. The linux-64 build is unverified |
| FC-B2 and FC-Q1, clumpify without `-eoom` after an `OutOfMemoryError` | Both outcomes occur | At one group, 20 of 27 out-of-memory runs exited with status 1 inside 3 s and 7 hung idle (`threads=1` hung in 4 of 7 runs). At `groups=auto`, 5 of 5 exited. With `-eoom`, 3 of 3 exited with status 3 in under 1 s. This led to O25 |

CHTC's own facts, read with `condor_status -af` on `oconnor-ap4000` on 2026-10-22 (Q-C3-6), count 265 machines, 255 of them
with `HasCHTCStaging`. Of those, 198 run CentOS Stream 9 (kernel 5.14), 51 AlmaLinux 10 (kernel 6.12), 4 CentOS 8 (kernel
4.18), 1 CentOS 7 (kernel 3.10, Apptainer 1.3.1) and 1 is aarch64. Every other staging host runs Apptainer 1.5.3 or 1.5.4,
and `MachineMaxVacateTime` is 600 s on every slot. HTCondor sends `kill_sig`, SIGTERM by default, for eviction, removal and
hold alike, since `remove_kill_sig` and `hold_kill_sig` apply to the scheduler universe only. So a run record says
`interrupted` with the signal number and the cause comes from the job event log. Signals through Apptainer's init shim are
still unobserved.

## C3 progress (2026-10-22)

The lanes are K0 to K5 of the inventory, run as `lge-worker` agents and reviewed by the seats the tally names. The state
below is the manager's STATE block of 17:35 CDT on 2026-10-22, and the section K4 and the close of C3 below supersedes it. K0 is the only C3 lane on the program branch so far.

| Lane | What it does | State |
|---|---|---|
| K0 | Adds the empty `LungfishPortable` and `LungfishHTC` targets, pins the Linux toolchain (Swift 6.4.0 and Static Linux SDK 0.1.0) and adds the Linux tier script, which picks a container runtime only when it answers, runs the containers hardened and probes PID 1. A static build inside the repository takes 73 s and gives a 148 MB static ELF. CHTC test job 590464 passed, on bytes that the K0 fix then changed (the x86_64 SHA-256 now begins `a23547ed`) | Landed in landing 4 (7 commits). The review found 5 fixes, all done at `fa6e2e110` |
| K1 | Renames the executor to `lungfish-executor` and adds the C target, the module map line, the contract change and the ratchets (milestone 1, `e11356211562771a591e298c8e0480e86d10f3db`, no moves). Continuation 1 (`d5b56c6a27d2ea05fdea009a9f7b97a9696938ef`) adds the reader seam, `FileDigest` and the reader moves, and leaves the Linux build broken on `autoreleasepool`. Continuation 2 adds a shim, moves the Foundation-only IO types, then the rest of the moves, and runs the golden compare | Continuation 2 running |
| K3 | The Linux process subset, the subreaper and the signal tests, at `9d98a0f12d52649e258eaf16fa32dcadc53f4b2a` on K1's milestone 1. CHTC test job 591283 passed | Review running. K3.1 and K3.2, the pigz child over K1's seam, wait for K1 |
| K5 | The linux-64 lock with Trim Galore 2.3.0 | Running on `beec05eea` |
| K2 | `PortableStorageStep` with the Trim Galore route behind the seam | Not started. It needs the N3 words of BIO's ruling, ARCH's conditions of round 2 and UX's words of round 2 |
| K4 | The plan, the run record and the parity tests | Not started. OQ-8, the OQ-9 vote and UX's N7 ruling for C4 are open |
| K6 | The statistics builder that both the Mac import and the adopt call | Proposed by ARCH, not started |

## Owner answers of 2026-10-23

Session 3 ran on the owner's laptop on 2026-10-23, after the owner tried to continue the program on the Mac Studio and
found the program branch and its records only on the laptop.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O28 | Q-C3-11, the retirement time of group jobs on the group's own slots | "We still have a 72 hour limit on oconnor machines" | The bound that C4-06 checks is 72 hours on the `oconnor` machines. The CHTC seat found that no C4 condition changes |
| O29 | Q5 first part, may LGE submit over a reused SSH session | "its fine to reuse SSH connections" | The C4 lane may submit, read the job log and fetch outputs over one reused SSH session. The Globus and quota parts of Q5 stay open |
| O30 | The session's scope | "Finish this work, merge, and push so I can continue building the next phase on the Mac Studio." | Session 3 finishes C3 with K4, records it, merges the program into `main` and pushes. C4 and C5 run on the Mac Studio |

## C3 round 3 (2026-10-23)

Six memos (`c3/memos/<FIELD>-r3.md`, Opus 5.5 at effort xhigh, the CHTC seat as `general-purpose`) voted three questions
and gave the field rulings the K4 brief needed. The manager's tally is `c3/votes/tally-r3.md`.

| Id | Decision | Vote |
|---|---|---|
| K1.3-A | A. Tally row K1.3 is amended as SWIFT's ruling 1 of the K3B review reads. A reader's pipe is made with `pipe()`, marked close-on-exec and handed to its child under the one spawn lock, since macOS declares `pipe2` only from version 27. CHTC's condition is one spawn lock per process | 4 to 0, BIO and UX abstained |
| XC-14 | A. The V15 comparison of record lines lives in C4 only. K4's parity test compares E0 to E3, reports E4, and checks that the run record's counts equal its own payload's | 6 to 0 |
| OQ-9 | A. V5 holds. A per-sample `request_disk` is a submit-side sample-sheet value that never reaches `plan.json`, an argv or the child environment. Any other size-derived submit value needs its own decision (ARCH) | 3 to 3, the tie went to A, the smaller change |

| Id | Ruling | By |
|---|---|---|
| OQ-8, first half | With `auto` requested, the plan's clumping entry stores `auto`, the resolved `bbtools` and the source `default`. A named tool takes `option` | ARCH |
| Placements | Plan types, the image tool manifest and `PlanResourceResolver` in `Sources/LungfishPortable/Plan/`, run record types in `Sources/LungfishPortable/RunRecord/`, the emitter in `Sources/LungfishWorkflow/ExecutorPlan/`, `run --plan` in `Sources/LungfishExecutor/`, format pages `docs/formats/executor-run-record.md` and `docs/formats/executor-plan.md`, the record written last as `run-record.json` | ARCH |
| OQ-8, second half | K4's N2 set is four tests, N2-T1 to N2-T4, and the fill tests move to C4 | QA |
| OQ-4 for K4 | The plan's clumping reason is "The automatic clumping choice names BBTools clumpify for every sample, at the plan's heap and with no size estimate, because clumpify's groups=auto compares its memory estimate for each input with the memory available in that heap and splits a large input into more groups." | UX |
| Q-K4-1 | `/opt/lungfish/image-manifest.json` stays the compiled-in path, and `run --plan` gains `--image-manifest <absolute file>`. The plan pins the manifest's digest and size with no path, and the record states the digest, size and source (`image` or `argument`) | SWIFT, ARCH consulted |
| Parity | `testVSP2PlanReplayMatchesInProcessImport` runs the merged recipe as VSP2 with rRNA removal off and as wastewater with rRNA removal on, on the 1,000,000-pair slice pinned by SHA-256, at threads 1 with bbtools, a 4 GB heap, `illumina4` and `bgzip` | BIO |
| Q-K4-2 | Refused, a third function in the C target. Swift's Musl module imports `posix_spawn_file_actions_addchdir_np`, so the executor calls it directly (`c3/rulings/ARCH-K4.md`) | ARCH |
| Q-K4-3 | A step's `PATH` is the manifest's tool folders in manifest order, then a fixed `/usr/bin:/bin`, with nothing inherited. Java comes only from the manifest. The record states the search path and the runtimes (`c3/rulings/SWIFT-K4.md`) | SWIFT |
| QK2 | Moved to the first C4 lane that touches `ExecutorSpawn.swift`. QA asked that the spawn rule be made structural. The vote's condition, one spawn lock per process, is met | The manager |

## K4 and the close of C3 (2026-10-23)

K4 ran as milestones of one `lge-worker` each (Opus 5.5 at effort xhigh, fixes at effort max), with two in parallel where
their files did not overlap. The manager merged each pair, and two rounds of four reviews (SWIFT, ARCH, BIO and QA, Sonnet
5.5 at effort max) read the work. The reports are `c3/lanes/K4/` and the reviews `c3/reviews/K4A-*.md` and `K4B-*.md`.

| Part | What it does |
|---|---|
| M1 | Moves `ImportSettingSource` into `LungfishPortable` by a pure move and adds `plan`. Adds the plan types and decoder, `PlanResourceResolver`, the run record types and the image tool manifest with its `conda-meta` builder |
| M2 | Adds the plan emitter and folder writer from the engine's own steps, the N2 tests, and plan forms for the deacon scrub, the deacon rRNA filter, the length filter and a named Trim Galore |
| M3 | Adds `lungfish-executor run --plan` with its self-check, manifest read, preflight, site facts, refusals, stderr tail and exit codes |
| M4 and M4b | Run the storage step on every route, the merged-to-mixed step and the full passes (record count, the exact Q20 and Q30 counts, `seqkit stats -a -T`), and write the two format pages |
| M5 | Adds `lungfish-executor image-manifest`, the plan replay parity test and the CHTC job |
| Fixes | 28 numbered fixes of part A, 23 of part B and 22 of part C (the last round added UX for the words), among them a NUL byte past the resolver's path check, symlinks staged by the folder writer, overflow in heap and deadline values, an unpinned `gzip`, a lost deadline reason, an abort when stderr is closed, and the child `PATH` of Q-K4-3 |

The results that close C3, each on the composed head of K4.

| Check | Result |
|---|---|
| The Mac replay, `testVSP2PlanReplayMatchesInProcessImport` | Both cases pass on the 1,000,000-pair slice with the real tools and a scratch storage root. E0 to E3 are equal, and E4 is equal in stored order. The VSP2 case keeps 950,309 records (153,874,043 bases, 100,191 pairs and 749,927 merged reads) in 79.0 s in process and 72.6 s replayed. The wastewater case keeps 196,598 records in 45.9 s and 41.7 s. Clumpify made 1 group on both routes |
| CHTC job 1, cluster 592725 | `lungfish-executor image-manifest` ran on `e2469` (AlmaLinux 10, Apptainer 1.5.4, HTCondor 26.1.0) in the C0 image and listed 520 tools, manifest SHA-256 `4b0c0fd1...2b54`. The panhuman index on `/staging`, hashed on the node, equals the plan's pin `a1577a10...71e6` |
| CHTC job 2, cluster 592726 | `lungfish-executor run --plan` ran the VSP2 case on `e2613` (CentOS Stream 9, `x86_64-v3`) in 188 s with binary `f5e36c51...b882b`. Its record count (950,309), Q20 (151,987,498) and Q30 (145,075,205) counts, every recipe step's read counts and the E2 and E3 digests equal the Mac replay of the same plan, and the decompressed streams are byte-identical (E4) |
| CHTC job 2 again, cluster 592727 | The same plan with the landing head's binary `2b005db7...9aaa` (`57f70bd9e`) ran on `e4075` in 125 s, and the Mac replay of it in 118 s. Every count, every recipe step's read counts and E2 to E4 are equal, and equal to cluster 592726 |
| Golden compare | Passes at `cd3345e4a` (cli-help 321 files, mapping 9, classifiers 24, genotype 133) |
| Gates | At the landing head `57f70bd9e`, 27 test classes (255 tests) pass, the executor's timing tests pass with every core busy, all 14 ratchets are at or below their baselines, the module map is current, and the Linux tier passes on a clean commit (`c3/land/land-10.md`) |
| Unit tier | Red at `b649ec95b` on 3 of 22,488 tests: the ONT import transcript after C2-ONTBIN added a binning pass, a source-text test that still named the ribokmers installer C2-RIBOPIN replaced, and a K4 deadline test whose tool could not write its PID file under full parallel load. Fixed in `e789e9ef2`, `82cfabeef` and `c203ebac8`, and green at `c203ebac8` |

Moved out of K4 into C4 or later, each with its reason in `c3/lanes/K4/`:

- The ONT import now prints "Import complete" twice, before and after its binning pass (`Tests/Fixtures/cli-events/commands/fastq-import-ont/complete.ndjson`). UX words it in C4 or later.
- QK2, the spawn rule made structural (the manager's decision above).
- The CHTC job script's check for `dirname`, `basename` and `readlink`, which C4's submit template carries.
- The plan folder writer copies the executor and each database into every sample's folder (ARCH's note on the 3.3 GB index on an external volume).
- `testClumpifySplitsIntoGroupsUnderPlanHeap` on real data, replaced in K4 by QA's N2-T4 with an injected launcher.
- RiboDetector, an unfused fastp, the interleaved-to-paired conversion and the storage route `none` for two files or a gzip input without binning, which the plan writer refuses with a named error.

## C4 pre-brief round (2026-10-23, session 4)

Session 4 ran on the Mac Studio (galah) on 2026-10-23. It settled what the C4 brief needed and wrote the C4 design
inventory, and the owner then moved Phase 2.14 ahead of C4. The records are in `~/lungfish-phase-records/chtc-program/c4/`
(`memos/`, `votes/tally-c4.md`, `votes/tally-c4r2.md`, `factcheck/`, `inv/C4-design.md`, `events.log`). Every seat ran on
Opus 5.5 at effort xhigh, the CHTC seat as `general-purpose`. The fact sheet, the fact-checks and the round-1 tally ran on
Sonnet 5.5 at effort max.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O31 | The retirement limit | "yes the 72 hour limit applies to oconnor jobs" | Confirms O28 for C4-06 |
| O32 | Q5 | "I don't understand this question ... Have the experts answer it by consensus." | The panel answered Q5 by consensus, below |
| O33 | The order of C4 and 2.14 | "Run Phase 2.14 first in a fresh session, then the Preview and the Phase 3 setup. C4 resumes afterwards in its own session from the pre-brief records." | C4 and C5 run after Phase 2.14 |
| O34 | Whether galah is a Mac only the owner manages, which CHTC's login guide requires for a reused SSH session | "Yes, only I manage it" | The C4 lanes may use one reused SSH session from galah |

The panel's answer to Q5, by consensus, 6 to 0 in round 2 (`c4/votes/tally-c4r2.md`).

- Reused SSH session. O29 covers the C4 lane, and CHTC's login rule holds it to a Mac only the owner manages (O34). The
  shared connection closes at each session's end. LGE's own SSH call takes the host alias and the SSH config file as
  settings, passes `-o BatchMode=yes` and a `ConnectTimeout`, and adds no `ControlMaster`, `ControlPersist` or
  `ControlPath` of its own. A C5 launch from LGE over SSH, the owner's or a lab member's, waits on CHTC's written
  agreement, as V14 says.
- Globus. LGE does not use it. The full-sample run waits on one working upload route for R1 and R2, which is the access
  point (as C0 did, and which CHTC asks people not to use for large files), Globus to the "CHTC Staging" collection, or
  `scp` to `transfer.chtc.wisc.edu`. The runner never moves a read file and checks each input with `stat` before it
  submits. The executor's digest check on the node proves the files. The full-sample run's R1 and R2 leave `/staging` only
  after the adopt passes and the E0 to E3 comparison is in the lane report.
- Quota. The manager read it on 2026-10-23 with `get_quotas -p /staging/groups/oconnor_group`. The group folder holds
  128,748 of 150,000 GB and 2,889,404 of 3,000,000 files, so about 21 TB and 110,000 files are free and neither C4 nor C5
  waits on a raise. One shared copy per SHA-256 serves every job, the executor included. The full-sample run also waits
  on the owner's confirmation that the study's data terms let the 32748 raw reads sit on `/staging`.

| Id | Decision | Vote |
|---|---|---|
| XC-1 | A. The stored payload's SHA-256 and size are recorded on both routes and never compared, and the V15 list says so | 6 to 0 |
| XC-2 | A. Clumpify's group count is a listed line, printed for both routes, and never fails the comparison | 6 to 0 |
| XC-3 | A. "Digest" in N9-V15 means the digests of the inputs, recipes, databases and E0's plans, plus the payload's E2 and E3. E4 is reported and never fails | 6 to 0 |
| XC-4 | B. A tool's path, its build string and the line that names where its version came from are route-shaped lines. Every version the plan pins must be equal | 4 to 2 |
| XC-5 | A. The list names `siteFacts` and the `--site-fact` arguments and no site file | 6 to 0 |
| XC-6 | B. One listed class holds the values in which the Mac differs from itself (dates, times, durations, scratch folder names, peak memory) | 5 to 1 |
| XC-7 | B. The three basis keys are listed, null on the adopted record (C4-01) and the host's value on the Mac. The requested tool and the reason must be equal | 5 to 1 |
| XC-8 | A. The list names the steps only one route holds, the executor's step, the counter step until MO-B1 removes it, and the adopt step | 6 to 0 |
| XC-9 | A. The list names one route-shaped line for the `seqkit stats` output. The statistics values must be equal | 6 to 0 |
| XC-10 | B. Each argv compares token by token after one function strips the Mac's staging root from path tokens. The executable compares by its file name | 6 to 0 |
| XC-11 | C. The lane never widens the list. An unlisted difference fails the test, and the lane fixes the code or brings the line to the panel with both values and its reason. A removal needs only the reviews C4-16 names | 5 to 1 in a round-2 runoff, UX for B |
| XC-12 | A. The list's baseline is BIO's V15-R as N9-V15 reads it, amended by this round | 6 to 0 |
| XC-13 | A. On the Mac record the source keys read `option`, and on the adopted record `plan` | 6 to 0 |
| Child environment | A. `environmentNames`, `searchPath` and `runtimes` are lines only the executor route holds | 6 to 0 in round 2 |

The exact words of each row, with the conditions the winning seats attached, are in `c4/votes/tally-c4.md` section 1 and
`c4/votes/tally-c4r2.md`.

| Id | Ruling | By |
|---|---|---|
| OQ-1 (N7) | An adopted record shows its per-run facts once in the Runtime section, each node step gets one "Version and build" row, and everything else stays in Raw JSON | UX, ARCH consulted |
| OQ-5 | `siteFacts` show under the label "Reported by the launcher", with UX's words for a version's source | UX |
| OQ-2 | ARCH concurs with QA's amended QC18 text for the bundle lane and withdraws its XC-19 sentence | ARCH |
| FC-A1 | C4-03 stands. The submit template passes node facts as `--site-fact` arguments from machine-ad macros, only for values with no space or quote, and no site-facts file is written | CHTC |
| FC-Q2 | The executor build takes the release's prefix maps for the checkout and scratch folders, and the Linux tier strips a copy and fails on all 13 portability patterns through a new `--binary --all-labels` mode. A plain `--binary` pass is never evidence | QA |
| Q-C4-5 | No new plan field. The image tool manifest copy and the SIF's identity become committed resources | ARCH |
| Q-C4-6 | The parity tests adopt a Mac replay through an `ExecutorAdoptPolicy` value that is `internal`, never `package` or `public` | ARCH, QA consulted |
| Q-C4-7 | The first job's `request_disk` is sized from a 10,000,000-pair Mac replay in GB units, and the payload lands in `/staging` | CHTC |
| Q-C4-8 | The lane submits, and C4's code opens no SSH | ARCH, CHTC concurs |
| Q-C4-9 | Threads 1 on both routes for the full-sample run, since fastp's dedup at 8 threads changes the kept-pair count | BIO, SWIFT consulted |
| Q-C4-10 | Cluster and process ids reach the envelope only as site facts, and the job log's usage numbers stay in the program record | ARCH, UX consulted |
| Q-C4-13 | RiboDetector, an unfused fastp, interleaved-to-paired and storage `none` get plan forms in C5 | BIO |
| Placement | One shared copy per SHA-256 of the executor and each database serves every job, and no sample folder holds either | ARCH |

| Fact-check | Verdict | What it changes |
|---|---|---|
| FC-A1, HTCondor machine-ad macros in `arguments` | Partly true | `$$(Attr)` and `$$([expr])` expand. A default form exists only for the plain form, a missing attribute holds the job, a value with a space needs single quotes and one with a quote cannot pass. The manual was read to 25.14.1, and the C4 node job checks 26.1 |
| FC-A2, an ELF in the app bundle | True | The release Tools walk never visits `Contents/Resources/LinuxExecutor`, and the app's signature seals the ELF as a resource. Notarization of an ELF stays to be seen in the bundle lane |
| FC-Q2, the stripped executor against the portability scan | Found | It holds 119 BoringSSL source paths in `.rodata`, which fail the app-folder scan. Clang and Swift file-prefix maps remove every one |

The design inventory `c4/inv/C4-design.md` sets C4 as ten lanes, S SPAWN (QK2), I IMAGE, H HTCONDOR, F FILL, R RECORD,
A ADOPT, P PARITY, U UI, B BUNDLE and X ACCEPT, with wave 1 of S, I, H, F, R and B. Its owner questions remain, Q-C4-1
(the upload route for the 61.6 GB of reads), Q-C4-2 (whether the reads come to galah for the comparison import) and
Q-C4-12 (which Mac builds the Debug app that the laptop uses).

## Open questions that remain (2026-10-23, session 4)

| Id | Question | Who answers |
|---|---|---|
| Q5 owner steps | Confirm the study's data terms, try Globus to "CHTC Staging" once, say how many samples 32748 holds and their size, and send CHTC the panel's draft (upload route, agreement for launches from LGE under V14) | The owner |
| Q-C4-1, Q-C4-2, Q-C4-12 | The upload route, the reads on galah, the Mac that builds the Debug app | The owner |
| MO-S1 | Should the Mac's own `auto` follow the plan's rule? It changes the stored bytes of large Mac imports | The owner |
| MO-B2 | Should clumpify follow the user's compression level? It changes compressed bytes | The owner |

## C4, the Linux runner and the adopt (2026-10-24 to 25, session 5)

Session 5 ran on the Mac Studio (galah) from 2026-10-24 10:32 to 2026-10-25 01:45. The records are in
`~/lungfish-phase-records/chtc-program/c4/` (`notes.md`, `events.log`, `briefs/`, `lanes/`, `reviews/`, `rulings/`,
`votes/`, `memos/`, `land/`, `factcheck/`, `llm/`). Lanes ran as `lge-worker` in their own worktrees, Opus 5.5 at effort
xhigh for design and Sonnet 5.5 at effort max for fixes and landings. Reviews ran on Sonnet 5.5 at effort max, rulings
and votes on Opus 5.5 at effort xhigh, with the CHTC seat on `general-purpose`.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O35 | CHTC test jobs from galah | "Yes. C4 lanes may submit test jobs on CHTC from galah and write under /staging/groups/oconnor_group/32748/lge-chtc-test/." | The lanes submit test jobs and write only there |
| O36 | Disk on galah | "Yes, you may thin the local snapshots with tmutil thinlocalsnapshots / 400000000000 4 for this session." | 24 local snapshots thinned |
| O37 | Containers | "CHTC only suppports apptainers." | Every CHTC job runs the Apptainer image. Docker is galah's local Linux test container only |
| O38 | The study's data terms | "Yes,, we can access the reads from /staging" | Reads may be read on `/staging` |
| O39 | Q-C4-1, the upload route | "The best thing to do is to use execute nodes and the files staged to /staging." | No upload from galah. Jobs read staged files on execute nodes |
| O40 | Q-C4-12, the Debug app | "Its fine to install the Linux toolchain app to this mac. We shouldn't need anything from the laptop since all releases are cut from this machine." | Galah builds the Debug app with the Linux executor, and the laptop needs nothing |
| O41 | The CHTC message | "There shouldn't be a specific CHTC message - we will want this tool to be generic so it can pre-process data on Linux and then import the pre-processed data into LGE on any machine running LGE." | The tool is generic: pre-process on any Linux machine, adopt on any Lungfish Mac. HTCondor is one launcher. No CHTC message |
| O42 | The full-sample test | "We also shouldn't be using a 60GB file for testing after we have the Linux tool operational. This would be wasteful." | No full-size study sample as a test |
| O43, O44 | The acceptance sample | "We can use any publicly available SRA dataset that is small to test the workflow instead of the 60GB test." Then "Yes, download SRR35520572 from ENA to galah and use it as the acceptance sample." | The acceptance sample is the public run SRR35520572 |

**The lanes.** Wave 1 was S (the spawn lock made structural), I (the image build job and the SIF on `/staging` by
digest), H (the HTCondor submit template, DAG, job wrapper and event-log reader), F (the plan template and sample fill,
the shared folder mode, `import fastq --write-plan`), R (the Mac records its storage writer, level and clumpify groups)
and B (the executor build, maps and strip in `release.py package`). Then A (the adopt, `import fastq --adopt`), P (the
three parity tests on the closed V15 list), U (the Provenance rows of an adopted record, then the plan sheet and the
Linux run adopt entry in the Import Center), V and W (the votes below applied), B M2 (the Debug app builds and places the
executor, or states its absence with `--without-linux-executor`) and X (the acceptance run). Six landings put them on
`chtc-c4`, each with the tests of its lanes, the 14 ratchets, the module map, the golden compare and the Linux tier.

| Vote | Decisions |
|---|---|
| C4-3 | C-1: the Mac records the exit status and times of its deacon and merge steps (6 to 0). C-2: the one strip function also maps each route's work-file stem, the `work/` folder and the Mac's per-run report UUID to one placeholder, and inputs to R1 or R2 by digest (6 to 0). C-3: the executor records the interleave's `pigz -dc` launches, a fourth adopt-only step (6 to 0). C-4: the writer `bgzip`'s managed tool id is route-shaped, and the node refuses a writer `bgzip` off the plan's pin (5 to 1) |
| C4-4 | D-1: peak memory is present on the adopted route only, and the Mac records none, as Phase 2.7's P4 holds (6 to 0). D-2: files and outputs match by digest and role, not index (6 to 0). D-3: an adopted report copy carries the sample's name, by the tie rule after 3 to 3. D-4: the reports compare by their parsed counts and rates (5 to 1). D-5: the adopted record names the payload's published path (4 to 2). D-6: C4-07's estimate clause is reported, not met, on this sample (6 to 0) |
| C4-5 | E-1: the outputs of the V15-S5 decompressor steps are adopt-only too, so the node's interleave file is reported, never compared (5 to 1) |

Rulings: ARCH-fill (the fill's home and conditions), QA-parity (the determinism excerpt, parent links by role, the
Debug app's `--without-linux-executor`), CHTC-H2 (the memory margin from `peakResidentBytes`, 8 GiB for a first job,
`ON_EXIT` kept, `request_disk` from DAG VARS), UX-XC26 (the plan sheet's words), QA-V15lines (28 parity lines sorted 7,
18, 3), QA-W-lines and ARCH-X3 (below).

**What CHTC taught the code.** Each item was found by a real job and fixed in this session.

| Found by | Fact | Fix |
|---|---|---|
| G1, a node job | HTCondor returned only the record, logs and payload, so the plan's reports never came home | The template returns each report the plan names at its `work/` path, and never the intermediates |
| X1, node 593391 held at 12/1 | A remap keyed by the payload's basename fails for a file listed with its path, and a missing destination folder holds the job at 12/256 | G3: the remap is keyed by the exact `transfer_output_files` string, and `run.dag` makes each payload folder with a `SCRIPT PRE /bin/mkdir -p` (DAG 593407 and job 593400 proved both) |
| CHTC seat, CH-8 | HTCondor's disk figure is a sample taken every 300 s and at exit, not a peak | W0: the executor walks its run folder every 0.25 s during the storage step and records `storage.peakWorkRootBytes` |
| X3 | The image's tools sit in one environment, `/opt/lge/env/bin`, so no `envs/<id>/` names a managed tool | R-1: the adopt names each image tool by its entry in the linux-64 lock (`bbtools`, `htslib`) |
| X3 | A job returns no input reads, and the adopt refused without them, naming no fix | R-2: the adopt takes each input's digest and size from the run record, which the node checked against the plan, hashes the files only when present, and names the fix in each refusal |

**The acceptance run.** SRR35520572 (PRJNA989177, Illumina NovaSeq 6000, paired, targeted capture of viral RNA,
4,632,098 pairs, R1 210,030,850 and R2 212,816,451 bytes from ENA with its MD5 checked) was staged once under
`lge-chtc-test/input-sra/`. The plan came from the landed writer at threads 1 with `--clumping-tool bbtools` and a 1 GB
clumpify heap, the largest at which clumpify split the reads into more than one group (X0).

| Check | Result |
|---|---|
| The node job | DAGMan 593411, node 593412 on `e4076` (`slot1_9`), exit 0 on its first start, no eviction. `run.dag`'s PRE script made the payload folder. Wall time 278 s (`TimeExecute`), the record's `wallSeconds` 276.6 |
| C4-06, one read of the job log | Disk 4,882,060 KB used of 10,485,760 requested (HTCondor's sample), memory 2,572 MB of 9,216 (1 GiB heap plus the 8 GiB margin), and `peakImageSizeKB` 4,796,216 KiB against the record's largest peak 4,845,678,592 B (deacon), 1.35% apart |
| The payload | 54,396,886 bytes, SHA-256 `36a55ca4...1493` on `/staging`, in the run record, and byte for byte equal to galah's own import of the same reads |
| C4-07 | Clumpify ran 11 groups on its second launch, every read kept (901,718 merged plus 82,724 pairs in, 1,067,166 stored), `storage.peakWorkRootBytes` 5,463,083,200. The estimate clause is not met on this sample (349,495,473 against half the heap, 536,870,912), as D-6 reports it |
| The adopt | `import fastq <returned folder> --adopt` with no input read in the folder: exit 0 |
| E0 to E4 | Equal |
| The closed V15 list | Every line equal or listed except the platform rows: with the reads absent the adopted record says no inference ran, 10 keys in 19 lines (`c4/lanes/X/X7.md`), the C5 line below |
| The parity tests on the C079876 1,000,000-pair slice | 11 tests, 0 failures, no unlisted line (landing 6) |
| The signal job K3B | Passed on landing 3's executor |

**Findings carried out of C4.**

- The adopted record says no platform inference ran when the input reads are absent, where the Mac's names its
  inference (`platformConfidence`, `platformEvidence`, `platformVendorDetail`, the sidecar's `platformAssignment`). A
  panel line for C5: the node records its own inference, or the adopt infers from the payload.
- The stripped executor's bytes changed between landings 3 and 4 with no executor or Portable source change (the same
  size, 58,829,344 bytes), so the build is not reproducible across worktrees. Plans pin the bytes a package ships, so a
  release is unharmed, but B M3's packaging run must check it.
- The plan sheet takes no recipe, so a recipe plan still needs the command line, and BIO rules that a long-read plan should
  not default the clumping box on (Q-UX26-1).
- `request_disk` for a full-size sample: CHTC-H2's formula needs the work and payload sizes of a C079876-size run, read
  again from the first lab batch before its `request_memory`, `request_disk` and the 72-hour check are trusted (CH-10).
  The 10,000,000-pair replay is dropped under O42.
- B M3, the packaging run with notarization, and the GUI walk of the two new Import Center cards are not done.

## Open questions that remain (2026-10-25, session 5)

| Id | Question | Who answers |
|---|---|---|
| MO-S1 | Should the Mac's own `auto` follow the plan's rule? It changes the stored bytes of large Mac imports | The owner |
| MO-B2 | Should clumpify follow the user's compression level? It changes compressed bytes | The owner |
| Push | `chtc-c4` holds 110 commits on `origin/main`, not pushed | The owner's go |

## C5, batches and the plain Linux launcher (2026-10-25, session 6)

Session 6 ran on the Mac Studio (galah) on 2026-10-25 from 07:25. The records are in
`~/lungfish-phase-records/chtc-program/c5/` (`notes.md`, `events.log`, `briefs/`, `inv/`, `memos/`, `votes/`,
`rulings/`, `factcheck/`, `lanes/`, `reviews/`, `land/`, `x/`, `llm/`). Lanes ran as `lge-worker` in their own worktrees,
Opus 5.5 at effort xhigh for design and Sonnet 5.5 at effort max for mechanical lanes, fixes and landings. Reviews ran
on Sonnet 5.5 at effort max. Inventories, memos and rulings ran on Opus 5.5 at effort xhigh, with the CHTC seat on
`general-purpose` for the web.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O45 | The order of work | "lets do c5 first and then cut a new preview build." | C5 lands, then `chtc-c4` and C5 go to `main` fast-forward only, then a Preview |
| O46 | C5's scope | "Small public batch (Recommended)" | The batch path (a sample sheet, a DAG of many samples, the lab's commands, a plain Linux launcher beside HTCondor) proved on small public SRA runs, one viral capture and one wastewater |
| O48 | The test reads | "Both runs (Recommended)" | Three public paired Illumina runs from ENA: SRR35520572 (C4's acceptance sample), SRR24403534 (PRJNA966185, wastewater, 2,559,001 pairs, R1 184,506,113 and R2 187,858,336 bytes) and SRR38262740 (PRJNA1438722, wastewater hybrid capture, 659,361 pairs, R1 46,094,697 and R2 48,137,833 bytes), MD5 checked against ENA |
| O49 | MO-S1 | "Change it in C5" | The Mac's own clumping `auto` follows the plan's rule, platform first |
| O51 | MO-B2 | "Keep level 4 (Recommended)" | Clumpify keeps `zl=4`. MO-B2 is closed |
| O52 | C4's scratch on CHTC | "Yes, at C5's end (Recommended)" | C4's scratch folders on `/staging` and the access point go after C5's batch has adopted |

**The votes.** Round 1 settled 19 questions (`c5/votes/tally-c5v1.md`). The ones that shape the code:

| Id | Decision |
|---|---|
| D1 | A job returns single files only. The run record, each report and the payload go to `batches/<batch>/<sample>/result/` on `/staging`; logs come home to the submit folder. HTCondor cannot remap a folder |
| D2 | A batch adopt imports nothing if any sample is refused, and lists every refusal |
| D3 | One preset a batch. Two presets make two batches |
| D6 | On a Mac, the plain launcher runs the pinned image in Docker under amd64 emulation, after a probe of the pinned executor |
| D7 | With the reads absent, the adopted record keeps "not inferred" for the platform, as one listed parity row |
| D8 | The plan sheet and the Import sheet clear the clumping box for ONT, PacBio and Unknown reads, from one platform-first function |
| D13 | `run.dag` runs at most 10 nodes at once (`CATEGORY`, `MAXJOBS`) and writes `run.dag.status` |
| D14 | A held node is removed with the lab's commands, and DAGMan's rescue DAG reruns it alone |
| D15 | The plan tar goes from the home submit folder, not `/staging` |
| D17 | `request_disk` is the larger of C4's rule and the amended rule, and the sample sheet's column wins |

Cut, in the panel's cut order: the Import Center's "Sample sheet…" control and storage `none`. Moved out of C5: V11
(plain FASTQ for Linux users), RiboDetector, interleaved-to-paired, and plan-time platform inference (D7 A).

**The lanes.** SPLIT (moved `ExecutorPlanNoPlanForm` to its own file), REPRO (the stripped Linux executor is the same
bytes from any checkout: no build id, no `.swift_modhash`), MOS1 (the Mac's clumping `auto` follows the plan's rule,
O49), BADOPT (the batch adopt: one flat folder a sample, preflight first, D2's ends), DISK (a sample needs five times its
read files free before clumpify), BF (an unfused fastp plan form), LAUNCH (the batch writer's `samples.csv`, D1, D9,
D13, D15, D17, `jobs.tsv`, `run-local.sh` and the batch `README.txt`), US (the plan sheet's clumping box, the Linux Run
Result card's batch adopt, the plain launcher's Provenance rows), CMD (no site word in any help line or generated file,
the executor and image defaults, the tab-sheet refusal), C-FAIL (a failing node, a passing node and a retry job on
CHTC) and X (the acceptance run).

**What CHTC taught the code.** Each item was found by a real job and fixed in this session.

| Found by | Fact | Fix |
|---|---|---|
| C-FAIL, R (594046) | A job that ends without every listed output is held at code 12, whatever its exit, so `max_retries` and `retry_until` never act | CHTC-3d R1: the retry lines go, and `periodic_release = (HoldReasonCode =?= 12) && (ExitCode =?= 0) && (NumHolds < 3)` releases, at most twice, a job held sending its files back after its run exited 0 (not yet seen to fire on the pool) |
| C-FAIL, P (594045) | A stalled `/staging` upload ("Aborted due to lack of progress") holds a job that passed | The same line; the README's held-job steps tell the two holds apart |
| C-FAIL, F (594044) | A rerun replaces `result/run-record.json`, so the failed attempt's record is lost | CHTC-3d R2: the README copies the record aside before `condor_rm`; R3: "Job was evicted" then "Job was held" is one hold |
| C-FAIL and X | Wastewater nodes use about twice the work space a byte of input that VSP2 does (w 9.94 and 10.60 against 4.995) | CHTC-3d R4: one work-root factor a preset, wastewater 10.61 and VSP2 5.03 |
| LAUNCH M3, X | `--write-plan` refuses `--pairing paired`; the plan pairs by name | The lab's commands drop `--pairing` on the plan route |

**The acceptance run (S10).** Two batches from the landed head `cfe90c4cc`, one preset each (D3 b): `c5-x1` (VSP2,
SRR35520572) and `c5-x2` (wastewater, SRR24403534 and SRR38262740), each written from a `samples.csv` with the
`request_disk` column empty, so the writer asked 10, 10 and 9 GB. Each ran as a DAG on CHTC. The results came home by the
README's copy step, and each batch was adopted whole on galah into one project.

| Sample (route) | Against galah's own import of the same reads |
|---|---|
| SRR35520572 (DAG node 594056) | Equal at E0 to E4, C4's X7 numbers exactly (1,067,166 records, payload `36a55ca4...1493`) |
| SRR24403534 (DAG node 594057) | Equal at E0 to E3. E4 differs, and two more galah imports of the same reads gave two more stream digests: clumpify above one group writes its groups in the order its fetch threads finish (BIOQA-X1 R2) |
| SRR38262740 (DAG node 594058) | Equal at E0 to E4 |
| SRR38262740 (`run-local.sh --runtime apptainer` in a vanilla job, 594059) | Equal at E0 to E4; the record holds D10's seven plain-launcher rows and no `ContainerImageID` |
| SRR38262740 (`run-local.sh --runtime docker` on galah, LAUNCH M3) | The pinned executor's self-check passed under amd64 emulation; the run, the copy step and the batch adopt each exited 0; the record holds `ContainerImageID` and no `ImageSHA256` |

Each node's peak work root, w, `DiskUsage` and wall time are in `c5/lanes/X/X.md`. Scaled to a 61.6 GB sample at one
thread, no node passes 36 hours of the 72-hour limit (O28). Every adopted record keeps "not inferred" for the platform
(D7 C). The parity hook first failed on those 10 platform lines in all four samples, since D7 C's listed row was never
written, and on 248 stored-order lines in SRR24403534. BIOQA-X1 ruled the two list lines V15-29 and V15-30 (tests only),
and lane X1F reran the hook on all four: 0 failures each, V15-29 in all four and V15-30 (8 lines) in SRR24403534 only. S10 stands.

C-FAIL proved D1 and D14 A on CHTC: a node whose reads were swapped refused with exit 2 and held, DAGMan waited, the
lab's `condor_rm` ended it with `run.dag.rescue001` marking the passing node DONE, and `condor_submit_dag run.dag` reran
only the failed node, which passed.

**The landings.** Three landings put the lanes on the C5 branch, each with the tests of its lanes, the 14 ratchets, the
module map, the source-portability check and the golden compare. Landing 1 (`2d303f7a6`: SPLIT, REPRO, MOS1, BADOPT) also
ran the Linux tier, which built the stripped x86_64 executor to `755d825b...30e1`, REPRO's value. Landing 2 (`cfe90c4cc`:
DISK, BF, LAUNCH M1 and M2) and landing 3 (`2fb78fab1`: US, LAUNCH M3, CMD, X1F) changed no executor or Portable source.
Every lane had a review and, where it asked, a fix agent; CMD's changed strings also had a fact-check (`FC-CMD`, 58
strings, 5 false ones fixed). Rulings after the votes: CHTC-3d (held nodes, retries, the lost record, w a preset) and
BIOQA-X1 (the parity list's V15-29 and V15-30).

**Findings carried out of C5** (the C6 list, `c5/record/C6-list.md`, has every row).

- A clumpify launch above one group stores reads in an order that varies run to run, on the Mac as on a node. The reads,
  counts and sorted digests are the same; the read-length and quality charts, drawn from the first 100,000 stored reads,
  can differ slightly. C6 tries `fetchthreads=1`.
- The adopted record keeps "not inferred" for the platform when the reads are absent. C6 infers it on the Mac from R1
  when the plan is written, which removes V15-29.
- `periodic_release` has not yet been seen to fire on the pool, and the disk factor a preset comes from small samples
  (CH-10 reads both again from the first lab batch).
- A Docker run's record names the SIF in `containerImage` and `containerDigest`; only `ContainerImageID` names the Docker
  image. The Import FASTQ sheet still reads the platform on the main actor.
- The Import Center sheets and cards of C4 and C5 still need the GUI walk (the owner check list of Preview 2026.10.24).

## Open questions that remain (2026-10-25, session 6)

| Id | Question | Who answers |
|---|---|---|
| Q-C5-C6 | The fetch route for lab payloads of GBs: the access point, as C4 and C5 did, or CHTC's transfer server | The owner |
| C6 scope | Which C6 rows run before the first lab batch of 32748 | The owner, with the panel |

## C6, reads staged on Linux and the CASPER batch (2026-10-25 to 26, session 7)

C6 ran in its own session on the Mac Studio (galah). It started from `main` = `origin/main` at `61c4fe0415c5a9227333b4fad16c61025c509129`, which holds C4 and C5 and Preview 2026.10.24. The manager integrated on branch `claude/chtc-c6-d57400` (`SCR/briefs/rules-c6-all.md:7`). In this section `SCR` is `~/lungfish-phase-records/chtc-program/c6`, and a source such as `X6b.md:136` is a line of a lane file there.

### The owner's rows of C6

Quoted as in `SCR/notes.md:57-66`.

| Id | Question | Owner's words | What it sets |
|---|---|---|---|
| O53 | What C6 is for | "We easily have multi-TB execute nodes. I'm not sure the 32748 raw reads are still on the staging server. Lets find three wastewater datasets that we can use for testing, and then test against that, running the wastewater preset with ribodepletion and human read depletion and clumpify." | Three public wastewater runs replace the 32748 batch. Disk on a node is not a limit (C6-DISK's slot question closed) |
| O54 | Which data | "Use three wastewater datasets from https://www.ncbi.nlm.nih.gov/bioproject/1247874" | PRJNA1247874 (CASPER, SecureBio, NovaSeq X, RNA metagenomic) |
| O55 | Which runs, and where they go | "Yes, these three are fine. But why do we need to download to Galah first? Why not just download directly to /staging on CHTC?" | SRR38294966 (1.90 GB), SRR35904062 (14.82 GB), SRR38294075 (17.87 GB), downloaded from ENA straight to /staging by CHTC jobs |
| O56 | Mac copy | "Only the small run (Recommended)" | Superseded by O59 |
| O57 | Q-C5-C6 fetch route | "Access point rsync (Recommended)" | Results come home by the README's rsync through the access point. transfer.chtc.wisc.edu is named for larger batches, untested |
| O58 | The exit | "Yes, that exit (Recommended)" | As amended by O59: the batch runs, every node exits 0, the batch adopts, figures recorded, only fixes the batch shows, the 19 C6 rows placed, record complete |
| O59 | Staged reads | "I don't think its critical to compare the mac ouptut to the CHTC output. It is more critical to ensure that the files that live on Linux are processed in a way that allows the processed reads to be imported into LGE." | No Mac comparison, and galah downloads nothing. Lane STAGED: `--write-plan` must plan reads it never holds (today it hashes each on the Mac, `ImportFastqPlanOptions.swift:289`) |
| O60 | Overnight | "I'm going to be away so have the experts solve any issues arising overnight." | Owner away from about 20:55. The panel rules on any issue the batch shows (ruling by lge-expert on opus at xhigh, a fix lane, a review, a landing on `claude/chtc-c6-d57400`, fast-forward only). Still waits for the owner: push, Preview, any new download, removal of leftover scratch, any new rm, kill or git form. A lost CHTC master cannot be reopened (Tailscale approval), so record it and stop CHTC work |

### Why the 32748 batch was replaced

O53 doubted that the 32748 raw reads were still on the staging server. The inventory of the access point found no 32748 raw reads (`SCR/notes.md:15`, `SCR/x/ap-inventory.log`). Its listing of `shared/` shows the executor files, the panhuman index (3,279,263,603 B) and the ribokmers index (10,107,947 B) and nothing else (`ap-inventory.log:355-363`). O53 and O54 replaced the batch with three public wastewater runs of PRJNA1247874. O55 sent them from ENA straight to `/staging` by CHTC jobs, so no Mac and no access point carried them. O59 dropped the comparison with the Mac. It asked instead that files that live on Linux be processed so that the processed reads import into LGE.

### Ruling STAGED and lane STAGED

The problem. `--write-plan` hashed every read on the Mac (`ImportFastqPlanOptions.swift:289`, `SCR/notes.md:65`), and the CASPER reads exist only on `/staging` (O55, O59).

Ruling STAGED (`SCR/rulings/STAGED.md:8-22`, lge-expert on opus at xhigh). One new plan option, `--staged-reads <list>`, used only with `--write-plan` and `--samplesheet`. The list is a tab-separated file made on the Linux machine that holds the reads, with a line a read giving `file`, `bytes` and `sha256`. The sample sheet's `r1` and `r2` are those absolute paths inside `--staging-folder`. The writer takes each read's size and SHA-256 from the list and never opens the read. Each job names the read where it sits, and `staging-files.json` lists it with no Mac file. `--platform` must name the platform. The node checks each read against the plan's pin before any tool runs, and the adopt already takes each input's digest from the run record. No byte of `Sources/LungfishExecutor` or `Sources/LungfishPortable` changes, and the plan sheet stays local-file only. The votes were ARCH yes, BIO yes on 2, 4, 5 and 6, QA yes on 1, 2, 4, 5 and 6, UX yes on 1, 5 and 7, and SWIFT yes on 5 and 6 (`STAGED.md:21-22`).

| Step | Result | Source |
|---|---|---|
| Lane STAGED (lge-worker, opus, xhigh, 117 calls) | Two commits. `f8be2ea66462f4912cebbe75109717bc1c35b612` holds the list parser `ImportFastqStagedReads.swift` (new, 120 lines), the option and its checks, the writer's staged path, the README passages and two test classes. `bff7e7ced2154c2b9f97bf5f95aaf760c32949b9` holds the two cli-help captures and the module map | `lanes/STAGED/STAGED.md:50-51`, `:143` |
| Red at the base | `ImportFastqStagedReadsTests` 23 tests, 34 failures, exit 1, since `--staged-reads` did not parse. `ExecutorPlanStagedReadTests` did not compile | `STAGED.md:15`, `:30-31` |
| Green at the head | `ImportFastqStagedReadsTests` 23 tests, `ExecutorPlanStagedReadTests` 2, `ImportFastqPlanOptionsTests` 17, `ExecutorPlanBatchWriterTests` 18, `ExecutorRunAdoptionTests` 27, `ImportFastqBatchAdoptTests` 11, 0 failures each. All 14 ratchets at baseline | `STAGED.md:55-62` |
| Dry run of the ruling's section 10 command | Exit 0, and no plan folder written | `STAGED.md:83-95` |
| Review (lge-expert, sonnet, max) | "Merge after fixes" with one numbered fix. Fix 1 was that a `--platform` that names no platform passed the guard and was written into the plan, so the adopt would refuse every sample after the CHTC run. Seven Optional findings | `reviews/STAGED.md:9-14`, `:217-238` |
| Fact-check (manual-fidelity-reviewer, sonnet, max) | True 2, Partly 3, False 0, Unknown 0. The help's `stat -c %s` gave a symbolic link the link's own size. README passage 3 kept `batches/<batch>/`. The `--staging-folder` help said reads sit in `batches/<plan folder name>/<sample>/`. The manual's access-point word was stronger than O35 | `factcheck/FC-STAGED.md:9-22`, `:134` |
| Landing (lge-worker, sonnet, max) | Head `7e6eb78f2c95a477d1b43f75ea9ce8f4a2664760`, ten commits over `61c4fe041` by `git merge --ff-only`, with fixes F1 to F6 each in its own commit. `ImportFastqStagedReadsTests` red at `bff7e7ced` (24 tests, 4 failures) and green at the head (24 tests, 0 failures). `LinuxRunScriptTests`, never run before, passed 12 of 12 | `land/land-STAGED.md:14-15`, `:34-43`, `:47-51`, `:87` |

The ruling's section 10 gave the command that lane X6 ran for the three runs (`SCR/rulings/STAGED.md:262-296`) with 8 threads, a clumpify heap of 16 GB, the wastewater recipe and `--platform illumina`.

### Lane FETCH, the reads onto /staging

Lane FETCH (`SCR/lanes/FETCH/FETCH.md`, lge-worker on opus at xhigh, records only, no commit) pulled the three runs from ENA to `/staging` with CHTC jobs.

The master was running (pid 32829). The group quota read 136,165 of 150,000 GB and 2,916,255 of 3,000,000 files, so 13,835 GB and 83,745 files were free (`FETCH.md:11-12`).

M2, the first attempt. Cluster 594620 ran one `curl` a file and was submitted 2026-10-25 19:21:11 CDT (`FETCH.md:35`). ENA closed two connections after 96,831,745 and 82,833,408 bytes, about 1.5 MB/s, and `--retry 5` does not retry `curl` exit 18. Two jobs held at code 12 subcode 256 with ExitCode 3, nothing reached `input-casper/`, and the three jobs were removed with `condor_rm` (`FETCH.md:38-56`). The fix, `fetch.sh` version 2, gets each file as 8 byte ranges at once. Each range resumes from its own size, up to 200 tries 15 s apart. The ranges join in order, the size must equal ENA's byte count, and `md5sum -c` runs (`FETCH.md:58-67`). Cluster 594631 was submitted 2026-10-25 19:34:10 CDT and ended "All jobs done." at 20:31:53 CDT with no hold (`FETCH.md:69-80`). The container test did not reach the resume path. SRR38294075 then resumed 48 ranges after `SSL_ERROR_SYSCALL` drops, and every resumed file passed `md5sum -c` (`FETCH.md:66-67`, `:114-115`).

M3, the check. `input-casper/` holds nine files. The six FASTQ files match ENA's byte count, `ls -la` and the job's `stat -c %s`, and pass `md5sum -c` in the job. The manifest is `SCR/x/casper-manifest.tsv` and the sums are `SCR/x/casper-SHA256SUMS`. No file was hashed on the access point and nothing on `/staging` was removed (`FETCH.md:84-100`).

| File | ENA bytes = `ls -la` = job `stat -c %s` | `md5sum -c` in the job | sha256 |
|---|---|---|---|
| SRR38294966_1.fastq.gz | 1,005,139,490 | OK | `78edc5c6...28352421` |
| SRR38294966_2.fastq.gz | 898,411,895 | OK | `70370a70...7eda82` |
| SRR35904062_1.fastq.gz | 7,708,771,820 | OK | `bc08c104...896c0bf2` |
| SRR35904062_2.fastq.gz | 7,110,161,778 | OK | `b299787f...94999f9f` |
| SRR38294075_1.fastq.gz | 8,720,618,551 | OK | `a1a2c675...27cd9c398` |
| SRR38294075_2.fastq.gz | 9,146,573,027 | OK | `04f89874...f5c9b093` |

The job table (`FETCH.md:102-109`).

| Job | Run | Host | Starts | Exit | Wall | DiskUsage KiB | BytesRecvd | BytesSent | Download rate (job's own timing) | Ranges resumed | Holds |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 594631.0 | SRR38294966 | slot1_39@e4014 | 1 | 0 | 449 s | 2,000,000 | 3,997 | 1,903,552,949 | `_1` 4.77 MB/s (210.8 s), `_2` 6.96 MB/s (129.1 s) | 2 | none |
| 594631.1 | SRR35904062 | slot1_48@e4050 | 1 | 0 | 2,856 s | 15,000,000 | 3,997 | 14,818,934,835 | `_1` 7.07 MB/s (1,090.0 s), `_2` 8.29 MB/s (857.7 s) | 0 | none |
| 594631.2 | SRR38294075 | slot1_32@e2471 | 1 | 0 | 3,431 s | 17,500,000 | 3,997 | 17,867,200,426 | `_1` 6.00 MB/s (1,453.5 s), `_2` 6.13 MB/s (1,491.7 s) | 48 | none |
| 594620.0 | SRR38294966 (v1) | slot1_55@e4064 | 1 | 3 | 69 s | 100 | 2,161 | 0 | about 1.5 MB/s before the drop | none | one, code 12, removed |
| 594620.1 | SRR35904062 (v1) | slot1_42@e4029 | 1 | 3 | 50 s | 100 | 2,161 | 0 | about 1.5 MB/s before the drop | none | one, code 12, removed |
| 594620.2 | SRR38294075 (v1) | slot1_55@e4017 | 1 | none | 396 s | 400,000 | 2,161 | 0 | 1.03 MB/s | none | none, removed while running |

The group quota grew by about 34.6 GB and 9 files (`FETCH.md:115-116`). C6-RELEASE was not observed. No exit-0 hold at code 12 happened in cluster 594631 (`FETCH.md:78-80`).

### The batch, lanes X6a and X6b

Lane X6a (`SCR/lanes/X6/X6a.md`) wrote the batch from the staged manifest and submitted the DAG. Its Handoff table (`X6a.md:166-176`).

| Item | Value |
|---|---|
| DAGMan | **594741**, submitted 20:59:22 CDT from `oconnor-ap4000:/home/dhoconno/lge-chtc-test/c6-x6/` |
| Nodes | SRR38294966 **594744**, SRR35904062 **594745**, SRR38294075 **594746** (each `.0`) |
| Nodes log | `/home/dhoconno/lge-chtc-test/c6-x6/run.dag.nodes.log` |
| DAGMan log | `run.dag.dagman.out` (debug) and `run.dag.dagman.log` (DAGMan's own job events) in the same folder |
| Node status file | `run.dag.status`, every 60 s |
| Job logs | `logs/<sample>.log`, `.out`, `.err` in the same folder |
| Results on `/staging` | `/staging/groups/oconnor_group/32748/lge-chtc-test/batches/c6-x6/<sample>/result/` |
| DAG end | `run.dag.dagman.out` ends with "All jobs Completed!" |

The state 7 min 25 s after the submit, at 21:06:47 (`X6a.md:128-135`). All three nodes ran on `oconnor` machines, so the 72-hour limit (O28) held for each (`X6a.md:139-140`).

| Node | ClusterId | Host | RequestCpus | RequestMemory (MiB) | RequestDisk (KiB) | Holds |
|---|---|---|---|---|---|---|
| SRR38294966 | 594744 | slot2_7@oconnor2002 | 8 | 24576 | 29,360,128 (28 GiB) | none |
| SRR35904062 | 594745 | slot2_1@oconnor2000 | 8 | 24576 | 197,132,288 (188 GiB) | none |
| SRR38294075 | 594746 | slot2_1@oconnor2007 | 8 | 24576 | 236,978,176 (226 GiB) | none |

X6a saw five things its brief did not foresee (`X6a.md:146-150`). `condor_wait` on an empty nodes log returns at once. One `ls -la` of four files on `/staging` took about 3 minutes. The image has no `source` in `staging-files.json`. Only the three home `plan.tar` files were hashed on the access point. Each sample's `recipe/` holds `illumina-paired-cleanup.recipe.json` while `plan.json` names `wastewater-metagenomics`.

Lane X6b (`SCR/lanes/X6/X6b.md`, lge-worker on opus at xhigh) checked the batch, fetched it home, adopted it and read the figures. The pass check (`X6b.md:13-75`).

| Node | Host | Events (CDT) | RemoteWallClockTime | DiskUsage of request | Memory (HTCondor) | CpusUsage | Bytes received, sent |
|---|---|---|---|---|---|---|---|
| SRR38294966, 594744 | slot2_7@oconnor2002 | 000 21:00:08, 001 21:04:52, 005 21:13:47 | 597 s | 12,500,000 of 29,360,128 KiB, 42.6% | 74 MB (the 5-minute sample missed the deacon steps) | 2.78 of 8 | 5,648,178,111 and 272,626,844 |
| SRR35904062, 594745 | slot2_1@oconnor2000 | 000 21:00:08, 001 21:07:09, 005 00:36:52 | 12,783 s (3.55 h) | 175,000,000 of 197,132,288 KiB, 88.8% | 12,208 MB, RSS 9.72 GiB, of 24,576 MB | 2.84 of 8 | 18,563,560,324 and 4,190,986,857 |
| SRR38294075, 594746 | slot2_1@oconnor2007 | 000 21:00:33, 001 21:07:13, 005 21:42:00 | 2,290 s | 45,000,000 of 236,978,176 KiB, 19.0% | 12,208 MB, RSS 9.73 GiB, of 24,576 MB | 4.23 of 8 | 21,611,818,304 and 502,392,622 |

Every node ended "Normal termination (return value 0)" with `NumJobStarts` 1 and no hold. DAGMan 594741 ended with ExitCode 0 after 13,053 s, 20:59:22 to 00:36:55, and `run.dag.dagman.out` ends "All jobs Completed!" (`X6b.md:37-38`, `:75`). `run.dag.nodes.log` holds nine events, `000`, `001` and `005` for each node, and no `004`, `012` or `013`, so C6-RELEASE's `periodic_release` did not fire (`X6b.md:41-43`).

The fetch, the check and the adopt (`X6b.md:79-88`).

| Step | Result |
|---|---|
| Fetch | The README's rsync loop, each rsync rc 0, 1 min 54 s and 4.96 GB in all. Payloads 272,194,599, 4,190,524,311 and 501,944,765 B |
| Check | Each returned file hashed against the run record: 8 EQUAL and 0 DIFFERENT a sample, and each payload's SHA-256 equals `payloads[0].sha256` |
| Adopt | Into the new project `SCR/x/X6/adopt.lungfish`, exit 0, "Adopted    : 3", "Not adopted: 0", "Duration   : 16.4s" |
| Copy, not move | Each returned payload stays beside the bundle's copy, so the Mac holds the 4.96 GB twice |
| `provenance verify` on the three bundles | Exit 64 each time, "Workflow execution failed: Signature artifact is missing". The adopt of a Mac with no signing key writes `"signatures" : [ ]` (`X6b.md:92-105`) |

The per-sample figures of the adopted bundles (`X6b.md:109-121`, with each figure's source key at `:107-121`). The step counts are pairs and the reads-out figure counts records (`X6b.md:123-125`).

| Figure | SRR38294966 | SRR35904062 | SRR38294075 |
|---|---|---|---|
| Reads in, R1 + R2 records | 39,979,120 | 501,311,756 | 305,836,222 |
| Read pairs in | 19,989,560 | 250,655,878 | 152,918,111 |
| Duplication rate | 0.0994 | 0.4426 | 0.8086 |
| Pairs after dedup and trim | 8,104,756 | 135,229,346 | 26,433,616 |
| Human reads removed, panhuman | 221,094 of 16,209,512 (1.36%) | 4,992,210 of 270,458,692 (1.85%) | 1,510,726 of 52,867,232 (2.86%) |
| rRNA reads removed, ribokmers | 1,177,266 of 15,988,418 (7.36%) | 101,923,840 of 265,466,482 (38.39%) | 23,938,134 of 51,356,506 (46.61%) |
| Merged reads | 5,038,327 | 66,593,213 | 13,069,113 |
| Pairs kept | 461,758 | 15,104,918 | 453,037 |
| Reads out | 5,961,843 | 96,803,049 | 13,975,187 |
| Clumpify groups | 1, 1, 1 | **35, 15, 35** | 1, 1, 1 |
| Clumpify memory estimate, against "Memory Available: 13396 MB" | 2,563, 2,563, 3,623 MB | 47,306, 18,957, 47,306 MB | 2,475, 2,475, 8,274 MB |

The per-node figures (`X6b.md:127-138`). F is the executor 58,829,184 B, the panhuman index 3,279,263,603 B and the ribokmers index 10,107,947 B, 3,348,200,734 B in all (`staging-files.json`). The image is 396,402,688 B and the plan tar 19,968 B. I is R1 plus R2 and W is the `peakWorkRootBytes` of the record's clumpify `storage` step. w = (W − F) / I and n = ceil(1.25 × (SIF + 2 × tar + F + w × I) / GiB). The writer's wastewater w was 10.61 (`ExecutorPlanBatchWriter.swift:156` at `7e6eb78f2`).

| Node | I | peakWorkRootBytes | w | n at this w, against the request | DiskUsage of the request | Memory, the record's largest step, against 24,576 MB | wallSeconds (record), RemoteWallClockTime |
|---|---|---|---|---|---|---|---|
| SRR38294966 594744 | 1,903,551,385 | 15,439,472,501 | 6.352 | 19 GB, of 28 GiB | 12,500,000 of 29,360,128 KiB, 42.6% | 5,821,562,880 B (clumpify), 22.6% | 524.2 s, 597 s |
| SRR35904062 594745 | 14,818,933,598 | 183,159,736,799 | **12.134** | **214 GB, above the 188 GiB asked** | 175,000,000 of 197,132,288 KiB, **88.8%** | 17,681,547,264 B (clumpify), 68.6% | 12,505.7 s, 12,783 s |
| SRR38294075 594746 | 17,867,191,578 | 46,390,092,149 | 2.409 | 55 GB, of 226 GiB | 45,000,000 of 236,978,176 KiB, 19.0% | 10,425,794,560 B (clumpify), 40.5% | 2,076.4 s, 2,290 s |

HTCondor's own memory figures miss the clumpify peak. `ResidentSetSize_RAW` was 10,191,312 KiB against the record's 17.68 GB for SRR35904062, and 50,908 KiB for SRR38294966's 10-minute job, so the record's `peakResidentBytes` is the figure (`X6b.md:140-142`). SRR35904062's time went to fastp 2,033.8 s, clumpify 4,420.9 s with 35 groups, seqkit statistics 1,643.2 s, seqkit length filter 1,015.8 s and pigz 766.6 s, at 2.84 of 8 CPUs (`X6b.md:144-145`).

Scaled to a 100 GB run, I = 100,000,000,000 B (`X6b.md:147-161`).

| Node | Scale | W for 100 GB | n for 100 GB (the writer at w 10.61 gave 1,240 GB) | DiskUsage for 100 GB | Wall for 100 GB | RemoteWallClockTime for 100 GB |
|---|---|---|---|---|---|---|
| SRR38294966 | 52.533 | 638.5 GB | 744 GB | 479.5 GB | 27,540 s, 7.65 h | 31,362 s, 8.71 h |
| SRR35904062 | 6.748 | 1,216.7 GB | **1,417 GB** | 1,187.7 GB (1,106.2 GiB) | 84,390 s, 23.44 h | 86,261 s, **23.96 h** |
| SRR38294075 | 5.597 | 244.2 GB | 285 GB | 240.7 GB | 11,621 s, 3.23 h | 12,817 s, 3.56 h |

Memory does not scale with I. The largest step is clumpify, whose heap the plan fixes at 16 GB, and clumpify splits into more groups rather than grow, so the figure for 100 GB is the largest measured peak, 17.68 GB, 68.6% of the request. Wall time is linear here and is a floor, since a 100 GB run splits into more groups (`X6b.md:152-155`). No figure passes the 72-hour limit (O28). At SRR35904062's w a 100 GB sample needs 1,417 GB against the writer's 1,240 GB, and the request would leave the same thin margin as the job here, 188 GiB asked and 166.9 GiB used (`X6b.md:163-165`).

### Ruling X6 and lane X6-FIX

Ruling X6 (`SCR/rulings/X6.md`, lge-expert on opus at xhigh, ARCH leading) ruled on what the batch showed (`X6.md:8-23`).

- **R-W.** Raise the wastewater w from 10.61 to 12.14, SRR35904062's 12.134 rounded up, by the standing rule at `ExecutorPlanBatchWriter.swift:153` ("A value rises when a node reads higher"). The form, max(C4 default, n), and the margin of 1.25 stay. The rule asked SRR35904062 for 188 GiB, 201,863,462,912 B. Its work root peaked at 183.16 GB, so SIF + 2 × tar + W was 90.9% of the request, and the margin left 9.1% (`X6.md:35-40`).
- **R-README.** Rewrite the passages that say which files to copy (README lines 6-7 and 14). Name the `source` key, and say to leave a file in `shared/` that is already there. Read literally, step 1 copies 3.35 GB over files that other batches' jobs read (`X6.md:146-152`).
- **R-PV.** No code change. A Mac import signs only when `LUNGFISH_PROVENANCE_SIGNING_KEY` or `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` is set (`ProvenanceSigning.swift:108-121`), so an unsigned adopted bundle is expected on galah. The adopt's own checks and X6b's 8 EQUAL a sample stand in for "provenance verify passes", and the record lane adds one signed re-adopt (`X6.md:104-133`).

The votes were R-W 4 to 0, R-PV 4 to 0 and R-README 3 to 1, with UX voting to add X6b finding 4 now (`X6.md:23`). The ruling's table of the five wastewater nodes (`X6.md:27-33`).

| Node | I (R1 + R2) | F | W | w = (W − F) / I | Source |
|---|---|---|---|---|---|
| SRR24403534, 594053 | 372,364,449 | 3,348,200,894 | 7,057,265,186 | 9.961 | `c5/rulings/CHTC-3d.md:89` |
| SRR38262740, 594045 | 94,232,530 | 3,348,200,894 | 4,347,450,604 | 10.604 | `c5/rulings/CHTC-3d.md:90` |
| SRR38294966, 594744 | 1,903,551,385 | 3,348,200,734 | 15,439,472,501 | 6.352 | `X6b.md:136` |
| SRR35904062, 594745 | 14,818,933,598 | 3,348,200,734 | 183,159,736,799 | **12.134** | `X6b.md:137` |
| SRR38294075, 594746 | 17,867,191,578 | 3,348,200,734 | 46,390,092,149 | 2.409 | `X6b.md:138` |

The C5 row of C-FAIL and X (line 736) reads "wastewater 10.61", which was C5's state. Ruling X6 raised w to 12.14 in commit `bfc5d08f5cb0ef9c819bbaf72db76a6f4aec863f` (review O3, `SCR/reviews/X6FIX.md:156`), and the 2026.10.24 release notes and report keep 10.61 for that release and stay as written.

Lane X6-FIX (`SCR/lanes/X6FIX/X6FIX.md`, lge-worker on sonnet at effort max, head `4eaa00fbd7d4433d3afea92208e975cd574740ac`) made the two code changes in two commits, the fix first and the tests second (`X6FIX.md:9-22`). It touched no file under `Sources/LungfishExecutor`, `Sources/LungfishPortable` or `Sources/LungfishApp`. Red at the base, the new writer test failed on SRR35904062 alone ("asks 188 GiB, 201863462912.0 B, where 229445224278.75 B cover its work root peak of 183159736799 B") and the new README test failed on both new sentences. After the change the writer asks 214 GiB, 229,780,750,336 B (`X6FIX.md:29-46`). Each class ran alone with 0 failures. The counts were `ExecutorPlanBatchWriterTests` 19, `LinuxRunScriptTests` 13, `ImportFastqStagedReadsTests` 24, `ImportFastqPlanOptionsTests` 17 and `HTCondorDAGTests` 6 (`X6FIX.md:50-56`). All 14 ratchets stayed at their baselines and the golden compare matched, cli-help 321, mapping 9, classifiers 24 and genotype 133 files (`X6FIX.md:71-85`). Its review (`SCR/reviews/X6FIX.md`, lge-expert on sonnet at effort max, ARCH seat, with the README fact-check) says "Merge" with no numbered fix. Every new or changed README sentence is True against the code and the written `staging-files.json`, and the head lands by `git merge --ff-only 4eaa00fbd7d4433d3afea92208e975cd574740ac` (`reviews/X6FIX.md:11-21`).

The commits of C6 at the base of the record lane (`git log 61c4fe041..4eaa00fbd`, oldest first).

| Commit | Subject |
|---|---|
| `f8be2ea66462f4912cebbe75109717bc1c35b612` | Plan reads that exist only in the Linux staging folder with --staged-reads |
| `bff7e7ced2154c2b9f97bf5f95aaf760c32949b9` | Recapture the import fastq help for --staged-reads and regenerate the module map |
| `8bd74af943fcdb49368aa70e03caceb8d4b997fd` | Refuse an unknown --platform name in a plan of staged reads |
| `5fbc8081acafc25e48e68151a9e0e35e42be2898` | Give a symbolic link its file's size in the staged-reads help command |
| `d97e9b0011d57aca2cac195173c68051e507dfd5` | Name the reads' folders in the README of a staged batch |
| `7282d4c3adb2265bf860dd7ad7a0578bf7f84b83` | Say where a staged plan's reads sit in the --staging-folder help |
| `b9bbbe8a5addbb98b63bc824b173fe59bef89fe4` | Recapture the cli-help goldens for the staged-reads help fixes |
| `ac808cbf3d33ac126530c74ea43540abb8d15779` | Test the batch writer's count, same-name and character refusals |
| `3ed3f238e440f66cda6fde298af40ea3417a0791` | Pin the staged read placements of a sample's DAG line |
| `7e6eb78f2c95a477d1b43f75ea9ce8f4a2664760` | Regenerate the module map for the line counts of the STAGED fixes |
| `bfc5d08f5cb0ef9c819bbaf72db76a6f4aec863f` | Raise the wastewater w to 12.14 and say which files the README copies |
| `4eaa00fbd7d4433d3afea92208e975cd574740ac` | Test the 12.14 w against every measured node and the README's copy step |

### FC-META, two facts in an adopted bundle's metadata

X6b had noticed that an adopted bundle's metadata says the returned folder holds no reads and reads `single_end` beside merged and paired classes, and BIO asked whether either was a false fact (`X6.md:254-259`). FC-META (`SCR/factcheck/FC-META.md`, lge-expert on sonnet at effort max, seat BIO) read the code at `7e6eb78f2` and the three bundles (`FC-META.md:3`, `:9-14`).

| Id | Verdict | In one line |
|---|---|---|
| M1 | True | "Reads" means the plan's pinned input R1 (`inputs/R1.fastq.gz`), which a CHTC job does not return. The adopt wrote the D7 C sentence that V15-29 pins, and the assignment records illumina as `given`. The wording is loose English, a panel call and not a defect |
| M2 | True | `single_end` with `detected` beside merged, paired_r1 and paired_r2 is what a Mac import writes for the same recipe, by the same two functions. C5's Mac and adopted bundles of SRR24403534 and SRR38262740 carry the same values |

No fix for either id. If the panel wants "no input reads (R1)" in place of "holds no reads", five places change together (`FC-META.md:34`).

### M1, the signed re-adopt (ruling X6, R-PV item 3)

The record lane adopted `SCR/x/X6/c6-x6` again into the new project `SCR/x/X6/adopt-signed.lungfish`. It set `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` to a throwaway key in a scratch file, which it never wrote into a record and deleted afterwards. It set `LUNGFISH_STORAGE_ROOT` to the C4 scratch root and ran lane X6-FIX's `lungfish-cli` at `4eaa00fbd` by its absolute path (`SCR/rulings/X6.md:126-133`). The adopt ended exit 0 with "Adopted    : 3", "Not adopted: 0" and "Duration   : 19.8s". `provenance verify` on each of the three bundles, one call a bundle, printed "Signature valid" and no other first line (`SCR/lanes/REC/REC.md`).

| Bundle | Verify | Provider | Provenance SHA-256 |
|---|---|---|---|
| `Imports/SRR38294966.lungfishfastq` | Signature valid | lungfish-local-deterministic-v1 | `7cddd491b342c6cd256f5d6292461ff9a22c7c6fd041593a01fe491fc7746b81` |
| `Imports/SRR35904062.lungfishfastq` | Signature valid | lungfish-local-deterministic-v1 | `f236aec9c5cc1e524d3f7c4ed95d30d2b79fb28b156d3ad3773ba56b3b761f70` |
| `Imports/SRR38294075.lungfishfastq` | Signature valid | lungfish-local-deterministic-v1 | `c80180cc3a4cf5871aa2e2ea025a3746a87c5149635770c7a855917ed28aadf0` |

The first adopt, with no key, left the same three bundles with "Signature artifact is missing" (`X6b.md:92-99`). With a key each bundle gained a `.signature.json` and a `.pub` beside its sidecar. So an adopted bundle verifies when a signing key was set as the adopt ran, and K2 states the other case.

### The exit, as the owner set it (O58 as amended by O59)

`SCR/notes.md:64` gives the exit. One line a part.

| Part | State | Evidence |
|---|---|---|
| The batch runs | Met | DAGMan 594741 ended "All jobs Completed!" with status 0 at 00:36:55 (`X6b.md:37-38`) |
| Every node exits 0 | Met | 594744, 594745 and 594746 each ended with ExitCode 0, `NumJobStarts` 1 and no hold (`X6b.md:24-26`, `:75`) |
| Files that live on Linux are processed so that the processed reads import into LGE (O59) | Met | The reads were never on a Mac. The adopt imported all three samples, "Adopted    : 3" and "Not adopted: 0" (`X6b.md:86`), and did so again in the signed project (M1 above) |
| The batch adopts, and provenance verify passes | Met | The first adopt passed its own checks and X6b's 8 EQUAL a sample (`X6b.md:83-86`). The signed re-adopt printed "Signature valid" for all three bundles (M1 above). The unsigned bundles say "Signature artifact is missing", which is K2 |
| Figures recorded | Met | The per-sample, per-node and 100 GB tables above (`X6b.md:109-161`) |
| Only fixes the batch shows | Met | Ruling X6 chose two fixes, w 12.14 and the README's copy step, and no change to `provenance verify` (`X6.md:8-21`). Lane X6-FIX made them (`X6FIX.md:9-14`), and its review says "Merge" with no numbered fix (`reviews/X6FIX.md:13`) |
| The 19 C6 rows placed | Met | "Carry-in from the CHTC program" in `docs/plans/2026-10-02-architecture-program.md`, with the rows C6 found |
| Record complete | Met | This section and the check list below |

## Open questions that remain (2026-10-26, session 7)

| Id | Question | State |
|---|---|---|
| Q-C5-C6 | The fetch route for lab payloads of GBs, the access point or CHTC's transfer server | Answered by O57. The access point's rsync carried the results home. `transfer.chtc.wisc.edu` is named for larger batches and is untested |
| C6 scope | Which C6 rows run before the first lab batch of 32748 | Answered by O53 to O59. Three CASPER runs replaced the 32748 batch, lane STAGED and lane FETCH ran, and there was no Mac comparison |
| Q-STAGED-1 | Should the adopted record name each staged read's staging path, which needs a plan or adopt change | The ruling's default stands, No (`SCR/rulings/STAGED.md:320`) |
| Q-STAGED-2 | Single-end and long-read staged batches, since a sheet row needs an R2 | Refused, and carried to Phase 3 with the review's Optional 1 (`STAGED.md:321`, `reviews/STAGED.md:219-220`) |
| Q-STAGED-3 | Accept `sha256sum` form or uppercase digests as well | The default stands, one form (`STAGED.md:322`) |
| Q-STAGED-4 | A plan sheet form for staged reads | Phase 3 (`STAGED.md:323`) |
| Q-STAGED-5 | X6's heap of 16 GB and 8 threads against the job logs' usage | The default stands (`STAGED.md:324`). The nodes used 2.78 to 4.23 of 8 CPUs and the largest clumpify peak was 17.68 GB of the 24,576 MB asked (`X6b.md:52`, `:62`, `:72`, `:136-138`) |
| New open questions | None | No file above names another |

## The owner's check list for the merge

| # | Check | State |
|---|---|---|
| 1 | Go for the push of `claude/chtc-c6-d57400` to `main`, fast-forward only | The owner's word in chat, after the manager states the head and the commit count |
| 2 | Go for any Preview from that head | The owner's word |
| 3 | The GUI walk rows of `docs/reports/2026.10.24-owner-checks.md` (the plan sheet's clumping box for a short-read and a long-read batch, the Linux Run Result card on a plan folder, a batch folder and a refusal, the Provenance tab of an adopted bundle) | Open, before Stable |
| 4 | Remove the program's scratch, one literal path a call. On `/staging` C5's `c5-cfail`, `c5-x1`, `c5-x2`, the `c3-*` folders, `c4-s`, `input/` and `out/`, and C6's `input-casper/` (34.6 GB) and `batches/c6-x6/`. On the access point `32748-c0-slice0`, `c3-*`, `c5-cfail`, `c5-x`, `c6-fetch` and `c6-x6`. On galah `SCR/x/X6` (two projects and the returned payloads) | With the owner at the Mac |
| 5 | Archive CHTC session 5's desktop session (local_f75edcf7) | The owner's yes |
| 6 | Whether galah's Docker image `lge-tools:eae819829358` (from LAUNCH M3) stays | The owner's word |

## Next step

The program is complete. Phase 3 carries its rows, which are in "Carry-in from the CHTC program" of `docs/plans/2026-10-02-architecture-program.md`.
