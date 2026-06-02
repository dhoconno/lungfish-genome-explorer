# Illustrations / graphics spec: Part II+ user manual (2026-06-02)

This spec proposes the schematic conceptual cartoons the revised Part II+
chapters need. These are hand-made or image-gen diagrams, not app screenshots.
Screenshots are tracked separately through the chapter `planned_shots[]`
front-matter and the shots pipeline; nothing in this spec is a screenshot.

Everything here is grounded in the revised chapters and the ground-truth
reality maps under `reviews/part-ii-fidelity-2026-06-02/ground-truth/`, so any
diagram that depicts app behaviour is factually accurate (primer trim
soft-clips, the real five-caller roster, the NVD assemble-then-BLAST concept,
and the FASTQ-preprocessing-scoped Workflow Builder).

## How to use this spec

The proposed illustrations are schematic cartoons in the fixed brand palette,
to be added to `docs/user-manual/illustrations.yaml` as new entries using the
same schema as the existing ones, then rendered to
`assets/illustrations-imagegen/<chapter-id>/<id>.{svg,png}`.

- **Schema.** Each entry has `id`, `target_dimensions`, `asset` (the rendered
  PNG path), `source` (the editable SVG path), and a `brief`. Use the existing
  entry `06-classification/01-what-is-classification` -> `classification-question`
  in `illustrations.yaml` as the format example to copy. The ready-to-paste
  block at the end of this spec already follows it exactly.
- **Palette only.** Lungfish Creamsicle `#EE8B4F`, Peach `#F6B088`, Deep Ink
  `#1F1A17` (primary text and strokes, never pure black), Cream `#FAF4EA` (page
  and panel backgrounds, never pure white), Warm Grey `#8A847A` (captions and
  metadata). No other colours. The classification-tool tints used elsewhere in
  the UI (Kraken2 blue, EsViritu green, TaxTriage purple) are app-chrome colours
  and must NOT appear in these palette-only cartoons; distinguish tools by label
  and shape instead.
- **Severity and emphasis.** Never encode "good versus bad" or "high versus low"
  with red-amber-green. Per `STYLE.md`, encode emphasis with Deep Ink stroke
  weight and an explicit text annotation. Where a diagram contrasts an expected
  case against a flagged case (a clean BLAST hit versus a divergent one, a
  passing edge versus a rejected one), the flagged item gets a heavier Deep Ink
  outline and a one-line Warm Grey caption, not a colour.
- **Typography in the SVG.** Headings/labels in Space Grotesk, body/caption in
  Inter, any sequence or code token (bases, accessions, CIGAR, thresholds) in
  IBM Plex Mono. These are the only faces permitted in an embedded SVG.
- **Wiring into a chapter.** After rendering, the chapter embeds the PNG with a
  Markdown image and descriptive alt text (see how
  `06-classification/01-what-is-classification.md` line 36 and
  `07-assembly/01-when-to-assemble.md` line 38 embed theirs), and adds the slim
  `id` + `brief` pair to the chapter front-matter `illustrations[]` list. Do not
  add a `<!-- SHOT: -->` marker; these are illustrations, not shots.

## Already covered

These existing `illustrations.yaml` entries already serve Part II+ concepts. Do
not redo them. The proposals below were chosen specifically because they do NOT
duplicate these.

| Entry (chapter -> id) | What it already shows |
|---|---|
| `01-foundations/03-amplicon-vs-shotgun` -> `amplicon-vs-shotgun` | Shotgun scatter versus tiled overlapping amplicons. Covers the amplicon coverage-profile concept. |
| `01-foundations/03-amplicon-vs-shotgun` -> `primer-scheme-diagram` | ARTIC-style forward/reverse primers and overlapping amplicon bands. |
| `01-foundations/03-amplicon-vs-shotgun` -> `primer-trim-soft-clip` | Before/after primer trim with primer bases retained but soft-clipped (correctly soft, not hard). |
| `01-foundations/02-sequencing-reads` -> `platform-read-length-comparison` | Illumina vs PacBio HiFi vs Nanopore read lengths. Covers the ONT-vs-Illumina length contrast. |
| `01-foundations/04-alignment-files` -> `read-mapping-cartoon`, `coverage-histogram`, `pileup-view`, `cigar-anatomy` | Pileup anatomy, coverage histogram with a low-coverage trough, the 10-read C/T pileup with AF, and CIGAR anatomy. The consensus proposal below reuses the pileup idiom but adds the threshold/N-mask step the foundations pileup does not show. |
| `01-foundations/05-variants-and-vcf` -> `vcf-row-anatomy`, `allele-frequency-haploid-vs-diploid`, `filter-flag-cartoon` | VCF row anatomy, haploid vs diploid AF, and FILTER flags. |
| `02-sequences/04-msa-and-trees` -> `msa-column-homology`, `tree-anatomy` | MSA gap-insertion homology and phylogram anatomy. |
| `06-classification/01-what-is-classification` -> `classification-question` | The generic reads -> classifier -> sunburst with bacteria/virus/host outputs. The strategy-contrast proposal below is the complement: it shows the three different internal strategies, which this single-box diagram deliberately abstracts away. |
| `07-assembly/01-when-to-assemble` -> `assembly-vs-mapping` | Map-against-reference versus de novo overlap-to-contigs. Covers the map-vs-assemble decision, so no new assembly-decision diagram is proposed. |

