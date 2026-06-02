# Round 2 reader re-review: 06-human-germline-variants (Human Germline Variants, Preview)

Round 2 of the iterative simulated-reader review. Verifies that the Round 1
editor pass corrected the section-wide STALE framing (GATK described as
"dry-run only / does not run GATK / coming soon" when every `lungfish gatk`
subcommand actually runs via `--execute`). Three personas re-read the revised
chapters against the ground-truth reality map.

**Section:** `docs/user-manual/chapters/06-human-germline-variants/` (four
chapters: HaplotypeCaller, joint genotyping, filtering/selecting/metrics,
reference files).
**Method:** Verification table for each Round 1 critical fix, then three
persona re-reads (bioinformatician, clinical-genomics analyst, CI/pipeline
engineer). All claims re-checked against `Sources/` directly, not just against
the ground-truth document.

**Headline:** Round 1 landed. The "dry-run only / does not run GATK / coming
soon" framing is gone from all four chapters and is replaced by an accurate
preview-vs-`--execute` model with a correct truth-table, present-tense
provenance, the GUI HaplotypeCaller path, and the "reference pack is advisory,
no code symbol" correction. Every spot-checked fact (the `isDryRun = !execute
|| dryRun` rule, GUI catalog strings, combine-strategy enum, 50-sample
threshold, leftalign defaults, `gatk4=4.6.2.0` pin, experimental flag, 600 MB)
matches source. Residual items are minor (one over-claim in a defaults table,
two small clarity nits). No new fidelity errors.

---

## Part 1: Verification table (Round 1 critical fixes)

Re-verified against source: `Sources/LungfishCLI/Commands/GATKCommand.swift`,
`Sources/LungfishWorkflow/Variants/GATKCommandBuilder.swift`,
`Sources/LungfishApp/Views/BAM/BAMVariantCallingCatalog.swift`,
`Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift`,
`Sources/LungfishWorkflow/Conda/PluginPack.swift`.

| # | Round 1 critical fix | Status | One-line note |
|---|---|---|---|
| 1 | Replace "does not run / coming soon" with preview-vs-`--execute` model (all 4 chapters) | LANDED | "Coming soon" block gone from all four; each opens with a "Preview feature (experimental)" admonition naming `--execute`. No surviving "does not run GATK" / "before real execution support is added" / "current CLI only prints commands" lines. |
| 2 | Document `--execute` / `--dry-run` and the truth-table; provenance present-tense | LANDED | 01 has the three-row truth-table (none / `--execute` / `--execute --dry-run`) and states the code rule `isDryRun = !execute || dryRun` verbatim. Matches source (`GATKCommand.swift:83-85`, call sites `execute: execute && !dryRun`). Provenance now present-tense: "written today, not 'on the way'" (01), "execution records the cohort VCF's lineage today" (02). |
| 3 | Add GUI HaplotypeCaller path; remove "GUI integration on the way" | LANDED | 01 has a "From the GUI" section naming **GATK HaplotypeCaller** with the exact catalog subtitle, the `variants/gatk/<id>.vcf.gz` output, the Operations Panel provenance, the **GATK + WhatsHap Phased** second tool, and the GUI-emits-final-VCF vs CLI-defaults-GVCF difference. Frontmatter has the second `entry_points` line and `gui` tag. All strings match source. |
| 4 | Clarify "reference pack" is advisory layout, no code symbol | LANDED | 04 retitled "Reference Files for GATK"; body states plainly "It is not a Lungfish object... no such symbol exists in the app." Section header is now "Plugin pack" (lowercase, scoped to the real `gatk-core` pack). Matches ground truth (zero `ReferencePack` hits in `Sources/`). |
| 5a | Keep 50-sample joint-genotyping threshold | LANDED | 02 keeps "50 samples or fewer... above that threshold" and explains the boundary twice. Matches `jointGenotypingCombineGVCFsThreshold = 50` and `<= 50 ? .combineGVCFs : .genomicsDB`. |
| 5b | Keep `gatk4=4.6.2.0` pin | LANDED | 04 keeps "pins `bioconda::gatk4=4.6.2.0` and verifies it with `gatk --version`." Matches `PluginPack.swift:461,469,467`. |

**Coverage gaps from Round 1 (secondary, but tracked):** all of the
"should land in the same revision" items also landed.

| Round 1 coverage gap | Status | Note |
|---|---|---|
| Promoted HaplotypeCaller defaults table (01) | LANDED | Six-row table with the exact defaults (GVCF, 2, CONSERVATIVE, 30.0, 6, 4). Matches `GATKCommand.swift:107-129`. |
| `--combine-strategy combine-gvcfs` value (02) | LANDED | All three literals now named: "`auto`, `combine-gvcfs`, or `genomicsdb`." |
| `variants-to-table` subcommand (03) | LANDED | Documented with default field set and `--fields`; added to `entry_points`. |
| `leftalign` numeric defaults + `collect-metrics --gvcf-input` (03) | LANDED | `--max-indel-length` 200 and `--max-leading-bases` 1000 documented as "load-bearing for clinical work"; `--gvcf-input` documented. |
| `bqsr --intervals` / `--create-output-bam-index` (04) | LANDED | Both named in 04 prose ("default `true`"). |
| `gatk-core` experimental + 600 MB (04) | LANDED | Both surfaced: "flagged experimental, which gates it out of validated or clinical use" and "roughly 600 MB." |

**One Round 1 editorial decision deferred (not a regression):** `markdup` and
`validate-sam` still have no documented chapter home for their full flag set
(ground truth section 03, item 3). This was flagged as an editorial call for
the human, not a must-fix, so its absence is acceptable for this round. Noted
again below under should-fix.

---

## Part 2: Three persona re-reads

### Persona A: Dr. Renata Volkov, bioinformatician evaluating the feature

In Round 1 she stopped trusting the section the moment a `--help` flag
contradicted "it does not run GATK." This round she re-opens the terminal
beside chapter 01.

The opener now matches what her terminal does:

> "By default the command below prints a GATK4 HaplotypeCaller invocation with
> Lungfish defaults and does not run GATK. Add `--execute` to run it" (01,
> "What it is").

> "This is the model I reverse-engineered last round, stated up front. No flag
> previews, `--execute` runs. And they put the actual code predicate in the
> table section: `isDryRun = !execute || dryRun`. I checked it against
> `GATKCommand.swift` and the call sites really do pass `execute: execute &&
> !dryRun`. When a manual quotes me the exact branch the binary takes, that is
> the opposite of last round. I trust the rest of the section now."

The provenance over-claim that read like a shipped TODO is fixed:

> "Last round it said 'there is no output bundle provenance to record yet.'
> Now it says the provenance record is 'written today, not on the way' (01,
> 'Preview versus execute') and the executor prints `Provenance: <path>`. That
> is true. `runOrPreview` emits exactly that line. The future arrived and the
> doc now admits it."

The escape hatch she liked survives unchanged:

> "`--extra-args \"--annotation Coverage\"` is still there and still correct,
> and they kept the verbatim-passthrough note. The examples carried the
> chapter once the framing flipped, exactly as I said they would."

