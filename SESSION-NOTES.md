# Session notes — docs/user-manual-resume

Branch: `docs/user-manual-resume`. Worktree:
`.worktrees/docs-user-manual-resume`.

## Sessions

- **2026-04-25 evening**: gate-1 + body + brand pass for both chapters
  using agents (no GUI driving). Recipes authored against assumed flow.
- **2026-04-25 night → 2026-04-26 morning**: GUI capture session driving
  Lungfish.app via Computer Use against the actual SARS-CoV-2 fixture.
  Found that the chapters' assumed flow did not match the shipped UI in
  several places. Procedures rewritten in place against what the UI
  actually does.

## What landed (committable)

- `docs/user-manual/chapters/04-variants/01-reading-a-vcf.md` body, with
  rewritten Procedure that matches the shipped UI: New Project → Import
  Center → Reference Sequences → Import Center → Variants → click the
  variants entry → click `Variants` tab → clear the `PASS` filter chip
  to reveal the nine `LowQual` rows. Lint green.
- `docs/user-manual/chapters/04-variants/02-calling-variants-from-a-bam.md`
  body, with step 1 rewritten to use Import Center for the BAM (after
  selecting the reference, since BAM import requires an active
  reference bundle) and step 4 corrected to point at the Inspector's
  `Duplicate Handling` section where `Call Variants…` actually lives.
  Lint green.
- `docs/user-manual/reviews/04-variants/2026-04-25-lead-gate1-calling-variants.md`
  gate-1 review.
- `docs/user-manual/GLOSSARY.md` four new entries: `amplicon`,
  `primer-scheme`, `primer-trim`, `variant-caller`.
- `docs/user-manual/features.yaml` two new ids: `variants.call`,
  `bam.primer-trim`.
- `docs/user-manual/assets/recipes/04-variants/` five recipes (two from
  chapter 01, three from chapter 02). All plan-validate against
  `schema.json`. Recipes do **not** yet reflect the procedure rewrite;
  they need updating once the primer-trim UI blocker is resolved.

## What was captured visually but not persisted to disk

The Computer Use MCP returned screenshot images inline in the
conversation transcript but `save_to_disk: true` did not surface a
file path to write to, and `screencapture` from Bash is TCC-blocked
in this harness. The following five chapter shots have visual
evidence in the transcript but no PNGs landed under
`docs/user-manual/assets/screenshots/04-variants/`:

1. **vcf-open-dialog** — Import Center → Variants → Import dialog
   filtered to VCF files, with the fixture file list visible.
2. **vcf-variant-table** — full window with the variant browser,
   `PASS` filter cleared, nine `LowQual` rows visible
   (`MT192765_1_197`, `_4788`, `_8236`, `_10506` indel, `_11837`,
   plus four more).
3. **variant-call-dialog (pre-trim)** — `CALL VARIANTS` dialog with
   iVar tab selected, "This BAM has already been primer-trimmed
   for iVar." toggle visible, unchecked and enabled, Run button
   greyed out, Readiness reads "Confirm the BAM was primer-trimmed
   before running iVar."
4. **primer-trim-dialog** — NOT captured. See blocker below.
5. **variant-table-fresh-call** — NOT captured. Depends on running
   primer trim first.

## Open blockers, in priority order

### 1. Primer-trim BAM button is not reachable in the shipped UI

The cartographer verified `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift:2209`
defines a `Button("Primer-trim BAM…")` inside an `AnalysisSection`
gated by an `AnalysisWorkflowSubsection` selector with cases
`.filtering | .annotations | .consensus | .primerTrim | .variantCalling | .export`.
That `AnalysisSection` is hosted on an `analysis` Inspector tab
(icon `arrow.triangle.branch`), one of five tabs the source defines
(`bundle | selectedItem | view | analysis | ai`).

In the running build (`build/Debug/Lungfish.app`, two consecutive
rebuilds tested: 19:29 on 2026-04-25 and 10:14 on 2026-04-26) the
Inspector renders only **three** tab icons:

- 📄 shippingbox = bundle
- ☞ scope = selectedItem
- ✨ sparkles = ai

The `view` (eye) and `analysis` (arrow.triangle.branch) tabs are
absent from the rendered segmented control, even though their
strings (`"Analysis"`, `"Variant Calling"`, `"Primer Trim"`) appear
in `strings build/Debug/Lungfish.app/Contents/MacOS/Lungfish`.

The visible Inspector for an alignment-loaded reference shows
`Selection | Sequence Style | Annotation Style | Sample Display |
Alignment Summary | Read Display | Read Filters | Show Bases as Dots
…| Consensus | Duplicate Handling | Forward / Reverse | Read Groups |
Flag Statistics | Processing Pipeline | Import Provenance`. The
`Duplicate Handling` section has `Call Variants… | Mark Duplicates
in Bundle Tracks | Create Deduplicated Bundle`, but no
`Primer-trim BAM…`.

