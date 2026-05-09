# Lungfish user manual — illustration TODO

**Date:** 2026-05-09
**Reviewers:** four-illustrator panel (medical, bioinformatics, UI/UX, scientific cartoonist)
**Inputs:** `illustrations.yaml`, every chapter's `illustrations:` frontmatter, `STYLE.md`, and the foundations + part-ii focus group syntheses.
**Reference style:** the bedtools "intersect" colored-pencil cartoons. Warm palette, hand-drawn line, named characters ("intervals A and B"), soft shading rather than flat fills, generous whitespace, one teaching point per frame.

This file replaces ad-hoc briefs with per-illustration specifications detailed enough that an illustrator (human or generative) can produce a final asset without coming back to ask. It also elevates the chapter-frontmatter illustrations that have not yet been promoted into `illustrations.yaml` so they are not lost.

---

## A. Style guide for illustrations

These rules apply to every illustration listed below. They extend `STYLE.md` (which governs prose and screenshots) into the cartoon-illustration domain.

### Brand palette and when to use each color

The five brand colors are the entire vocabulary for the dominant elements of every figure. Reach for complements only when the brand five cannot encode a meaningful distinction without ambiguity.

| Role | Color | Hex | Use |
|---|---|---|---|
| Dominant data element | Lungfish Creamsicle | `#EE8B4F` | Reads, contigs, classifier boxes, primary highlight strokes, callout arrows |
| Secondary warm tint | Peach | `#F6B088` | Primer regions, soft-clipped bases, low-coverage callouts, "before" state in a before/after pair, gentle warning |
| Reference and structural ink | Deep Ink | `#1F1A17` | Reference backbones, axis rules, hand-lettered labels, line work, value text |
| Page and figure ground | Cream | `#FAF4EA` | Background of every figure, fill behind tables, breathing room |
| Captions and metadata | Warm Grey | `#8A847A` | Tick labels, secondary captions, axis numerals when not load-bearing |

Hard rules carried over from `STYLE.md`:

1. Never place Creamsicle on Peach (low contrast, brand banned).
2. Never use Creamsicle for body text inside a figure. Hand-lettered labels are Deep Ink.
3. Never encode severity with red-amber-green. Use Deep Ink weight, Peach for warnings, and an explicit text annotation. Where a check icon is required (only `filter-flag-cartoon`), draw a hand-inked Deep Ink check mark, not a saturated green tick.
4. Never use pure black (`#000000`) or pure white (`#FFFFFF`). Backgrounds are Cream, ink is Deep Ink.

### When to introduce complementary colors

The brand five are sufficient for most figures. A complementary color is justified only when:

1. A figure must encode three or more taxonomic-style categories that need to be perceptually distinct at glance distance (`classification-question` is the only current example).
2. A figure must show a quantitative gradient where a single-hue ramp loses resolution at the dark end.

In the first case use the four classification accent colors specified in project memory: Kraken2 = `#3B6FB6` (cool blue), EsViritu = `#3F8E66` (forest green), TaxTriage = `#7A56B0` (cool purple), NAO-MGS = `#C99435` (amber). Render them at 70 percent saturation with colored-pencil shading so they read as warm, not flat. Do not introduce other category accents elsewhere.

In the second case (gradient ramps such as Phred quality) use a single-hue Creamsicle ramp from a 25 percent-tinted Cream to full Creamsicle, then optionally extend toward Deep Ink for the most saturated end. Do not introduce a contrasting ramp end (no purple, no blue).

### Hand-drawn colored-pencil style notes

- **Line work.** Outline weight target is 1.5–2.5 pt at 1× export, with deliberate variation so the line "breathes." Contours are not perfectly closed; small gaps where strokes overlap are acceptable and preferred to a sealed vector look.
- **Shading.** Soft directional pencil shading inside shapes, never flat fills. Shade from a consistent imaginary light source in the upper left across the figure set.
- **Texture.** A subtle paper-grain texture lives beneath every figure on the Cream ground. Render this as a 4–6 percent opacity noise layer or a real scanned cold-press paper texture multiplied at low opacity. Do not overdo it.
- **Edges.** Organic edges. No vector-perfect right angles for genome backbones, read arrows, or table cell borders. A 1–2 px wobble across a long edge is correct.
- **Labels.** Inter SemiBold rendered with a slight (≤2°) random rotation per word and a 1–2 px baseline jitter to read as hand-set. Numeric data and code stay IBM Plex Mono and remain perfectly upright (jitter would imply bad data).
- **Callouts.** 2 px Creamsicle strokes with a small open circle at the anchor end and a hand-drawn waver. Lead lines may curve gently.

### Composition rules

- Maximum five named elements per figure. If the chapter wants more, split into two figures.
- One teaching point per figure. The reader should be able to state what the figure taught in one sentence after looking at it for three seconds.
- Generous whitespace. The Cream ground occupies at least 30 percent of the bounding box, distributed.
- Reading order is left-to-right and top-to-bottom. Place the eye-anchor (the strongest contrast) at the upper-left third for figures with multiple elements; place it at the optical center for single-element figures.

### Label conventions

- Lower-case sentence case for descriptive labels: `forward primer`, `low coverage`, `read 2 (reverse complement)`.
- Title case is reserved for proper nouns and tool names: `Kraken2`, `MN908947.3`, `SARS-CoV-2`.
- No terminal punctuation on labels and callouts. Sentences in caption blocks (one or two lines under the figure) take a period.
- Code and numeric data stay in IBM Plex Mono and may include punctuation that is part of the syntax (`5S140M5S`, `MN908947.3:21618 C>T`).
- Callouts use 2 px Creamsicle strokes anchored to the labeled element with a small open circle at the contact point.

### Banned

Flat saturated fills. Vector-perfect rectangles for biological objects. Gradient meshes. Photorealism. Drop shadows. Heavy uniform outlines. Clip-art icons. Emojis. Sans-perfect grids of evenly-spaced reads (real reads tile irregularly, so should the cartoon).

### Working principle

When in doubt, reach for the bedtools intersect aesthetic. Two named characters, one teaching point, soft pencil shading, hand-lettered labels. If a figure cannot survive being printed at 50 percent size on Cream paper without losing its teaching point, it is over-designed.

---

## B. Per-illustration specifications

The illustrations are listed in chapter order. Each entry is self-contained so an illustrator working on one figure does not need to read the others.

Illustrations from chapter frontmatter that are not yet in `illustrations.yaml` are flagged with **(promote to illustrations.yaml)**.

### linear-vs-circular-genomes