**New issue she raises (minor, should-fix).** She reads the promoted-defaults
table header in chapter 01:

> "Lungfish promotes the HaplotypeCaller flags below to first-class options so
> you rarely need `--extra-args`. Each shows its default; override any of them
> on the command line." (01, "Promoted defaults")

> "Six flags, fine. But the prose around it says I 'rarely need `--extra-args`'
> and then the very first example in the chapter uses `--extra-args
> \"--annotation Coverage\"`. Both are true, it is just a slight tension. Not
> wrong, just worth a half-sentence so a new reader does not think the table
> made `--extra-args` obsolete." Verdict: clarity nit, not a fidelity bug.

**Trust restored.** No source-dive required this round. She would adopt the CLI
path on the strength of the truth-table alone.

---

### Persona B: Marcus Adeyemi, clinical-genomics analyst

Last round the manual hid the GUI tool he works in daily and buried the
normalization defaults he signs cases on. Both are his first checks now.

The GUI path he reaches for first is now documented, and honestly:

> "HaplotypeCaller also runs from the project window, not only the CLI... choose
> **GATK HaplotypeCaller** ('Germline SNP and indel calling with standard VCF
> genotypes'). Lungfish runs HaplotypeCaller on the selected alignment track,
> writes `variants/gatk/<id>.vcf.gz` inside the bundle, and attaches the result
> as a variant track" (01, "From the GUI").

> "That subtitle is verbatim what the dialog shows. The output path is the real
> one. And critically they did not stop at 'a GUI exists', they told me the
> behavioral difference that would otherwise make me think one front door is
> broken: 'the GUI tool emits a final genotyped VCF (`--emit-ref-confidence
> NONE`), whereas the CLI defaults to a GVCF.' That is the single sentence that
> saves an analyst a false bug report. This is the honest documentation of two
> doors I asked for."

The clinically load-bearing normalization defaults are now visible:

> "an indel longer than `--max-indel-length` (default `200`) or one needing
> more than `--max-leading-bases` (default `1000`) of left shift falls outside
> the default window. If you call long indels, raise these before you rely on
> the output." (03, "Normalizing and tabulating").

> "200 and 1000, named, with the consequence spelled out and a 'raise these
> before you rely on the output' warning. That is exactly the number-plus-
> consequence I need before I sign out a case. Last round these were invisible.
> Keep this sentence word for word."

The reference-file table he praised survives, now under an honest name:

> "Reference Files for GATK" with "'Reference pack' is a convenience name this
> manual uses... It is not a Lungfish object" (04).

> "The `.fa` / `.fai` / `.dict` / dbsnp / known-indels table is intact and they
> stopped calling it a thing the software does not have. Good. The `.dict` row
> even says it is 'used by Picard and metrics tools', which is the right reason."

**New issue he raises (minor, should-fix).** Re-reading the GUI section for the
phased tool:

> "A second GUI tool, **GATK + WhatsHap Phased**... requires both the
> `gatk-core` pack and the `phasing` pack." (01, "From the GUI").

> "That is accurate, the tool really is gated on both `gatk-core` and `phasing`.
> But the `phasing` pack gets named here for the first and only time in the
> whole section, with no pointer to how I install it. Chapter 04 documents
> `conda install --pack gatk-core` but never `--pack phasing`. For a clinical
> analyst who wants phased calls, the manual names the requirement and then
> drops it. A one-line 'install the phasing pack the same way' would close it."
> Verdict: coverage nit, not a fidelity error (the requirement statement itself
> is correct).

**Confidence restored.** He would now use the GUI tool knowing precisely how its
output differs from the CLI.

---

### Persona C: Priya Nair, pipeline / CI engineer

Last round chapter 03 told her the printed command was "dry-run scaffolding,
real execution later," which would have made her build a CI test on a false
premise. She re-reads for the exact flag surface and exit semantics.

The truth-table she demanded is present and exact:

> "| (none) | Preview. Prints the GATK command. Writes nothing. | / |
> `--execute` | Runs GATK4 in `gatk-core`. Writes the output and provenance. |
> / | `--execute --dry-run` | Preview. `--dry-run` overrides `--execute`. |"
> (01, "Preview versus execute").

> "This is the three-line table I asked for, and it matches the predicate. The
> header even states it: 'you must pass `--execute`, and `--dry-run` always
> wins if both are present.' For CI that is the whole contract. The difference
> between a green check and a 40-minute GATK job is now one glance, not a
> source-dive. This is the fix that mattered most to me and it landed."

The dangerous chapter-03 sentence is gone and replaced correctly:

> "By default a command is printed for review; add `--execute` to run it and
> attach provenance." (03, "What it is").

> "No more 'before real execution support is added.' The cross-link admonition
> in 02-04 even points back to 01 for 'the full preview-versus-`--execute`
> model and the `isDryRun = !execute || dryRun` rule', so I do not have to
> re-derive it per chapter. That is the right structure: state it once, link
> the rest."

The forceable strategy value she flagged is now complete:

> "You can force any of the three strategy values: `auto`, `combine-gvcfs`, or
> `genomicsdb`." (02).

> "All three literals, and they explicitly bless pinning for reproducible CI:
> 'Pin `combine-gvcfs` or `genomicsdb` when you want deterministic behaviour...
> a reproducible pipeline that must not flip strategies at the 50-sample
> boundary.' That is written as if for me. The 50-sample constant is still
> stated and still correct."

The exit semantics she needs for non-interactive use are present:

> "On `--execute`, Lungfish runs GATK through the managed environment and prints
> two lines: the GATK exit code and `Provenance: <path>`." (01).

> "Two lines, exit code plus provenance path. That is parseable. I can assert on
> the exit code in CI and capture the provenance path as an artifact. Good
> enough to wire."

**New issue she raises (minor, should-fix).** She looks for the literal exit
behavior on failure:

> "The doc says it prints 'the GATK exit code' on `--execute`, and the truth-
> table is precise about which flags execute. What it does not say is what the
> `lungfish` process exit status is when GATK fails. `runOrPreview` prints
> `result.exitCode` but the CLI command's own exit code on a nonzero GATK run is
> not documented. In CI I branch on the wrapper's exit status, not on scraped
> stdout. A one-line 'the command exits nonzero if GATK does' would make this
> bulletproof." Verdict: coverage nit. The current claims are accurate; this is
> an unstated detail, not a wrong statement.

**Trust restored.** She would now wire `--execute` into CI from the truth-table
without reading source.

---

## Round 2 fixes for editors

The fidelity work is done. Everything below is should-fix polish. There are no
must-fix items this round.

### Must-fix (fidelity)

None. All five Round 1 critical fixes and all six coverage gaps landed and
re-verified against source. No new inaccuracies were introduced.

### Should-fix (clarity / coverage / style)

1. **(Clarity, 01) Soften the `--extra-args` tension in the promoted-defaults
   intro.** The "Promoted defaults" header says you "rarely need `--extra-args`"
   while the chapter's first example uses it. Add a half-clause such as "use
   `--extra-args` only for flags not in this table" so the table is not read as
   making `--extra-args` obsolete. (Persona A.)

2. **(Coverage, 01 + 04) Tell readers how to install the `phasing` pack.** The
   `phasing` pack is named once (01, GATK + WhatsHap Phased requirement) with no
   install instruction anywhere. Add one line, most naturally in chapter 04's
   "Plugin pack" section, e.g. "the phased GUI tool also needs `lungfish conda
   install --pack phasing`." The requirement statement itself is correct
   (`BAMVariantCallingCatalog.swift:53-54`); only the install pointer is
   missing. (Persona B.)

3. **(Coverage, 01/02) Document the wrapper's own exit status on GATK failure.**
   The chapters document the printed GATK exit code but not the `lungfish`
   process exit status when GATK fails, which is what CI branches on. One line in
   chapter 01's "Preview versus execute" would close it. (Persona C.)

4. **(Coverage, editorial carryover) Give `markdup` and `validate-sam` a
   documented home.** Still unmentioned anywhere in the section, as in Round 1.
   `bqsr` now has its flags in 04. This remains an editorial decision flagged for
   the human (ground truth 03, item 3); list both verbs in chapter 03's scope or
   a short "BAM preparation" note, or explicitly state they are out of scope for
   the preview. Not a regression, just unfinished coverage.

5. **(Style, optional) Bullet/admonition repetition is already mitigated.** The
   02-04 admonitions now cross-link to 01 rather than repeating the full model,
   which resolves the Round 1 "same block four times" complaint. No action
   needed; noted only to confirm the accessibility fix landed.

### Style and lint check

- **Em dashes:** none in any of the four chapters (grep `—` clean).
- **Hype words:** none (`powerful`, `seamless`, `robust`, `revolutionary`,
  etc. all absent).
- **Trailing `!` in body prose:** none.
- **Bullet cap (5 items / 2 lists per H2):** not exceeded. The four enumerations
  that grew (promoted defaults, the truth-table, the reference-file rows, the
  preview/execute combinations) were all rendered as Markdown tables, which is
  exactly the STYLE.md remedy for enumerations over five items. Prose bullet
  lists in the bodies are short and within cap.
- **No-em-dash rule honored in this report.**
