# Post-fix re-evaluation synthesis

**Date:** 2026-05-09 (sweep) and 2026-05-10 (capture + finalize)
**Build under test:** `~/Library/Developer/Xcode/DerivedData/Lungfish-aygvdshcdayvgybtylkaywokohex/Build/Products/Debug/Lungfish.app` (`lungfish-cli 0.4.0-alpha.11`)
**Reviewer:** dho, raven.local
**Personas:** see `personas.md` in this directory
**Source backlog:** `docs/issues/2026-05-09-technical-gaps-from-documentation.md`
**Follow-up backlog:** `docs/issues/2026-05-09-followups-from-evaluation-sweep.md`
**Manifest:** `/tmp/lungfish-eval/MANIFEST.md` (reviewer-local; the persistent copy of its findings lives in this synthesis and in the follow-up backlog)
**Screenshots:** `docs/user-manual/shots/captured/2026-05-09/`

## What this round evaluated

The first round of focus groups (`docs/user-manual/reviews/foundations/`
and `docs/user-manual/reviews/part-ii/`) reviewed chapter prose and
flagged 40 technical gaps the implementation needed to close
(`2026-05-09-technical-gaps-from-documentation.md`). The technical-experts
team merged 22 fixes against that backlog. This round reconvened the same
personas to re-evaluate the resulting build.

Each persona re-read the parts of the manual they cared about, then
exercised the in-app behavior or CLI surface that should have been
delivered by the fix. Verdicts are recorded in the manifest.

## Final tally (40 issues)

- **15 FIXED.** Implementation lands the spec end-to-end.
- **10 PARTIAL.** Primary path works; named gap remains. Each gap has a follow-up issue id (docs-NNNa style).
- **13 NON-RESPONSIVE.** No implementation; parent issue stays open.
- **1 BROKEN.** docs-040 (Workflow Builder is dead code; not wired into Tools menu).
- **1 CLOSED.** docs-015 was already resolved during chapter revision.

The roll-up table by issue id is in
`docs/issues/2026-05-09-followups-from-evaluation-sweep.md` and (in
greater detail) in the reviewer-local manifest.

## Cross-cutting findings

### What landed cleanly

- **Provenance + attribution.** docs-002 + docs-027 closed end-to-end.
  Project locks write user, host, pid, schemaVersion. Provenance sidecars
  carry `runtime.user`. Diana Reyes (clinical microbiology) and Sam Okafor
  (wastewater) accept this work without caveats.
- **NCBI fetch ergonomics.** docs-004 (429 retry) and docs-005 (API key
  in Settings) both closed. Aisha Bello and Maya Chen both flagged that
  the API key field is discoverable in Settings > General.
- **Pathoplexus first-class search.** docs-006 closed beyond the original
  spec. The Pathoplexus dialog ships with 10 organism presets covering
  the surveillance-PI persona's use cases (James Okonkwo) without further
  tuning.
- **Reject VCFv3 with clear error.** docs-025 closed verbatim to spec.
  Sara Linhardt (consultant, audit-trail focus) accepts.
- **Methods banner + bibliography + version table.** docs-028, 030, 029
  all closed. Marcus Chen accepts the Methods Section banner as
  sufficient for "do not paste verbatim into a paper without review."
  Chris Okafor accepts `lungfish version --tools` as the per-release
  pin.
- **Offline conda + bundle migration.** docs-031, docs-003 closed. The
  offline export/install flow is what David Okafor (sequencing-company
  bioinformatician) wanted for air-gapped lab installs.
- **Annotation preservation.** docs-001 was already FIXED but the
  earlier sweep filed an incorrect docs-001a claim about mat_peptide
  drops. The corrected verdict: NCBI's MN908947.3 record has no
  mat_peptide features in its nucleotide form (just gene + CDS); RefSeq
  NC_045512.2 ships 26 mat_peptide + 5 stem_loop features and Lungfish
  preserves all of them. Verified by CLI roundtrip and GUI annotation
  chips visible in `reference-bundle-loaded.png`.

### Where work remains (per persona theme)

- **GUI surface lags CLI.** docs-014a is the canonical example: CLI has
  `--rg-id`, `--rg-sm`, `--rg-lb`, `--rg-pl`, `--rg-pu` for read groups,
  but the Mapping dialog never asks for them. Margaret Chen and Sara
  Linhardt both flagged this. The fix is straightforward (add a Read
  Group disclosure to the Mapping dialog).
