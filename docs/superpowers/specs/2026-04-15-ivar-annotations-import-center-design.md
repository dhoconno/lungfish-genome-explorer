# iVar, Annotations, and Import Center Consolidation — Design

**Date:** 2026-04-15
**Author:** Claude (sad-morse worktree, branch `claude/sad-morse`)
**Parent plan:** `docs/superpowers/plans/2026-04-15-documentation-agent-team.md`
**Status:** Draft for user review

---

## 1. Scope and non-goals

### In scope

Three categories of change, landed as six PRs to `main`.

**App (Swift, LungfishApp):**
- Remove the `File > Import` submenu entirely. `File > Import Center…` becomes the single import entry point for every file type.
- Add a new **Annotations** section to Import Center. It accepts GFF3, GTF, and BED. The user picks an existing reference in the project to anchor the annotation track.
- Diagnose and fix the bug that prevents `reference.fasta` from being importable via Import Center → References on `main`.

**Fixture (`docs/user-manual/fixtures/sarscov2-clinical/`):**
- Swap the reference accession from MT192765.1 to NC_045512.2 (same genome sequence; NC_045512.2 is the canonical RefSeq accession and has a matching standard GFF3).
- Regenerate `alignments.bam` + `.bai` against the new reference.
- Re-call variants with **iVar** (using `--output-format vcf`) against the new reference and the new annotations GFF3, producing `variants.vcf.gz` + `.tbi` with iVar's native `ANN=` functional consequence fields.
- Add `annotations.gff3` from NCBI RefSeq for NC_045512.2.
- Update `fetch.sh` to document provenance (not automate iVar re-runs).

**Documentation (`docs/user-manual/`):**
- Rewrite chapter `04-variants/01-reading-a-vcf.md` to cover the end-to-end Import Center flow: reference → annotations → VCF → (optional) sample metadata, with a deep-dive into functional variant interpretation (synonymous vs nonsynonymous) via iVar `ANN`.
- Initially draft 5-6 recipe YAML stubs for screenshots; prune down during prose revision to whatever the text actually needs.
- Update `GLOSSARY.md` with new terms: GFF3, annotation track, synonymous, nonsynonymous, missense, consequence, sample metadata, iVar.
- Update `features.yaml` to add `import.reference`, `import.annotations`, `import.center`, `sample-metadata` feature entries. Remove the obsolete submenu entries.

### Non-goals

- **Bundling iVar** inside Lungfish. iVar is run externally, once, to produce the fixture VCF. Future plug-in architecture is out of scope.
- **New TSV variant importer.** iVar is invoked with `--output-format vcf` directly; no iVar-TSV code path needed.
- **Release-build script changes.** Reserved for the parallel `codex/portable-bundle…` worktree/branch.
- **Revising any chapter other than `04-variants/01-reading-a-vcf.md`.**
- **Adding BigBed to the Annotations section.** BigBed has its own path today; keeping the new section focused on line-oriented formats.
- **Shot capture + annotation compositing.** Deferred to PR 6 after the user rebuilds the app from `main`.

---

## 2. App-code changes (PR 2 and PR 3)

Three atomic tasks, grouped into two PRs so that the Annotations section and the FASTA bug fix land together (they touch overlapping eligibility logic and should share a single review).

### B1 — Remove File > Import submenu (PR 2)

**What:** Delete the entire `Import` submenu from the File menu. The existing `Import Center…` menu item (⇧⌘Y) stays and moves up in the File menu to occupy roughly where `Import` was.

**Why:** Two entry points for the same operation confuses users and the existing `File > Import > Files…` dialog bypasses the Import Center's curation (including the reference-eligibility logic that the Annotations section will rely on).

**Files to touch:**
- Whichever Swift source defines the File menu `CommandGroup` (found during Phase A).
- Any CLI or URL-handler code path that mentions the removed menu items (grep during Phase A).
- User-facing help strings referring to `File > Import`.

**Acceptance:**
- `File` menu shows `Import Center…` as a single entry with ⇧⌘Y.
- `git grep -i "file.*import.*files"` returns no matches in user-facing strings or code that routes to UI.
- Existing CLI import commands (`lungfish import vcf`, `lungfish import fasta`, etc.) unchanged.
- Unit/regression tests pass.