## New illustrations needed

Six proposals, ordered by comprehension value. Each is genuinely additive (it is
not in the table above) and is fact-checked against the ground-truth maps.

---

### 1. `classifier-strategy-contrast`

- **Chapter / slot:** `06-classification/01-what-is-classification`. Slots in the
  "Three runnable classifiers, three import-only tools" section, just after the
  table at lines 56-63, to make the abstract "different tools take different
  routes" point visual before the per-tool chapters.
- **Why it aids comprehension:** A biologist's hardest conceptual jump in this
  section is that "classification" is not one algorithm. Three of the tools the
  chapter names reach a taxonomic answer by fundamentally different routes:
  read-by-read k-mer assignment, reference-guided alignment, and
  assemble-then-BLAST. The existing `classification-question` diagram collapses
  all of that into one box. This diagram opens the box and shows why the tools
  give different answers and why their viewports differ.
- **target_dimensions:** `1500x700`
- **asset:** `assets/illustrations-imagegen/06-classification/01-what-is-classification/classifier-strategy-contrast.png`
- **source:** `assets/illustrations-imagegen/06-classification/01-what-is-classification/classifier-strategy-contrast.svg`
- **brief:**
  Three stacked horizontal lanes on a Cream background, each starting from the
  same small pile of short reads (Creamsicle ticks) on the left and ending at a
  taxonomic label on the right, contrasting how three classifier strategies get
  there. Lane 1, labelled "Read by read (Kraken2)": each individual read carries
  a small Deep Ink k-mer bracket and an arrow to a per-read taxon tag, then the
  tags fan into a small taxonomy tree; caption in Warm Grey "every read assigned
  independently by k-mer". Lane 2, labelled "Reference-guided (EsViritu)": the
  reads stack as a shallow pileup against a single Deep Ink reference bar, with a
  Peach breadth bracket under the covered span, ending at a strain-level label;
  caption "reads aligned to a curated viral reference, called to strain". Lane 3,
  labelled "Assemble then BLAST (NVD)": the reads first merge into one long Deep
  Ink contig bar (an overlap-to-contig glyph), the contig then points to a small
  BLAST hit row, ending at a best-match label with a small secondary-hit stub;
  caption "reads assembled into contigs, each contig BLASTed". Keep all three
  end-labels neutral Deep Ink text, no tool-chrome colours. A short footer line
  in Warm Grey: "same reads, three routes, different viewports". Palette only;
  emphasis via Deep Ink weight, no red-amber-green.

---

### 2. `nvd-discovery-flow`

- **Chapter / slot:** `06-classification/08-novel-virus-detection`. Slots in the
  "What it is" section after the opening paragraph (around lines 37-47), or at
  the head of "How NVD differs from the read classifiers". The chapter currently
  has `illustrations: []`.
- **Why it aids comprehension:** The entire value of NVD is the idea that a
  partial or low-identity hit on a long assembled contig is the signal, not
  noise. That inverts the usual "high identity is good" intuition, which is hard
  to convey in prose. A diagram that shows two contigs reaching BLAST and ending
  at "known / routine" versus "novel / divergent: verify this" makes the
  discovery framing immediate. Ground truth confirms NVD assembles reads into
  contigs and BLASTs each contig, keyed by contig with best plus secondary hits
  (`ground-truth/06-classification.md` Section-wide; chapter lines 29-51,
  119-146).