- **Chapter:** `01-foundations/01-what-is-a-genome`
- **Where used:** Primer section establishing that genomes come in two physical topologies before the manual specializes to viral linear/circular cases.
- **Pedagogical purpose:** the reader should understand, after one look, that "genome" is not a single physical shape, and should be able to point at which side represents the linear and which the circular case.
- **Target dimensions:** 1200x600
- **Composition:** Two named characters share the frame. On the left, a horizontal Creamsicle backbone runs about 60 percent of the half-frame width with two ends labeled `5'` and `3'` in IBM Plex Mono. On the right, a closed Creamsicle loop the same total length sits centered with a single tick at the top labeled `position 1`. A thin Warm Grey caption beneath each character reads `linear chromosome` and `circular genome`. The eye reads the linear one first because the 5' label sits in the upper left.
- **Color usage:** Creamsicle for both backbones. Deep Ink for the position labels and the 5'/3' tick marks. Warm Grey for the descriptive captions. Cream ground.
- **Labels and callouts:** `5'`, `3'`, `position 1`, `linear chromosome`, `circular genome`. No callout strokes; labels sit directly above or below their target.
- **Hand-drawn style notes:** the linear backbone has a slight upward bow in the middle, suggesting tension. The circular genome is not a perfect circle; let it lean slightly out of round.
- **Common pitfalls:** drawing the circle as a vector-perfect ellipse; making the two backbones different colors instead of both Creamsicle; positioning `5'` in the wrong corner so the reading direction is ambiguous.
- **Illustrator panel discussion:** The medical illustrator pushes for accurate end-cap geometry on the linear chromosome (a small thickening, not a sharp arrow) so it reads as a real chromosome rather than a directional arrow. The bioinformatics illustrator reminds the panel that for SARS-CoV-2 the genome is single-stranded RNA, not double, so the backbone should not be drawn as a double helix; a single contour line is correct. The UI/UX illustrator wants the labels closer to the elements and warns against ambiguous reading order if the circular genome's `position 1` lands far from the top. The cartoonist wins on the hand-drawn imperfection question: she insists the circle is not perfectly round and the linear backbone should breathe, because a clinical-poster vector look would jar against the bedtools-style warmth that defines the rest of the manual. Final consensus: imperfect contours, single-line backbone, labels close in.
- **Priority:** P0
- **Estimated production time:** 2 hours hand-drawn, or 30 min generation prompt + 60 min refinement

### position-coordinates

- **Chapter:** `01-foundations/01-what-is-a-genome`
- **Where used:** The 1-based, inclusive positioning section. This figure carries the load that the focus groups asked be defined once and cross-linked from later chapters.
- **Pedagogical purpose:** the reader should leave knowing positions are 1-based, that 29,903 is the canonical SARS-CoV-2 genome length, and that ticks are spaced log-arbitrarily for readability rather than truly to scale.
- **Target dimensions:** 1400x300
- **Composition:** A single horizontal Creamsicle backbone runs across about 80 percent of the frame width, slightly off-center toward the bottom. Above the backbone sits a callout box (hand-drawn Creamsicle border, Cream fill) reading `SARS-CoV-2 MN908947.3, 29,903 bases`. Below the backbone, five ticks at positions 1, 1000, 5000, 10000, and 29,903 in IBM Plex Mono. A small `1-based` caption sits to the left of the leftmost tick.
- **Color usage:** Creamsicle for the backbone and callout border. Deep Ink for tick numerals and the callout text. Warm Grey for the `1-based` caption. Cream ground.
- **Labels and callouts:** `SARS-CoV-2 MN908947.3, 29,903 bases`, `1`, `1000`, `5000`, `10000`, `29903`, `1-based`.
- **Hand-drawn style notes:** ticks are slightly uneven in length. The callout's lead line bends gently rather than going straight down.
- **Common pitfalls:** spacing the ticks linearly to scale, which makes the leftmost ticks crowded; using Warm Grey for the position numerals, which fails reproducibility-of-numbers expectations; omitting the `1-based` caption, which is the entire point of the figure.
- **Illustrator panel discussion:** The bioinformatics illustrator insists that 29,903 must be the actual MN908947.3 length and not a rounded approximation, because focus group reviewers (especially the power-user persona) catch this kind of error immediately. The medical illustrator suggests treating ticks as small notches the way a ruler would, with a slight bevel at each tick base. The UI/UX illustrator notes that the eye anchor must be the callout, not the leftmost tick, so the reader knows which genome the ruler describes. The cartoonist asks for tick numerals slightly hand-jittered in baseline; the bioinformatics illustrator vetoes baseline jitter on numerals (numeric data must read precisely) but agrees to slight character spacing variance. Final consensus: ticks irregular in length, numerals upright IBM Plex Mono, callout in upper position with a curved lead.
- **Priority:** P0
- **Estimated production time:** 2 hours hand-drawn, or 30 min generation prompt + 60 min refinement

### variant-notation

- **Chapter:** `01-foundations/01-what-is-a-genome`
- **Where used:** The variant notation breakdown praised by all twenty foundations focus group personas as a competence checkpoint. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should be able to decompose `MN908947.3:21618 C>T` into chromosome name, position, reference base, and alternate base, and to write a similar string for any variant they encounter.
- **Target dimensions:** 1400x500
- **Composition:** the variant string `MN908947.3:21618 C>T` sits in the upper-center in IBM Plex Mono at oversized scale. Five Creamsicle callout lines lead diagonally outward from each component to a hand-lettered Deep Ink label: `chromosome name`, `colon separator`, `1-based position`, `reference base`, `alternate base`. The labels fan out evenly. The eye reads the variant string first because of its scale, then follows the callouts outward.
- **Color usage:** the variant string itself is Deep Ink with each component subtly tinted: chromosome and separators in Deep Ink, position in Deep Ink, REF base softly tinted Peach, ALT base saturated Creamsicle. Callout strokes Creamsicle. Labels Deep Ink. Cream ground.
- **Labels and callouts:** `chromosome name`, `colon separator`, `1-based position`, `reference base`, `alternate base`.
- **Hand-drawn style notes:** the callout strokes are not straight; each curves gently with a small open circle at the anchor. The five labels are arranged radially but not on a perfect circle.
- **Common pitfalls:** putting the labels too close together so the callouts overlap; using a different position number than the canonical SARS-CoV-2 spike L452R or D614G example unless deliberately matching prose; making the REF and ALT base colors so different that a reader thinks the colors carry meaning beyond highlighting.
- **Illustrator panel discussion:** The bioinformatics illustrator insists on `MN908947.3:21618 C>T` exactly because that is the spike-protein A23403G variant in genome coordinates and the prose anchors to it. The medical illustrator wants the REF/ALT bases visually distinguished but is happy with a tint contrast rather than a saturated color. The UI/UX illustrator argues for radial fan layout because it lets each label breathe; the cartoonist agrees and adds that the callouts should curve to feel hand-drawn, not engineered. There is a productive disagreement on whether to spell out `1-based` in the `position` label: the bioinformatics illustrator wants it explicit, the cartoonist wants the brevity of `position`. Compromise: label reads `1-based position` because foundations focus group called out the 1-based discipline as a recurring teaching point.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### fastq-record-anatomy

- **Chapter:** `01-foundations/02-sequencing-reads`
- **Where used:** First introduction of the FASTQ format.
- **Pedagogical purpose:** the reader should know that one FASTQ record is exactly four lines and what each line contains.
- **Target dimensions:** 1400x600
- **Composition:** four horizontal stripes stacked vertically, each representing one FASTQ line. From top to bottom: a Creamsicle banner with `@SRR123.1 length=150` in IBM Plex Mono, a longer Cream stripe holding the 150-base read sequence in IBM Plex Mono on a faintly-tinted Creamsicle ground, a thin Cream stripe with a single `+` character centered, and a final stripe holding the quality string in IBM Plex Mono. To the left of each stripe, a hand-lettered label: `header`, `sequence`, `separator`, `quality`. A short Warm Grey caption beneath the figure explains the four-line repeating unit.
- **Color usage:** Creamsicle for the header banner and the sequence stripe ground tint. Deep Ink for the labels and the sequence/quality characters. Warm Grey for the explanatory caption. Cream for the figure ground.
- **Labels and callouts:** `header`, `sequence`, `separator`, `quality`.
- **Hand-drawn style notes:** the four stripes are not perfectly the same height; the sequence stripe is the tallest because it carries the most ink. The `+` separator stripe is deliberately the shortest.
- **Common pitfalls:** truncating the sequence and quality strings asymmetrically (they must be the same length); making the header line look like a code comment rather than a label; using a real read header from the SRA that turns out to be unrealistic for SARS-CoV-2 amplicon data.
- **Illustrator panel discussion:** The bioinformatics illustrator wants the header to follow real SRA conventions (`@SRR12345.1.1` for paired) and the quality string to be a plausible Phred encoding rather than uniform `IIIII`. The cartoonist warns that real-looking strings at full length will dominate the figure; she wants the strings shortened to ~30 bases with an em-dash or `…` showing truncation. The bioinformatics illustrator vetoes the em-dash on prose-style grounds (the manual bans em dashes) and offers `[…]` instead. The medical illustrator is neutral. The UI/UX illustrator asks for the labels to sit on the same baseline as the stripe centers so the eye sweeps cleanly. Final consensus: shortened sequence and quality strings with `[…]` truncation, real SRA-style header, labels left-aligned at stripe center.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### paired-end-reads

