---
title: Troubleshooting
chapter_id: appendices/troubleshooting
audience: bench-scientist
prereqs: []
estimated_reading_min: 12
task: Diagnose and fix common Lungfish problems.
tags: [reference, troubleshooting, errors, support]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This appendix is a symptom-to-fix lookup for the failures that turn up most often in Lungfish. Each section names a category, lists the symptoms in a table, then talks through the fix in prose. If your problem matches nothing here, the final section shows how to gather diagnostics and file a bug report someone can actually act on.

## Plugin packs and conda environments

Lungfish runs most bioinformatics tools out of per-tool conda environments under `~/.lungfish/conda`. When something goes wrong at this layer, it almost always shows up as a "missing tool" error the moment an operation tries to launch.

| Symptom | Probable cause |
|---|---|
| Operation fails with `command not found: minimap2` | Pack `read-mapping` not installed, or pack install was interrupted |
| Operation fails with `command not found: ivar` | Pack `variant-calling` not installed |
| `lungfish conda install` exits with `permission denied` | Home directory permissions or read-only filesystem |
| Pack install hangs at "solving environment" for over 10 minutes | Network proxy blocking bioconda mirror |
| Disk full during pack install | `~/.lungfish/conda` ran out of space mid-install |

For any missing-tool error, the first thing to try is the simplest: run the install command again. Lungfish's `conda install` is idempotent. It hash-checks the pack and exits without re-downloading anything if the pack is already current, and on a half-installed pack it finishes the job it started.

```bash
lungfish conda install --pack read-mapping variant-calling
```

If the install still fails, work through three checks in order. First, confirm `~/.lungfish/conda/` exists and is writable (`ls -ld ~/.lungfish/conda`). If your lab keeps tools on shared storage, set `LUNGFISH_CONDA_ROOT=/path/to/shared/conda` in the shell that runs Lungfish and make sure that directory is readable and writable for installs. Second, confirm the drive holding the conda root has at least 5 GB free (`df -h ~/.lungfish/conda`, or `df -h "$LUNGFISH_CONDA_ROOT"` when you have overridden it). Third, confirm bioconda is reachable (`curl -I https://conda.anaconda.org`). A firewall or proxy that quietly blocks bioconda will leave the solver hanging forever. On a corporate or institutional network, ask the network team about an HTTPS proxy and set `HTTPS_PROXY` in the shell that runs Lungfish.

If a classifier asks for a database the Plugin Manager does not list, remember that the database pack is separate from the tool pack. EsViritu, TaxTriage, and Kraken2 each carry their own database pack, and each installs the same way: `lungfish conda install --pack <database-name>`.

## Network and download failures

Downloads from NCBI and SRA ride on shared public infrastructure, which comes with rate limits and the occasional outage.

| Symptom | Probable cause |
|---|---|
| `lungfish fetch ncbi` returns "rate limit exceeded" | Too many requests per second; NCBI throttle |
| `lungfish fetch sra download` falls back to SRA Toolkit | ENA refused or timed out; the toolkit fallback is automatic |
| Accession not found despite being valid | Typo in accession; missing version suffix; record withdrawn |
| Download is slow (under 1 MB/s) | SRA Toolkit fallback path is used; ENA is faster when available |
| Network errors in the middle of a long download | Transient connectivity issue; retry usually works |

When NCBI throttles you, Lungfish handles it for you: it retries an HTTP 429 up to five times, starting at a 5-second wait and doubling each time to a 5-minute cap. If you plan to run many fetches back to back, register for an NCBI API key (it is free and takes about 30 seconds) and set `NCBI_API_KEY` in the shell that runs Lungfish. Authenticated requests get higher rate limits. Reach for `lungfish fetch ncbi --no-retry ...` only in scripts that are meant to fail fast. Provenance sidecars log the retry count and the backoff timing, and they record only whether an API key was provided.

For SRA downloads, the Operations Panel notes which path served each one. If ENA refused and the SRA Toolkit stepped in, the operation row's provenance disclosure reads `Falling back to SRA Toolkit (prefetch + fasterq-dump)`. That fallback is slower, since it streams `.sra` and converts on the fly, but the FASTQs it produces are equivalent. When both paths fail, wait a few hours and retry. Both archives have transient outages.