- **target_dimensions:** `1500x650`
- **asset:** `assets/illustrations-imagegen/06-classification/08-novel-virus-detection/nvd-discovery-flow.png`
- **source:** `assets/illustrations-imagegen/06-classification/08-novel-virus-detection/nvd-discovery-flow.svg`
- **brief:**
  A left-to-right four-stage flow on a Cream background. Stage 1: a small pile of
  short reads as Creamsicle ticks, labelled "reads". Stage 2: an "assemble" arrow
  leading to two Deep Ink contig bars of unequal length, labelled "contigs"
  (reinforce that a contig is long: make the bars clearly longer than the
  individual reads). Stage 3: a "BLAST each contig" arrow; each contig points to
  its own small alignment-to-subject glyph (the contig bar over a Deep Ink
  subject bar). Stage 4, the payoff, two outcome cards: the TOP card shows the
  contig fully overlapping its subject with an IBM Plex Mono tag "identity 99%,
  full length" and a thin Deep Ink outline, captioned in Warm Grey "known virus,
  routine"; the BOTTOM card shows the contig only partially overlapping its
  subject (a visible gap, and a portion of the contig with no subject beneath it)
  with an IBM Plex Mono tag "identity 71%, partial" and a HEAVIER Deep Ink
  outline, captioned in Warm Grey "novel or divergent, verify this first". Under
  the bottom card add a small expandable-row stub hinting at secondary BLAST hits
  ("hit 2, hit 3 ..."). Do not use red or green to mark the two outcomes; the
  contrast is carried by overlap geometry, the identity numbers, and stroke
  weight. A footer in Warm Grey: "contigs first, taxa second". Palette only.

---

### 3. `cross-caller-agreement`

- **Chapter / slot:** `05-variants/03-cross-caller-comparison` ("Reading Two
  Callers in One Table"). Slots after the "How iVar, LoFreq, and bcftools differ"
  table (around lines 54-56) or just before "Step 4. Walk through four
  positions". The chapter currently has `illustrations: []`.
- **Why it aids comprehension:** This is the single highest-value diagram in the
  set. The fabricated "comparison view" was removed, so the chapter now teaches
  the reader to compare two callers by eye in one aggregated table, and it hinges
  on four recurring disagreement patterns that are genuinely hard to hold in the
  head from prose alone: iVar-only at moderate AF, LoFreq-only deep in the
  sub-percent band, both-agree-but-different-frequency, and the codon-merge case
  where one merged iVar row lines up against several single-base LoFreq rows. A
  two-track schematic over a shared genome axis makes all four legible at once
  and primes the four-position walkthrough. Faithful to ground truth: there is no
  comparison feature, the shared table aggregates all of a bundle's variant
  tracks with a `Source` column, and iVar merges adjacent within-codon SNPs while
  LoFreq does not (`ground-truth/05-variants.md` ch.03 and Section-wide).
- **target_dimensions:** `1600x650`
- **asset:** `assets/illustrations-imagegen/05-variants/03-cross-caller-comparison/cross-caller-agreement.png`
- **source:** `assets/illustrations-imagegen/05-variants/03-cross-caller-comparison/cross-caller-agreement.svg`
- **brief:**
  A shared horizontal genome coordinate axis (Deep Ink, IBM Plex Mono tick
  labels) on a Cream background, with two parallel caller lanes above and below
  it: the upper lane labelled "iVar (Source: iVar)", the lower labelled "LoFreq
  (Source: LoFreq)". Each called position is a lollipop mark on its lane whose
  height encodes allele frequency (a small Deep Ink AF scale on the left, 0 to
  1). Place four annotated landmark groups left to right. (a) An iVar-only mark
  at moderate height (AF about 0.12) with no LoFreq mark beneath it; Warm Grey
  callout "iVar only: above its 5% threshold". (b) A LoFreq-only mark very low
  near the axis (AF about 0.005) with no iVar mark above it; Warm Grey callout
  "LoFreq only: sub-1%, below iVar's threshold". (c) A position where BOTH lanes
  have a mark but at different heights (iVar near 0.99, LoFreq near 0.61) joined
  by a faint dashed Deep Ink connector; Warm Grey callout "both call it,
  frequencies differ". (d) The codon-merge group: in the iVar lane a SINGLE wide
  mark spanning two adjacent reference bases tagged in IBM Plex Mono "GG>AA (one
  row)", and in the LoFreq lane TWO separate single-base marks at the same two
  coordinates tagged "G>A  G>A (two rows)"; Warm Grey callout "same biology, one
  merged row vs two". Use Creamsicle to fill the lollipop heads and Deep Ink for
  stems and the axis. Do not colour-code agreement versus disagreement; the
  presence/absence of a paired mark and the callouts carry it. Footer in Warm
  Grey: "one shared table, read apart by the Source column". Palette only.

