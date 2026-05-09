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

This appendix is a symptom-to-fix lookup for the failures that come up most often in Lungfish. Each section names a category, lists symptoms in a table, and walks through the fix in prose. When a problem in your workflow does not match any entry here, the last section explains how to gather diagnostics and file a useful bug report.

## Plugin packs and conda environments

Lungfish runs most bioinformatics tools out of per-tool conda environments under `~/.lungfish/conda`. Failures here usually surface as "missing tool" errors when an operation tries to run.

| Symptom | Probable cause |
|---|---|
| Operation fails with `command not found: minimap2` | Pack `read-mapping` not installed, or pack install was interrupted |
| Operation fails with `command not found: ivar` | Pack `variant-calling` not installed |
| `lungfish conda install` exits with `permission denied` | Home directory permissions or read-only filesystem |
| Pack install hangs at "solving environment" for over 10 minutes | Network proxy blocking bioconda mirror |
| Disk full during pack install | `~/.lungfish/conda` ran out of space mid-install |

The first fix to try for any missing-tool error is to re-run the install command. Lungfish's `conda install` is idempotent: it does a hash check and exits without re-downloading if the pack is current. Re-running on a partially-installed pack repairs the install.

```bash
lungfish conda install --pack read-mapping variant-calling
```

If the install still fails, check three things in order. Confirm `~/.lungfish/conda/` exists and is writable (`ls -ld ~/.lungfish/conda`). Confirm there is at least 5 GB of free space on the drive holding the home directory (`df -h ~`). Confirm bioconda is reachable from the network (`curl -I https://conda.anaconda.org`). A firewall or proxy that blocks bioconda will hang the solver indefinitely; on a corporate or institutional network, ask the network team about an HTTPS proxy and set `HTTPS_PROXY` in the shell that runs Lungfish.

If a classifier asks for a database that the Plugin Manager does not list, the database pack is separate from the tool pack. EsViritu, TaxTriage, and Kraken2 each have their own database pack, installed the same way: `lungfish conda install --pack <database-name>`.

## Network and download failures

Downloads from NCBI and SRA depend on shared infrastructure that has rate limits and occasional outages.

| Symptom | Probable cause |
|---|---|
| `lungfish fetch ncbi` returns "rate limit exceeded" | Too many requests per second; NCBI throttle |
| `lungfish fetch sra download` falls back to SRA Toolkit | ENA refused or timed out; the toolkit fallback is automatic |
| Accession not found despite being valid | Typo in accession; missing version suffix; record withdrawn |
| Download is slow (under 1 MB/s) | SRA Toolkit fallback path is used; ENA is faster when available |
| Network errors in the middle of a long download | Transient connectivity issue; retry usually works |

For NCBI rate limits, wait a few minutes and retry. NCBI imposes per-IP request rate limits that ease automatically. To run many fetches in succession, register for an NCBI API key (free, takes 30 seconds) and configure it in `Settings > General > NCBI API key`; rate limits are higher for authenticated requests.

For SRA downloads, the Operations Panel records which path served each download. If ENA refused and the SRA Toolkit ran, the operation row's provenance disclosure shows `Falling back to SRA Toolkit (prefetch + fasterq-dump)`. The toolkit fallback is slower (it streams `.sra` and converts on the fly) but produces equivalent FASTQs. If both paths fail, retry after a few hours; both archives have transient outages.

For "accession not found", confirm the accession string. Nucleotide accessions need the version suffix (`MN908947.3`, not `MN908947`). Assembly accessions go through `lungfish fetch genome`, not `lungfish fetch ncbi`.

## Read mapping problems

| Symptom | Probable cause |
|---|---|
| Mapping rate below 10% | Wrong reference, or wrong preset for the read type |
| "No reads in pair" error | Paired files have inconsistent read counts; pairing failed |
| Mapping completes but no track appears in sidebar | `bam adopt-mapping` step was skipped or failed |
| BAM index missing | Manual mapping run did not include `samtools index` |
| Wildly different mapping rates between Read 1 and Read 2 | Adapter contamination or library-prep failure |

Very low mapping rate almost always means the wrong reference. Check that the reference matches the organism (a SARS-CoV-2 reference will not align reads from monkeypox). For ONT or PacBio data with the wrong preset, mapping silently produces poor alignments instead of failing; verify the preset matches the platform (`sr` for Illumina, `map-ont` for Nanopore, `map-hifi` for PacBio HiFi).

When paired-end pairing fails, Lungfish surfaces an error early in the operation. Both files must have the same read count and the same per-read order. If one file has been re-sorted or a subset of reads dropped, re-pair the FASTQs from the original source.

When mapping completes but no track appears, the `bam adopt-mapping` step did not run. Re-run it manually: `lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir>`. The mapping output directory is preserved on disk after the failure, so re-adoption recovers the work without re-mapping.

## Variant calling failures

| Symptom | Probable cause |
|---|---|
| iVar reports zero variants | Wrong reference, or BAM is empty after primer-trim |
| iVar errors with "BAM not primer-trimmed" | Calling iVar on un-trimmed BAM without acknowledgement |
| LoFreq runs but produces zero rows | Indelqual step skipped (LoFreq under-calls indels by design) |
| Codon-merge does not fire | GFF3 not attached to the reference bundle |
| Variant call takes hours instead of minutes | Coverage cap not raised on amplicon data |

