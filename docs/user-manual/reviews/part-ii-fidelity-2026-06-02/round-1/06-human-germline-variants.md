# Focus group + synthesis: 06-human-germline-variants (Human Germline Variants, Preview)

Round 1 focus-group review + synthesis. Personas cross-checked against the ground-truth reality map.

**Section:** `docs/user-manual/chapters/06-human-germline-variants/` (four chapters: HaplotypeCaller, joint genotyping, filtering/selecting/metrics, reference packs).
**Audience tier (declared):** `power-user`.
**Method:** Four named power-user personas read all four chapters as a unit, quote lines, and react. Reactions are reconciled against `ground-truth/06-human-germline-variants.md` (the arbiter), which corrects the chapters' uniform "dry-run only / does not run GATK / coming soon" framing: every `lungfish gatk` subcommand has a real `--execute` flag wired to `GATKPipelineExecutor` + `ManagedGATKCommandRunner` that runs GATK4 in the managed `gatk-core` conda env and writes provenance. There is also a GUI germline path (GATK HaplotypeCaller from the BAM variant-calling dialog) the chapters never mention. "Reference pack" is a docs-only advisory layout with no code symbol.

---

## Part 1: Personas

### Persona A: Dr. Renata Volkov, bioinformatician evaluating whether to adopt the feature

Core facility staff scientist. She test-drives every CLI verb before committing a pipeline to it, and she reads docs with a terminal open beside them.

**The decisive moment: the docs say it cannot run, the tool runs.** Renata reads chapter 01: *"The command below constructs a GATK4 HaplotypeCaller invocation with Lungfish defaults, but it does not run GATK and does not create a VCF"* (01-haplotype-caller, lines 27-28). Her first instinct as an evaluator is to look at `--help`. She sees a `--execute` flag described as *"Run GATK and write final-location provenance."* She runs it on a test BAM, GATK4 executes in the `gatk-core` env, a GVCF appears, and the CLI prints `Provenance: <path>`.

> "The headline of the chapter is a factual error. The title literally says 'HaplotypeCaller Dry Runs' and the body says 'it does not run GATK' (line 1, lines 27-28). It does run GATK. There's a flag right there in the help text, `--execute`, and it does exactly what it says. The moment I catch a manual telling me a feature doesn't exist when it's wired into the binary, I stop trusting every other sentence in the section. Now I have to source-dive to find out what else is undersold."

She is equally annoyed by the scope paragraph: *"Because no scientific output is written, there is no output bundle provenance to record yet"* (01, lines 53-54).

> "This reads like a TODO note left in shipping documentation. Provenance IS written on `--execute`. The ground truth points straight at `GATKPipelineExecutor.run` calling `writeProvenance` and the CLI printing the path. The chapter is describing a future that already arrived. Tell me the real preview-vs-execute model: no flag previews, `--execute` runs and writes provenance. That's a two-sentence fix and it would have saved me an afternoon."

**Strength she names:** the command examples themselves are correct and copy-pasteable, and `--extra-args "--annotation Coverage"` is exactly the escape hatch she wanted. *"The flags are right. It's the framing around them that's wrong. If you just flip the framing, the examples carry the chapter."*

---

### Persona B: Marcus Adeyemi, clinical-genomics analyst

Works in a CAP/CLIA-adjacent research lab. He cares about whether outputs are defensible, what the normalization defaults are, and whether the GUI and CLI produce the same VCF.

**The omitted GUI path is the thing he would actually use.** Marcus reads the section's "Coming soon" admonition on every page: *"Full execution workflows, GUI integration, and expanded documentation are on the way"* (01-04, repeated verbatim). He works in the GUI most days.

> "Every page tells me GUI integration is 'on the way.' But the ground truth says there's a GUI BAM variant-calling tool, `gatk-haplotype-caller`, labeled 'GATK HaplotypeCaller, Germline SNP and indel calling with standard VCF genotypes,' that runs HaplotypeCaller on a bundle BAM and attaches the VCF as a track. That's the affordance a bench-to-clinic analyst like me reaches for first. The manual hid the feature I'd use and pointed me at a CLI I'd use second. For single-sample HaplotypeCaller, 'GUI integration on the way' is just wrong."