- **Chapter:** `01-foundations/02-sequencing-reads`
- **Where used:** Section explaining paired-end sequencing.
- **Pedagogical purpose:** the reader should understand that one DNA fragment yields two reads pointing inward, and that the reads do not necessarily overlap in the middle.
- **Target dimensions:** 1400x500
- **Composition:** two named characters in one frame. Across the middle of the frame, a horizontal Deep Ink line represents the DNA fragment, drawn as a thin double-line (paired strands) for the full length. From the left end, a Creamsicle right-pointing arrow extends about 35 percent of the fragment length, labeled `read 1 (forward)`. From the right end, a Creamsicle left-pointing arrow extends about 35 percent, labeled `read 2 (reverse complement)`. A Warm Grey gap in the middle is labeled `unsequenced insert`.
- **Color usage:** Deep Ink for the fragment. Creamsicle for the two read arrows. Warm Grey for the insert gap label. Cream ground.
- **Labels and callouts:** `read 1 (forward)`, `read 2 (reverse complement)`, `unsequenced insert`.
- **Hand-drawn style notes:** the two arrows are slightly different in length to underscore that paired reads need not be symmetric. The arrowheads are hand-drawn triangles with a small notch at the tip.
- **Common pitfalls:** drawing the arrows so they overlap in the middle, which contradicts the teaching point; making the fragment too short so the gap reads as a printing artifact; labeling read 2 as "reverse" without "reverse complement" — the focus groups asked for precision here.
- **Illustrator panel discussion:** The bioinformatics illustrator wants the unsequenced gap explicit because clinical and surveillance personas read paired-end as "the reads always meet in the middle" and that confusion is exactly what this figure exists to break. The medical illustrator pushes for showing the fragment as a double strand to be biologically honest. The UI/UX illustrator counters that a double-line strand will visually compete with the read arrows and reduce comprehension on first read. The cartoonist breaks the tie: a single Deep Ink line is correct because the figure is teaching the read geometry, not the strand chemistry, and the chapter has already established DNA structure elsewhere. Note also that read 2 is reverse-complement, not just reverse; the label must say so.
- **Priority:** P0
- **Estimated production time:** 2 hours hand-drawn, or 30 min generation prompt + 60 min refinement

### phred-quality-bar

- **Chapter:** `01-foundations/02-sequencing-reads`
- **Where used:** Quality scoring section.
- **Pedagogical purpose:** the reader should map a Phred number to an error rate (Q20 = 1 percent, Q30 = 0.1 percent) and understand that quality varies along a read.
- **Target dimensions:** 1400x400
- **Composition:** three stacked elements. Top: a 30-character read sequence in IBM Plex Mono. Middle: a horizontal bar showing Phred score 0-40 as a Creamsicle gradient (low end is 25 percent-tinted Cream, high end is full Creamsicle). Bottom: a per-base quality bar matching the read sequence above, with each base's column shaded by its quality on the same gradient. Two annotations to the right: `Q20 = 1% error` and `Q30 = 0.1% error`.
- **Color usage:** single-hue Creamsicle gradient for the quality scale. Deep Ink for sequence characters and annotations. Warm Grey for the 0/10/20/30/40 axis labels. Cream ground.
- **Labels and callouts:** `Q20 = 1% error`, `Q30 = 0.1% error`, axis tick labels `0`, `10`, `20`, `30`, `40`.
- **Hand-drawn style notes:** the per-base columns vary slightly in width and have soft edges where neighboring quality scores blend. The gradient bar is shaded with directional pencil strokes.
- **Common pitfalls:** introducing a contrasting hue at the high end of the gradient (banned); using a uniform quality across all bases, which defeats the visual point that quality varies; mislabeling Q20 and Q30 percentages — the math is `10 ** (-Q/10)`.
- **Illustrator panel discussion:** The bioinformatics illustrator insists the gradient be perceptually monotonic; the cartoonist warns that a literal monotonic ramp through Cream-to-Creamsicle will look weak at the low end. They compromise on the low end being a 25 percent Cream tint over a faint paper texture, so it reads as "low" without bleaching out. The medical illustrator notes that real Illumina reads typically have quality dropping at the 3' end and asks that the bottom bar reflect that pattern. The UI/UX illustrator asks for the Q20 and Q30 annotations placed level with the appropriate gradient stops, not floating freely. Final consensus: monotonic single-hue ramp, slight 3' quality drop, annotations level with their gradient positions.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### platform-read-length-comparison

- **Chapter:** `01-foundations/02-sequencing-reads`
- **Where used:** Platform comparison section. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should see at a glance the order-of-magnitude difference in read length between Illumina, PacBio HiFi, and Oxford Nanopore.
- **Target dimensions:** 1400x500
- **Composition:** three horizontal Creamsicle bars stacked vertically, each labeled with its platform and a length range. Top bar: a short Illumina bar (~150 bp) on the left side of the frame. Middle bar: a medium PacBio HiFi bar (~15 kb) extending further right. Bottom bar: a long Nanopore bar (1-100 kb) with a frayed right edge to indicate variable maximum length. A Warm Grey log-scale ruler underneath. Each bar is labeled at the right with the platform name and the length range in IBM Plex Mono.
- **Color usage:** Creamsicle for the bars. Deep Ink for platform names. Warm Grey for the length-axis numerals. Cream ground.
- **Labels and callouts:** `Illumina, ~150 bp`, `PacBio HiFi, ~15 kb`, `Oxford Nanopore, 1-100 kb`, axis labels `100 bp`, `1 kb`, `10 kb`, `100 kb`.
- **Hand-drawn style notes:** the Nanopore bar's right edge is deliberately frayed and uneven to show the variable distribution. The log-scale ruler ticks are notch-style and slightly varied in length.
- **Common pitfalls:** drawing the bars on a linear scale so Illumina is invisible; using different colors per platform which would imply categorical encoding; failing to update the chemistry numbers (the focus group flagged that R10.4.1 simplex hits Q20+ and the platform table is dated; the length-comparison figure is less affected, but ensure it matches the latest body copy).
- **Illustrator panel discussion:** The bioinformatics illustrator and the cartoonist agree the log-scale ruler is essential because a linear scale would render Illumina as a dot. The medical illustrator wants the bars to be roughly genomic-realistic in proportion (their lengths along the log axis must match the labeled ranges). The UI/UX illustrator wants the platform names on the right, not the left, so the eye reads the bar's length first and the name second, reinforcing the relative-length teaching point. The frayed Nanopore edge is the cartoonist's contribution and lands well across the panel. Final consensus: log-scale, frayed Nanopore right edge, platform labels on the right.
- **Priority:** P1
- **Estimated production time:** 2-4 hours hand-drawn, or 30 min generation prompt + 90 min refinement

### amplicon-vs-shotgun

