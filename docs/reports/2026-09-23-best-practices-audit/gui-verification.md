# Computer Use verification — Lungfish Debug built from da91880a1 (/Applications/Lungfish Debug.app)
Scratch project: ~/Desktop/LGE-audit-verify.lungfish (SARS-CoV-2 MT192765.1 + GFF + VCF + 200,000-read uniform BAM)

| Item | Result | Evidence |
|---|---|---|
| NEW-01 CLI `import bam -o <bundle>` attaches a track | PASS | manifest alignments ['uniform200k'] |
| NEW-02 sidebar picks up CLI-added bundle in new project | PASS (not reproduced) | "Reference Sequences" appeared within seconds (project on Desktop) |
| FEA-09 Go to Location accepts `MT192765.1:10,001-11,000` | PASS | ruler 10,001 - 11,000 bp. Follow-up: dialog help text does not list comma/bare-chromosome forms |
| DS-01 owner downsampling bug | PASS | banner "Showing 49,765 of 200,000 reads, sampled evenly across the view"; reads span whole window at 10-11 kb (old build: first 50k reads only reach ~7.5 kb). Follow-up DS-02: small contigs pad the fetch window to the whole contig, so the in-view share is ~1/30 of the sample; fetch visible range fully first |
| FEA-01 variant delete keeps alignment track | PASS | manifest alignments ['uniform200k'] after "Delete Selected Variant"; reads still drawn |
| P7b View menu Next/Previous/All Samples | PRESENT | View menu |
| Setup note | Launch by path | open_application by bundle id launched a stale primary-checkout debug build first |
| FEA-02 same-name FASTQ re-import does not replace | PASS (CLI) | second `import fastq` → Skipped: 1; original bundle untouched |
| NEW-03 Open Recent de-dup + focus existing window | PASS | no duplicate entries; choosing the open project created no new window |
| NEW-02 live watcher | FAIL (reproduced live) | Imports/ created by CLI while window open never appeared (Desktop project, >2 min); also in a home-folder copy (read-only window). Root-cause lane dispatched |
| Project copy lock warning | PASS | copying a project with its lock record → "may already be open" sheet with Open Read-Only/Cancel |
| Minor: `open -a app project.lungfish` replaced the current window's project instead of opening a new window | NOTE | observed once |
| WFL-10 EsViritu Advanced Settings has no Min read length | PASS | Threads + Extra arguments only; window capture saved as esviritu-advanced-settings-new.png for the manual media recapture |
| NEW-06 (new, P2) | FINDING | EsViritu dialog labels an interleaved paired bundle "Single-end reads" and runs it `-p unpaired` (EsVirituConfig treats interleaved as unpaired by design); mates counted as independent reads. Recommend deinterleave to R1/R2 and run paired, or at least label "Interleaved pairs (run as unpaired)" |
| FEA-06 quit with running operation | PASS | sheet "Quit with 1 Operation Running?" listing "EsViritu test", Cancel Operations and Quit / Don't Quit; Don't Quit kept app running |
| Cancel All Operations (EsViritu) | PASS | confirmation sheet; no esviritu/fastp/minimap2 processes remained |
| FEA-08 read sort/color modes reachable | PASS | Inspector > View > Reads: "Sort reads by" and "Color reads by" pickers. Follow-up: legacy "Color reads by strand" checkbox now duplicates the picker |
| FEA-03 Inspector delete persists | BLOCKED → NEW-07 | selecting an annotation (drawer row) started "Update Annotation" operations and rewrote genome.db with no edit; one stuck at 0% held the bundle lock, so Inspector Delete Annotation was refused "Bundle Busy". Regression from P2-A persistence. Fix lane dispatched |
| Orphaned test processes | CLEANED | 3 fake lungfish-cli + 4 SIGTERM-ignoring grandchildren from CLIImportRunnerTests/CLIVariantCallingRunnerTests runs (5-7 h old, pre-fix) killed |
