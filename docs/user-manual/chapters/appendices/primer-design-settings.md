---
title: Primer Design Settings
chapter_id: appendices/primer-design-settings
audience: power-user
prereqs: [10-primer-design/01-what-is-primer-design]
estimated_reading_min: 16
task: Look up every control of the PCR Primer Design dialog, engine by engine, with its default, what it does, and its command-line flag.
tags: [reference, primer-design, primer3, primalscheme, olivar, varvamp, settings]
tools: [primer3, primalscheme3, olivar, varvamp]
entry_points:
  - "Tools > PCR Primer Design > Primer3…"
  - "Tools > PCR Primer Design > PrimalScheme…"
  - "Tools > PCR Primer Design > Olivar…"
  - "Tools > PCR Primer Design > varVAMP…"
shots: []
illustrations: []
glossary_refs: [degenerate-base, design-reference, gc-clamp, gc-content, iupac-ambiguity-code, melting-temperature, oligo, primer, primer-dimer, primer-pool, probe, blast, msa, hydrolysis-probe, qpcr]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) runs four primer design engines from one dialog, **Tools > PCR Primer Design**, and between them they expose about a hundred controls. The Primer Design chapters carry the ones a first design touches. This appendix carries all of them, engine by engine, so a reader tuning a design has one place to look.