- **Chapter:** `01-foundations/03-amplicon-vs-shotgun`
- **Where used:** Top of the chapter, contrasting the two strategies.
- **Pedagogical purpose:** the reader should distinguish at a glance between random-position shotgun reads and tiled, fixed-position amplicon reads, and understand that amplicons overlap.
- **Target dimensions:** 1400x800
- **Composition:** two stacked schematics sharing the same horizontal genome backbone in Deep Ink. Top half: shotgun. About 40 short Creamsicle reads scattered randomly across the backbone, with arbitrary start and end positions, some on top, some below the backbone, some forward, some reverse. Bottom half: amplicon. The same backbone with reads starting and ending at fixed primer positions, plus 8-10 overlapping Peach amplicon rectangles tiling the backbone. A row label sits at the left margin of each half: `shotgun` and `amplicon`.
- **Color usage:** Deep Ink for the backbones. Creamsicle for reads. Peach for amplicon tiles. Warm Grey for axis ticks if used. Cream ground.
- **Labels and callouts:** `shotgun`, `amplicon`. Optionally a small `~400 bp` tag on one amplicon to anchor scale.
- **Hand-drawn style notes:** the shotgun reads tile irregularly, with deliberate clustering and gaps to suggest realistic stochastic coverage. The amplicon tiles are not perfect rectangles; they have slight rounded corners and overlap each other in 50-100 bp regions.
- **Common pitfalls:** drawing shotgun reads in a perfectly even grid (defeats the point); drawing amplicons that do not overlap (clinical and surveillance personas will catch this); making the row labels small enough that the comparison is unclear.
- **Illustrator panel discussion:** The cartoonist's preferred composition: irregular reads above, neatly tiled amplicons below, with the visual rhythm reinforcing the conceptual contrast. The bioinformatics illustrator insists on the overlap region; ARTIC v3, v4, and the new v5 schemes all overlap and the figure must reflect that. The medical illustrator suggests a small primer-stub indicator at each amplicon end to foreshadow `primer-scheme-diagram`; the UI/UX illustrator pushes back because that adds a sixth named element and violates the five-element ceiling. Compromise: do not draw primer stubs in this figure; reserve them for `primer-scheme-diagram`. The cartoonist's irregular shotgun pattern is endorsed unanimously.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 45 min generation prompt + 120 min refinement

### primer-scheme-diagram