He flags a clinically meaningful gap in chapter 03. The filter presets are documented (*"`--preset best-practices-both`"*, 03, line 34) and the ground truth confirms `best-practices-snp`, `best-practices-indel`, `best-practices-both` are real, but the normalization defaults are invisible:

> "Chapter 03 shows `leftalign ... --split-multi-allelics` but never tells me `--max-indel-length` defaults to 200 and `--max-leading-bases` to 1000. For clinical normalization those numbers are the whole ballgame. If a 250 bp indel silently falls outside the default window, I need to know that before I sign out a case, not after."

One more: the GUI tool emits `emitReferenceConfidence: .none` (per ground truth), i.e. a final VCF, whereas the CLI defaults to GVCF.

> "GUI gives me a genotyped VCF, CLI gives me a GVCF by default. That's a real behavioral difference between the two front doors and the manual documents neither door honestly. An analyst comparing outputs will think one of them is broken."

**Strength he names:** the reference-pack file table (`04-reference-packs`, lines 28-35) is genuinely useful. *"The `.fa` / `.fai` / `.dict` / dbsnp / known-indels table is the cleanest statement of the GRCh38 pack I've seen. Keep it. Just stop calling it something the software doesn't call it."*

---

### Persona C: Priya Nair, pipeline / CI engineer

Wraps tools in Nextflow and GitHub Actions. She reads docs to learn the exact flag surface, exit semantics, and what is safe to call non-interactively.

**She would wire `--execute` into CI and the docs would have actively misled her.** Priya reads chapter 03: *"The printed command is meant for review, logging, and workflow integration tests before real execution support is added"* (03, lines 65-67).

> "This sentence tells a CI author 'this is dry-run scaffolding, real execution is later.' So I'd build my integration test assuming the command only prints. Then in code review someone points at `runOrPreview` with `execute: execute && !dryRun` and I realize the same verb runs the tool for real. The gap between `--execute` and `--dry-run` is exactly the kind of thing I need stated precisely, because in a pipeline the difference between 'prints a command' and 'launches GATK4 and writes files' is the difference between a green check and a 40-minute job."

She wants the precise truth-table, which the chapters never give:

> "From the ground truth the rule is: no flag previews, `--execute` runs, and `--dry-run` forces preview even alongside `--execute`. That's `isDryRun = !execute || dryRun`. Put that in a three-line table. CI engineers live and die by 'which flag combination actually executes.'"

She also catches a forceable-value omission in chapter 02. The doc shows *"`--combine-strategy auto`"* and *"`--combine-strategy genomicsdb`"* (02, lines 38, 49) but never the third literal:

> "The strategy option takes `auto`, `combine-gvcfs`, or `genomicsdb`, default `auto`. The chapter names two of the three. If I want to pin `combine-gvcfs` so my cohort behavior is deterministic regardless of sample count, the manual doesn't tell me that value exists. For reproducible CI I always pin the strategy rather than let `auto` flip at the 50-sample boundary."

**Strength she names:** the 50-sample threshold is stated and it is correct. *"`CombineGVCFs` up to 50, `GenomicsDBImport` above (02, lines 38-39). Ground truth confirms the constant is 50. That's the one number a cohort pipeline must branch on, and it's right. Good."*

---

### Persona D: Dr. James Okonkwo-Reilly, cautious PI who needs to know what is validated

Runs the lab, signs the grants, and will not let a tool into a manuscript or a validation packet until he knows its maturity and its provenance story. He reads for risk, not for features.

**He needs the maturity signal the docs bury and the capability the docs deny.** James actually likes the "Coming soon" honesty at first read, but the ground truth changes his assessment:

> "On the page, 'in active development, dry-run commands available today' sounds appropriately humble, and humility is what I want from a preview feature. The problem is it's humble about the wrong thing. The thing the chapter under-promises is that it *runs GATK4*. The thing it should be flagging is that the `gatk-core` pack is marked experimental in the source. So the honesty is pointed 180 degrees away from where my risk actually is. Don't tell me it can't run. Tell me it can run, and tell me it's experimental, so I can decide whether it's allowed near a clinical question yet."