Each entry names the control as the dialog labels it, says what it does, gives the default and why it is the default, says when to change it, and names the command-line flag. Where an engine's own documentation sets a value, the entry says so, because LGE passes that engine's value through rather than inventing one. Positions and lengths are 1-based and inclusive, as [Counting from one and from zero](../02-sequences/03-extracting-and-comparing.md#counting-from-one-and-from-zero) describes for the manual as a whole.

Three groups of controls are shared. The input section holds **Records** and **Template row**, the choice of which sequences become templates. "Design settings" and "Scheme settings" hold the assay or mode and the product sizes. "Advanced settings" holds everything else and stays collapsed until you open it. Every engine also has **Analysis name**, which names the `.lungfishprimeranalysis` bundle LGE writes into the project's `Analyses` folder, defaults to "Primer analysis" with a number added when that name is taken, and refuses a name already used in the project. On the command line the name is the last part of the `--output` path.

## Primer3

Primer3 designs one primer pair, or a pair plus a [hydrolysis probe](../../GLOSSARY.md#hydrolysis-probe), on one template at a time. [Designing a PCR Assay](../10-primer-design/02-designing-a-pcr-assay.md) and [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md) run it.

### Inputs and the assay

**Records.** Chooses which records of a FASTA file or reference bundle become templates. The default ticks every record, because LGE cannot guess which one you want. Untick the rest for a design on one sequence, since Primer3 designs each ticked record separately. On the command line this is `--fasta-record`, repeated once per record.

**Template row.** Chooses which row of a [multiple sequence alignment](../../GLOSSARY.md#msa) Primer3 designs on. There is no default, and Run stays disabled until you pick a row, because target positions and reported positions are counted on that row. On the command line this is `--msa-template`.

**Assay.** Chooses the rule set and loads its values into every field below, which you may still edit. The default is "PCR primers". The two qPCR choices replace the product range, primer lengths, melting temperatures, GC limits and complementarity thresholds, so pick the assay before you adjust anything. On the command line this is `--assay`, with `pcr`, `qpcr-dye` or `qpcr-probe`.

**Require binding sites conserved across all alignment rows.** Stops Primer3 from placing an [oligo](../../GLOSSARY.md#oligo) over any alignment column where the rows disagree, where a row has a gap, or where a row carries an ambiguous base. It is on by default whenever an alignment is among the inputs, because a primer on a variable column mismatches some of the aligned sequences. Turn it off to see the best pair for the template row alone. On the command line this is `--binding-site-policy`, with `exclude-variable-and-gapped-columns` for on and `template-only` for off.

The three assays differ as follows. Every value is Primer3's own unless the table gives a number, and a blank cell in the dialog means Primer3's built-in value is used.

| Rule | PCR primers | qPCR, dye | qPCR, probe |
|---|---|---|---|
| Product size (bp) | 100 to 400 | 70 to 150 | 70 to 150 |
| Primer length (nt), min/opt/max | 18/20/27 | 18/20/24 | 18/20/24 |
| Primer Tm (°C), min/opt/max | 57/60/63 | 58/60/62 | 58/60/62 |
| Primer GC (%) | 20 to 80 | 40 to 60 | 40 to 60 |
| Pair Tm difference, 3′-end G/C in the last five, GC clamp, poly-X | Primer3's own (100 °C, 5, 0, 5) | 1 °C, 2, 1, 4 | 1 °C, 2, 1, 4 |

### Product and target

**Product minimum (bp)** and **Product maximum (bp)** set the shortest and longest product Primer3 may return, counted from the first base of the forward primer to the last base of the reverse primer. Raise both together when the product must span a long target, as a design across two exons does. On the command line these are `--product-size-min` and `--product-size-max`.

**Amplify a specific region** turns on a target every product must contain, with the forward primer before it and the reverse primer after it. It is off by default, which lets Primer3 place the product anywhere on the template. **Target start** and **Target end** set the first and last base of that target on the template's own bases, and the end may not be smaller than the start. A target longer than the product maximum is refused before the run. The switch itself has no flag, because giving `--target-start` and `--target-end` turns it on.

### Primer rules under Advanced settings

**Primer length (nt).** Sets the minimum, optimum and maximum primer length. Allow shorter primers when a stretch is GC-rich and every candidate runs too hot, and longer ones when a stretch is AT-rich and a short primer cannot reach the melting temperature. On the command line these are `--primer-min-size`, `--primer-opt-size` and `--primer-max-size`.

**Primer melting temperature (°C).** Sets the minimum, optimum and maximum [melting temperature](../../GLOSSARY.md#melting-temperature) for each primer, so both primers of a pair work at one annealing temperature. Change the range to match a cycling protocol that anneals elsewhere, or to admit a primer whose 3′ end you have anchored on a chosen position. On the command line these are `--primer-min-tm`, `--primer-opt-tm` and `--primer-max-tm`.

**Minimum GC (%)** and **Maximum GC (%)** bound the share of G and C bases in a primer. The PCR defaults of 20 and 80 leave the melting-temperature rules to do most of the work, and the qPCR presets tighten them to 40 and 60. Raise the maximum toward 65 or 70 in GC-rich sequence such as MHC exons, then prove efficiency with a standard curve. On the command line these are `--primer-min-gc` and `--primer-max-gc`.

The four fields under "Assay rules (blank keeps Primer3's default)" are **Pair Tm difference max (°C)**, the largest melting-temperature gap allowed between the two primers, **3′-end G/C max (last 5 nt)**, how many of the last five bases may be G or C, **GC clamp (nt)**, how many G or C bases must sit at the very 3′ end, and **Poly-X max (nt)**, the longest run of one repeated base. Their flags are `--pair-max-tm-difference`, `--primer-max-end-gc`, `--primer-gc-clamp` and `--primer-max-poly-x`. A GC clamp of 1 and a discriminating position that carries an A or a T are mutually exclusive, so set the clamp to 0 when you anchor a 3′ end on such a column.

The four fields under "Complementarity thresholds (duplex Tm, °C)" each cap how stably a primer may pair with itself or its partner, measured as the duplex melting temperature. **Self, any** and **Self, 3′ end** cover one primer against a copy of itself, and **Pair, any** and **Pair, 3′ end** cover the two primers against each other. The 3′-end pair is the one a polymerase can extend into a [primer dimer](../../GLOSSARY.md#primer-dimer), which is why the qPCR presets drop it furthest. The flags are `--primer-max-self-any-th`, `--primer-max-self-end-th`, `--pair-max-compl-any-th` and `--pair-max-compl-end-th`.

**Candidate pairs.** Sets how many pairs Primer3 returns per template. The default is 5, enough for a choice without a long list. Raise it when you expect to discard several pairs after checking them against other sequences. On the command line this is `--pair-count`.

### The hydrolysis probe window

The "Hydrolysis probe (internal oligo)" group appears only for the probe assay. **Probe melting temperature (°C)** defaults to 64, 67 and 70, **Probe length (nt)** to 20, 25 and 30, and **Probe GC (%)** to 40, 60 and 80. Their flags are `--probe-min-tm` and its optimum and maximum partners, `--probe-min-size` and partners, and `--probe-min-gc` and partners.

**Probe Tm at least this far above the primers (°C).** Raises the probe's minimum melting temperature to the highest primer melting temperature plus this figure, so the probe is bound before extension reaches it. The default is 5, the lower bound varVAMP enforces, and it matters because the 64 °C probe floor and the 62 °C primer ceiling would otherwise allow a gap of 2 °C. With the 62 °C ceiling the effective probe minimum becomes 67 °C, which the analysis records. Enter 0 to use the window exactly as typed. On the command line this is `--probe-min-tm-offset-over-primers`.

Two probe rules are set for you, and the probe group shows them as the fields "Probe poly-X max (nt)" and "Probe 5′ must-match pattern", where you can change them. Runs of one base in a probe are capped at 3, tighter than the primers' 4, because a GC-rich probe with a run of four G stacks into a structure that both quenches the reporter dye and resists melting. The probe may not begin with a G at its 5′ end, since a G next to the reporter quenches it. On the command line these are `--probe-max-poly-x` and `--probe-must-match-five-prime`, whose value `hnnnn` means the first base may be A, C or T.

### Keeping an oligo you chose

The "Keep these oligos (design the rest around them)" group lets you fix part of an assay and have Primer3 design the rest. **Forward primer**, **Reverse primer (as ordered)** and **Probe** each take one sequence written 5′ to 3′ as you would order it, and each must occur in the template. **Forward 3′ end** and **Reverse 3′ end** instead take a template position that a primer's last base must land on, which is how you put a 3′ end on a column that separates your targets from the sequences you must not detect. Leave a field blank to let Primer3 choose that oligo. The flags are `--left-primer`, `--right-primer`, `--probe`, `--force-left-end` and `--force-right-end`. [Testing the lineage assay for specificity](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) works through a design built this way.

## PrimalScheme

PrimalScheme designs tiled two-pool schemes and handles variation by adding one exact-match oligo per variant at a site. [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) runs it. Its size fields, **Output grouping** and **Primer pools** are covered there.

**Minimum overlap (bp).** Sets how many bases neighbouring amplicons must share. The default is 10, enough to join reads across a join. It appears only with one scheme per alignment, and a combined design always uses 10. On the command line this is `--min-overlap`.

**Minimum base frequency.** Sets how common a base must be at a site before PrimalScheme makes an oligo for it. The default is 0, so every variant in the alignment gets an oligo. Raise it, for example to 0.1, to drop oligos for variants carried by one or two sequences, accepting that those sequences will carry a mismatch. On the command line this is `--minimum-base-frequency`.

**CPU cores.** Sets how many processor cores PrimalScheme uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a large alignment to finish sooner. On the command line this is `--core-count`.

**Dimer score threshold.** Sets how strong an interaction between two oligos may be before PrimalScheme refuses to put them in one pool. The default is -26, PrimalScheme's own value on its own scale, where a more negative number means a stronger interaction is tolerated. Change it only when a design fails because too many candidate pairs are refused. On the command line this is `--dimer-score`.

**Check the primer mispriming database.** Checks each candidate against a database PrimalScheme builds from the sequences you supplied, for other places in those sequences where the primer could bind and make an unwanted product. It is on by default. It knows nothing about genes you did not include, so it is not a paralog check. Turn it off only to test whether it is why a design fails. On the command line, off is `--disable-matchdb`.

**Backtrack when extending the scheme.** Lets PrimalScheme revisit earlier amplicon choices when it cannot place the next one. It is off by default, which is faster. Turn it on when a design stops short of the end of the alignment. On the command line this is `--backtrack`.

**Ignore unknown bases (N).** Leaves `N` bases out of the site sequences PrimalScheme collects. It is off by default. Turn it on when some sequences carry runs of `N` from low-quality sequencing. On the command line this is `--ignore-n`.

**Use high-GC design settings.** Switches PrimalScheme to its own settings for GC-rich targets. It is off by default. Try it when a GC-rich target leaves gaps under the standard settings. On the command line this is `--high-gc`.

**"Treat uncovered alignment ends as missing observations".** Tells PrimalScheme that a sequence stopping before the end of the alignment has no data there rather than a gap that counts against a primer. It is on by default, so shorter sequences do not block sites near the ends, and missing data never counts as a match. Turn it off only to reproduce a design made under the older behaviour. On the command line this is `--terminal-gap-policy`, with `observed-only` for on and `legacy` for off.

**Choose verified executable….** Runs a PrimalScheme program you select instead of the one the plugin pack installed, shown as "Managed runtime (legacy defaults)" until you pick one. Leave it alone unless a developer asks you to test a build. On the command line this is `--primalscheme3-path`.

A caption in the same group states a fact rather than a setting. PrimalScheme writes its coordinates on the first row of the alignment, so put the sequence you want coordinates on first when you build the alignment. PrimalScheme also accepts a nominal amplicon size only between 100 and 2,000 bases.

### Combined panels

Six controls appear only with "Combined scheme from selected MSAs", which designs one panel across several alignments. **Panel selection** either weights every position equally, the default, or favours amplicons containing more variation, and neither mode guarantees even amplification. **Maximum panel amplicons** and **Maximum per MSA** cap the panel and are blank by default. **Allow bounded dimer salvage** runs the strict panel first and then retries with relaxed interaction limits, which are search budgets rather than safety thresholds. **Choose parent output…** starts a follow-up design that fills the gaps of an earlier combined panel, and "Generate bounded candidates for uncovered regions" produces candidates for those gaps, with defaults of 2,000 anchors and 1,000 pair checks per alignment. On the command line these are `--panel-mode`, `--max-amplicons`, `--max-amplicons-per-msa`, `--legacy-salvage`, `--gap-completion-parent` and `--gap-expansion`.

## Olivar

Olivar designs tiled two-pool schemes by scoring every base for risk and placing primers where the risk is lowest. Every control except the amplicon sizes lives under "Advanced settings", most of them in a group named "Olivar native settings". Olivar refuses a minimum amplicon size below 120 bases.

**CPU workers.** Sets how many processor cores Olivar uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a long alignment. On the command line this is `--workers`.

**Minimum variant frequency (--min-var).** Sets how common a difference between the aligned sequences must be before Olivar records it as a variant and treats that base as risky. The default is 0.01, Olivar's own value, so on twelve sequences even one differing allele counts. Raise it toward 0.1 to ignore differences carried by a single sequence. On the command line this is `--minimum-variant-frequency`.

**Maximum primer length.** Sets the longest primer Olivar may build. The default is 36 bases, Olivar's own value, which is long because Olivar extends a primer until its binding reaches the required free energy. Lower it when your supplier charges by length. On the command line this is `--maximum-primer-length`.

**Minimum complexity.** Rejects primers whose sequence is too repetitive, on a scale from 0 to 1. The default is 0.4, Olivar's own value, which excludes runs and simple repeats. Raise it when a design returns primers full of repeats. On the command line this is `--minimum-complexity`.

**Design degenerate oligos.** Lets Olivar build primers with [ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code) instead of one exact sequence per site. It is off by default. Turn it on when too many alleles mismatch the plain primers, and expect the sensitivity and combination risk weights to start acting, since Olivar sets both to zero in plain mode. On the command line this is `--degenerate`.

**Avoid variants at binding sites.** Throws away any candidate with a variant in the last five bases at its 3′ end. It is off by default because, as Olivar's own documentation warns, turning it on when many variants are recorded leaves very few candidates. Turn it on for a target with only a few known differences. On the command line this is `--check-variants`.

**Minimum GC fraction** and **Maximum GC fraction** bound the share of G and C bases in a primer. The defaults are 0.2 and 0.75, Olivar's own values, written as fractions here while Primer3 and varVAMP use percentages. Narrow them toward 0.4 and 0.6 when primers bind unevenly. On the command line these are `--minimum-gc` and `--maximum-gc`.

**Temperature (°C).** Sets the annealing temperature Olivar assumes when it works out how strongly a primer binds. The default is 60, the temperature most protocols use. Change it only to match a protocol that anneals elsewhere. On the command line this is `--temperature-c`.

**Salinity (M).** Sets the concentration of monovalent salt Olivar assumes, in moles per litre, because salt changes binding strength. The default is 0.18, Olivar's own value. Change it only for a reaction buffer you know differs. On the command line this is `--salinity-m`.

**Maximum primer-target binding ΔG (--dG-max).** Sets the free energy in kilocalories per mole a primer's binding to its own target must reach, which is how Olivar bounds primer length and stability. The default is -11.8, Olivar's own value, and a more negative number means stronger binding. It is not a primer-dimer threshold, and the caption beneath it says so. Leave it alone unless Olivar's own documentation guides you otherwise. On the command line this is `--maximum-dimer-delta-g`.

**Random seed.** Fixes the starting point of Olivar's random search, so the same inputs give the same design. The default is 10, Olivar's own value. Change it to see whether a different search finds a better layout, and record the value you used. On the command line this is `--seed`.

**Search effort.** Multiplies how many candidate layouts Olivar tries. The default is 1. Raise it to 2 or more when coverage falls short, at the cost of a longer run. On the command line this is `--effort`.

**Native risk weights.** Six fields, Extreme GC, Low complexity, Non-specificity, Variation, Sensitivity and Combination, set how much each kind of risk counts when Olivar scores the target. All six default to 1. Raise Variation to push primers away from variable sites, or Non-specificity once you have given Olivar something to screen against, and leave Sensitivity and Combination alone while degenerate design is off. On the command line these are `--risk-extreme-gc`, `--risk-low-complexity`, `--risk-non-specificity`, `--risk-variation`, `--risk-sensitivity` and `--risk-combination`.

## varVAMP

varVAMP builds a consensus of the alignment with [degenerate bases](../../GLOSSARY.md#degenerate-base) and designs on it. Its **Design mode**, **Cumulative consensus threshold**, amplicon sizes, **Maximum primer ambiguities** and **Tiled overlap (bp)** are covered in [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md), and its qPCR controls in [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md).

**Scheme name.** Names the scheme inside varVAMP's own output, which is where oligo names such as `varVAMP_0_LEFT` come from. The default is "varVAMP". Change it to tell two designs apart in an order sheet. On the command line this is `--scheme-name`.

**Reported assays (blank = native).** Caps how many single-amplicon assays varVAMP reports, and appears only in single-amplicon mode. It is blank by default, which keeps varVAMP's own count. On the command line this is `--report-count`.

**Compatible-primer input path (optional).** Points at a file of primers a new design must not interact with, so a second scheme can share a tube with one you already ordered. It is blank by default. On the command line this is `--compatible-primers`.

**Terminal masking threshold.** Decides when a gap at the very start or end of the alignment is masked. The default is 0.5, so such a base is masked only when more than half the sequences are missing it. On the command line this is `--terminal-masking-threshold`.

### Primer constraints

The "Primer constraints" group repeats varVAMP's own primer rules, and LGE sends every one of them on every run, so a value you change here is a value varVAMP obeys. Length is 18, 21 and 24 bases as minimum, optimum and maximum, melting temperature 56, 60 and 63 °C, and GC content 35, 50 and 65 percent. **Maximum homopolymer** and **Maximum dinucleotide repeats** are both 4, **Hairpin threshold** is 47 °C, **Maximum dimer Tm** is 35 °C, and **Unambiguous 3′ bases** is 3, so the last three bases of a primer never carry an ambiguity code. **GC bases at primer 3′ minimum** and **maximum** are 1 and 3, which is varVAMP's [GC clamp](../../GLOSSARY.md#gc-clamp) rule, and **End overlap** is 5. Each field's flag has the same shape as its label, such as `--primer-tm-min`, `--primer-gc-end-max` and `--primer-maximum-poly-x`, and [Primer schemes and primer design](cli-reference.md#primer-schemes-and-primer-design) in the CLI Reference lists them.

### qPCR probe constraints

The "qPCR probe constraints" group appears only in qPCR mode and works the same way. Probe length is 20, 25 and 30 bases, probe melting temperature 64, 67 and 70 °C, and probe GC content 40, 60 and 80 percent, with only the GC fields showing their unit on screen. **GC bases at probe end** runs 0 to 4. **Probe/primer Tm difference** runs 5 to 10 °C, which varVAMP enforces, unlike Primer3's window. **Probe distance** runs 4 to 15 bases, the gap between the probe and the primer on its own strand. **Amplicon GC** runs 40 to 60 percent, **Amplicon deletion cutoff** is 4, so a region is folded only when its deletions are shorter than 4 bases, and **qPCR primer difference** is 2 °C, the gap allowed between the two primers.

### Chemistry and masking defaults

The "Chemistry and masking defaults" disclosure holds the reaction conditions varVAMP assumes when it predicts melting temperatures. They are 100 and 2 millimolar for monovalent and divalent cations, 0.8 millimolar for the deoxynucleotides the polymerase adds, and 15 nanomolar primer. Change them only to match a buffer you know differs, and record the change, because every melting temperature in the result depends on them. On the command line these are `--pcr-monovalent-concentration`, `--pcr-divalent-concentration`, `--pcr-dntp-concentration` and `--pcr-dna-concentration`.

## Off-target screening

Olivar and varVAMP can check their candidates against sequences the assay must not amplify, and the "Off-target screening" group is the same for both. **Add Sequences to Screen Against…** opens a chooser for alignment bundles, reference bundles or nucleotide FASTA files, and LGE builds the [BLAST](../../GLOSSARY.md#blast) database from them with `makeblastdb` and records the sequences in provenance. A file of another kind is skipped with a message naming it. With nothing chosen, the line reads that candidates are not checked for off-targets. On the command line this is `--screen-against`, repeatable.

The "Use an existing BLAST database instead" disclosure holds **Local nucleotide BLAST database prefix** for a database you built outside LGE, whose component files are copied into the analysis. The two routes are mutually exclusive, and each dims the other. On the command line this is `--blast-database`.

A screen reports off-targets rather than designing around them. When no better candidate exists in a region, varVAMP keeps the assay and adds a warning, as [Testing the lineage assay for specificity](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) shows.

## Next

Go back to [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md) for the ideas behind these controls, or to [Primer Scheme Bundles](primer-schemes.md) for the bundle a saved tiled scheme writes.
