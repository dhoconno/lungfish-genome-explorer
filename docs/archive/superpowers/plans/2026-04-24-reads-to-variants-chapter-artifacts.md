# "From Reads to Variants" Chapter Artifacts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Populate `/Users/dho/Downloads/Lungfish Docs.lungfish` with the exact artifacts the "From reads to variants" chapter will teach (SARS-CoV-2 reference from NCBI, ARTIC-style paired-end reads from SRA, primer-trimmed and un-trimmed BAMs, iVar and LoFreq VCFs), verify every step end-to-end against the shipped app, and capture prep notes that the chapter author will write against.

**Architecture:** Two phases separated by Spec 2's merge. Phase A runs immediately and covers the app-today subset of the workflow (download reference, download reads, map, LoFreq). Phase B runs after Spec 2 merges and adds primer-trim + iVar, then produces a cross-caller comparison. Phase B concludes by snapshotting the verified project into a version-controlled fixture location.

**Tech Stack:** The shipped Lungfish Genome Explorer app (Release build), NCBI Downloads, SRA import, minimap2, LoFreq, iVar, ripgrep. No code changes.

**Spec:** `docs/superpowers/specs/2026-04-24-reads-to-variants-chapter-artifacts-design.md`

---

## Preconditions

- Spec 1 has merged. Working copy is at `/Users/dho/Documents/lungfish-genome-explorer`.
- A shipped Release build exists at `build/Release/Lungfish.app` under the repo root.
- `/Users/dho/Downloads/Lungfish Docs.lungfish` project exists (empty: `Downloads/`, `Imports/`, `Reference Sequences/`, `Analyses/`).
- An internet connection capable of reaching NCBI and SRA.

---

## Worktree smoke-test gate (Phase A step 0)

The user reports that the worktree/JRE-dylib restriction is fixed. Verify before committing to a worktree.

- [ ] **Step 1: Create the Track 2 worktree**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
git worktree add .worktrees/track2-docs-artifacts -b track2-docs-artifacts main
```

- [ ] **Step 2: Verify the Release app launches from outside the worktree** (the app is always launched from its installed path, so this is a one-time check)

```bash
open build/Release/Lungfish.app
```
Expected: the app launches and shows the Welcome screen within ~3 seconds.

- [ ] **Step 3: Confirm a Java-backed tool invocation works**

The Java-backed tools are BBTools. If the chapter workflow does not invoke any Java-backed tool, this is technically optional; skip if so. If the chapter does invoke one (e.g., Clumpify for dedup) add a verification step that runs it through the app and confirms success.

No commit for this gate; it's verification only.

---

## Phase A

Phase A uses only features that exist today. Runs immediately.

---

## Task A1: Download the SARS-CoV-2 reference in-app

**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Downloads/MN908947.3.lungfishref/`
**Prep notes section:** "A1 — Reference download"

- [ ] **Step 1: Launch the app against the docs project**

```bash
open "/Users/dho/Downloads/Lungfish Docs.lungfish"
```
Expected: the app opens the project. If double-click-to-open isn't wired, use File → Open Project and pick the folder.

- [ ] **Step 2: Download `MN908947.3`**

Menu: File → Download from NCBI → Genome (or whatever menu path the UI exposes today; record the exact path in prep notes).

Enter accession: `MN908947.3`.

Wait for download to complete.

- [ ] **Step 3: Verify the artifact**

```bash
ls "/Users/dho/Downloads/Lungfish Docs.lungfish/Downloads/MN908947.3.lungfishref/"
```
Expected: a `manifest.json`, a FASTA file, and any supporting files the bundle format defines.

- [ ] **Step 4: Record observations in prep notes**

Create `/Users/dho/Downloads/Lungfish Docs.lungfish/TRACK2-PREP-NOTES.md` with this first entry:

```markdown
# Track 2 Prep Notes

App version: <record from "About Lungfish Genome Explorer">
Start date: 2026-04-24

## A1 — Reference download

- Exact menu path taken: File → …
- Accession entered: MN908947.3
- Time from submit to bundle visible in sidebar: <record>
- Accession form persisted: <MN908947.3 | NC_045512.2 | both>
- Bundle display name in sidebar: <record>
- Any alerts, confirmation dialogs, surprises: <record>
```

- [ ] **Step 5: Do not commit the project folder to the worktree; commit only the notes template**

Since the project lives in `~/Downloads/`, prep notes will be committed to the worktree as a tracking document, not the project itself. Copy the notes into the worktree under `docs/user-manual/fixtures/prep-notes/track2-phase-a-prep-notes.md` (keep it in sync with the in-project copy via a manual sync at phase ends).

```bash
mkdir -p /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts/docs/user-manual/fixtures/prep-notes
cp "/Users/dho/Downloads/Lungfish Docs.lungfish/TRACK2-PREP-NOTES.md" \
   /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts/docs/user-manual/fixtures/prep-notes/track2-phase-a-prep-notes.md
```

No git commit yet; wait until the phase ends.

---

## Task A2: Download the SRA reads in-app

**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Downloads/SRR36291587.lungfishfastq/`
**Prep notes section:** "A2 — SRA reads download"

- [ ] **Step 1: Open SRA search/import in the app**

Menu: File → Import from SRA (or whatever the exact path is; record in notes).

- [ ] **Step 2: Search or enter accession**

Accession: `SRR36291587`.

- [ ] **Step 3: Download**

Confirm paired-end download. Wait for completion. This is ~22 MB on the wire but may expand significantly on disk.

- [ ] **Step 4: Verify read count**

In the app, open the resulting `.lungfishfastq` bundle's Inspector. Confirm read count = 85,199 pairs. If the count differs, record the discrepancy and proceed.

- [ ] **Step 5: Record observations**

Append to `TRACK2-PREP-NOTES.md`:

```markdown
## A2 — SRA reads download