### B2 — Add Annotations section to Import Center (PR 3)

**What:** New Import Center section `AnnotationsSection` alongside existing References, Alignments, Variants, Reads, Metadata, Other.

**Behavior:**
- Section icon + label `Annotations`.
- File picker accepts `.gff`, `.gff3`, `.gtf`, `.bed` (not BigBed).
- Dropdown: "Attach to reference" lists every FASTA reference already in the project. If the project has no references, the dropdown is empty and a helper row shows "Import a reference first" with a button that switches to the References section.
- On import, the file is parsed via the existing GFF/GTF/BED ingestion code, and an annotation dataset is created bound to the chosen reference's identifier.

**Why:** Annotations are coordinate-anchored; without a reference in the project, an annotation file has no meaningful target. The UI must make this explicit. Importing without an anchor would leave orphan annotations the user can't view.

**Files to touch:**
- `Sources/LungfishApp/Views/ImportCenter/…` (exact files TBD in Phase A).
- Existing GFF/GTF/BED parser wiring (re-used, no new parsing).
- Import Center model/view-model plumbing for the new section.

**Acceptance:**
- Import Center shows Annotations section with file picker and reference dropdown.
- Manual test: import `annotations.gff3` from the fixture, annotation track renders against the reference.
- Regression test: import annotation with no reference in project → section is blocked with the helper row.

### B3 — Fix FASTA grey-out bug (PR 3)

**What:** Diagnose and fix the bug that makes `reference.fasta` appear greyed-out (ineligible) under Import Center → References on `main`.

**Why:** Import Center must be the single import door; if References silently refuses valid FASTA the user has no fallback.

**Diagnosis plan (Phase A):**
- Reproduce on `main` with the fixture's `reference.fasta`.
- Inspect the References section's eligibility predicate. Candidates: file extension allow-list that omits `.fasta` (only accepts `.fa`?), MIME check failing, symlink-resolution bug, size zero-check, text-encoding false negative.
- Read `Sources/LungfishApp/Views/ImportCenter/…` (Phase A deliverable names the exact file) and trace the predicate.

**Files to touch:** Exact files depend on root cause. Almost certainly one Swift file in `Sources/LungfishApp/Views/ImportCenter/`.

**Acceptance:**
- `reference.fasta` imports cleanly via Import Center → References.
- A new regression test file-asserts References accepts the fixture reference and a synthetic minimal FASTA with `.fa`, `.fasta`, `.fna`, `.ffn` extensions.

### Grouping rationale

B2 and B3 land together in PR 3 because:
- Both touch Import Center section eligibility/validation code.
- B3's fix may change assumptions B2 depends on (e.g. if the bug is in a shared predicate module).
- Splitting introduces a risk that PR 3 (Annotations-only) ships while FASTA still silently fails on `main`, so a user following the new chapter would hit the bug before the fix lands.

---

## 3. Fixture regeneration (PR 4)

One PR, five changes, all in `docs/user-manual/fixtures/sarscov2-clinical/`.

### C1 — Swap reference accession to NC_045512.2

- Pull `reference.fasta` via `efetch -db nucleotide -id NC_045512.2 -format fasta`.
- Sequence identical to MT192765.1 (both are the Wuhan-Hu-1 SARS-CoV-2 reference, 29,903 bp). Only the header changes from `>MT192765.1 …` to `>NC_045512.2 …`.
- Regenerate `reference.fasta.fai` via `samtools faidx reference.fasta`.

### C2 — Regenerate alignments.bam

- Re-align the existing `reads_R1.fastq.gz` + `reads_R2.fastq.gz` (unchanged, ~100 pairs) to the new NC_045512.2 reference.
- `bwa index reference.fasta && bwa mem reference.fasta reads_R1.fastq.gz reads_R2.fastq.gz | samtools sort -o alignments.bam && samtools index alignments.bam`.
- Output: `alignments.bam` + `.bai` with `@SQ  SN:NC_045512.2` header.

### C3 — Add annotations.gff3