He zeroes in on the maturity metadata the chapter omits (per ground truth, the pack carries `isExperimental: true` and `estimatedSizeMB: 600`):

> "A PI's first two questions for any new dependency are 'how mature is it' and 'how big is the download my students are about to pull on lab wifi.' The pack is flagged experimental and it's a 600 MB install. Neither fact is in chapter 04. Surface both. 'Experimental' is a green light for a methods-development project and a red light for a diagnostic one, and only I get to decide which."

On the term "reference pack" he is blunt:

> "Chapter 04 is titled 'Reference Packs for GATK' and the section header is 'Plugin Pack.' I assumed 'reference pack' was a Lungfish object I could install or validate, parallel to the plugin pack. The ground truth says there is no such symbol anywhere in the source. It's a recommended folder layout. That's fine, even good advice, but call it 'recommended reference layout,' not 'reference pack,' because the noun made me hunt for a `lungfish` command that does not exist."

**Strength he names:** the provenance commitment. The chapters repeatedly insist any execution must record the command, environment identity, checksums, sizes, exit status, and wall time (01, lines 53-57; 02, lines 60-61; 03, lines 70-73). *"This is the right standard and the source already meets it via `writeProvenance`. So change the tense from 'future execution must' to 'execution records,' and you've turned an aspiration into the single best reason for a cautious PI to trust the feature."*

---

## Part 2: Synthesis

### Critical fidelity fixes (the app does not work as written)

All four chapters frame the entire GATK feature set as "dry-run / command-construction only" and assert it "does not run GATK." Per the ground truth this is the central, section-wide error: every `lungfish gatk` subcommand has a real `--execute` flag wired to `GATKPipelineExecutor` + `ManagedGATKCommandRunner` that runs GATK4 in the managed `gatk-core` env and writes provenance (`GATKCommand.swift:37-52, 95-99`; `GATKPipelineExecutor.swift:691-766`). Default behavior with no flag is preview, so "construct without running" is true *by default*, but the absolute claims that execution does not exist are false. These four fixes are the top priority; everything else is secondary.

**1. Replace the "does not run / coming soon" framing with the real preview-vs-`--execute` model (all four chapters).** The "Coming soon" admonition appears verbatim on every page and the bodies repeat the false claim ("does not run GATK," 01 line 28; "construct ... without running it," 02 line 27; "before real execution support is added," 03 line 67; "the current CLI only prints commands," 04 line 63). Reword to the actual model. Ground truth recommendation (line 249): *"previews by default; `--execute` runs (experimental)."*

Corrected admonition (replaces the four identical "Coming soon" blocks):

> !!! note "Preview feature (experimental)"
>     Human germline variant support is a power-user preview. By default each `lungfish gatk` command prints the GATK command it would run, so you can review and log it. Add `--execute` to actually run GATK4 in the managed `gatk-core` environment; Lungfish writes full provenance for the run. The `gatk-core` pack is experimental, so validate results before relying on them.

Corrected chapter 01 "What it is" opener (replaces lines 27-28):

> By default the command below prints a GATK4 HaplotypeCaller invocation with Lungfish defaults and does not run GATK. Add `--execute` to run it: Lungfish launches GATK in the managed `gatk-core` environment, writes the GVCF, and records provenance. Add `--dry-run` to force a preview even when `--execute` is present.

**2. Document the `--execute` flag and the preview/dry-run truth-table (all chapters, once in 01, cross-linked after).** The flag is currently treated as nonexistent. State the exact semantics from `GATKCommand.swift:95-99` and the `isDryRun = !execute || dryRun` rule (`GATKCommand.swift:43-52`, `265-274`). Recommended insert in chapter 01:

| Flags passed | Behavior |
|---|---|
| (none) | Preview. Prints the GATK command. Writes nothing. |
| `--execute` | Runs GATK4 in `gatk-core`. Writes outputs and provenance. |
| `--execute --dry-run` | Preview. `--dry-run` overrides `--execute`. |

Add a one-line scope correction everywhere the chapters say provenance is "future": on `--execute`, `GATKPipelineExecutor.run` calls `writeProvenance(...)` and the CLI prints `Provenance: <path>` (`GATKPipelineExecutor.swift:714-726`, `GATKCommand.swift:50-51`). Change "Any future execution workflow must preserve provenance" (02, lines 60-61; echoed 01, 03) to present tense: execution records the GATK command, environment identity, inputs, outputs, checksums, sizes, exit status, wall time, and stderr in the bundle today.