---

### 4. `consensus-from-pileup`

- **Chapter / slot:** `05-variants/05-consensus-and-lineage`. Slots in the "What
  it is" section after the opening definition (around lines 35-37) or alongside
  the "Consensus threshold choices" table. The chapter currently has
  `illustrations: []`.
- **Why it aids comprehension:** The chapter's core idea is that a consensus base
  is decided by a threshold on the read pileup, with positions masked to `N` when
  the reads do not agree or coverage is too thin. Showing one pileup column
  resolving to a called base, and an adjacent low-coverage column resolving to
  `N`, makes the threshold tangible in a way the prose and table cannot. Crucial
  fidelity guardrail: the diagram must NOT imply this comes from the iVar Call
  Variants step. Per ground truth, the iVar variant pipeline never writes a
  consensus FASTA, and `ivarConsensusAF` is a codon-merge rule, not an N-mask
  threshold; real consensus lives in the Viral Recon wizard, `lungfish msa
  consensus`, and the Inspector consensus preview (`ground-truth/05-variants.md`
  ch.05 and Section-wide). Keep the diagram about the generic pileup-to-consensus
  concept with no caller named, so it stays accurate against any of the three
  real surfaces.
- **target_dimensions:** `1400x600`
- **asset:** `assets/illustrations-imagegen/05-variants/05-consensus-and-lineage/consensus-from-pileup.png`
- **source:** `assets/illustrations-imagegen/05-variants/05-consensus-and-lineage/consensus-from-pileup.svg`
- **brief:**
  A pileup-to-consensus cartoon on a Cream background. Across the top, a short
  reference bar with a few IBM Plex Mono bases. Below it, a stack of aligned reads
  (Deep Ink rows) forming a pileup, drawn over four highlighted columns. Column 1
  (deep, unanimous): every read shows the same base, an upward arrow to a called
  Deep Ink consensus base; small Warm Grey note "all reads agree -> call the
  base". Column 2 (deep, mixed at about 80/20): most reads show one base, a few
  show another; because the majority clears the threshold, it resolves to the
  majority base; note "majority above threshold -> call majority". Column 3 (deep,
  near 50/50 split): roughly half-and-half, which falls below the threshold and
  resolves to a Deep Ink "N" glyph; note "no clear majority -> mask as N".
  Column 4 (shallow, only one or two reads): too little coverage, also resolves
  to "N"; note "below minimum depth -> mask as N". Render the resulting consensus
  as a single bar beneath the columns reading the four outcomes in IBM Plex Mono
  (for example "A  C  N  N"). Add a small Creamsicle threshold dial or labelled
  marker to the side annotated "consensus threshold (e.g. 0.75)" to show it is a
  tunable cutoff. Do NOT label the source as iVar or "Call Variants"; keep it the
  generic pileup-to-consensus idea. Encode the N-mask outcomes with the "N" glyph
  and Deep Ink weight, not with a warning colour. Palette only.

---

### 5. `workflow-builder-typed-ports`

- **Chapter / slot:** `08-workflows/01-the-workflow-builder`. Slots in "What it
  is" after the scope paragraph (around lines 49-62) or at the head of "Connect
  nodes with edges". The chapter currently has `illustrations: []`.
- **Why it aids comprehension:** Two ideas anchor the chapter and both are
  spatial: a workflow is a single linear chain of typed-port nodes, and the
  builder accepts a connection only when port types match (and otherwise just
  beeps). A schematic of the real VSP2 chain with a compatible reads-to-reads
  edge shown next to a rejected mismatched edge teaches the typed-port rule and
  the linear-chain constraint at a glance, before the reader builds anything.
  Faithful to ground truth: the seven real categories, the five runnable
  FASTQ-preprocessing nodes in the VSP2 chain (dedup, adapter+quality trim,
  human-read removal, merge pairs, length filter), typed-port matching, the
  no-fan-out linear-chain native runner, and a rejected edge producing a system
  beep rather than a "red flash" (`ground-truth/08-workflows.md` ch.01 and
  Section-wide). Use no red for the rejected edge: per STYLE rules and because the
  app does not draw a red flash.