- **Pass-through args are inconsistent.** docs-021a (rename
  `--advanced-options` to `--extra-args`) and docs-021b (add to nine
  wrapped tools that don't have it). Aiko Tanaka (Snakemake builder)
  flagged that consistent forwarding is what makes wrapped tools
  trustable.
- **CZ-ID is an analysis-only CLI tool.** docs-038a: `lungfish cz-id
  summary` exists, but `lungfish import cz-id` does not. David Okafor
  wanted parity with NAO-MGS / NVD, which have full importers and
  Classifications-folder bundles. Verified by Import Center >
  Classification Results screenshot showing NAO-MGS, Kraken2, EsViritu,
  TaxTriage but no CZ-ID entry.
- **Multi-sample VCF filter syntax.** docs-024a: substrate (SQLite
  variant store) is in place; the per-sample filter grammar is not.
  Rachel Sturm (human germline PhD) wants `Sample[NA12878].GT=1/1` and
  `count(Sample[*].GT=1/1) >= 5`. The variant browser already shows
  promising filter chips (PASS, Qual ≥ 30, Singleton, Mixed 20-80%, etc.)
  but no per-sample axis yet.
- **Workflow Builder is dead code.** docs-040c is the deepest finding.
  The 2,809-line WorkflowBuilder view + 1,300-line model exist in
  source, but `WorkflowBuilderViewController` is never instantiated;
  there is no Tools menu entry; the Tools menu shows FASTQ/FASTA
  Operations / Call Variants / Search Online Databases / Plugin Manager
  only. Any persona who reads `chapters/08-workflows/01-the-workflow-builder.md`
  hits a dead end at step one. Filed as docs-040a/b/c/d. Chapter 08
  must be deleted or the feature must ship before the manual goes wide.
- **Many P2 surveillance / clinical / human-germline gaps remain
  NON-RESPONSIVE.** docs-011 (Freyja — partial: command-plan surface
  only), docs-008 (Clair3 — FIXED in the latest manifest update),
  docs-010 (bcftools), docs-012 (database update tracking), docs-013
  (BLAST rate-limiting), docs-017 (tree-viewport tools), docs-018
  (container export), docs-019 (conda lockfile), docs-023
  (sample-sheet), docs-026 (signed provenance), docs-033 (per-op
  runtime estimates), docs-034a (hardware floor in About panel), docs-035,
  docs-036, docs-037. The parent backlog file holds the full specs;
  each one is queued for a future sprint.

## How to resurrect this work in a future session

1. Read this file (`synthesis.md`) and `personas.md`.
2. Read `docs/issues/2026-05-09-followups-from-evaluation-sweep.md` for
   the full follow-up specs (single recommendation per issue, with
   reproductions and acceptance criteria).
3. Read the reviewer-local manifest at `/tmp/lungfish-eval/MANIFEST.md`
   if still on the same machine; otherwise the manifest's findings are
   redundantly captured in the follow-up backlog and this synthesis.
4. To dispatch a fresh focus group, name personas from `personas.md` and
   point them at the new evidence.

## Captured screenshots referenced by this round

All in `docs/user-manual/shots/captured/2026-05-09/`. The 13 shots that
ship with this commit are validated, window-bounded, and free of
background-app intrusion:

| File | Source view |
|---|---|
| `welcome-window.png` | Lungfish Welcome window with Get Started, Recent Projects, Required Setup, Optional Tools sidebar; Create Project / Open Project cards; Third-Party Tools status with Install button and Ready badge |
| `empty-project-window.png` | Newly opened project window with sidebar (Reference Sequences / reference / variants), empty viewport, Bundle inspector showing No Bundle Loaded |
| `sidebar-folder-conventions.png` | Project sidebar close-up showing Reference Sequences > reference / variants hierarchy |
| `tools-menu.png` | Tools menu open: FASTQ/FASTA Operations, Call Variants, Search Online Databases, Plugin Manager — verifies docs-040c (no Workflow Builder entry) |
| `tools-fastq-fasta-submenu.png` | Tools > FASTQ/FASTA Operations submenu: QC & Reporting, Demultiplexing, Trimming & Filtering, Decontamination, Read Processing, Search & Subsetting, Multiple Sequence Alignment, Mapping, Assembly, Classification, Reverse Complement, Translate |
| `tools-search-online-databases-submenu.png` | Tools > Search Online Databases submenu: Search NCBI, Search SRA, Search Pathoplexus — verifies docs-006 |
| `plugin-manager-window.png` | Plugin Manager > Packs tab: Required Setup (Third-Party Tools, 17 of 17 ready, ~2.6 GB) plus offline pack export/install command, Optional Tools > Read Mapping (minimap2, BWA-MEM2, Bowtie2) |
| `reference-bundle-loaded.png` | NC_045512 bundle loaded with annotation chips: 5'UTR, 3'UTR, CDS, gene, **mat_peptide**, stem_loop — verifies docs-001 mat_peptide preservation |
| `full-app-genome-viewport.png` | Full project window maximized: genome viewport with annotation tracks (ORF1ab, polyprotein bars), 31 annotations table, Bundle inspector with Source / Genome / Alignment Tracks (alignments.bam 197 mapped) / Read Groups / Flag Statistics / Processing Pipeline / Import Provenance |
| `variant-browser-overview.png` | Variant browser populated with 9 variants, smart-filter chips: SNV (8), Indel (1), QC (PASS, Qual ≥ 30, DP ≥ 10), Population (Singleton, Minor <20%, Mixed 20-80%, Dominant ≥80%), Type (DEL, SNP), Region/Genome/Auto toggle |
| `variant-browser-with-inspector.png` | Pileup view zoomed to 9024-12923 bp showing depth histogram + read pileup + selected variant inspector (Position, Alleles, Quality, Genotype Summary, Alt Allele Freq, INFO Fields) |
| `variant-call-dialog-lofreq.png` | Call Variants sheet, LoFreq tab: Tools sidebar (LoFreq, iVar, Medaka, GATK HaplotypeCaller with "Requires GATK Core Pack" badge), Thresholds (Min Allele Frequency 0.05, Min Depth 10), LoFreq Settings, Advanced Options text field with `--call-indels` |
| `variant-call-dialog-medaka.png` | Call Variants sheet, Medaka tab: Medaka Settings > Medaka Model `r1041_e82_400bps_sup_v5.0.0`, Advanced Options `--call-indels`, Run button disabled with "Provide the ONT/basecaller model required by Medaka" message |

## Coverage gaps (acknowledge, don't pretend)

Of 88 chapter `planned_shots` ids across the manual, 12 are fully
captured by this round and 1 (`sidebar-folder-conventions`) is partially
satisfied. The remaining 75 require additional fixtures (a loaded FASTQ
bundle, an Operations Panel with a running operation, an Assembly
viewport with contigs, a Kraken2 result with sunburst, etc.) that this
session did not seed. Future sessions can pick up where this left off
with the same capture harness (`/tmp/lungfish-eval/capture.sh`) and the
same hide-others discipline.
