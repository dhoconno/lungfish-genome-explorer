---
title: Primer Design Settings
chapter_id: appendices/primer-design-settings
audience: power-user
prereqs: [10-primer-design/01-what-is-primer-design]
estimated_reading_min: 17
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
glossary_refs: [bundle, degenerate-base, design-reference, gc-clamp, gc-content, iupac-ambiguity-code, melting-temperature, oligo, primer, primer-dimer, primer-pool, probe, blast, msa, hydrolysis-probe, qpcr, reverse-complement, gap, provenance, mhc]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) runs four primer design engines, [Primer3](https://github.com/primer3-org/primer3), [PrimalScheme](https://github.com/dhoconno/primalscheme3-lge), [Olivar](https://github.com/treangenlab/Olivar) and [varVAMP](https://github.com/jonas-fuchs/varVAMP), from **Tools > PCR Primer Design**, and between them they expose more than a hundred controls. This appendix carries the controls the Primer Design chapters leave out, engine by engine, and names the chapter for each control a chapter already explains. If your target is GC-rich, start at [Tuning for a GC-rich target](#tuning-for-a-gc-rich-target).

Each entry names the control as the dialog labels it, says what it does, and gives its default, when to change it and its command-line flag. Where an engine's own documentation, linked above, sets a value, the entry says so, because LGE passes that value through. Positions and lengths are 1-based and inclusive, as [Counting from one and from zero](../02-sequences/03-extracting-and-comparing.md#counting-from-one-and-from-zero) describes.

The input section, **Selected project inputs**, lists what was selected in the sidebar, and for Primer3 it also holds **Records** and **Template row**. "Design settings" and "Scheme settings" hold the assay or mode, the sizes and a few other settings every design needs, and "Advanced settings" holds the rest and stays collapsed until you open it. Every engine also has **Analysis name**, which names the `.lungfishprimeranalysis` [bundle](../../GLOSSARY.md#bundle), a folder LGE treats as one item, in the project's `Analyses` folder. It defaults to "Primer analysis" with a number added when that name is taken, and the dialog refuses a name already in use.

On the command line each engine is its own command, `lungfish-cli primers design primer3`, `primalscheme3`, `olivar` or `varvamp`, which [Finding the program](cli-reference.md#finding-the-program) shows how to run. Give it `--project` with `--name`, or `--output` with the path of a new bundle.

## Tuning for a GC-rich target

A GC-rich target, such as the macaque [MHC](../../GLOSSARY.md#mhc) gene *Mamu-A1* at about 60 percent G and C, often outgrows the defaults. G and C pair more strongly than A and T, so a GC-rich primer reaches a given [melting temperature](../../GLOSSARY.md#melting-temperature) at a shorter length, folds on itself more readily and holds on to partial matches. The table gives each engine's controls and the direction to move them.

| Engine | Controls | Direction for a GC-rich target |
|---|---|---|
| Primer3 | **Maximum GC (%)**, **Primer melting temperature (°C)**, **Primer length (nt)** | Raise the GC maximum from a qPCR preset's 60 toward 65 or 70, as [When a preset finds nothing](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#when-a-preset-finds-nothing) does. Allow shorter primers, which lowers the melting temperature, or raise the melting-temperature maximum a degree or two. |
| PrimalScheme | **Use high-GC design settings** | Turn it on, as [Tuning a scheme that covers too little](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md#tuning-a-scheme-that-covers-too-little) advises. It sets the allowed primer length to 17 to 30 bases instead of 19 to 36, and the allowed GC share to 40 to 65 percent instead of 30 to 55. |
| Olivar | **Maximum GC fraction**, **Extreme GC**, **Maximum primer-target binding ΔG (--dG-max)** | Raise the GC maximum above 0.75 in steps of 0.05. Lower **Extreme GC** toward 0 when much of the target is GC-rich. Leave the ΔG alone, since primers stop growing once binding reaches it. |
| varVAMP | **GC maximum (%)**, **GC optimum (%)**, **Tm maximum**, **Length optimum**, **Hairpin threshold** | Raise the GC maximum and optimum together, because varVAMP drops a primer whose penalty passes 10. Shorten primers before raising the Tm maximum. Keep the hairpin and dimer limits. |

## Primer3

Primer3 designs one primer pair, or a pair plus a [hydrolysis probe](../../GLOSSARY.md#hydrolysis-probe), on one template at a time. [Designing a PCR Assay](../10-primer-design/02-designing-a-pcr-assay.md) and [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md) run it.

### Inputs and the assay

**Records.** Chooses which records of a FASTA file or reference bundle become templates. The default selects every record in a checklist you can see. Clear the other checkboxes for a design on one sequence, since Primer3 designs each selected record separately. On the command line this is `--fasta-record`, repeated once per record.

**Template row.** Chooses which row of a [multiple sequence alignment](../../GLOSSARY.md#msa) Primer3 designs on. There is no default, and Run stays disabled until you pick a row, because target positions and reported positions are counted on that row. On the command line this is `--msa-template`.

**Assay.** Chooses the rule set and loads its values into every field below, which you may still edit. The default is "PCR primers". The two qPCR choices replace the product range, primer lengths, melting temperatures, GC limits and complementarity thresholds, so pick the assay before you adjust anything. On the command line this is `--assay`, with `pcr`, `qpcr-dye` or `qpcr-probe`.

**Require binding sites conserved across all alignment rows.** Stops Primer3 from placing an [oligo](../../GLOSSARY.md#oligo), a short synthetic DNA strand, over any alignment column where the rows disagree, where a row has a gap, or where a row carries an ambiguous base. It is on by default whenever an alignment is among the inputs, because a primer on a variable column mismatches some of the aligned sequences. Turn it off to see the best pair for the template row alone. On the command line this is `--binding-site-policy`, with `exclude-variable-and-gapped-columns` for on and `template-only` for off.

The PCR column is LGE's historical default set, which leaves its last six rows at Primer3's own values, and the qPCR columns are LGE's presets. A blank field means Primer3's built-in value is used.

| Rule | PCR primers | qPCR · intercalating dye | qPCR · internal hydrolysis probe |
|---|---|---|---|
| Product size (bp) | 100 to 400 | 70 to 150 | 70 to 150 |
| Primer length (nt), min/opt/max | 18/20/27 | 18/20/24 | 18/20/24 |
| Primer Tm (°C), min/opt/max | 57/60/63 | 58/60/62 | 58/60/62 |
| Primer GC (%), min to max | 20 to 80 | 40 to 60 | 40 to 60 |
| **Pair Tm difference max (°C)** | 100, no limit in practice | 1 | 1 |
| **3′-end G/C max (last 5 nt)** | 5 | 2 | 2 |
| **GC clamp (nt)** | 0 | 1 | 1 |
| **Poly-X max (nt)** | 5 | 4 | 4 |
| **Self, any** and **Pair, any** (°C) | 45 | 40 | 40 |
| **Self, 3′ end** and **Pair, 3′ end** (°C) | 35 | 30 | 30 |

### Product and target

**Product minimum (bp)** and **Product maximum (bp)** set the shortest and longest product Primer3 may return, counted from the first base of the forward primer to the last base of the reverse primer. Raise both together when the product must span a long target, as a design across two exons does. On the command line these are `--product-size-min` and `--product-size-max`.

**Candidate pairs.** Sits beside the product sizes in "Design settings" and sets how many pairs Primer3 returns per template. The default is 5. Raise it when you expect to discard several pairs. On the command line this is `--pair-count`.

**Amplify a specific region** turns on a target every product must contain, with the forward primer before it and the reverse primer after it, and is off by default. **Target start** and **Target end** set the first and last base of that target, counted on the template with alignment gaps skipped, and the end may not be smaller than the start. A target longer than the product maximum is refused before the run. The switch has no flag, because giving `--target-start` and `--target-end` turns it on.

### Primer rules under Advanced settings

**Primer length (nt).** Sets the minimum, optimum and maximum primer length. Allow shorter primers when a stretch is GC-rich and every candidate runs too hot, and longer ones when it is AT-rich. On the command line these are `--primer-min-size`, `--primer-opt-size` and `--primer-max-size`.

**Primer melting temperature (°C).** Sets the minimum, optimum and maximum [melting temperature](../../GLOSSARY.md#melting-temperature) for each primer, so both primers of a pair work at one annealing temperature. Change the range to match a cycling protocol that anneals elsewhere, or to admit a primer whose 3′ end you have anchored on a discriminating column, one that separates your targets from the sequences you must not detect. On the command line these are `--primer-min-tm`, `--primer-opt-tm` and `--primer-max-tm`.

**Minimum GC (%)** and **Maximum GC (%)** bound the share of G and C bases in a primer. The wide PCR defaults leave the melting-temperature rules to do most of the work, and the qPCR presets tighten them. From a qPCR preset, raise the maximum toward 65 or 70 for GC-rich sequence such as MHC exons, as [When a preset finds nothing](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#when-a-preset-finds-nothing) does. On the command line these are `--primer-min-gc` and `--primer-max-gc`.

The four fields under "Assay rules (blank keeps Primer3's default)" cap the melting-temperature gap between the two primers (**Pair Tm difference max (°C)**), the G or C bases among the last five (**3′-end G/C max (last 5 nt)**), the G or C bases required at the very 3′ end (**GC clamp (nt)**) and the longest run of one base (**Poly-X max (nt)**). Their flags are `--pair-max-tm-difference`, `--primer-max-end-gc`, `--primer-gc-clamp` and `--primer-max-poly-x`. A GC clamp of 1 and a discriminating column that carries an A or a T are mutually exclusive, so set the clamp to 0 when you anchor a 3′ end on such a column.

The four fields under "Complementarity thresholds (duplex Tm, °C)" each cap how stably a primer may pair with itself (**Self, any**, **Self, 3′ end**) or with its partner (**Pair, any**, **Pair, 3′ end**), measured as the duplex melting temperature. The 3′-end pair is the one a polymerase can extend into a [primer dimer](../../GLOSSARY.md#primer-dimer), so Primer3's own limit for it is already the lower one, and the qPCR presets lower both limits by 5 °C. The flags are `--primer-max-self-any-th`, `--primer-max-self-end-th`, `--pair-max-compl-any-th` and `--pair-max-compl-end-th`.

### The hydrolysis probe window

The "Hydrolysis probe (internal oligo)" group appears only for the probe assay, and [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#settings) explains its rules. **Probe melting temperature (°C)** defaults to 64, 67 and 70, **Probe length (nt)** to 20, 25 and 30, and **Probe GC (%)** to 40, 60 and 80, each as minimum, optimum and maximum, with the flags `--probe-min-tm`, `--probe-opt-tm`, `--probe-max-tm`, `--probe-min-size`, `--probe-opt-size`, `--probe-max-size`, `--probe-min-gc`, `--probe-opt-gc` and `--probe-max-gc`.

**Probe Tm at least this far above the primers (°C).** Raises the probe's minimum melting temperature to the highest primer melting temperature plus this figure, so the probe is bound before extension reaches it. The default is 5, the lower bound varVAMP enforces, and 0 uses the window exactly as typed. On the command line this is `--probe-min-tm-offset-over-primers`.

"Probe poly-X max (nt)" is 3, tighter than the primers' 4, because a run of four G folds into a guanine quadruplex, a compact fold of G-rich DNA, that quenches the reporter dye. "Probe 5′ must-match pattern" holds five [IUPAC ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code) read from the 5′ end, and its default `hnnnn` allows A, C or T first, which keeps a G off the 5′ end, since a G next to the reporter quenches it. On the command line these are `--probe-max-poly-x` and `--probe-must-match-five-prime`.

### Keeping an oligo you chose

The "Keep these oligos (design the rest around them)" group fixes part of an assay and has Primer3 design the rest. **Forward primer**, **Reverse primer (as ordered)** and **Probe**, which shows only with the hydrolysis-probe assay, each take one sequence written 5′ to 3′ as you would order it, and each must occur in the template, the reverse primer by its [reverse complement](../../GLOSSARY.md#reverse-complement). **Forward 3′ end** and **Reverse 3′ end** take a 1-based template position that a primer's last base must land on, which puts a 3′ end on a column that separates your targets from the sequences you must not detect. Leave a field blank to let Primer3 choose that oligo. The flags are `--left-primer`, `--right-primer`, `--probe`, `--force-left-end` and `--force-right-end`.

## PrimalScheme

PrimalScheme designs tiled two-pool schemes and handles variation by adding one exact-match oligo per variant at a site. [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) runs it and covers its size fields, **Output grouping**, **Primer pools**, **Minimum base frequency** and **Backtrack when extending the scheme**. Its "Advanced settings" have no field for primer length, GC or melting temperature, and here "legacy" means the behavior of the original upstream PrimalScheme, not an option LGE added.

**CPU cores.** Sets how many processor cores PrimalScheme uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a large alignment to finish sooner. On the command line this is `--core-count`.

**Dimer score threshold.** Sets the score at or below which PrimalScheme counts two oligos as interacting and refuses to put them in one pool, a more negative score meaning a stronger predicted interaction. The default is -26, PrimalScheme's own value, and the engine names no unit for it. Change it only when too many candidate pairs are refused, and then try -30, which refuses fewer. On the command line this is `--dimer-score`.

**Check the primer mispriming database.** Checks each candidate against a database PrimalScheme builds from the sequences you supplied, for other places in those sequences where the primer could bind and make an unwanted product. It is on by default. It knows nothing about genes you did not include, so it is not a paralog check. Turn it off only to test whether it is why a design fails. On the command line, off is `--disable-matchdb`.

The next two controls, like **Backtrack when extending the scheme**, appear only with "One scheme per MSA".

**Minimum overlap (bp).** Sets how many bases neighboring amplicons must share between the next forward primer and the previous reverse primer, so primer bases are not counted. The default is 10, PrimalScheme's own value, and a combined design always uses 10. Raise it for more shared sequence at each join. On the command line this is `--min-overlap`.

**Ignore unknown bases (N).** Leaves unknown `N` bases out of the variants PrimalScheme collects at a primer site. It is off by default and cannot change a design, because in "One scheme per MSA", the only mode that shows it, LGE has already turned every `N` into a [gap](../../GLOSSARY.md#gap) before PrimalScheme runs. Leave it off. On the command line this is `--ignore-n`.

**Use high-GC design settings.** Switches PrimalScheme to its high-GC primer settings, which allow primers of 17 to 30 bases and 40 to 65 percent GC where the standard settings allow 19 to 36 bases and 30 to 55 percent, and leave the melting-temperature window of 59.5 to 64.5 °C as it is. It is off by default. Turn it on when a GC-rich target leaves gaps with the standard settings. On the command line this is `--high-gc`.

**"Treat uncovered alignment ends as missing observations".** Tells PrimalScheme that a sequence stopping before the end of the alignment has no data there, rather than a gap that counts against a primer. It is on by default, so a sequence that stops 30 columns early does not block sites near the ends, and missing data never counts as a match. Turn it off only to use PrimalScheme's `legacy` handling of alignment ends, which a gap-completion follow-up always uses, shown as the dimmed switch "Follow-up uses legacy alignment-end policy". On the command line this is `--terminal-gap-policy`, with `observed-only` for on and `legacy` for off.

**Choose verified executable….** Runs a PrimalScheme program you select instead of the one the plugin pack installed, shown as "Managed runtime (legacy defaults)" until you pick one, and **Clear** returns to the installed one. Leave it alone unless a developer asks you to test a build. On the command line this is `--primalscheme3-path`.

PrimalScheme writes its coordinates on the first row of the alignment, so put the sequence you want coordinates on first, and keep **Output Order** at Input Order in the MAFFT dialog. It also accepts a nominal amplicon size only between 100 and 2,000 bases.

### Combined panels

"Combined scheme from selected MSAs" designs one panel across several alignments. PrimalScheme adds amplicons to each alignment in turn and refuses any primer that would form a dimer with primers already in its pool, so with many alignments the pools fill up, coverage drops and run time grows quickly. Olivar tiles each alignment as it would alone, then chooses each tile's primers to keep predicted dimers low across all alignments that share a pool.

A combined PrimalScheme panel can run for hours, so its Operations row names the alignment it is searching, by number out of the total, then counts the amplicons added so far. On the **Overview** tab, each reference that ends under 90 percent coverage gets a warning. The warning gives the number of the panel's references under 90 percent, and says a one-scheme-per-MSA run of that alignment shows the coverage it reaches alone. Six controls appear only for a combined PrimalScheme panel.

**Panel selection.** Chooses how PrimalScheme weights candidate amplicons, "Uniform position weighting" or "Prioritize variable regions (entropy)". The default is Uniform position weighting, which gives every target position equal weight for broad coverage of conserved and variable regions. Choose entropy, a score of how mixed the bases of an alignment column are, to favor amplicons with more variation between their two primers and not at the primer sites, knowing that neither mode guarantees equal amplification or allele representation. On the command line this is `--panel-mode`, with `equal` or `entropy`.

The command line also has `--selection-algorithm`, which the dialog leaves at `legacy`. Its `coverage` and `allele-coverage` selectors run only on a combined panel with uniform weighting, the mispriming database on, an explicit amplicon size bound and a verified PrimalScheme program given with `--primalscheme3-path`, and the [CLI Reference](cli-reference.md#primer-schemes-and-primer-design) lists their flags.

**Maximum panel amplicons (optional)** and **Maximum per MSA (optional)** cap how many amplicons the whole panel and each alignment may hold. Both are blank by default, which leaves PrimalScheme's panel selection unrestricted. Set them to keep the order to a size you can afford. On the command line these are `--max-amplicons` and `--max-amplicons-per-msa`.

**Allow bounded dimer salvage.** Runs the strict panel first and then a bounded salvage round that retries with relaxed interaction limits, set by the six fields below, which its caption calls search budgets, not experimentally established safety thresholds. It is off by default. Turn it on when the strict panel leaves gaps, with uniform weighting and both caps blank, which the dialog requires. On the command line this is `--legacy-salvage bounded`.

| Field | Default | What it limits | Flag |
|---|---|---|---|
| **Thresholds (comma-separated)** | -28,-30,-32 | Relaxed dimer scores tried in turn, each below the **Dimer score threshold** | `--legacy-salvage-threshold`, once per value |
| **Floor** | -32 | Lowest relaxed score, which no threshold may pass | `--legacy-salvage-floor` |
| **Allowed relaxed primer interactions per pool** | 8 | Most oligo pairs in one pool that may interact more strongly than the strict score allows | `--legacy-salvage-max-edges-per-pool` |
| **Primers with relaxed interactions per pool** | 4 | Most different oligos in one pool that may take part in those pairs | `--legacy-salvage-max-incident-species-per-pool` |
| **Minimum added reference bases** | 1 | Fewest bases a candidate must add to coverage, counted after primer trimming | `--legacy-salvage-min-reference-gain` |
| **Maximum candidate evaluations** | 10000 | Most candidates tested in one pass | `--legacy-salvage-max-candidate-evaluations` |

**Choose parent output….** Picks a saved combined PrimalScheme analysis whose gaps a separate follow-up scheme should fill. It reads "No gap-completion parent selected" until you pick one, and a parent cannot be combined with salvage. Use it when a panel left regions without amplicons and you will run a second set of reactions for them. On the command line this is `--gap-completion-parent`.

**"Generate bounded candidates for uncovered regions".** Produces new primer candidates for the parent's gaps, and stays dimmed until a parent is chosen. It is off by default, and when on it shows **Max anchors / MSA** and **Max pair checks / MSA** at 2,000 and 1,000 per alignment, where an anchor is one alignment position tried for one primer direction and a pair check one forward and reverse combination, and the caption says raising them does not guarantee better coverage. Turn it on when a follow-up without it leaves gaps unfilled. On the command line this is `--gap-expansion bounded`.

## Olivar

Olivar designs tiled two-pool schemes by scoring every base for risk and placing primers where the risk is lowest. Apart from **Output grouping** and the amplicon sizes, which sit in "Scheme settings", and **Analysis name**, every control lives under "Advanced settings", most of them in a group named "Olivar native settings", where a name in parentheses, such as `--min-var`, is Olivar's own option. [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) covers its size fields, **Search effort** and **Random seed**.

**CPU workers.** Sets how many processor cores Olivar uses. The default is 4, or fewer on a Mac with fewer cores. Raise it on a long alignment. On the command line this is `--workers`.

**Minimum variant frequency (--min-var).** Sets the share of the aligned sequences that must differ from the consensus at a column before Olivar treats that base as a risky variant. The default is 0.01, Olivar's own value, a share and not a count, so one differing sequence counts with up to 100 sequences and it takes two with 200. Raise it toward 0.1 to ignore differences carried by a single sequence. On the command line this is `--minimum-variant-frequency`.

**Maximum primer length.** Sets the longest primer Olivar may build, in bases. The default is 36, Olivar's own value, which is long because Olivar extends a primer until its binding reaches the required free energy, and a primer that reaches the cap first is kept at the cap. Lower it to keep oligos short. On the command line this is `--maximum-primer-length`.

**Minimum complexity.** Rejects primers whose sequence is too repetitive, scored from 0 to 1 by how evenly a primer uses single bases, two-base words and three-base words. The default is 0.4, Olivar's own value, so `ACGTAACGTAACGTAACGTA` scores about 0.38 and is rejected, while a 65 percent GC primer such as `GACCTGGCGTTCGAGGCTCA` scores about 0.68 and passes. Raise it when a design returns primers full of repeats. On the command line this is `--minimum-complexity`.

**Design degenerate oligos.** Lets Olivar build primers with [ambiguity codes](../../GLOSSARY.md#iupac-ambiguity-code) instead of one exact sequence per site. It is off by default. Turn it on when too many alleles mismatch the plain primers, which makes the Sensitivity and Combination risk weights below act. On the command line this is `--degenerate`.

**Avoid variants at binding sites.** Throws away any candidate with a variant in the last five bases at its 3′ end. It is off by default because, as Olivar's own documentation warns, turning it on when many variants are recorded leaves very few candidates. Turn it on for a target with only a few known differences. On the command line this is `--check-variants`.

**Minimum GC fraction** and **Maximum GC fraction** bound the share of G and C bases in a primer. The defaults are 0.2 and 0.75, Olivar's own values, written as fractions here while Primer3 and varVAMP use percentages. Olivar widens both by 0.05 when GC is why a region has no candidates, so for a GC-rich target raise the maximum. On the command line these are `--minimum-gc` and `--maximum-gc`.

**Temperature (°C).** Sets the annealing temperature Olivar assumes when it works out how strongly a primer binds. The default is 60, Olivar's own value. Change it only to match a protocol that anneals elsewhere. On the command line this is `--temperature-c`.

**Salinity (M).** Sets the concentration of monovalent salt Olivar assumes, in moles per liter, because salt changes binding strength. The default is 0.18, which is 180 millimolar and Olivar's own value, where varVAMP assumes 100 millimolar. Change it only for a reaction buffer you know differs. On the command line this is `--salinity-m`.

**Maximum primer-target binding ΔG (--dG-max).** Sets the free energy in kilocalories per mole that a primer's binding to its own target must reach, which is how Olivar bounds primer length and stability, and it is not a primer-dimer threshold, whatever its flag's name suggests. The default is -11.8, Olivar's own value, and a more negative number means stronger binding, so -13 gives longer primers and -10 shorter ones. Leave it alone unless Olivar's own documentation guides you otherwise. On the command line this is `--maximum-dimer-delta-g`.

**Native risk weights.** Six fields, Extreme GC, Low complexity, Non-specificity, Variation, Sensitivity and Combination, each multiply one kind of risk, so 0 switches that risk off and 2 counts it twice as heavily. All six default to 1, but Olivar sets Sensitivity and Combination to zero while degenerate design is off. Raise Variation to push primers away from variable sites, or Non-specificity once you have given Olivar something to screen against, and lower Extreme GC when much of a GC-rich target is flagged, because it counts bases whose surrounding GC is under 0.25 or over 0.75, lines Olivar fixes. On the command line these are `--risk-extreme-gc`, `--risk-low-complexity`, `--risk-non-specificity`, `--risk-variation`, `--risk-sensitivity` and `--risk-combination`.

## varVAMP

varVAMP builds a consensus of the alignment with [degenerate bases](../../GLOSSARY.md#degenerate-base) and designs on it. [Designing a Tiled Amplicon Scheme](../10-primer-design/03-designing-a-tiled-amplicon-scheme.md) covers its **Design mode**, **Cumulative consensus threshold**, amplicon sizes, **Maximum primer ambiguities** and **Tiled overlap (bp)**, and [Designing qPCR and dPCR Assays](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md) its qPCR controls. **CPU workers** works as it does for Olivar, with the same default and flag.

**Scheme name.** Names the scheme inside varVAMP's own output, which is where oligo names such as `varVAMP_0_LEFT` come from. The default is "varVAMP". Change it to tell two designs apart in an order sheet. On the command line this is `--scheme-name`.

**Reported assays (blank = native).** Caps how many single-amplicon assays varVAMP reports, and appears only in single-amplicon mode. It is blank by default, which keeps varVAMP's own setting, no limit. Fill it in to keep only the best few. On the command line this is `--report-count`.

**Compatible-primer input path (optional).** Points at a FASTA file of primers a new design must not interact with, so a second scheme can share a tube with one you already ordered. It is blank by default. On the command line this is `--compatible-primers`.

**Terminal masking threshold.** Decides when a gap at the very start or end of the alignment is masked, meaning written as `N` so that no primer crosses it. The default is 0.5, so a terminal gap is masked only when more than half the sequences have one. On the command line this is `--terminal-masking-threshold`.

### Primer constraints

The "Primer constraints" group repeats varVAMP's own primer rules, and LGE sends every one of them on every run. varVAMP also drops any primer whose penalty exceeds 10, counting 2 per °C, 0.2 per GC percentage point and 0.5 per base away from the optimum, so move an optimum together with the limits around it. Each flag is named after varVAMP's setting, not after the label.

| Label | Default | What it limits | Flag |
|---|---|---|---|
| **Length minimum**, **Length optimum**, **Length maximum** | 18, 21, 24 bases | Primer length | `--primer-size-min`, `--primer-size-opt`, `--primer-size-max` |
| **Tm minimum**, **Tm optimum**, **Tm maximum** | 56, 60, 63 °C | Primer melting temperature | `--primer-tm-min`, `--primer-tm-opt`, `--primer-tm-max` |
| **GC minimum (%)**, **GC optimum (%)**, **GC maximum (%)** | 35, 50, 65 | Share of G and C bases | `--primer-gc-min`, `--primer-gc-opt`, `--primer-gc-max` |
| **Maximum homopolymer** | 4 bases | Longest run of one base | `--primer-maximum-poly-x` |
| **Maximum dinucleotide repeats** | 4 | Most back-to-back repeats of a two-base unit | `--primer-maximum-dinucleotide-repeats` |
| **Hairpin threshold** | 47 °C | Highest melting temperature of a primer's own hairpin | `--primer-hairpin` |
| **Maximum dimer Tm** | 35 °C | Highest melting temperature of a dimer between two primers, where lower is stricter | `--primer-maximum-dimer-temperature` |
| **Maximum dimer ΔG** | -9000 | Most negative free energy, in calories per mole, of such a dimer, where higher is stricter | `--primer-maximum-dimer-delta-g` |
| **Unambiguous 3′ bases** | 3 | Bases at the 3′ end that may not carry an ambiguity code | `--primer-minimum-3-prime-without-ambiguity` |
| **GC bases at primer 3′ minimum**, **GC bases at primer 3′ maximum** | 1, 3 | G or C bases among the last 5, varVAMP's [GC clamp](../../GLOSSARY.md#gc-clamp) rule | `--primer-gc-end-min`, `--primer-gc-end-max` |
| **End overlap** | 5 bases | Overlap two primers' ends may have before the pair counts as a dimer | `--end-overlap` |

### qPCR probe constraints

The "qPCR probe constraints" group appears only in qPCR mode and works the same way. Probe length is 20, 25 and 30 bases, probe melting temperature 64, 67 and 70 °C, and probe GC content 40, 60 and 80 percent. **GC bases at probe end minimum** and **maximum** are 0 and 4, counted among the last 5 bases at the probe's 3′ end. **Probe/primer Tm difference minimum** and **maximum** are 5 and 10 °C. **Probe distance minimum** and **maximum** are 4 and 15 bases, the gap left between the probe and the primer on the same strand. **Amplicon GC minimum (%)** and **maximum** are 40 and 60 percent, **Amplicon deletion cutoff** is 4, so only regions whose deletions are shorter than 4 bases are tested for folding energy, and **qPCR primer difference** is 2 °C.

### Chemistry and masking defaults

The "Chemistry and masking defaults" disclosure holds the reaction conditions varVAMP assumes when it predicts melting temperatures, and the **Terminal masking threshold** above. **Monovalent cation** and **Divalent cation** are 100 and 2 millimolar, **dNTP**, the deoxynucleotides the polymerase adds, is 0.8 millimolar, and **DNA**, the primer concentration, is 15 nanomolar. Change them only to match a buffer you know differs, because every melting temperature in the result depends on them. On the command line these are `--pcr-monovalent-concentration`, `--pcr-divalent-concentration`, `--pcr-dntp-concentration` and `--pcr-dna-concentration`.

## Off-target screening

Olivar and varVAMP can check their candidates against sequences the assay must not amplify, and the "Off-target screening" group is the same for both. **Add Sequences to Screen Against…** opens a chooser for alignment bundles, reference bundles or nucleotide FASTA files, and LGE builds the [BLAST](../../GLOSSARY.md#blast) database from them and records the sequences in [provenance](../../GLOSSARY.md#provenance). On the command line this is `--screen-against`, which you can give more than once.

The "Use an existing BLAST database instead" disclosure holds **Local nucleotide BLAST database prefix** for a database you built outside LGE, typed as the path of its files without their extensions, and LGE copies those component files into the analysis. The two routes are mutually exclusive. On the command line this is `--blast-database`.

A screen steers the design as well as checking it. Olivar steers primers away from regions that match the screening sequences, and varVAMP penalizes candidates that bind them. When no better candidate exists in a region, varVAMP keeps the assay and adds a warning, as [Testing the lineage assay for specificity](../10-primer-design/04-designing-qpcr-and-dpcr-assays.md#testing-the-lineage-assay-for-specificity) shows.

## Next

Go back to [What Is Primer Design](../10-primer-design/01-what-is-primer-design.md) for the ideas behind these controls, or to [Primer Scheme Bundles](primer-schemes.md) for the bundle a saved tiled scheme writes.