- Exact UI flow: File → …
- Accession entered: SRR36291587
- Download time (start to finish, approximate): <record>
- Final on-disk size: <record with `du -sh`>
- Paired-end detected: <yes/no>
- Read pair count per Inspector: 85,199 (expected)
- Any caching behavior noted: <record>
```

---

## Task A3: Map reads to reference with minimap2

**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/SRR36291587.minimap2.lungfishmapping/` (exact naming may differ; record the app's actual output directory name in prep notes)
**Prep notes section:** "A3 — Mapping"

- [ ] **Step 1: Open the Mapping wizard**

From the SRR36291587 FASTQ bundle's Inspector, find the operation that maps reads to a reference and open its wizard. Record the exact control path.

- [ ] **Step 2: Configure**

- Reads: `SRR36291587` (pre-selected).
- Reference: `MN908947.3` from Downloads.
- Mapper: minimap2.
- Preset: the one appropriate to Illumina short reads. If the wizard default is not obviously the Illumina preset, explicitly select `sr` or the GUI-named equivalent. If the default is `sr` already, note that.

- [ ] **Step 3: Run and wait**

- [ ] **Step 4: Verify output**

- Output bundle appears under `Analyses/` (or wherever the app places it).
- BAM is coordinate-sorted and indexed. Verify at a shell:

```bash
BAM="/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/SRR36291587.minimap2.lungfishmapping/<bam-file>"
samtools view -H "$BAM" | head -2    # Expect @HD … SO:coordinate and @SQ SN:MN908947.3
samtools index "$BAM"                # Should succeed even if already indexed; if already indexed, this is a no-op
samtools idxstats "$BAM"             # Expect mapped-reads count for MN908947.3
```

- Coverage sanity check at three positions (5', middle, 3' of the 29,903 bp genome):

```bash
samtools depth -a -r "MN908947.3:100-100" "$BAM"
samtools depth -a -r "MN908947.3:15000-15000" "$BAM"
samtools depth -a -r "MN908947.3:29800-29800" "$BAM"
```

Record the three depths in prep notes. They should all be > 0 for an ARTIC-like amplicon panel; amplicon gaps may produce zeros at primer-binding sites, which is normal.

- [ ] **Step 5: Record observations**

Append to `TRACK2-PREP-NOTES.md`:

```markdown
## A3 — Mapping

- Mapping wizard control path: <record>
- Mapper selected: minimap2
- Preset selected: <record>
- Runtime (start to finish): <record>
- Output bundle path: <record>
- Sort order per @HD header: <coordinate | unknown>
- @SQ SN: MN908947.3
- idxstats mapped read count: <record>
- Depth at pos 100: <record>
- Depth at pos 15000: <record>
- Depth at pos 29800: <record>
- Any errors, warnings, or progress-stall surprises: <record>
```

---

## Task A4: Call variants with LoFreq

**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/SRR36291587.lofreq.lungfishvariants/`
**Prep notes section:** "A4 — LoFreq variant calling"

- [ ] **Step 1: Open Variant Calling from the mapped BAM bundle's Inspector**

Click "Call Variants…" in the Analysis section.

- [ ] **Step 2: Configure**

- Caller: LoFreq (default, per current dialog state).
- Other options: defaults.

- [ ] **Step 3: Run and wait**

- [ ] **Step 4: Verify output**

```bash
VCF="/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/SRR36291587.lofreq.lungfishvariants/<vcf-file>"
bcftools stats "$VCF" | grep "^SN" | head -20
```
Record key stats: number of SNPs, number of indels, ts/tv ratio if reported. Open the VCF in the variant browser in-app and confirm it renders without errors.

- [ ] **Step 5: Record observations**

Append to `TRACK2-PREP-NOTES.md`:

```markdown
## A4 — LoFreq variant calling

- Caller: LoFreq
- Runtime: <record>
- Output path: <record>
- Variants called: <count>
- Variant browser opens VCF: <yes/no, any errors>
- Provenance chain reads → BAM → VCF intact: <yes/no, what is shown>
```

---

## Task A5: Commit Phase A prep notes

- [ ] **Step 1: Sync notes into the worktree**

```bash
cp "/Users/dho/Downloads/Lungfish Docs.lungfish/TRACK2-PREP-NOTES.md" \
   /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts/docs/user-manual/fixtures/prep-notes/track2-phase-a-prep-notes.md
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts
git add docs/user-manual/fixtures/prep-notes/track2-phase-a-prep-notes.md
git commit -m "$(cat <<'EOF'
docs: Track 2 Phase A prep notes — reference, reads, mapping, LoFreq

Captures observations from running the pre-Spec-2 subset of the reads-to-variants workflow against the shipped app: NCBI reference download, SRA reads download, minimap2 mapping, and LoFreq variant calling. Exact UI paths, timings, and coverage spot-checks recorded for the chapter author.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase A "Done" checklist

- [ ] `Downloads/MN908947.3.lungfishref/` exists and opens in the app.
- [ ] `Downloads/SRR36291587.lungfishfastq/` exists, Inspector shows 85,199 read pairs.
- [ ] `Analyses/<mapping output>/` exists, BAM is sorted and indexed, depth > 0 at three sample positions.
- [ ] `Analyses/<lofreq output>/` exists, VCF opens in the variant browser.
- [ ] Prep notes committed to the worktree.

---

## Phase B (blocks on Spec 2 merging)

Phase B runs after Spec 2's PR lands on `main`. At that point, the canonical `QIASeqDIRECT-SARS2.lungfishprimers` ships built-in, the BAM primer-trim operation is available, and the auto-confirm behavior in the variant calling dialog is live.

Before Phase B begins, the worktree must rebase on the latest `main`:

```bash
cd /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts
git fetch origin
git rebase origin/main
```

If the Release build is stale (produced before Spec 2 merged), a rebuild happens first:

```bash
cd /Users/dho/Documents/lungfish-genome-explorer
bash scripts/release/build-notarized-dmg.sh    # or whichever release build path is canonical
```

(If that script isn't appropriate for this in-development verification, the implementer uses `swift build -c release` and locates the binary from the build output.)

---

## Task B1: Select and run primer trim using the built-in QIASeq bundle

**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Primer Schemes/QIASeqDIRECT-SARS2.lungfishprimers/` (via app's built-in → project copy mechanism)
**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<primer-trim output>/`
**Prep notes section:** "B1 — Primer trim"

- [ ] **Step 1: From the mapped BAM bundle's Inspector, click "Primer-trim BAM…"**

- [ ] **Step 2: In the picker, select `QIASeq Direct SARS-CoV-2` from the Built-in section**

Record: does the app copy the bundle into `Primer Schemes/` at selection time or run against the built-in in place? Record in notes.

- [ ] **Step 3: Accept default advanced options; click Run**

- [ ] **Step 4: Verify output**

```bash
TRIMMED="/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<primer-trim output>/<trimmed-bam>"
samtools view -H "$TRIMMED" | head -2          # coordinate-sorted
samtools view -c "$TRIMMED"                    # read count (expect lower than un-trimmed because primer-overlap reads are soft-clipped or trimmed)

# Provenance sidecar
cat "/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<primer-trim output>/<provenance>.json" | python3 -m json.tool
```

Expected provenance content: `{"operation": "primer-trim", "primer_scheme": {"bundle_name": "QIASeqDIRECT-SARS2", ...}, "source_bam": "…", "ivar_version": "…", "ivar_trim_args": [...], "timestamp": "..."}`.

- [ ] **Step 5: Record observations**

```markdown
## B1 — Primer trim

- App version (rebuilt post-Spec-2-merge): <record>
- Bundle selected: QIASeq Direct SARS-CoV-2 (Built-in)
- Bundle copy-on-select behavior: <copied into Primer Schemes/ | referenced in place | other>
- Runtime: <record>
- Output path: <record>
- Read count pre-trim: <from A3>
- Read count post-trim: <record>
- Provenance contents: <paste JSON>
```

---

## Task B2: Call variants with iVar and observe auto-confirm

**Artifact:** `/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<ivar output>/`
**Prep notes section:** "B2 — iVar variant calling"

- [ ] **Step 1: From the trimmed BAM bundle's Inspector, click "Call Variants…"**

- [ ] **Step 2: Select iVar in the caller picker**

Observe: the primer-trim attestation checkbox is auto-checked, disabled, and carries a caption like "Primer-trimmed by Lungfish on 2026-04-24 using QIASeqDIRECT-SARS2." Record the exact caption text.

- [ ] **Step 3: Accept defaults; click Run**

- [ ] **Step 4: Verify output**

```bash
IVAR_VCF="/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<ivar output>/<vcf>"
bcftools stats "$IVAR_VCF" | grep "^SN" | head -20
```

- [ ] **Step 5: Record observations**

```markdown
## B2 — iVar variant calling

- Auto-confirm checkbox state: checked + disabled + caption present: <exact caption>
- Runtime: <record>
- Output path: <record>
- Variants called: <count>
- Variant browser opens VCF: <yes/no>
```

---

## Task B3: Compare the two VCFs side-by-side

**Prep notes section:** "B3 — Cross-caller comparison"

- [ ] **Step 1: Open both LoFreq (from A4) and iVar (from B2) VCFs in the variant browser over the same reference**

- [ ] **Step 2: Count concordant, LoFreq-exclusive, iVar-exclusive sites**

A shell-level comparison is the easiest ground truth:

```bash
LOFREQ="/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<lofreq output>/<vcf>"
IVAR="/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<ivar output>/<vcf>"

bcftools isec -p /tmp/isec "$LOFREQ" "$IVAR"
# Produces:
#   /tmp/isec/0000.vcf - LoFreq only
#   /tmp/isec/0001.vcf - iVar only
#   /tmp/isec/0002.vcf - concordant (LoFreq record), 0003.vcf - concordant (iVar record)

bcftools view -H /tmp/isec/0000.vcf | wc -l    # LoFreq-exclusive
bcftools view -H /tmp/isec/0001.vcf | wc -l    # iVar-exclusive
bcftools view -H /tmp/isec/0002.vcf | wc -l    # concordant
```

- [ ] **Step 3: Inspect a small sample of exclusive sites and write the "why" interpretation**

Pick one LoFreq-exclusive site and one iVar-exclusive site. For each, note: position, alleles, AF, DP, and what about each caller's defaults most plausibly explains the discrepancy (e.g., "iVar's default min-AF is 0.03; this site has AF=0.01, below iVar's threshold but above LoFreq's").

- [ ] **Step 4: Record observations**

```markdown
## B3 — Cross-caller comparison

- Concordant sites: <N>
- LoFreq-exclusive: <N>
- iVar-exclusive: <N>
- Example LoFreq-exclusive site: <POS> <REF>→<ALT>, AF=<>, DP=<>, likely reason: <>
- Example iVar-exclusive site: <POS> <REF>→<ALT>, AF=<>, DP=<>, likely reason: <>
- One-paragraph "teaching summary" the chapter can draw from: <record>
```

---

## Task B4: Snapshot the project into the repo

**Artifact:** `docs/user-manual/fixtures/reads-to-variants-project/`

The project currently lives in `~/Downloads/`. We copy it into a repo-tracked fixture location so the chapter and the Screenshot Scout can work from a stable, committed state.

- [ ] **Step 1: Decide what to commit vs. regenerate**

Per Spec 3 §7, the recommendation is: commit the reference bundle and both VCFs (all small), but script the reads download + mapping so a fresh checkout regenerates them.

- Reference bundle: ~100 KB → commit.
- LoFreq VCF: ~10 KB → commit.
- iVar VCF: ~10 KB → commit.
- Trimmed BAM: ~5–50 MB → commit only if the repo's Git LFS is already configured; otherwise, regenerate via a short script.
- Un-trimmed BAM: same question as trimmed.
- Reads FASTQ bundle: 22 MB compressed on disk → regenerate via script.
- Primer scheme bundle: already in `Sources/LungfishApp/Resources/PrimerSchemes/` (shipped with the app). Do not duplicate into the fixture.

Decide by inspecting `.gitattributes` for Git LFS:

```bash
cat /Users/dho/Documents/lungfish-genome-explorer/.gitattributes 2>/dev/null
```

If LFS is not configured, commit only the small files.

- [ ] **Step 2: Create the fixture directory and copy small files**

```bash
FIX=/Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts/docs/user-manual/fixtures/reads-to-variants-project
mkdir -p "$FIX/Downloads" "$FIX/Analyses"
cp -R "/Users/dho/Downloads/Lungfish Docs.lungfish/Downloads/MN908947.3.lungfishref" "$FIX/Downloads/"
cp -R "/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<lofreq output>" "$FIX/Analyses/"
cp -R "/Users/dho/Downloads/Lungfish Docs.lungfish/Analyses/<ivar output>" "$FIX/Analyses/"
```

- [ ] **Step 3: Author a regeneration script**

Create `$FIX/regenerate.sh`:

```bash
#!/bin/bash
# Regenerates the large artifacts (reads, BAMs) that aren't committed.
# Requires the shipped Release app installed and reachable on disk.

set -euo pipefail

APP="/Applications/Lungfish Genome Explorer.app"   # adjust if installed elsewhere
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Project: $PROJECT"
echo "App: $APP"
echo ""
echo "This script is a placeholder. Full automation of the Mapping wizard from the CLI requires the app's CLI surface (lungfish-cli)."
echo "Manual steps to regenerate:"
echo "  1. Open the project in the Lungfish Genome Explorer."
echo "  2. File → Import from SRA, enter SRR36291587, download."
echo "  3. From the reads bundle Inspector, Map → minimap2 → reference MN908947.3."
echo "  4. From the mapped BAM bundle, Primer-trim BAM → QIASeq Direct SARS-CoV-2 (Built-in)."
echo "  5. From each BAM, Call Variants → LoFreq (un-trimmed) and iVar (trimmed)."
```

If `lungfish-cli` already exposes these operations non-interactively, replace the manual steps with actual CLI invocations. Investigate:

```bash
lungfish-cli --help
```

If it does expose them, author full automation here. If not, the manual prose is acceptable for this spec.

- [ ] **Step 4: Commit the snapshot**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts
git add docs/user-manual/fixtures/reads-to-variants-project
git commit -m "docs(fixtures): snapshot reads-to-variants project state

Commits the reference bundle and both VCFs as small stable fixtures; includes a regenerate.sh describing how to rebuild the BAMs and reads bundle against a fresh checkout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task B5: Commit Phase B prep notes

- [ ] **Step 1: Sync notes into the worktree**

```bash
cp "/Users/dho/Downloads/Lungfish Docs.lungfish/TRACK2-PREP-NOTES.md" \
   /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts/docs/user-manual/fixtures/prep-notes/track2-phase-b-prep-notes.md
```

Rename the Phase A notes file if Phase B adds content on top of Phase A; the cleanest pattern is one combined file:

```bash
cp "/Users/dho/Downloads/Lungfish Docs.lungfish/TRACK2-PREP-NOTES.md" \
   /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts/docs/user-manual/fixtures/prep-notes/track2-prep-notes.md
git rm docs/user-manual/fixtures/prep-notes/track2-phase-a-prep-notes.md  # if Phase A's filename differs
```

- [ ] **Step 2: Commit**

```bash
git add docs/user-manual/fixtures/prep-notes
git commit -m "docs: Track 2 Phase B prep notes — primer-trim, iVar, caller comparison

Extends Phase A notes with observations from primer-trimming the BAM, calling variants with iVar, and comparing iVar and LoFreq VCFs. Includes the teaching summary the chapter author can draw from for the cross-caller interpretation section.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task B6: Push and open PR

- [ ] **Step 1: Push the branch**

```bash
cd /Users/dho/Documents/lungfish-genome-explorer/.worktrees/track2-docs-artifacts
git push -u origin track2-docs-artifacts
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "docs(fixtures): From reads to variants — prep artifacts and notes" --body "$(cat <<'EOF'
## Summary

- Commits the "From reads to variants" chapter's stable fixtures (reference bundle, LoFreq VCF, iVar VCF) under `docs/user-manual/fixtures/reads-to-variants-project/`.
- Commits prep notes (`track2-prep-notes.md`) covering exact UI paths, timings, and cross-caller comparison observations from running the workflow end-to-end against the shipped app.
- Includes a regenerate script documenting how to rebuild the larger artifacts (reads FASTQ, BAMs) from a fresh checkout.

Spec: `docs/superpowers/specs/2026-04-24-reads-to-variants-chapter-artifacts-design.md`

## Test plan

- [ ] Fixture directory renders correctly in a fresh clone.
- [ ] Regeneration script (or manual steps) produces the full project from the fixture + SRA + the shipped app.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## "Done" criteria

### Phase A

- [ ] Downloads (reference, reads), mapping, and LoFreq VCF all exist in the user's docs project.
- [ ] Prep notes (Phase A) committed to the worktree.

### Phase B

- [ ] Primer-trimmed BAM exists; its provenance sidecar carries the expected fields.
- [ ] iVar VCF exists; variant calling dialog auto-confirmed the primer-trim attestation with the expected caption.
- [ ] Cross-caller comparison notes recorded, including a teaching summary for the chapter.
- [ ] Project snapshot committed to `docs/user-manual/fixtures/reads-to-variants-project/` with a regeneration script.
- [ ] Prep notes (Phase B) committed.
- [ ] PR exists on GitHub titled `docs(fixtures): From reads to variants — prep artifacts and notes`.