iVar requires a primer-trimmed BAM for amplicon data. The Variant Calling dialog auto-confirms when the primer-trim sidecar is present. If you call iVar against an un-trimmed BAM, either run primer-trim first or check the manual acknowledgement and accept the resulting phantom variants at primer footprints. The CLI flag is `--ivar-primer-trimmed`.

For LoFreq, the typical issue is missing indelqual preprocessing. LoFreq's manual recommends `lofreq indelqual --dindel` before calling. Lungfish runs this step by default, but a hand-built CLI invocation that calls `lofreq call-parallel` directly will under-call indels.

For codon-merge, confirm that the bundle's `annotations/` directory contains a GFF3 file. Open the bundle in Finder, look for the directory, and check the manifest; if the GFF3 was not provided at bundle creation, re-create the bundle with `--annotation` pointing at the GFF3 file. The codon-merge happens in the iVar pipeline only when the bundle's GFF is exported into the working directory.

## Project and file integrity

| Symptom | Probable cause |
|---|---|
| Project window opens empty | `manifest.json` corrupted or missing |
| Bundle disappeared from sidebar | Bundle folder was moved or deleted on disk |
| FASTA index `.fai` missing | Index was deleted or never generated |
| BAM `.bai` missing | Same |
| `Tabix` index `.tbi` missing | VCF was bgzipped without indexing |

If a project opens empty, the project's `manifest.json` may be corrupted. Open the project folder in Finder. Look for `manifest.json` at the root. If it is missing or zero bytes, restore from a backup. If it parses (open with TextEdit or `cat`), the issue is elsewhere. Lungfish projects are folders; you can copy a project to another machine and double-click it to open.

If a bundle is missing from the sidebar but the folder is still in `Reference Sequences/`, restart Lungfish. The sidebar refresh reads the project tree on launch.

Missing index files (`.fai`, `.bai`, `.tbi`) regenerate automatically when Lungfish needs them. The first operation that requires an index will rebuild it. To regenerate manually, the underlying tools are `samtools faidx`, `samtools index`, and `tabix`.

## Performance and resource issues

| Symptom | Probable cause |
|---|---|
| Kraken2 runs out of memory | Standard or PlusPF database loaded on a 16 GB machine |
| Variant calling slow on amplicon data | Default mpileup depth cap (8000) limits high-coverage amplicons |
| App becomes unresponsive during a download | Operations Panel shows progress; UI thread is fine but window updates are throttled |
| Assembly fails with out-of-memory | SPAdes or Hifiasm needs more RAM than the machine has |
| Disk fills up during multi-step pipeline | Intermediate files accumulate; cleanup happens after operation completes |

Kraken2 loads the entire database into RAM. The Standard database needs roughly 50 GB. The PlusPF database needs roughly 80 GB. On a 16 GB MacBook, only the Viral database (about 500 MB) fits. The other databases will swap heavily and crash; use the Viral database or run on a workstation with enough RAM.

For variant calling on amplicon data, the chapter on iVar mentions that Lungfish raises the mpileup depth cap to 600,000. If a CLI run uses the default cap of 8000, high-coverage amplicons (often 1000x+) get silently truncated. Power-user notes appendix has the exact mpileup invocation.

The app remains responsive during long operations because work runs on background threads. The UI updates are throttled when an operation produces dense progress events; the window may appear to freeze for a few seconds, but it is not crashed.

## iCloud, NFS, and shared storage

Lungfish projects are folders. They live on disk and assume local filesystem semantics.

iCloud Drive synchronization can corrupt project folders mid-write because iCloud's eventual-consistency model conflicts with Lungfish's assumption that file writes complete atomically. Do not put projects in iCloud Drive. Use `~/Documents` (with iCloud sync turned off for that folder), or use a path outside iCloud entirely.

NFS-mounted lab storage works but file locking can fail on some configurations, leading to "could not acquire lock on manifest.json" errors. If NFS is the only available storage, configure it with `noac,actimeo=0` on the client to disable attribute caching.

For team workflows, the right answer is currently: one project per researcher per analysis, on local disk. Multi-user shared projects are not yet supported.

## Migrating from older Lungfish versions

Bundle formats are versioned. The bundle's `manifest.json` declares its `version` field. Lungfish reads older bundle versions transparently but will refuse to write to a bundle version older than the current.

If you need to migrate an old project: open the project in the latest Lungfish, run `Project > Migrate Bundles to Current Version` from the menu (when available), or re-create the bundles from their source FASTAs by re-importing. The provenance in the original bundles is preserved if you copy the `provenance/` subdirectory into the new bundles by hand.

## Collecting diagnostics for a bug report

When a problem does not match any entry above, gather these artifacts before filing a bug:

- The Operations Panel row for the failing operation, expanded to show the log
- The exact command line Lungfish ran (visible in the operation's provenance disclosure)
- The Lungfish app version (Lungfish menu > About Lungfish)
- The plugin pack versions (`lungfish conda list`)
- The macOS version (Apple menu > About This Mac)

For complex failures that involve multiple operations, the project's `.lungfish/logs/cli.log` carries the full transcript. Attach the relevant portion (or the whole file if it is small) to the bug report. Do not include the project's data files; the log alone usually has enough context.

File bug reports through the GitHub repository linked from the Lungfish Help menu, or through the support email listed in `Lungfish menu > About Lungfish`.

## Next

See [CLI Reference](cli-reference.md) for the exact command-line syntax of any operation, [Power User Notes](power-user-notes.md) for deeper-dive content on tool internals, or [File Formats](file-formats.md) for what each Lungfish bundle file contains.