Two independent fixes either of which unblocks the chapter:

- **A**: Restore the `view` and `analysis` Inspector tab rendering so
  the existing `AnalysisSection` becomes reachable. Investigate
  `InspectorTabGrid` in `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift:2780`
  and `availableTabs` at line 2548.
- **B**: Lift `Primer-trim BAM…` out of `AnalysisSection` and add it
  to the visible `Duplicate Handling` section next to `Call
  Variants…`. The two are conceptually paired anyway and the
  chapter procedure already treats them as a sequence in the same
  Inspector view.

### 2. BAM import requires an active reference bundle

When `File > Import Center… > Alignments > Import…` runs without
the reference selected in the sidebar (and thus without it loaded
into the middle pane), the import fails with a modal error:
"No Bundle Loaded — Please open a reference genome bundle before
importing alignments." Chapter 02 step 1 now documents this
explicitly. If the team prefers a different UX (auto-select the
reference, or show a picker in the import dialog when no reference
is active), the procedure should be revised accordingly.

### 3. PASS filter hides the entire fixture variant table

Variant table rows are filtered by the `Quality / QC: PASS` chip
which is enabled by default. Every record in the
`sarscov2-clinical` fixture carries `FILTER=LowQual`, so the table
shows zero rows on first load and only reveals the nine fixture
variants after the user clicks the `PASS` chip to deselect it.
Chapter 01 step 5 now documents this. For production data the
default is correct, but for the pilot fixture it surfaces a
discoverability issue worth noting.

### 4. Reference accession behaviour during VCF import

The fixture's `reference.fasta` is `MT192765.1` (GenBank clinical
isolate). When `File > Import Center… > Variants` imports the
fixture's `variants.vcf.gz`, Lungfish creates a self-contained
variant bundle whose internal reference is `NC_045512.2` (RefSeq
Wuhan-Hu-1). The two accessions describe sequences that are
functionally identical, with 1:1 coordinates, but Lungfish treats
them as separate chromosomes. The variant table's `Chrom` column
correctly shows `MT192765.1` for the rows themselves, but the
genome track view at the top of the variant browser shows
`NC_045512.2` annotations and reports "no variants in this region"
because the chromosome name check is strict.

The chapter does not currently address this. Three options for the
team to consider:

- **A**: When importing a VCF whose `##contig` lines reference an
  accession already present in the project's references, point the
  variant bundle at the existing reference rather than a fresh
  RefSeq lookup. This avoids the duplicate-reference state.
- **B**: Auto-resolve known SARS-CoV-2 accession aliases
  (`MT192765.1` ↔ `NC_045512.2` are byte-identical sequences) so
  the genome view and the variant table agree.
- **C**: Document the dual-reference state in chapter 01 with a
  short note explaining why the genome view says "no variants in
  this region" while the variant table shows nine rows. Lower lift,
  but exposes a UX wart in the pilot chapter.

### 5. Default Folder X overlay intercepts clicks in NSOpenPanel

Default Folder X (a Finder enhancer) augments macOS save/open
dialogs with its own UI. During this session, several clicks inside
the New Project save panel and the Import Center file pickers were
rejected by Computer Use's tier check because they would have
landed on Default Folder X's overlay rather than on Lungfish's
NSOpenPanel. Workaround used: `cmd+shift+G` to type the path
directly, then `Return` twice. Not a bug in Lungfish, but worth
flagging for anyone re-running the screenshot capture procedure.

### 6. Screenshot persistence

The Computer Use MCP screenshot tool's `save_to_disk: true` flag
returned no path in the tool result during this session. The MCP
log shows the call completing in ~200 ms with no payload. Bash's
`screencapture` is TCC-blocked from this harness ("could not create
image from display"), so I could not work around the issue from
inside the conversation. Resolution will be needed before a
fully-automated capture session can land PNGs under
`docs/user-manual/assets/screenshots/04-variants/`.

## Suggested resume order

1. Decide between blocker-1 fix A or B and ship it. Either is
   small.
2. Decide blocker-4 disposition (A, B, or C) and make the matching
   chapter or code change.
3. Re-run the capture session from a state where Inspector exposes
   the primer-trim button. Capture all five shots, persist as PNGs
   (resolve blocker-6 first), update the recipes to match the
   actual click coordinates and crop regions.
4. Run brand pass + documentation-lead gate-2 on both chapters.

## Open agent threads (resumable)

- documentation-lead (chapter 02 gate-1): `a505dab5c0dab6e46`
- code-cartographer: `addebf217965242cc`
- bioinformatics-educator (chapter 02 body): `a4d854ef6a1857071`
- screenshot-scout (chapter 02 recipes): `a8cf4615e085f8342`
- brand-copy-editor (chapter 01): `a3082647ba717f5ea`
- brand-copy-editor (chapter 02): `a65599f0ec24ac81c`