**3. Add the omitted GUI HaplotypeCaller path (chapter 01, and remove "GUI integration on the way").** The chapters never mention that GATK HaplotypeCaller runs from the GUI. Per ground truth, the BAM variant-calling dialog exposes a `gatk-haplotype-caller` tool ("GATK HaplotypeCaller", "Germline SNP and indel calling with standard VCF genotypes") that runs HaplotypeCaller on a bundle BAM, emits `emitReferenceConfidence: .none` (a genotyped VCF, not a GVCF), writes `variants/gatk/<id>.vcf.gz`, and attaches it as a variant track (`BAMVariantCallingCatalog.swift:15,30-31,167-168`; `BAMVariantCallingDialogState.swift:380-396`; `InspectorViewController+VariantWorkflow.swift:224-248`). Add a short "From the GUI" subsection to chapter 01 and a second `entry_points` line in its frontmatter. Note the GUI/CLI default difference explicitly: GUI emits a final VCF (`.none`); CLI defaults to GVCF (`--emit-ref-confidence GVCF`). Delete "GUI integration ... on the way" from the admonition, since single-sample HaplotypeCaller already has a GUI front door.

**4. Clarify that "reference pack" is an advisory layout, not a code feature (chapter 04).** There is no `ReferencePack` / `refpack` / "reference pack" symbol anywhere in `Sources/`; grep returns zero hits (ground truth lines 188-195, 261-264). The file table is a recommended on-disk layout, correctly described, but the noun "reference pack" implies an installable/validatable object parallel to the plugin pack, which misleads readers (Persona D hunted for a nonexistent command). Rename the chapter and its framing to "recommended reference layout" (or "reference files for GATK") and add one sentence: Lungfish does not define, download, validate, or enforce a "reference pack"; assemble these files yourself and pass absolute paths. Keep the chapter 04 claim "Lungfish does not ship a human reference pack" (line 37), which the ground truth marks accurate, but fix the stale second half of "the current CLI only prints commands" (line 63) per fix 1. The `gatk-core` pin (`bioconda::gatk4=4.6.2.0`, verified with `gatk --version`) is correct and stays (ground truth lines 197-201).

### Coverage gaps (real app features missing from the docs)

These are real, shipped features the ground truth confirms but the chapters omit. They are secondary to the fidelity fixes above but should land in the same revision.

**Promoted HaplotypeCaller tuning flags (chapter 01).** The chapter says it "includes explicit defaults for the main tuning flags" but names none (01, lines 37-39). Document the real promoted flags and defaults from `GATKCommand.swift:110-129`: `--emit-ref-confidence` (GVCF), `--ploidy` (2), `--pcr-indel-model` (CONSERVATIVE), `--stand-call-conf` (30.0), `--max-alternate-alleles` (6), `--pair-hmm-threads` (4). A small defaults table is the cleanest fit and stays within the five-row bullet cap if rendered as a table.

**`--combine-strategy combine-gvcfs` value (chapter 02).** The chapter shows `auto` and `genomicsdb` but never the third forceable literal `combine-gvcfs`, default `auto` (`GATKCommand.swift:232-233`; CLI help). State all three values so a pipeline can pin behavior across the 50-sample boundary (Persona C).

**`variants-to-table` subcommand (chapter 03).** Entirely undocumented in the chapter and absent from its `entry_points` frontmatter. It builds a `VariantsToTable` command with default fields `CHROM,POS,REF,ALT,QUAL,AF,DP` (`GATKCommand.swift:471-487`; top-level `gatk --help` lists it). Add it alongside filter/select/leftalign/collect-metrics.

**`leftalign` and `collect-metrics` numeric defaults / flags (chapter 03).** `leftalign` defaults `--max-indel-length` (200) and `--max-leading-bases` (1000) are invisible; document them (`GATKCommand.swift:896-903`), clinically load-bearing per Persona B. `collect-metrics --gvcf-input` (treat input as GVCF) is undocumented (`GATKCommand.swift:1002-1003`).

