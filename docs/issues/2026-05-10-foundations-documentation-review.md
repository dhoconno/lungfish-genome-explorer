# Foundations Documentation Review Manifest

**Filed:** 2026-05-10
**Scope:** `docs/user-manual/chapters/01-foundations/01-what-is-a-genome.md` through `09-shared-projects.md`
**Baseline:** `v0.4.0-alpha.12`, commit `921ba202a82d8806d6ac95a7c4ca273d6350da35`
**Status:** Planning review only. Do not implement fixes until the manifest and plans are reviewed.

This manifest captures claims in the Foundations section that are scientifically incorrect, too broad for expert readers, out of sync with the alpha app, or temporally unstable. The proposed dispositions are intentionally conservative: correct the manual where it overstates current behavior, and create implementation work only where the missing behavior is important enough to support.

Severity levels:

- **P0 - Blocking correctness.** A claim is scientifically wrong or teaches a workflow in a way that can mislead analysis.
- **P1 - App/manual mismatch.** A current-behavior claim appears unsupported, too absolute, or needs an alpha limitation.
- **P2 - Important precision.** The statement is directionally useful but needs scientific or product nuance.
- **P3 - Editorial/hygiene.** Low-risk wording, dated phrasing, or navigation cleanup.

## Executive Summary

The Foundations section is useful and mostly aligned with the direction of the app, but it currently reads more mature than the `v0.4.0-alpha.12` product in several places. The highest-priority fixes are:

- Correct the SARS-CoV-2 D614G example: D614G is `A23403G` relative to `MN908947.3`/`NC_045512.2`, not `21618 C>T`.
- Correct the shotgun low-abundance arithmetic: if viral reads are 0.01% of reads, one viral read is expected per roughly 10,000 reads, not 300 million; 1x breadth for a 30 kb genome with 150 bp reads is roughly 2 million total reads before losses, not 300 million.
- Align the project chapter with the current project layout, including the `Analyses/` folder and the fact that some top-level folders are created lazily.
- Rework provenance wording so it matches both the product and the repository provenance requirement: missing provenance is blocking for new scientific workflows, but the manual should not imply every legacy or UI-adjacent path already has perfect provenance unless tested.
- Add expert-level caveats around BAM/VCF semantics: BAM rows are alignment records, not always one record per read; VCF `QUAL`, `GT`, `AF`, and `FILTER` fields are caller-defined and must be interpreted through headers and Lungfish normalization.
- Tone down claims about Operations Panel persistence, "anywhere" coordinate-string support, Help menu anchoring/search/reporting, and exact export/provenance UX until verified in app tests.
- Treat plugin-pack and active-issue drift as a documentation infrastructure problem: pack tables should be generated or checked against source, and active issue files need reconciliation when the implementation has moved on.

External checks used for this draft:

- D614G coordinate: the SARS-CoV-2 D614G spike variant is caused by `A23403G` relative to `MN908947.3` in published sequencing work ([PMC7566627](https://pmc.ncbi.nlm.nih.gov/articles/PMC7566627/)).
- ARTIC primer scheme wording: ARTIC v5.3.2 was released in January 2023, and ARTIC later posted a v5.4.2 update for JN.1-era mutations, so the manual should avoid unqualified "current ARTIC primer set" language without a dated source ([v5.3.2 release](https://community.artic.network/t/sars-cov-2-version-5-3-2-scheme-release/462), [v5.4.2 release](https://community.artic.network/t/scheme-release-artic-sars-cov2-400-v5-4-2/546)).

## Issue Manifest

| ID | Severity | Location | Claim | Assessment | Proposed disposition |
| --- | --- | --- | --- | --- | --- |
| FND-001 | P0 | `01-what-is-a-genome.md:68-82` | `21618 C>T` is used as the D614G example. | Wrong coordinate and substitution for D614G. D614G is `A23403G` relative to the Wuhan-Hu-1 reference. | Replace the example with `MN908947.3:23403 A>G` and adjust nearby prose. Add a quick doc check that prevents `21618 C>T` and `D614G` from co-occurring. |
| FND-002 | P0 | `03-amplicon-vs-shotgun.md:40` | At 0.01% viral nucleic acid, "roughly 300 million reads" are needed before one viral read. | Arithmetic is wrong by orders of magnitude if the percentage is read fraction. | Replace with a transparent calculation: one viral read per 10,000 reads; about 200 viral 150 bp reads for 1x nominal coverage of 30 kb; about 2 million total reads before losses. |
| FND-003 | P1 | `06-the-lungfish-project.md:48,72-82` | A project has five sidebar/Finder folders. | Current code has a project-level `Analyses/` folder and treats Downloads/Analyses as important top-level concepts. Some folders are created lazily. | Update the chapter to describe active top-level project areas as a current alpha layout, including `Analyses/`, and distinguish always-created from created-on-use folders. |
| FND-004 | P1 | `08-provenance-and-reproducibility.md:29-102` | Every operation producing a file writes a sidecar; schema example is authoritative; Lungfish verifies checksums when reading later. | Provenance is a repository requirement and many workflows implement it, but the chapter overstates unverified legacy coverage and likely shows a schema that does not match all current sidecars. | Rewrite as a guarantee for newly supported scientific workflows, list audited workflow families, and link gaps to active provenance issues. Refresh the example from a real alpha 12 sidecar. |
| FND-005 | P1 | `06-the-lungfish-project.md:106-112` | Operations Panel is the audit trail; rows persist across launches; a running job keeps going after the window closes. | Current operation tracking exists, but persistence/resume-after-close needs direct UI and code verification before being taught as a guarantee. | Either prove with tests and keep precise wording, or downgrade to current live-session behavior plus provenance/sidecar audit trail. |
| FND-006 | P1 | `01-what-is-a-genome.md:90`, `08-provenance-and-reproducibility.md:142-202` | Exports have a citation block; File > Export > Provenance produces shell/Nextflow/Snakemake/methods artifacts in the described shapes. | Provenance export menu items exist, but the exact output packaging and citation behavior need verification against current implementation. | Audit export paths and either fix docs to match actual files or create implementation tickets for missing export formats. |
| FND-007 | P1 | `06-the-lungfish-project.md:128` | Help opens the manual in the default browser anchored to current view; Help > Search; Report a Problem includes the operation log. | Needs app-menu verification. The manual should not teach non-existent menu items. | Verify the menu surface. Keep implemented items only; file follow-up specs for Help search/reporting if absent. |
| FND-008 | P1 | `01-what-is-a-genome.md:70` | Lungfish accepts coordinate strings "anywhere it asks for a location." | Code search did not show a general coordinate parser surfaced across the app. | Replace with the specific surfaces that accept genomic regions, or implement a shared parser before keeping broad wording. |
| FND-009 | P1 | `07-plugin-packs.md:74-105` | macOS requirement, pack table, pack sizes, and "current" pack examples. | Several claims are plausible but must be aligned with `PluginPack.swift`, release settings, and current docs. Variant-calling now includes Medaka and Clair3, which is current; OS/version wording needs special verification. | Generate the table from or manually reconcile against `PluginPack.builtIn`, and replace "current" biology wording with dated/versioned wording. |
| FND-010 | P2 | `01-what-is-a-genome.md:28,32,58` | Every cell/virus particle carries a copy; SARS-CoV-2 has a "chromosome"; RNA/DNA viruses look identical once deposited. | Oversimplified. Expert readers will notice anucleate cells, defective particles, segmented genomes, direct RNA workflows, and imprecise "chromosome" terminology. | Tighten wording: genome copy is conceptual, SARS-CoV-2 has a single positive-sense RNA genome, and most common reference files represent RNA viruses with DNA alphabet conventions. |
| FND-011 | P2 | `02-sequencing-reads.md:34-86` | Quality thresholds and read-pair observations are presented as broadly reliable. | Q-score calibration and pair counting vary by platform and caller. | Reframe Q30/Q20 guidance as Illumina-centered heuristics and explain that variant callers count evidence according to their pileup/fragment model. |
| FND-012 | P2 | `03-amplicon-vs-shotgun.md:30,63,97`, `04-alignment-files.md:101`, `05-variants-and-vcf.md:158` | Primer trimming is always the first step; strand-bias filters are usually disabled/ignored for amplicon data. | Primer trimming in Lungfish is a BAM-level operation after alignment. Strand-bias guidance is too absolute. | Make the workflow order explicit and teach strand bias as "inspect in context; protocol dependent", not "ignore". |
| FND-013 | P2 | `04-alignment-files.md:48-75` | Lungfish ships four mappers; always reads/writes BAMs, never SAMs; every BAM has a `.bai` next to it. | The mapper list is supported by current CLI/catalog language. The "never SAM" and "every BAM" statements need caveats because imports and intermediate tool outputs may vary. | Keep mapper list, replace absolutes with "current GUI workflows store indexed BAM/CRAM tracks" and document regenerate-index behavior only where implemented. |
| FND-014 | P2 | `05-variants-and-vcf.md:49,98,146-170` | VCF compression/indexing, single-sample VCFs, caller flags, default filters, and browser presets. | Directionally likely for viral workflows, but exact filter labels and browser controls should be verified against UI tests and real output. | Refresh from current fixtures and dialog state. Include Clair3/bcftools/GATK caveats where alpha behavior differs by caller. |
| FND-015 | P2 | `09-shared-projects.md:28-110` | GUI shared-project warnings are future; CLI lock/migrate examples are shown. | This chapter is unusually honest about limitations. Current code includes `lungfish project lock`, `unlock`, and `migrate`; GUI warnings/read-only mode remain future. | Keep the limitation framing. Verify exact CLI examples and add acceptance criteria for future GUI read-only mode instead of rewriting now. |
| FND-016 | P3 | `01-what-is-a-genome.md:96-98` and chapter navigation prose | Forward pointers describe the section flow loosely. | Minor stale navigation after Foundations grew to include projects, plugins, provenance, and sharing. | Update after the substantive content pass. |
| FND-017 | P2 | `03-amplicon-vs-shotgun.md:71`, `04-alignment-files.md:97` | Primer-trim output BAM has the same number of reads as input. | `ivar trim` often soft-clips primer bases, but options and primer matching can remove or exclude reads. | Say trimming usually preserves records in the common soft-clip path, but read counts can change depending on options; require provenance to record trim options. |
| FND-018 | P2 | `03-amplicon-vs-shotgun.md:75` | A six-column BED row is described as listing primer sequence. | Standard six-column BED does not include primer sequence. | Distinguish primer coordinates from optional primer sequence FASTA/TSV or nonstandard extra columns. |
| FND-019 | P2 | `04-alignment-files.md:34,54` | BAM is described as one row per read. | BAM stores alignment records. One read can have primary, secondary, supplementary, and mate records with flags describing their roles. | Rewrite the BAM introduction around alignment records and flags. |
| FND-020 | P2 | `04-alignment-files.md:75`, `05-variants-and-vcf.md:49` | `.bai` and `.tbi` are treated as universal indexes. | BAI/TBI are common for the current viral-scale examples, but CSI may be needed for very large references. | Add a short CSI caveat without distracting novice readers. |
| FND-021 | P2 | `05-variants-and-vcf.md:83,93,95,128-136` | `QUAL`, `GT`, and `AF` are taught as universal semantics. | VCF field semantics are caller- and header-defined. Human/cohort VCFs, pooled samples, viral haploid calls, and Lungfish-normalized viral VAFs differ. | Define the Lungfish viral convention explicitly and tell users to inspect VCF headers for other callers and multisample/human files. |
| FND-022 | P2 | `05-variants-and-vcf.md:146-158` | FILTER flags are common across iVar, LoFreq, and Medaka. | iVar native output is TSV before conversion; Medaka and Clair3 use different conventions; Lungfish may normalize some labels. | Split the table by caller or label it as Lungfish-normalized output, with the VCF header as authoritative. |
| FND-023 | P2 | `06-the-lungfish-project.md:38` | Copying a project folder to another Mac preserves all data/history. | Project data and provenance can travel, but plugin packs, conda environments, databases, and compatible app versions live outside the project. | Rephrase portability as "data and provenance travel; execution requires compatible Lungfish and managed tools/databases." |
| FND-024 | P1 | `02-sequencing-reads.md:124`, `04-alignment-files.md:105`, `05-variants-and-vcf.md:36,146`, `07-plugin-packs.md:95` | Variant caller inventory and GATK status are inconsistent. | Current source/tests expose LoFreq, iVar, Medaka, Clair3, bcftools support, and more GATK execution/provenance behavior than "dry-run only" implies. | Audit caller surfaces and update Foundations to distinguish current GUI lanes, CLI-supported lanes, installed-but-not-promoted tools, and docs-039 GATK first-class scope. |
| FND-025 | P1 | `07-plugin-packs.md:92-105,244` | Plugin-pack IDs/tools/sizes are hand-maintained and drift from source; tool-pack size is blended with database size. | `PluginPack.builtIn`, the managed-tool lock, and database registry are the source of truth. Databases can dominate disk by tens or hundreds of GB. | Create a plugin-pack doc sync task or generated table; separate tool environment disk usage from database storage. |
| FND-026 | P1 | `08-provenance-and-reproducibility.md:31,196,208-224` | Same pack version is implied to be close to enough for bit-identical reproduction; helper/converter versions are under-specified. | Bit-identical reproduction needs resolved packages/lockfiles or container digests. Internal helpers such as iVar TSV-to-VCF conversion need tool name, version/checksum, argv, inputs, outputs, runtime, and useful stderr. | Strengthen the provenance contract and make helper tools first-class provenance steps. |
| FND-027 | P2 | `08-provenance-and-reproducibility.md:47` | The chapter says seven top-level keys, but the example includes eight. | Minor internal inconsistency. | Remove the count or correct it after the sidecar example refresh. |
| FND-028 | P1 | `09-shared-projects.md:104` | Migration provenance omits explicit workflow/tool version and runtime identity. | Repository provenance requirements apply to migrations that rewrite scientific data. | Ensure migration docs and implementation include tool/workflow name/version, argv/defaults, runtime identity, final payload paths, checksums, sizes, exit status, wall time, and useful stderr. |
| FND-029 | P2 | `docs/issues/2026-05-09-followups-from-evaluation-sweep.md:57` | Active issue status says Workflow Builder is dead code, while current source exposes menu/save paths. | Not directly a Foundations prose bug, but it affects planning confidence for documentation follow-up work. | Add an active-issue reconciliation pass before implementation sprint planning. Do not archive or implement from stale issue status without verification. |

## Recommended Workstreams

### SPEC-FND-001: Scientific Correctness Patch

Correct D614G, shotgun-depth arithmetic, viral genome terminology, FASTQ/Q-score caveats, amplicon workflow order, and strand-bias guidance. This should be documentation-only unless reviewers identify an app behavior that enforces the wrong model.

### SPEC-FND-002: Foundations/App Capability Alignment

Audit every app/CLI claim in Foundations against `Sources/`, `Tests/`, and a small UI smoke where needed. Patch prose where the feature exists differently; create implementation tickets where the feature is important but missing.

### SPEC-FND-003: Provenance Contract and Example Refresh

Replace generic provenance claims with a precise alpha 12 contract, anchored in the repository provenance requirement. Use real sidecar examples from current workflows and list known gaps explicitly.

### SPEC-FND-004: Project, Plugin Pack, and Shared-Project Truth Table

Reconcile project folders, plugin pack tables, OS/storage requirements, lock behavior, and shared-project limitations against current code and release artifacts.

### SPEC-FND-005: Active Issue Reconciliation Gate

Before turning the Foundations review into implementation work, reconcile active issue files that mention documentation-derived technical gaps. Mark completed items, update partially implemented scopes such as Workflow Builder and GATK, and keep still-salient expert-review issues active.

## Rationales for Not Addressing Now

- Do not implement GUI read-only mode for shared projects as part of the Foundations doc pass. The manual can honestly describe CLI locking and current GUI limitations while a separate product spec handles multi-user behavior.
- Do not add a universal coordinate parser just to justify the phrase "anywhere it asks for a location." Patch the wording first; implement the parser only if later workflow chapters need it repeatedly.
- Do not promise "current ARTIC" status in the manual. Use explicit scheme names and dates, and teach users to verify primer schemes against their protocol/source.
- Do not broaden the release scope for provenance export packaging until the export audit distinguishes implemented menu items from missing output shapes.
- Do not treat plugin-pack hand tables as trustworthy after this point. Either generate/check them or require a source-code audit when editing the chapter.
- Do not plan from active issue files that conflict with current source until those issue files are reconciled.