- **target_dimensions:** `1600x600`
- **asset:** `assets/illustrations-imagegen/08-workflows/01-the-workflow-builder/workflow-builder-typed-ports.png`
- **source:** `assets/illustrations-imagegen/08-workflows/01-the-workflow-builder/workflow-builder-typed-ports.svg`
- **brief:**
  A simplified node-graph canvas on a Cream background showing the VSP2 FASTQ
  chain as a single straight left-to-right line of rounded Deep Ink-outlined node
  cards: "FASTQ Bundle Input" -> "Remove PCR duplicates" -> "Adapter + quality
  trim" -> "Remove human reads" -> "Merge overlapping pairs" -> "Remove short
  reads" -> a pinned "Project output" card. Each card has small circular ports on
  its left (input) and right (output) edges. The connecting edges are smooth
  Creamsicle curves drawn port-to-port; label one edge inline in small IBM Plex
  Mono "FASTQ reads -> FASTQ reads" to show the port types match. Tuck a tiny
  parameter chip under one node (for example, under Adapter + quality trim show
  "Q 15, window 5"). Below the main chain, draw a small inset labelled
  "incompatible connection": an output port typed "BAM Track" with an attempted
  edge toward an input port typed "FASTQ reads", the edge drawn as a broken or
  greyed Deep Ink dashed stub that does not connect, with a Warm Grey caption
  "type mismatch: connection dropped (the app beeps)". Add a second short Warm
  Grey note near the chain "native runs are a single linear chain, no fan-out".
  Keep the pinned "Project output" card visually distinct (a heavier Deep Ink
  outline) to mark it as the fixed anchor. Do not use the app's per-category
  chrome colours and do not draw the rejected edge in red. Palette only.

---

### 6. `joint-genotyping-strategy`

- **Chapter / slot:** `06-human-germline-variants/02-joint-genotyping`. Slots
  after the `--combine-strategy auto` paragraph (around lines 46-50). The chapter
  currently has `illustrations: []`.
- **Why it aids comprehension:** The chapter's key operational decision is that
  `auto` picks `CombineGVCFs` at or below 50 samples and `GenomicsDBImport` above
  it, both feeding `GenotypeGVCFs`. That branch-at-a-threshold-then-rejoin shape
  is exactly what a small decision diagram conveys better than a sentence, and it
  helps a power user reason about when to pin a strategy for reproducibility.
  Both facts are verified-correct in ground truth (the 50-sample boundary and the
  two combine paths into `GenotypeGVCFs`, `ground-truth/06-human-germline-variants.md`
  ch.02), so the diagram depicts real behaviour.
- **target_dimensions:** `1400x550`
- **asset:** `assets/illustrations-imagegen/06-human-germline-variants/02-joint-genotyping/joint-genotyping-strategy.png`
- **source:** `assets/illustrations-imagegen/06-human-germline-variants/02-joint-genotyping/joint-genotyping-strategy.svg`
- **brief:**
  A decision-flow cartoon on a Cream background. On the left, a column of several
  small per-sample GVCF document glyphs (Deep Ink) labelled "per-sample GVCFs".
  An arrow leads to a Creamsicle diamond decision node reading "cohort size?"
  with the IBM Plex Mono branch labels "<= 50" and "> 50". The "<= 50" branch
  goes to a Deep Ink box "CombineGVCFs (one combined GVCF)"; the "> 50" branch
  goes to a Deep Ink box "GenomicsDBImport (on-disk workspace)". Both boxes
  converge with arrows into a single downstream Deep Ink box "GenotypeGVCFs",
  which emits one cohort VCF document glyph on the right labelled "cohort VCF".
  Annotate the diamond in Warm Grey "default: auto picks the path; pin
  combine-gvcfs or genomicsdb for reproducibility". Keep the two strategy boxes
  visually parallel (same size, same Deep Ink weight) so neither reads as the
  "better" one; the only distinction is the size label on the branch. Palette
  only, no red-amber-green for the branch.

---

## Suggested illustrations.yaml additions

Paste each block under its chapter key in `docs/user-manual/illustrations.yaml`.
The first four chapter keys are new (those chapters have no existing entry in the
registry), so add the full `<chapter-id>:` + `illustrations:` header shown.
`06-classification/01-what-is-classification` already exists in the registry, so
append only the new list item under its existing `illustrations:` key.