**`bqsr` flag surface and chapter home (chapters 03/04).** `bqsr` is shown in chapter 04 but its full surface is undocumented: `--intervals` and `--create-output-bam-index` (default true) (`GATKCommand.swift:588-592`). The `gatk` command also exposes `markdup` and `validate-sam`, which currently have no chapter home for their flags (`GATKCommand.swift:667-767`, `769-870`). Editorial decision for the human: give `bqsr` / `markdup` / `validate-sam` a documented home (likely chapter 03 or a new "BAM preparation" subsection) rather than leaving them unmentioned.

**`gatk-core` maturity and size metadata (chapter 04).** The pack carries `isExperimental: true` and `estimatedSizeMB: 600` (`PluginPack.swift:455, 474`); neither is surfaced. Both are decision-grade facts for a cautious PI (Persona D): experimental status gates clinical use, and the 600 MB download is install-planning information.

### Accessibility fixes

This section is text-and-CLI only (no shots, no illustrations), so accessibility work is about scannability, terminology, and not assuming knowledge the page has not provided.

**Make the execute/preview distinction scannable, not buried in prose.** The single most important fact in the section (no flag = preview, `--execute` = runs GATK) is currently absent; when added (fix 1-2) it must be a visible admonition plus a small truth-table near the top of chapter 01, not a sentence mid-paragraph. Power-users skim for the flag that changes behavior; bury it and they will miss it exactly as the current "does not run" line misled every persona.

**Name promoted defaults in tables, not in narrative.** "Explicit defaults for the main tuning flags" (01) and the `leftalign` numeric defaults (03) should be tables with flag / default / meaning columns. A reader cannot skim a default they cannot see, and a screen-reader user benefits from the table structure over a prose run-on.

**Fix terminology that sends readers hunting.** "Reference pack" (chapter 04) reads as an installable object and made a reviewer search for a nonexistent command; rename per fix 4. Every chapter declares `audience: power-user`, which is correct here, but the chapters lean on GVCF/BQSR/GenomicsDB without a one-line gloss at first use; add a single inline gloss for GVCF (genomic VCF, per-position reference confidence) and GenomicsDB (GATK's on-disk multi-sample store) at first mention, consistent with the foundations-synthesis rule "no vocabulary load-bearing without inline gloss."

**Cross-link rather than repeat the admonition four times.** The identical "Coming soon" block on all four pages is repetitive once corrected; state the preview/execute model fully in chapter 01 and have 02-04 carry a one-line "Preview feature: see chapter 01 for the preview-vs-`--execute` model" pointer. This mirrors the foundations finding that repeating the same framing block across chapters annoys readers.

### What to keep

These elements are correct against the ground truth or praised by personas and should survive the revision.

- **The CLI command examples themselves.** Every example's flags are correct and copy-pasteable: HaplotypeCaller with `--extra-args` (01), joint-genotype with `--intermediate` (02), the filter/select/leftalign/collect-metrics block (03), and the bqsr example (04). Personas A and B both said the flags are right and only the framing is wrong. Flip the framing, keep the examples.
- **The 50-sample joint-genotyping threshold (02, lines 38-39).** Verified-correct (`GATKCommandBuilder.swift:380, 408-413`). The one number a cohort pipeline branches on, and it is accurate (Persona C).
- **The `gatk4=4.6.2.0` pin and `conda install --pack gatk-core` syntax (04).** Both verified-correct (`PluginPack.swift:447-474`; `conda install --help`). Keep verbatim.
- **The reference-file table (04, lines 28-35).** Accurate as a recommended layout and the cleanest GRCh38-pack statement a reviewer had seen (Persona B). Keep the table; only rename the surrounding concept.
- **The filter presets and `select --type` values (03).** `best-practices-{snp,indel,both}` and `SNP/INDEL/MIXED` are verified-correct (`GATKCommand.swift:316-317, 400-401, 453`). Keep.
- **The provenance standard.** The chapters' insistence on recording command, environment identity, checksums, sizes, exit status, and wall time is the right bar and the source already meets it. Keep the standard; change the tense from "future execution must" to "execution records" (Persona D called this the single best adoption reason).