For "accession not found", check the accession string itself. Nucleotide accessions need their version suffix (`MN908947.3`, not `MN908947`). Assembly accessions go through `lungfish fetch genome`, not `lungfish fetch ncbi`.

## Read mapping problems

| Symptom | Probable cause |
|---|---|
| Mapping rate below 10% | Wrong reference, or wrong preset for the read type |
| "No reads in pair" error | Paired files have inconsistent read counts; pairing failed |
| Mapping completes but no track appears in sidebar | `bam adopt-mapping` step was skipped or failed |
| BAM index missing | Manual mapping run did not include `samtools index` |
| Wildly different mapping rates between Read 1 and Read 2 | Adapter contamination or library-prep failure |

A very low mapping rate almost always means the wrong reference. Confirm the reference matches the organism, because a SARS-CoV-2 reference will not align monkeypox reads. The trap with ONT or PacBio data is that the wrong preset does not fail. It quietly produces poor alignments, so check that the preset matches the platform: `sr` for Illumina, `map-ont` for Nanopore, `map-hifi` for PacBio HiFi.

When paired-end pairing fails, Lungfish raises the error early in the operation rather than later. The two files have to carry the same read count in the same per-read order. If one was re-sorted, or a subset of reads was dropped, re-pair the FASTQs from their original source.

When mapping finishes but no track shows up in the sidebar, the `bam adopt-mapping` step never ran. Run it by hand: `lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir> --name <track-name>`. The `--name` option is required. The mapping output directory survives the failure on disk, so re-adopting recovers the work without re-mapping a single read.

## Variant calling failures

| Symptom | Probable cause |
|---|---|
| iVar reports zero variants | Wrong reference, or BAM is empty after primer-trim |
| iVar errors with "BAM not primer-trimmed" | Calling iVar on un-trimmed BAM without acknowledgement |
| LoFreq runs but produces zero rows | Indelqual step skipped (LoFreq under-calls indels by design) |
| Codon-merge does not fire | GFF3 not attached to the reference bundle |
| Variant call takes hours instead of minutes | Coverage cap not raised on amplicon data |

For amplicon data, iVar expects a primer-trimmed BAM. The Variant Calling dialog confirms this automatically when the primer-trim sidecar is present. Call iVar against an un-trimmed BAM and you have two choices: run primer-trim first, or check the manual acknowledgement and accept the phantom variants that will appear at primer footprints. On the CLI, the flag is `--ivar-primer-trimmed`.

For LoFreq, the usual culprit is missing indelqual preprocessing. LoFreq's own manual recommends `lofreq indelqual --dindel` before calling, and Lungfish runs that step by default. A hand-built CLI invocation that jumps straight to `lofreq call-parallel`, though, will under-call indels.

For codon-merge, confirm the bundle's `annotations/` directory actually holds a GFF3 file. Open the bundle in Finder, find the directory, and check the manifest. If no GFF3 was supplied when the bundle was built, re-create it with `--annotation` pointing at the GFF3 file. Codon-merge only fires in the iVar pipeline when the bundle's GFF is exported into the working directory.

## Project and file integrity

| Symptom | Probable cause |
|---|---|
| Project window opens empty | `manifest.json` corrupted or missing |
| Bundle disappeared from sidebar | Bundle folder was moved or deleted on disk |
| FASTA index `.fai` missing | Index was deleted or never generated |
| BAM `.bai` missing | Same |
| `Tabix` index `.tbi` missing | VCF was bgzipped without indexing |

A project that opens empty usually has a corrupted `manifest.json`. Open the project folder in Finder and look for `manifest.json` at the root. If it is missing or zero bytes, restore it from a backup. If it opens and parses cleanly (try TextEdit or `cat`), the trouble lies elsewhere. Remember that Lungfish projects are just folders. You can copy one to another machine and double-click it to open.

If a bundle has vanished from the sidebar but its folder is still sitting in `Reference Sequences/`, restart Lungfish. The sidebar rebuilds itself from the project tree on launch.