```yaml
  05-variants/03-cross-caller-comparison:
    illustrations:
      - id: cross-caller-agreement
        target_dimensions: 1600x650
        asset: assets/illustrations-imagegen/05-variants/03-cross-caller-comparison/cross-caller-agreement.png
        source: assets/illustrations-imagegen/05-variants/03-cross-caller-comparison/cross-caller-agreement.svg
        brief: >
          Two caller lanes (iVar above, LoFreq below) over a shared genome axis,
          lollipop marks whose height encodes allele frequency, annotating four
          patterns: an iVar-only mark above 5%, a LoFreq-only sub-1% mark, a
          both-call-but-different-frequency pair, and the codon-merge case where
          one wide iVar GG>AA row aligns against two single-base LoFreq rows.
          Read apart by the Source column, not by colour.

  05-variants/05-consensus-and-lineage:
    illustrations:
      - id: consensus-from-pileup
        target_dimensions: 1400x600
        asset: assets/illustrations-imagegen/05-variants/05-consensus-and-lineage/consensus-from-pileup.png
        source: assets/illustrations-imagegen/05-variants/05-consensus-and-lineage/consensus-from-pileup.svg
        brief: >
          A read pileup over four columns resolving to a consensus bar: a
          unanimous deep column calls its base, a majority-above-threshold column
          calls the majority base, a near-50/50 column masks as N, and a shallow
          low-depth column masks as N. A side threshold marker labelled about
          0.75 shows the tunable cutoff. Generic pileup-to-consensus concept, not
          tied to the iVar Call Variants step; N-masking shown by glyph and Deep
          Ink weight, not colour.

  06-classification/08-novel-virus-detection:
    illustrations:
      - id: nvd-discovery-flow
        target_dimensions: 1500x650
        asset: assets/illustrations-imagegen/06-classification/08-novel-virus-detection/nvd-discovery-flow.png
        source: assets/illustrations-imagegen/06-classification/08-novel-virus-detection/nvd-discovery-flow.svg
        brief: >
          Reads assemble into two long contigs, each contig is BLASTed, and the
          payoff is two outcome cards: a full-length high-identity hit captioned
          known/routine, and a partial low-identity hit (visible overlap gap)
          with a heavier Deep Ink outline captioned novel-or-divergent, verify
          first, with a secondary-hit stub beneath it. Contigs first, taxa
          second. Outcome contrast carried by overlap geometry and identity
          numbers, not red-amber-green.

  06-human-germline-variants/02-joint-genotyping:
    illustrations:
      - id: joint-genotyping-strategy
        target_dimensions: 1400x550
        asset: assets/illustrations-imagegen/06-human-germline-variants/02-joint-genotyping/joint-genotyping-strategy.png
        source: assets/illustrations-imagegen/06-human-germline-variants/02-joint-genotyping/joint-genotyping-strategy.svg
        brief: >
          Per-sample GVCFs feed a cohort-size decision diamond: at or below 50
          samples to CombineGVCFs, above 50 to GenomicsDBImport, both converging
          into GenotypeGVCFs and out to one cohort VCF. The two strategy boxes
          are drawn equal-weight so neither reads as better; auto picks the path
          by default, pin a strategy for reproducibility.

  08-workflows/01-the-workflow-builder:
    illustrations:
      - id: workflow-builder-typed-ports
        target_dimensions: 1600x600
        asset: assets/illustrations-imagegen/08-workflows/01-the-workflow-builder/workflow-builder-typed-ports.png
        source: assets/illustrations-imagegen/08-workflows/01-the-workflow-builder/workflow-builder-typed-ports.svg
        brief: >
          The VSP2 FASTQ chain as a single straight line of typed-port node cards
          (FASTQ Bundle Input through dedup, adapter+quality trim, human-read
          removal, merge pairs, length filter, into the pinned Project output),
          with one edge labelled FASTQ reads to FASTQ reads to show types match.
          An inset shows an incompatible BAM-Track-to-FASTQ-reads edge dropped as
          a greyed dashed stub captioned type mismatch, the app beeps. Single
          linear chain, no fan-out, no red edge.
```

Append this single item under the EXISTING
`06-classification/01-what-is-classification:` -> `illustrations:` key already
present in `illustrations.yaml` (do not re-add the chapter header):

```yaml
      - id: classifier-strategy-contrast
        target_dimensions: 1500x700
        asset: assets/illustrations-imagegen/06-classification/01-what-is-classification/classifier-strategy-contrast.png
        source: assets/illustrations-imagegen/06-classification/01-what-is-classification/classifier-strategy-contrast.svg
        brief: >
          Three stacked lanes starting from the same reads and ending at a taxon
          label, contrasting read-by-read k-mer assignment (Kraken2), reference-
          guided alignment to a curated viral reference called to strain
          (EsViritu), and assemble-then-BLAST per contig (NVD). Same reads, three
          routes, different viewports. Tools distinguished by label and shape, not
          by app chrome colours.
```