- `efetch -db nucleotide -id NC_045512.2 -format gff3 > annotations.gff3`.
- Expected size ~60 KB; includes `CDS`, `mature_protein_region_of_CDS`, `five_prime_UTR`, `three_prime_UTR`, `gene` features.
- No editing; commit as-fetched so provenance is trivially verifiable.

### C4 — Re-call variants with iVar (run externally, once)

Run this command once on a machine with iVar installed. Commit only the outputs.

```
samtools mpileup \
  -aa -A -d 600000 -B -Q 20 -q 0 \
  -f reference.fasta \
  alignments.bam \
  | ivar variants \
      -p variants \
      -q 20 -t 0.0 -m 1 \
      -r reference.fasta \
      -g annotations.gff3 \
      --output-format vcf
bgzip -f variants.vcf
tabix -p vcf variants.vcf.gz
```

Outputs committed: `variants.vcf.gz` + `.tbi`. VCF `INFO` field carries iVar's `ANN=` with consequence, AA change, codon change, and gene/feature ID. At least one nonsynonymous record expected in the output (verified post-run).

### C5 — Update fetch.sh + README.md

**`fetch.sh`:** Becomes a provenance record, not an iVar runner. Content:
- `efetch` invocations to pull `reference.fasta` and `annotations.gff3` fresh (deterministic against NCBI).
- `bwa`/`samtools` invocations to regenerate `alignments.bam`.
- A commented block showing the iVar command (for provenance), with a note that the committed `variants.vcf.gz` was produced by running that command once against a specific iVar version.
- `ivar --version` output captured in the README.

**`README.md`:** Updated to:
- List the new accession (NC_045512.2).
- Explain that variants were called with iVar and the `ANN=` field carries functional annotations.
- Document the iVar version that produced the committed VCF.
- Note that `fetch.sh` regenerates the reference/GFF/BAM deterministically but does not re-run iVar.

### Acceptance
- `bash fetch.sh` re-derives `reference.fasta`, `annotations.gff3`, and `alignments.bam` byte-identically on a clean machine with `efetch`/`bwa`/`samtools` available.
- `variants.vcf.gz` header shows `##source=iVar` (or equivalent).
- `zcat variants.vcf.gz | grep -c '^[^#]' > 0` (non-zero record count).
- At least one record has `ANN=` containing a `missense` or `nonsynonymous` entry.

---

## 4. Chapter rewrite (PR 5)

One chapter, expanded from ~8 min to ~15 min reading time. The existing draft is superseded wholesale.

### Outline

1. **What it is** — VCF primer. Mostly unchanged; one paragraph added describing iVar's `ANN=` fields.
2. **Why this matters** — Unchanged.
3. **Procedure** — End-to-end Import Center flow:
   - 3.1 Open Import Center (⇧⌘Y or `File > Import Center…`).
   - 3.2 Import reference FASTA via References section.
   - 3.3 Import annotation track via Annotations section.
   - 3.4 Import variant VCF via Variants section.
   - 3.5 (Optional) Attach sample metadata — exact UX resolved in Phase A based on what Lungfish already supports.
4. **Interpreting what you see** — Expanded:
   - 4.1 Reading the table (REF/ALT/QUAL/FILTER/GT) — existing prose, updated for iVar's `PASS`/`FAIL` filter semantics.
   - 4.2 Functional impact via iVar `ANN` — synonymous vs nonsynonymous/missense, how iVar encodes the consequence string, how to read `ANN=ORF1ab|L2048P|missense_variant` (or the equivalent iVar syntax).
   - 4.3 Using sample metadata — attaching a CSV/TSV so the sample column in the VCF surfaces patient ID, Ct, collection date, etc.
5. **Next steps** — Unchanged.

### Frontmatter