Missing index files (`.fai`, `.bai`, `.tbi`) regenerate on their own the moment Lungfish needs them. The first operation that requires an index simply rebuilds it. To force one by hand, the underlying tools are `samtools faidx`, `samtools index`, and `tabix`.

## Performance and resource issues

| Symptom | Probable cause |
|---|---|
| Kraken2 runs out of memory | Standard or PlusPF database loaded on a 16 GB machine |
| Variant calling slow on amplicon data | Default mpileup depth cap (8000) limits high-coverage amplicons |
| App becomes unresponsive during a download | Operations Panel shows progress; UI thread is fine but window updates are throttled |
| Assembly fails with out-of-memory | SPAdes or Hifiasm needs more RAM than the machine has |
| Disk fills up during multi-step pipeline | Intermediate files accumulate; cleanup happens after operation completes |

Kraken2 loads its entire database into RAM. The Standard database needs roughly 50 GB, and PlusPF roughly 80 GB. On a 16 GB MacBook, only the Viral database (about 500 MB) fits. The larger ones will swap heavily and then crash, so either stay on the Viral database or move to a workstation with the RAM to hold the one you need.

For variant calling on amplicon data, the iVar chapter notes that Lungfish raises the mpileup depth cap to 600,000. A CLI run that keeps the default cap of 8000 will silently truncate high-coverage amplicons, which often run past 1000x. The Power User Notes appendix has the exact mpileup invocation.

The app stays responsive during long operations because the real work runs on background threads. When an operation fires off dense progress events, the interface throttles its updates, and the window can look frozen for a few seconds. It has not crashed.

## iCloud, NFS, and shared storage

Lungfish projects are folders. They live on disk and assume the semantics of a local filesystem.

iCloud Drive can corrupt a project folder mid-write. Its eventual-consistency model collides with Lungfish's assumption that a file write either completes or does not. So keep projects out of iCloud Drive. Use `~/Documents` with iCloud sync turned off for that folder, or pick a path outside iCloud altogether.

NFS-mounted lab storage works, but on some configurations file locking fails, which surfaces as "could not acquire lock on manifest.json". If NFS is your only option, mount it on the client with `noac,actimeo=0` to disable attribute caching.

For team workflows, the honest answer today is one project per researcher per analysis, on local disk. Multi-user shared projects are not supported yet.

## Migrating from older Lungfish versions

Bundle formats carry a version. Each bundle's `manifest.json` declares it in a `version` field. Lungfish reads older bundle versions transparently, but it refuses to write into a bundle older than the current version.

To migrate an old project, start with the migration report from the command line. `lungfish project migrate <project>` scans the bundles, reports the schema versions it can see, and synthesizes the current reference-bundle fields wherever it can do so safely. Add `--dry-run` to scan without writing anything. See [Shared Projects](shared-projects.md) for the full migration behavior. Bundles whose legacy schema has no transformer are reported, not rewritten. For those, re-create the bundles by re-importing their source FASTAs. The original provenance carries over if you copy the `provenance/` subdirectory into the new bundles by hand.

## Collecting diagnostics for a bug report

When a problem matches nothing above, gather these artifacts before you file a bug:

- The Operations Panel row for the failing operation, expanded to show the log
- The exact command line Lungfish ran (visible in the operation's provenance disclosure)
- The Lungfish app version (Lungfish menu > About Lungfish)
- The plugin pack versions (`lungfish conda list`)
- The macOS version (Apple menu > About This Mac)

For tangled failures that span several operations, the project's `.lungfish/logs/cli.log` holds the full transcript. Attach the relevant slice, or the whole file if it is small. Leave the project's data files out. The log on its own usually carries enough context.

File bug reports through the GitHub repository linked from the Lungfish Help menu, or the support email listed under `Lungfish menu > About Lungfish`.

## Next

See [CLI Reference](cli-reference.md) for the exact command-line syntax of any operation, [Power User Notes](power-user-notes.md) for deeper-dive content on tool internals, or [File Formats](file-formats.md) for what each Lungfish bundle file contains.