- **Chapter:** `01-foundations/03-amplicon-vs-shotgun`
- **Where used:** Section introducing ARTIC-style primer schemes.
- **Pedagogical purpose:** the reader should map a primer-scheme BED file to its physical layout: forward primers on top, reverse primers below, three overlapping amplicons.
- **Target dimensions:** 1400x500
- **Composition:** a 2000 bp Deep Ink genome backbone runs across the upper half of the frame. Above the backbone, three Creamsicle right-pointing forward primer arrows. Below the backbone, three left-pointing reverse primer arrows offset so each forward/reverse pair brackets one amplicon. The three resulting amplicons are shown as faint Peach bands behind the primers. Below the figure, a small table in IBM Plex Mono with three rows: `amp_1_LEFT 30 54`, `amp_1_RIGHT 410 434`, `amp_2_LEFT 380 404`, etc. Three columns: name, start, end.
- **Color usage:** Deep Ink for the backbone and table text. Creamsicle for the primer arrows. Peach for the amplicon bands. Warm Grey for axis ticks. Cream ground.
- **Labels and callouts:** primer names attached to each arrow with a short Creamsicle lead. `BED-style coordinates` caption above the table.
- **Hand-drawn style notes:** the primer arrows are hand-drawn, with arrowheads slightly variable. The amplicon bands are softly shaded with directional pencil strokes, not flat fills.
- **Common pitfalls:** drawing primer pairs that do not overlap (must overlap by ~30 bp on real ARTIC schemes); using Creamsicle for the amplicon bands (would clash with primer arrows); making the table text not match the visual positions in the figure.
- **Illustrator panel discussion:** The bioinformatics illustrator is most exacting here: the BED rows must be 0-based half-open (BED's actual convention) even though the rest of the manual emphasizes 1-based inclusive elsewhere. The figure should show this in the table to reinforce the format-specific coordinate distinction the focus groups asked be made explicit. The cartoonist prefers a simpler table without belaboring the BED-vs-1-based point in this figure; she wants that to live in the file-formats appendix instead. The bioinformatics illustrator concedes if a small Warm Grey footnote `BED is 0-based, half-open` sits below the table. The medical illustrator and UI/UX illustrator agree this is an acceptable compromise. Final consensus: BED-honest coordinates, footnote, soft Peach amplicon bands.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 45 min generation prompt + 120 min refinement

### primer-trim-soft-clip

- **Chapter:** `01-foundations/03-amplicon-vs-shotgun`
- **Where used:** Section explaining what `lungfish primer trim` produces in the BAM.
- **Pedagogical purpose:** the reader should see that primer trim does not remove bases; it marks the primer-derived bases as soft-clipped so the variant caller ignores them.
- **Target dimensions:** 1400x500
- **Composition:** the same single read shown twice, stacked. Top instance: untrimmed read; the leftmost ~20 bases are highlighted Peach (primer-derived) and the rest of the read is Creamsicle (sample-derived). Bottom instance: same read after primer trim; the primer-derived bases are lightened to a 30 percent-tinted Peach and the segment is bracketed with `[soft-clipped]`. Body unchanged. A Deep Ink annotation reads `primer bases ignored by the variant caller`.
- **Color usage:** Peach for primer-derived bases (full saturation in untrimmed, 30 percent in trimmed). Creamsicle for sample-derived bases. Deep Ink for annotations and brackets. Cream ground.
- **Labels and callouts:** `before primer trim`, `after primer trim`, `[soft-clipped]`, `primer bases ignored by the variant caller`.
- **Hand-drawn style notes:** the read is drawn as a long capsule with a slight wobble. The "before/after" annotation is a curved Creamsicle arrow connecting the two instances.
- **Common pitfalls:** showing the trimmed read with the primer bases removed (this is the wrong mental model and the focus group flagged it as a foundational bug); replacing the soft-clipped bases with `N` (the chapter explicitly fixes this misconception in its current revision).
- **Illustrator panel discussion:** The bioinformatics illustrator was the most insistent reviewer here; the focus groups specifically flagged that the foundations chapters had a CIGAR example using N-padded soft-clipped sequences that was technically wrong. The figure must show the soft-clipped bases retaining their original color identity (just lightened to indicate ignore status), never replaced with N or removed. The medical illustrator agrees. The cartoonist focuses on the curved arrow connecting before-and-after states; she wants it to feel like a teaching gesture rather than a process diagram. The UI/UX illustrator raises a worry that "ignored by the variant caller" is too long for the available space; the panel agrees the annotation can wrap to two lines if needed. Final consensus: same bases, just visually quieter after trim, never disappeared.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### read-mapping-cartoon

- **Chapter:** `01-foundations/04-alignment-files`
- **Where used:** Top of the chapter, anchoring what an alignment file represents.
- **Pedagogical purpose:** the reader should leave understanding that an alignment is a stack of reads pinned to reference positions, with strand and soft-clip status visible.
- **Target dimensions:** 1400x600
- **Composition:** a Deep Ink reference backbone runs along the top of the frame. Below it, twenty short Creamsicle read arrows arranged in a pileup-style stack at irregular tile positions; some arrows point right (forward strand), some left (reverse). About four reads have soft-clipped Peach tips at one end. A Warm Grey position ruler runs underneath in IBM Plex Mono. The eye anchor is the densest part of the pileup, ~ 40 percent into the frame.
- **Color usage:** Deep Ink for the backbone and ruler labels. Creamsicle for read arrows. Peach for soft-clipped ends. Warm Grey for the position numerals. Cream ground.
- **Labels and callouts:** `reference`, `forward strand`, `reverse strand`, `soft-clipped end`, axis labels `1`, `500`, `1000`, `1500`.
- **Hand-drawn style notes:** the reads do not tile evenly; clustering and gaps are deliberate. The soft-clipped tips are softly shaded so they read as "different status" not "different read."
- **Common pitfalls:** drawing all reads at the same y-offset (defeats pileup metaphor); making the soft-clipped Peach as saturated as the body Creamsicle (loses the "ignored" reading); over-labeling so the figure becomes a key rather than a story.
- **Illustrator panel discussion:** The cartoonist's strongest single recommendation across the manual: this figure should feel like a chorus of named characters, not a data plot. Each read is a small actor. The bioinformatics illustrator wants the soft-clipped reads to be a believable fraction (about 20 percent), not all twenty reads carrying soft clips. The medical illustrator suggests representing strand by tail style rather than just direction; the panel rejects this as an extra encoding the figure does not need. The UI/UX illustrator asks for callouts naming exactly one example of each status (one forward read labeled `forward strand`, one reverse, one soft-clipped) rather than a separate legend. Final consensus: callouts on representative reads, soft-clipped tips reserved for ~four reads, no extra strand encoding.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

### coverage-histogram

- **Chapter:** `01-foundations/04-alignment-files`
- **Where used:** Coverage section.
- **Pedagogical purpose:** the reader should read coverage as per-position read depth and identify a low-coverage region.
- **Target dimensions:** 1400x350
- **Composition:** a horizontal Creamsicle area-fill histogram across a 2000 bp region, with depth from ~50 to ~2000 reads. One trough (~150 bp wide, depth ~10) is highlighted with a Peach overlay and labeled `low coverage`. The y-axis shows depth values 0, 500, 1000, 1500, 2000 in IBM Plex Mono. The x-axis shows 1, 500, 1000, 1500, 2000.
- **Color usage:** Creamsicle area fill, hand-shaded with directional pencil. Peach overlay for the low-coverage region. Deep Ink for axis labels and the `low coverage` callout. Warm Grey for tick numerals. Cream ground.
- **Labels and callouts:** `low coverage`, axis labels.
- **Hand-drawn style notes:** the histogram top edge wobbles to suggest sampled real data. The Peach overlay has soft edges and a hand-drawn arrow lead to the callout text.
- **Common pitfalls:** drawing the histogram with vector-perfect bars rather than a sketched contour; using red for "low coverage" which violates the data-viz palette rule; making the overlay too saturated so it competes with the histogram itself.
- **Illustrator panel discussion:** The bioinformatics illustrator wants the histogram shape to reflect a realistic ARTIC amplicon coverage profile, with characteristic dips at amplicon junctions. The cartoonist agrees but warns against making the figure too literal; the dips should be visible without dominating. The medical illustrator suggests a small inset showing a zoomed view of the low-coverage trough; the UI/UX illustrator pushes back because that introduces a sixth element and the figure already serves a single teaching point. Compromise: skip the inset; reserve the zoom for `pileup-view`. Final consensus: realistic dip pattern, single Peach callout, no inset.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### pileup-view

- **Chapter:** `01-foundations/04-alignment-files`
- **Where used:** Section introducing pileups and allele frequency.
- **Pedagogical purpose:** the reader should compute allele frequency from read evidence at one position.
- **Target dimensions:** 1000x700
- **Composition:** a single column at the center of the frame. At the top, the reference base `C` in IBM Plex Mono on a small Creamsicle banner. Below, ten short read fragments stacked vertically; seven show `C`, three show `T`. Each base is shaded by Phred quality on the Creamsicle ramp from `phred-quality-bar`. To the right of the stack, the annotation `7 × C, 3 × T` and below it `allele frequency = 3/10 = 30%`. The eye reads the reference at top, scans down the stack, and lands on the AF computation.
- **Color usage:** Creamsicle ramp for base quality. Deep Ink for the bases and the annotation. Cream ground.
- **Labels and callouts:** `7 × C`, `3 × T`, `allele frequency = 3/10 = 30%`, optional `reference` label on the top banner.
- **Hand-drawn style notes:** each read fragment is drawn as a small horizontal capsule. The base characters are upright IBM Plex Mono (no jitter on data).
- **Common pitfalls:** failing to color-grade by quality (loses the "evidence has weight" teaching point); making the AF compute incorrectly (3/10 is exactly 30 percent, not 30.0 or "about 30"); using a different reference base than `C` so the prose anchor breaks.
- **Illustrator panel discussion:** The bioinformatics illustrator wants to add a strand indicator (forward/reverse) to each read because the chapter on cross-caller comparison teaches strand bias next; the UI/UX illustrator vetoes this on the five-element rule. The cartoonist proposes a compromise: half the reads visually slightly different (subtle baseline offset) without an explicit label, foreshadowing strand without naming it. The medical illustrator approves. Final consensus: subtle visual variation hinting at strand without explicit labeling.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### cigar-anatomy

- **Chapter:** `01-foundations/04-alignment-files`
- **Where used:** Section explaining what a CIGAR string encodes. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should decompose `5S140M5S` into a 5-base soft-clip, a 140-base match, and a 5-base soft-clip, and connect the string to a physical read.
- **Target dimensions:** 1400x600
- **Composition:** the read sequence in IBM Plex Mono runs along the top, 150 bases long, with the leftmost and rightmost 5 bases tinted Peach (soft-clip) and the middle 140 bases Creamsicle (match). Below the read, the reference sequence runs in Deep Ink IBM Plex Mono. Beneath both sequences, a hand-drawn bracket spans the leftmost 5 bases labeled `5S`, a longer bracket spans the middle 140 labeled `140M`, and a final bracket spans the rightmost 5 labeled `5S`. The full CIGAR string `5S140M5S` sits prominently below the brackets in oversized IBM Plex Mono. A position ruler with `1000` marked at the alignment start. The annotation `soft-clipped bases keep their base calls. they are not replaced with N` sits in Deep Ink to the right.
- **Color usage:** Peach for soft-clip regions. Creamsicle for matched region. Deep Ink for reference and brackets. Cream ground.
- **Labels and callouts:** `5S`, `140M`, `5S`, `5S140M5S`, `soft-clipped bases keep their base calls. they are not replaced with N`.
- **Hand-drawn style notes:** the brackets are hand-drawn with slightly variable thickness. The read and reference are pixel-aligned so the eye can compare bases.
- **Common pitfalls:** drawing the soft-clipped bases as `N` characters (the focus group flagged this exact error in the prior version of the prose); making the brackets perfectly geometric so they read as vector graphics rather than annotations; mismatching the bracket spans to the labels (5+140+5 must equal 150).
- **Illustrator panel discussion:** This figure carries the highest correctness load in the foundations because the chapter's preceding prose error was specifically about CIGAR semantics. The bioinformatics illustrator insists the soft-clipped bases must be real DNA bases (real `ACGT...`) not `N` filler; the cartoonist agrees and adds that the visual encoding (Peach vs Creamsicle) does the conceptual work without requiring the reader to count bases. The medical illustrator wants the alignment relationship to the reference visually clear: matched bases sit directly above their reference partners with no horizontal offset. The UI/UX illustrator asks for the explanatory annotation right next to the brackets so the teaching point lands without scrolling. Final consensus: real bases throughout, Peach/Creamsicle does the encoding, alignment is positionally honest, annotation adjacent.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

### vcf-row-anatomy

- **Chapter:** `01-foundations/05-variants-and-vcf`
- **Where used:** First introduction of VCF format.
- **Pedagogical purpose:** the reader should know the column order and meaning of a VCF row well enough to read one without external reference.
- **Target dimensions:** 1600x500
- **Composition:** a single VCF row laid out as a horizontal table. Column headers in Inter SemiBold on a Creamsicle banner: `CHROM`, `POS`, `ID`, `REF`, `ALT`, `QUAL`, `FILTER`, `INFO`, `FORMAT`, `sample`. Below each header, the data for one variant row in IBM Plex Mono: `MN908947.3`, `21618`, `.`, `C`, `T`, `1234`, `PASS`, `DP=200;AF=0.95`, `GT:DP:AF`, `1:200:0.95`. Below each column, a one-line explanatory caption in Inter Regular Warm Grey: `chromosome`, `1-based position`, `variant ID or .`, `reference base`, `alternate base`, `Phred-scaled quality`, `filter status`, `key=value annotations`, `format keys`, `per-sample values`.
- **Color usage:** Creamsicle banner for the column headers. Deep Ink for headers and data. Warm Grey for the explanatory captions. Cream ground.
- **Labels and callouts:** column captions as listed above.
- **Hand-drawn style notes:** the table cells are softly bordered (1 px Deep Ink hand-drawn). The Creamsicle banner has subtle directional pencil shading.
- **Common pitfalls:** using `chr1` instead of `MN908947.3` so the SARS-CoV-2 anchor is broken; forgetting that QUAL can be `.` for some callers; using a real but inconsistent example across columns (e.g., AF in INFO disagreeing with AF in sample).
- **Illustrator panel discussion:** The bioinformatics illustrator wants every value in the row to be internally consistent: AF=0.95 in INFO and AF=0.95 in sample, DP=200 in both. The medical illustrator pushes for visual hierarchy: column headers larger, data smaller, captions smallest. The UI/UX illustrator points out the table is wide and may need to wrap on smaller publication formats; the cartoonist suggests treating it as a single row designed to be panned horizontally on screen and printed at full width. The team accepts that this figure is wider than most. Final consensus: 1600 wide is correct, internally consistent values, hierarchy by font size.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

### allele-frequency-haploid-vs-diploid

- **Chapter:** `01-foundations/05-variants-and-vcf`
- **Where used:** Section that focus groups praised as the strongest writing in foundations.
- **Pedagogical purpose:** the reader should understand that AF=0.5 means very different things in human diploid versus viral haploid contexts.
- **Target dimensions:** 1400x600
- **Composition:** two named characters. Left half: a human diploid sample. Two stacked Deep Ink chromosome shapes (sister chromatid bowtie shape), with one carrying a Creamsicle highlight at the variant position. Caption: `human diploid, 1 of 2 alleles carries the variant, AF = 0.5`. Right half: a viral haploid sample. A Cream sample tube outline holding many small virion circles in Deep Ink, with about half the virions showing a Creamsicle dot (variant). Caption: `viral haploid, half the read evidence supports the variant, AF = 0.5`. A vertical Warm Grey divider between the halves.
- **Color usage:** Deep Ink for chromosomes and virions. Creamsicle for the variant alleles. Warm Grey for the divider. Cream ground.
- **Labels and callouts:** the two captions as written above; small `variant` callouts on representative chromatid and virion.
- **Hand-drawn style notes:** virions are not perfectly circular; small variation in size and slight hand-jitter. Chromosomes have soft pencil shading along their long axis. The Creamsicle highlights are crescent-shaped, not perfect dots.
- **Common pitfalls:** drawing too few virions to convey "many copies" (need at least 30); making both halves visually identical so the reader misses the conceptual contrast; using saturated red or green for the variant which violates the palette rule.
- **Illustrator panel discussion:** The medical illustrator is most engaged here; she wants the diploid chromosomes drawn as the textbook X-shape (replicated mitotic chromosomes) rather than as plain bars, because that is the canonical anatomy. The bioinformatics illustrator pushes back: diploid here means two homologous copies, not replicated sister chromatids; mitotic chromosomes are misleading. The medical illustrator concedes after the bioinformatics illustrator clarifies; they settle on two homologous chromosome bars with a centromere notch. The cartoonist contributes the "many virions in a tube" gestalt; the UI/UX illustrator approves because the visual density alone communicates the haploid-but-many concept. Final consensus: two homologous bars, a tube of many virions, conceptual contrast carried by visual density.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

### filter-flag-cartoon

- **Chapter:** `01-foundations/05-variants-and-vcf`
- **Where used:** FILTER column section; praised as a competence builder by undergrad personas.
- **Pedagogical purpose:** the reader should leave understanding that a row's FILTER column carries the caller's decision and that `PASS` is one option among several.
- **Target dimensions:** 1200x500
- **Composition:** three stacked horizontal VCF rows in tabular form. Each row shows truncated `CHROM POS REF ALT` columns and an emphasized FILTER column. Row 1: FILTER=`PASS` with a hand-drawn Deep Ink check mark. Row 2: FILTER=`ft` with a Peach warning triangle and the side annotation `failed allele-frequency threshold`. Row 3: FILTER=`sb` with a Peach warning triangle and the annotation `failed strand bias filter`. The FILTER column is highlighted with a faint Creamsicle background tint across all three rows.
- **Color usage:** Creamsicle background tint on the FILTER column. Deep Ink for check mark, row data, and PASS text. Peach for warning triangles. Warm Grey for non-FILTER row data. Cream ground.
- **Labels and callouts:** `failed allele-frequency threshold`, `failed strand bias filter`. The check mark and triangles serve as wordless symbols.
- **Hand-drawn style notes:** the warning triangles are deliberately hand-drawn, not vector. The check mark is a single confident pencil stroke.
- **Common pitfalls:** using a saturated green check (banned, traffic-light palette); failing to mention that `ft` and `sb` are Lungfish-conventional cross-caller names rather than caller-native names (the focus group flagged this exact misattribution in the iVar QUAL discussion); making the warnings too alarming.
- **Illustrator panel discussion:** The bioinformatics illustrator wants the side annotations to read `Lungfish-normalized name` somewhere so the reader knows `ft` and `sb` are unified across callers; the cartoonist worries this clutters the figure and pushes for the disambiguation to live in the prose. The UI/UX illustrator suggests a small Warm Grey footnote: `ft, sb are Lungfish cross-caller filter names`. The bioinformatics illustrator accepts. The medical illustrator focuses on the visual rhythm: three rows, three states, one teaching point. Final consensus: footnote, hand-drawn check, Peach triangles.
- **Priority:** P0
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### reference-bundle-anatomy

- **Chapter:** `02-sequences/01-importing-and-viewing`
- **Where used:** Section explaining what a reference bundle is on disk. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should recognize the canonical files inside a Lungfish reference bundle and know which Lungfish guarantees are tied to bundle structure.
- **Target dimensions:** 1400x600
- **Composition:** a hand-drawn folder icon at the upper left labeled `MN908947.3.lungfishref/`. Lines lead from the folder to four file icons arrayed across the figure: `MN908947.3.fasta`, `MN908947.3.fasta.fai`, `manifest.json`, `provenance.json`. Each file icon has a small Warm Grey caption underneath summarizing its purpose: `sequence`, `samtools faidx index`, `bundle metadata`, `network provenance`.
- **Color usage:** Creamsicle for folder and file icon outlines. Deep Ink for filenames. Warm Grey for captions. Cream ground.
- **Labels and callouts:** filenames and the four captions.
- **Hand-drawn style notes:** the folder icon has a slight droop; the file icons have a folded corner on each. None of these are vector-perfect.
- **Common pitfalls:** showing too many files (the bundle has more in practice but the figure is teaching the conceptual core); making the folder icon look like a system folder (use a hand-drawn manila tab); using `.fa` instead of `.fasta` since the Lungfish convention is `.fasta`.
- **Illustrator panel discussion:** The bioinformatics illustrator confirms the four files are the right minimal set to teach. The UI/UX illustrator notes that this figure is essentially a tree diagram and could become rigid; the cartoonist counters that the lead lines should curve gently to keep the warmth. The medical illustrator is neutral. Final consensus: four files, curved lead lines, warm captions.
- **Priority:** P1
- **Estimated production time:** 2-4 hours hand-drawn, or 30 min generation prompt + 90 min refinement

### viewport-panes

- **Chapter:** `02-sequences/01-importing-and-viewing`
- **Where used:** Tour of the sequence viewport. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should associate each named pane in the Lungfish sequence viewport with what it shows.
- **Target dimensions:** 1400x800
- **Composition:** a stylized cartoon of the viewport window with the three or four panes shown in proportion: track viewer at the top, sequence/feature panel below, optional inspector panel on the right. Each pane is drawn as a hand-bordered rectangle with a representative sketch of its contents (a tiny coverage track for the track viewer, a couple of ATG codons for the sequence panel, a list of feature attributes for the inspector). Hand-lettered labels lead from each pane to a Deep Ink caption.
- **Color usage:** Creamsicle for pane borders and example tracks. Deep Ink for labels and caption text. Warm Grey for inspector field placeholders. Cream ground (representing the app's Cream-on-light theme).
- **Labels and callouts:** `track viewer`, `sequence panel`, `feature inspector`.
- **Hand-drawn style notes:** the panes have visibly hand-drawn borders. The contents are sketched rather than rendered; pixel-perfect screenshot fidelity is the wrong target.
- **Common pitfalls:** drawing the panes so faithfully that the figure becomes a screenshot rather than a cartoon (the manual already has annotated screenshots for that role); using non-brand colors for the example tracks.
- **Illustrator panel discussion:** The UI/UX illustrator is most engaged here; she emphasizes that this is a wayfinding cartoon, not a literal app render. The cartoonist agrees: the goal is a memorable mental map, not a re-creation of the chrome. The medical illustrator suggests a slightly out-of-proportion drawing where the most-used pane is visually dominant; the bioinformatics illustrator approves, suggesting the track viewer should dominate because that is where users land first. Final consensus: stylized panes, oversize track viewer, hand-bordered.
- **Priority:** P1
- **Estimated production time:** 3-4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

### ncbi-accession-anatomy

- **Chapter:** `02-sequences/02-downloading-from-ncbi`
- **Where used:** Section decomposing an NCBI accession. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should be able to take an arbitrary accession (`MN908947.3`, `NC_045512.2`, `SRR12345`) and identify the prefix, number, and version, and pick the right fetch path.
- **Target dimensions:** 1400x500
- **Composition:** the accession `MN908947.3` displayed at oversized scale in IBM Plex Mono near the top. Three Creamsicle callouts lead from the components: from `MN` to a Deep Ink label `prefix (database, type)`; from `908947` to `accession number`; from `.3` to `version`. Below, three small file icons or path captions show what each component selects: prefix → INSDC database (GenBank, RefSeq), number → record, version → snapshot. A short footer caption: `prefix tells you which fetch path. version tells you which snapshot.`
- **Color usage:** Deep Ink for the accession string. Creamsicle for callouts. Warm Grey for the footer caption. Cream ground.
- **Labels and callouts:** `prefix (database, type)`, `accession number`, `version`, `prefix tells you which fetch path. version tells you which snapshot.`
- **Hand-drawn style notes:** callouts curve gently. The three component labels fan out evenly.
- **Common pitfalls:** using an SRA accession (`SRR...`) where the version semantics differ; failing to gloss `INSDC` (which the focus group flagged needs an inline definition); making the callouts overlap each other.
- **Illustrator panel discussion:** The bioinformatics illustrator pushes for showing both `MN908947.3` and `NC_045512.2` because the chapter teaches the difference between INSDC primary and RefSeq curated; the cartoonist objects on the five-element rule and proposes a sequel figure if needed. The compromise is to keep this figure single-accession and add a tiny Warm Grey side note: `RefSeq accessions start with NC_, NM_, etc.` The UI/UX illustrator approves the side note. Final consensus: single accession, side note for the second pattern.
- **Priority:** P1
- **Estimated production time:** 2-3 hours hand-drawn, or 30 min generation prompt + 90 min refinement

### msa-column-homology

- **Chapter:** `02-sequences/04-msa-and-trees`
- **Where used:** Section introducing multiple sequence alignment. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should see, in one frame, how MAFFT inserts gaps so homologous bases share a column.
- **Target dimensions:** 1400x600
- **Composition:** two stacked panels. Top panel: three short sequences listed as raw, unaligned, varying lengths, each on its own row in IBM Plex Mono. Bottom panel: the same three sequences with MAFFT-style gap characters inserted so homologous columns line up; matching columns are highlighted with a faint Creamsicle background. A curved Creamsicle "alignment" arrow between the panels.
- **Color usage:** Deep Ink for all sequence text. Creamsicle for column highlights and the connecting arrow. Cream ground.
- **Labels and callouts:** `before MAFFT`, `after MAFFT`, optional `homologous columns share a column` annotation.
- **Hand-drawn style notes:** the gap characters are hand-drawn dashes with slight variation. The column-highlight rectangles have soft edges.
- **Common pitfalls:** picking sequences that align trivially (no insertions/deletions to demonstrate); using too many sequences (focus group expects ≤3 here); failing to mark which columns are homologous.
- **Illustrator panel discussion:** The bioinformatics illustrator wants real biology: three short SARS-CoV-2 spike fragments rather than ACGT alphabet noise. The cartoonist warns that real biological sequences will be harder to read; she pushes for a stylized 12-base example with a couple of insertion/deletion events that clearly motivate the gap insertion. The medical illustrator and UI/UX illustrator side with the cartoonist on legibility grounds. The bioinformatics illustrator concedes if the surrounding prose links to real MSA fixtures. Final consensus: stylized 12-base example, real-MSA pointer in prose.
- **Priority:** P1
- **Estimated production time:** 3 hours hand-drawn, or 45 min generation prompt + 90 min refinement

### tree-anatomy

- **Chapter:** `02-sequences/04-msa-and-trees`
- **Where used:** Phylogenetic tree section. **(promote to illustrations.yaml)**
- **Pedagogical purpose:** the reader should label tips, internal nodes, branches, branch lengths, and bootstrap support values on a rectangular phylogram.
- **Target dimensions:** 1400x700
- **Composition:** a rectangular phylogram with five tips at the right edge, internal nodes branching back to a single root at the left. Branch lengths visibly varied. Three branch internal nodes labeled with bootstrap values (e.g., `0.95`, `0.78`, `1.00`) on a small Creamsicle pill. Hand-lettered Deep Ink callouts identify: `tip`, `internal node`, `branch length`, `bootstrap support`. The tips bear short hypothetical sample names in IBM Plex Mono.
- **Color usage:** Deep Ink for the tree skeleton. Creamsicle for callouts and bootstrap pills. Warm Grey for tip names. Cream ground.
- **Labels and callouts:** `tip`, `internal node`, `branch length`, `bootstrap support`, plus five hypothetical tip names like `sample-A`, `sample-B`, etc.
- **Hand-drawn style notes:** branch corners are slightly imperfect; the tree breathes. Bootstrap pills are hand-drawn ellipses, not perfect ovals.
- **Common pitfalls:** drawing a circular tree (the figure should be rectangular); using fictitious tip names that look real (use clearly hypothetical placeholders); putting bootstrap values directly on branches without pills, which reduces legibility.
- **Illustrator panel discussion:** The bioinformatics illustrator wants the tree topology to be biologically plausible (no zero-length branches, no impossibly long terminal branches); the cartoonist reminds the panel this is a teaching figure not a real phylogeny and nudges toward simple. The medical illustrator suggests color-coding tips by clade; the UI/UX illustrator pushes back as too many elements. Final consensus: monochrome tree skeleton, callouts for the four labeled features, hypothetical sample names.
- **Priority:** P1
- **Estimated production time:** 3-4 hours hand-drawn, or 45 min generation prompt + 120 min refinement

### classification-question

- **Chapter:** `06-classification/01-what-is-classification`
- **Where used:** Top of the classification chapter.
- **Pedagogical purpose:** the reader should see classification as input → tool → taxonomic breakdown, and recognize that the tool is one of several alternatives.
- **Target dimensions:** 1400x500
- **Composition:** three named characters left to right. Left: a small file icon labeled `reads.fastq.gz`. Center: a Creamsicle box labeled `classifier (Kraken2 / EsViritu / TaxTriage / NAO-MGS)`. Right: a sunburst with three top-level wedges (`bacteria`, `virus`, `host`) and a couple of subdivisions in each. Two Creamsicle arrows connect the elements. The eye anchor is the classifier box at center.
- **Color usage:** Creamsicle for the box and arrows. Deep Ink for labels. Cream for the file icon ground. The four sunburst wedges may use the four classification accent colors (Kraken2 blue, EsViritu green, TaxTriage purple, NAO-MGS amber) at 70 percent saturation, but only if the sunburst is teaching tool-specific outputs; otherwise restrict to Creamsicle, Peach, and Warm Grey shades.
- **Labels and callouts:** `reads.fastq.gz`, `classifier (Kraken2 / EsViritu / TaxTriage / NAO-MGS)`, `bacteria`, `virus`, `host`.
- **Hand-drawn style notes:** the sunburst wedges are not perfect circular arcs; the arcs wobble slightly. Arrows curve.
- **Common pitfalls:** making the sunburst too complex (more than ~6 wedges total); using saturated traffic-light colors; making the classifier box look like a sealed system rather than an alternative-among-alternatives.
- **Illustrator panel discussion:** This is the only figure where the panel agrees complementary colors are warranted. The bioinformatics illustrator wants the four classifiers visually distinct because the chapter teaches comparing tools; the cartoonist insists the four accent colors (blue, green, purple, amber) be desaturated and rendered with colored-pencil shading so they sit in the warm aesthetic. The UI/UX illustrator points out the sunburst is the part most likely to be misread; she wants the wedges large enough that the labels fit without truncation. The medical illustrator approves the three-character composition. Final consensus: complementary colors used judiciously in the sunburst, warm rendering, large wedges.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

### assembly-vs-mapping

- **Chapter:** `07-assembly/01-when-to-assemble`
- **Where used:** Top of the assembly chapter, contrasting the two strategies.
- **Pedagogical purpose:** the reader should see at a glance that mapping requires a reference and assembly does not, and that assembly produces contigs from read overlaps.
- **Target dimensions:** 1400x600
- **Composition:** two named characters in a left/right split. Left: a Deep Ink reference backbone with Creamsicle reads pinned to it via short Creamsicle arrows. Caption: `mapping`. Right: a stack of overlapping Creamsicle reads at the top, an "overlap then extend" middle layer, and a few longer Creamsicle contigs at the bottom. Caption: `assembly`. A Warm Grey vertical divider between the halves.
- **Color usage:** Deep Ink for the reference. Creamsicle for reads, arrows, and contigs. Warm Grey for the divider. Cream ground.
- **Labels and callouts:** `mapping`, `assembly`, optional `reference required` and `no reference required` sub-captions.
- **Hand-drawn style notes:** the assembly side has visibly nested overlap layers, drawn so the eye can trace one read up into the contig it joined.
- **Common pitfalls:** making both sides look the same (defeats the contrast); failing to convey the overlap-then-extend mechanic; drawing the contigs as separate from the source reads (they should look like consolidations).
- **Illustrator panel discussion:** The bioinformatics illustrator wants the assembly side to faithfully represent overlap-layout-consensus rather than de Bruijn graphs because de Bruijn would be impossible to render simply; the cartoonist agrees. The medical illustrator suggests the contigs at the bottom of the assembly side be visibly thicker than individual reads to convey "consolidated evidence." The UI/UX illustrator approves the left/right split as cognitively cheap. Final consensus: clear overlap-to-contig flow, thicker contigs, no graph theory.
- **Priority:** P0
- **Estimated production time:** 4 hours hand-drawn, or 60 min generation prompt + 120 min refinement

---

## C. Summary table

| ID | Chapter | Priority | Status | Estimated time |
|---|---|---|---|---|
| linear-vs-circular-genomes | 01-foundations/01 | P0 | planned | 2 h |
| position-coordinates | 01-foundations/01 | P0 | planned | 2 h |
| variant-notation | 01-foundations/01 | P0 | planned | 3 h |
| fastq-record-anatomy | 01-foundations/02 | P0 | planned | 3 h |
| paired-end-reads | 01-foundations/02 | P0 | planned | 2 h |
| phred-quality-bar | 01-foundations/02 | P0 | planned | 3 h |
| platform-read-length-comparison | 01-foundations/02 | P1 | planned | 2-4 h |
| amplicon-vs-shotgun | 01-foundations/03 | P0 | planned | 4 h |
| primer-scheme-diagram | 01-foundations/03 | P0 | planned | 4 h |
| primer-trim-soft-clip | 01-foundations/03 | P0 | planned | 3 h |
| read-mapping-cartoon | 01-foundations/04 | P0 | planned | 4 h |
| coverage-histogram | 01-foundations/04 | P0 | planned | 3 h |
| pileup-view | 01-foundations/04 | P0 | planned | 3 h |
| cigar-anatomy | 01-foundations/04 | P0 | planned | 4 h |
| vcf-row-anatomy | 01-foundations/05 | P0 | planned | 4 h |
| allele-frequency-haploid-vs-diploid | 01-foundations/05 | P0 | planned | 4 h |
| filter-flag-cartoon | 01-foundations/05 | P0 | planned | 3 h |
| reference-bundle-anatomy | 02-sequences/01 | P1 | planned | 2-4 h |
| viewport-panes | 02-sequences/01 | P1 | planned | 3-4 h |
| ncbi-accession-anatomy | 02-sequences/02 | P1 | planned | 2-3 h |
| msa-column-homology | 02-sequences/04 | P1 | planned | 3 h |
| tree-anatomy | 02-sequences/04 | P1 | planned | 3-4 h |
| classification-question | 06-classification/01 | P0 | planned | 4 h |
| assembly-vs-mapping | 07-assembly/01 | P0 | planned | 4 h |

**Totals.** P0 illustrations: 18, ~58 hours hand-drawn or ~30 hours of generation-and-refinement work. P1 illustrations: 6, ~17 hours hand-drawn or ~10 hours generation-and-refinement.

**Sequencing for production.** Ship the foundations P0 set (chapters 1-5 of foundations) before the manual goes public; these are the figures referenced most heavily by the focus-group-praised teaching points. The classification and assembly P0s anchor their respective chapters' opening pages, so they ship in the same wave. P1 illustrations land in the first revision after the manual goes public; none of them block initial publication, but each unblocks a chapter that focus groups identified as competence-building.

**Promotion to `illustrations.yaml`.** Seven illustrations are currently only declared in chapter frontmatter and need to be promoted with full briefs into the canonical `illustrations.yaml`: `cigar-anatomy`, `platform-read-length-comparison`, `variant-notation`, `reference-bundle-anatomy`, `viewport-panes`, `ncbi-accession-anatomy`, `msa-column-homology`, `tree-anatomy`. The briefs in this document supersede the shorter chapter-frontmatter sketches and should be the source of truth.