```yaml
title: Reading a VCF file
chapter_id: 04-variants/01-reading-a-vcf
audience: bench-scientist
prereqs: []
estimated_reading_min: 15
shots:
  # Initial stub list; prune during prose revision.
  - id: import-center-empty
    caption: "Import Center with all sections visible, project empty."
  - id: import-reference
    caption: "References section with reference.fasta selected."
  - id: import-annotations
    caption: "Annotations section with annotations.gff3 picked and reference chosen."
  - id: import-vcf
    caption: "Variants section with variants.vcf.gz picked."
  - id: variant-table-with-consequences
    caption: "Loaded variant browser showing ANN consequence annotations."
  - id: sample-metadata-attached
    caption: "Variant browser with sample metadata columns populated."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency, GFF3, annotation-track, synonymous, nonsynonymous, missense, consequence, sample-metadata, iVar]
features_refs: [import.center, import.reference, import.annotations, import.vcf, viewport.variant-browser, sample-metadata]
fixtures_refs: [sarscov2-clinical]
brand_reviewed: false
lead_approved: false
```

### Shot pruning rule

Start the draft with all six recipe stubs. As the prose evolves, reassess each shot against this test: **Does removing this image degrade the reader's ability to follow the step?** If the answer is no, delete the shot stub and the `<!-- SHOT: … -->` marker. Target 3-5 final shots unless the prose genuinely needs more.

### Acceptance
- Chapter passes lint (no em dashes per `lungfish_docs_prose_rules.md`, bullet cap 5 items / 2 lists per H2).
- All `<!-- SHOT: … -->` markers correspond to existing recipe files.
- All recipes validate via `docs/user-manual/build/scripts/run-shot.sh plan`.
- GLOSSARY entries exist for every term in `glossary_refs`.
- features.yaml entries exist for every feature in `features_refs`.

---

## 5. Phase ordering and merges

Six PRs to `main`. Each PR is merged to `main` automatically by the executing agent (no human approval between PRs, per user direction). User rebuilds the release app from `main` between PR 4 and PR 6.

| PR  | Phase | Title | Content type | Merges when |
| --- | ----- | ----- | ------------ | ----------- |
| 1   | A     | Investigation notes (file paths, bug diagnoses, parser inventory) | Docs only | Notes committed, no code |
| 2   | B1    | Remove File > Import submenu | Swift code | Tests pass |
| 3   | B2+B3 | Import Center Annotations section + FASTA fix | Swift code | Tests pass |
| 4   | C     | Fixture regeneration (NC_045512.2, iVar VCF, GFF3) | Binary + scripts | Fixture integrity checks pass |
| 5   | D     | Chapter rewrite + recipe stubs + GLOSSARY + features.yaml | Docs | Lint green |
| 6   | E     | Shot capture + annotation compositing | PNGs | After user rebuilds release from `main` |

PR 6 has an explicit external gate: user rebuilds the app from `main` at the top of PR 6, then agent resumes by driving Computer Use against the rebuilt app.

### Ownership at each PR
- PRs 1-4: Agent drives with subagent-driven-development (implementer + spec-reviewer + code-quality-reviewer per task).
- PR 5: Agent dispatches the documentation-lead, bioinformatics-educator, code-cartographer, and brand-copy-editor sub-agents per the existing documentation-agent-team plan pattern.
- PR 6: Agent (via Computer Use) drives the rebuilt app to capture shots; composites annotations; commits PNGs.

---

## 6. Success criteria

At each phase boundary, a specific observable condition proves the phase is done.

**PR 1 — Investigation notes:** A notes file `docs/superpowers/notes/2026-04-15-ivar-annotations-import-center-investigation.md` lands on `main`. PR 1 contains no Swift code changes; it is docs only. It cites (a) the specific file + line number where the FASTA grey-out bug originates, (b) the exact Swift file where the File menu `CommandGroup` lives, (c) whether Lungfish's existing annotation ingestion handles GFF3/GTF/BED or needs new parsers (names the parser files if they exist, or flags that new parsers are required), (d) whether Lungfish has an existing sample-metadata-attachment UX for VCF samples (names the UI file if yes, or flags that the chapter's 3.5 needs to be re-scoped if no), (e) where the Import Center section list is defined so the Annotations section can be slotted in.

**PR 2 — Remove submenu:** `git grep -E "Import.*(VCF|BAM|Files|Variants)" Sources/` returns zero hits in user-facing menu code. ⇧⌘Y opens Import Center. No regression in CLI imports or URL-handler imports.

**PR 3 — Annotations + FASTA fix:**
- Manual walkthrough: import `reference.fasta` → it lands; import `annotations.gff3` → annotation track renders against reference.
- Regression test: References section accepts `.fasta`/`.fa`/`.fna`/`.ffn` extensions.
- Regression test: Annotations section requires a reference in the project and shows the helper row when none exists.

**PR 4 — Fixture:**
- `bash fetch.sh` re-derives `reference.fasta` + `annotations.gff3` + `alignments.bam` byte-identically.
- `zcat variants.vcf.gz | head -40 | grep -q iVar`.
- `zcat variants.vcf.gz | grep -cE "ANN=[^;]*(missense|nonsynonymous)" > 0`.

**PR 5 — Chapter:**
- `node docs/user-manual/build/scripts/manual_lint.mjs docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` exits 0.
- All recipes validate via `run-shot.sh plan`.
- GLOSSARY and features.yaml contain entries for everything the chapter references.

**PR 6 — Shots + publish:**
- All PNGs for the final pruned shot list exist in `docs/user-manual/assets/shots/04-variants/`.
- `mkdocs build` renders the chapter with no warnings or broken references.
- Brand Copy Editor passes; `brand_reviewed: true` set.
- Lead gate 2 approves; `lead_approved: true` set.

---

## 7. Open decisions (none)

All design decisions resolved with the user in brainstorming:

- iVar output: VCF via `--output-format vcf` (iVar 1.4+).
- Reference accession: NC_045512.2 (canonical RefSeq, matches standard GFF3).
- Chapter: one chapter, up to ~15 min reading, 5-6 initial recipe stubs with prune-during-prose rule.
- Branch: `claude/sad-morse`, merge per-PR to `main` automatically.
- BigBed: excluded from the new Annotations section.
- iVar bundling: out of scope.
- Release build: out of scope.

---

## 8. Risks and mitigations

**Risk:** FASTA grey-out bug root cause is in shared eligibility code used by multiple sections, so the fix might accidentally relax validation for other file types.
**Mitigation:** Phase A diagnosis cites the exact code path. PR 3 adds regression tests for every section (References, Alignments, Variants, Reads, Metadata) that touch the shared predicate, asserting they still reject obviously-wrong file types.

**Risk:** Lungfish's existing annotation ingestion does not handle GFF3 or GTF (only BigBed), requiring significant new parser code inside PR 3.
**Mitigation:** Phase A confirms the parser inventory before PR 3 scope is finalized. If new parsers are needed, they get their own sub-task within PR 3's subagent-driven-development loop.

**Risk:** The sample-metadata UX Lungfish already has is structured in a way that makes it awkward to teach in this chapter.
**Mitigation:** Phase A documents the exact UX. If it's awkward, the chapter's section 3.5 becomes a short "see X feature documentation" pointer instead of a full walkthrough, and we drop the `sample-metadata-attached` shot.

**Risk:** iVar's `ANN` encoding differs from SnpEff / VEP `ANN` — the chapter must teach iVar's specific format, not the more common SnpEff format.
**Mitigation:** Chapter prose explicitly calls out that iVar's `ANN` is a lighter-weight encoding and provides the exact field order. Chapter does not conflate iVar `ANN` with SnpEff `ANN`.

**Risk:** The release app rebuild between PR 4 and PR 6 fails, blocking shot capture indefinitely.
**Mitigation:** PR 6 prompt includes a build-verification step. If the rebuild fails, the agent halts PR 6 and reports the build error for the user to resolve.

**Risk:** Worktree collision with the parallel `codex/portable-bundle…` work on release-build scripts.
**Mitigation:** No PR in this plan touches `scripts/release/*` or CI. `git diff main...claude/sad-morse -- scripts/release/ .github/workflows/` must stay empty at every PR boundary.

---

## 9. Out-of-scope follow-ups

Captured for future planning rounds, not this work.

- Bundling iVar as a Lungfish plug-in (post-plug-in-architecture).
- Native iVar-TSV importer (only if users report friction with the VCF path).
- Adding BigBed / BigWig to the new Annotations section.
- Adding SnpEff / VEP post-processing for richer consequence annotations.
- Teaching variant calling (as opposed to reading a pre-called VCF) in a sibling chapter `04-variants/02-calling-variants.md`.

