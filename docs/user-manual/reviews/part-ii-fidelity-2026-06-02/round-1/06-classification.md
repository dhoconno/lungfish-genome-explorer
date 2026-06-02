# 06-classification focus group synthesis (Round 1)

Standard note: this is a Round-1 simulated-reader focus group plus revision plan for the eight Classification chapters, graded against the arbiter-of-truth reality map in `../ground-truth/06-classification.md`. Personas quote chapter lines and react to fidelity breaks and accessibility gaps. The synthesis converts those reactions into a prioritized revision plan. No chapters were edited. No em dashes, per `docs/user-manual/STYLE.md`.

**Section under review:** `docs/user-manual/chapters/06-classification/` chapters 01 through 07 (note two files share the `07-` prefix: `07-running-freyja.md` and `07-importing-cz-id-results.md`).

**Headline findings:** the section is built on a false "four runnable classifiers" premise; NVD (Novel Virus Diagnostics), a whole shipped tool with its own CLI, Import Center card, and viewport, has zero coverage; the NAO-MGS chapter (05) and the BLAST chapter (06) describe features that do not exist and need ground-up rewrites; and the per-tool menu paths in nearly every front-matter block point at menu items that are not in the app.

---

## PART 1: Reader focus group

Four bench biologists, novice to power-user, each read the chapters that match their task. Quotations are verbatim from the chapters. Reactions are written in persona voice.

### Persona 1: Wendy Okafor, first-year research tech (novice, running her first Kraken2)

Wendy has been at the lab three weeks. Her PI handed her a wastewater FASTQ and said "run Kraken2 and tell me what's in it." She has never used a command line. She opens chapter 01 first, then 02.

**What worked.** "Chapter 01 is the best onboarding writing in this whole manual for me. Read classification answers a single, very practical question: 'what is in this FASTQ?' (line 30). That is exactly the sentence I needed. The contrast with mapping in the next paragraph (Mapping assumes you already know what you are looking for, line 32) finally made the difference click. And the distribution framing, A typical run produces something like '63% human, 22% bacterial ... 11% unclassified' (line 34), told me what the output is *shaped* like before I ran anything. I felt oriented."

**First fidelity break: the menu path.** "Chapter 02's front matter says the entry point is Tools > FASTQ/FASTA Operations > Classification > Kraken2 (line 11). So I open the Tools menu, find FASTQ/FASTA Operations, and there is no Kraken2 submenu. There is one item that just says Classification. I clicked it not knowing if it was the right thing. The ground truth confirms I was right to be confused: the real path is the single item `Classification…` wired to `showFASTQClassificationOperations`, and paths like `> Kraken2` do not exist (ground truth fact 3). For a novice, a menu path that is wrong is not a small thing. It is the moment I think *I broke it* or *I have the wrong version*."

**Second break: the Plugin Manager location.** "Step 1 of the procedure says Open `Lungfish > Settings > Plugin Manager` (line 108). I went to the Lungfish menu, opened Settings, and there was no Plugin Manager in there. I gave up and asked a postdoc, who told me it is under the Tools menu. Ground truth: it is at `Tools > Plugin Manager…` (Cmd-Shift-B), not under Settings (chapter 02 section 1). That is two wrong navigation instructions before I have classified a single read."

**Third break: the confidence default.** "The wizard text says a Confidence threshold slider (default 0.0, which keeps every hit) (line 133). The slider in front of me said 0.20. So either the docs are wrong or I am looking at the wrong control. I am a novice. I cannot tell which. Ground truth says the real default is 0.2 and 'the 0.0 keeps every hit rationale is fabricated' (chapter 02 section 1). The doc even invented a reason for a number that is not the number."

**A missing control made me doubt myself.** "The chapter lists three options: Database, Confidence, Minimum hit groups. But there was a Sensitivity preset picker right at the top of the wizard (Sensitive / Balanced / Precise) that the chapter never mentions. I left it alone because I did not know what it did and the manual gave me nothing. Ground truth confirms the preset is real and shown prominently and 'the chapter omits it entirely' (chapter 02 section 1). When the screen has more controls than the manual, a novice freezes."

**Accessibility.** "Every single screenshot is a planned shot, a `<!-- planned: ... -->` comment with no image. I am a visual learner and there is nothing to look at. The captions describe images that do not exist (kraken2-wizard, kraken2-plugin-manager). If a low-vision reader were relying on alt text, there is no alt text because there is no image. Also the only real illustration in 01, the classification-question schematic, has a long descriptive alt string, which is good, but it is the exception."

**Net.** "The conceptual writing earned my trust and then three wrong navigation and parameter facts in a row spent it. I finished the run only because a human rescued me."

### Persona 2: Raj Mehta, research associate (intermediate, trying EsViritu then TaxTriage)

Raj runs respiratory panels. He suspects influenza in a set of swabs and wants strain-level calls, then wants to try TaxTriage for a clinical batch. He is comfortable in the GUI and occasionally uses the CLI.

**What worked.** "Chapter 03's framing of why EsViritu over Kraken2 is genuinely useful. EsViritu does the slower, more direct thing: it aligns the read ... and lets the alignment speak for itself (line 41), and the resolution example, not just 'Influenzavirus A' but 'H3N2, clade 3C.2a1b' (line 70 in ch01, echoed in 03), is the exact mental model I wanted. The read the sparkline before the numeric columns interpretation guidance (line 173) is good craft."

**Break: the CLI command does not exist.** "Front matter says CLI: lungfish esviritu run (line 12). I tried `lungfish esviritu run` and it errored. The real subcommand is `lungfish esviritu detect` (ground truth chapter 03 section 1). Then the chapter says power users can install with `lungfish esviritu db install` (line 125), which also does not exist. So both CLI affordances the chapter hands an intermediate user are wrong."

**Break: wizard options that aren't there.** "Step 5 says leave the defaults: minimum read length 100 nt, minimum breadth 10%, minimum read count 50 (line 148). The wizard only had Min Read Length and a quality-filter toggle. There was no breadth field and no read-count field. Ground truth: 'There is no minimum-breadth or minimum-read-count field in the wizard ... the 50 reads / 10% breadth thresholds are fabricated as wizard options' (chapter 03 section 1). I spent five minutes hunting for fields that do not exist, convinced I had collapsed an Advanced section somewhere."

**Break: a whole feature that isn't real.** "I was looking forward to the strain comparison view. The chapter devotes a long section to it: Select two rows ... click Compare ... stacks the two coverage tracks ... a small bar chart breaks down how many reads aligned uniquely (lines 199 to 214). There is no Compare button in the EsViritu viewport. Ground truth is blunt: 'No such feature exists in EsViritu' (chapter 03 section 1). There is a `StrainComparisonView`, but it lives in TaxTriage and it is a per-position SNP table, not a coverage-track stack. I read two pages of instructions for a button that will never be on my screen."

**Break: the mini-BAM trigger.** "To audit a sparkline the chapter says click any strain row and then click Show reads in the inspector (line 219). There is no Show reads button. The mini-BAM just appears in the detail pane when I select a virus row. Ground truth confirms it is automatic (chapter 03 section 1). Small thing, but it is the third wrong control in one chapter."

**Then TaxTriage stopped me cold at setup.** "Chapter 04 tells me to open the Plugin Manager, find the TaxTriage entry, click Install, and then the wizard picks up (lines 105 to 109). I installed the database. The wizard still would not run. It turns out TaxTriage needs Nextflow and Docker, and the wizard literally checks for them. Ground truth: 'Installing a database is necessary but not sufficient ... requires Nextflow + Docker (or Apple Containerization) ... the chapter never mentions this hard dependency' (chapter 04 section 1). There is even a `lungfish taxtriage check-prerequisites` command to verify the runtime, and the chapter does not mention it. This is not a footnote. It is the difference between TaxTriage working and not working, and I lost an afternoon to it."

**Break: the Profile step and the flags are fiction.** "The procedure has me choose Clinical surveillance (default) in a Profile step (line 145), and there is no Profile step. The whole manual-review flag table, LOW_BREADTH, CLASSIFIER_DISAGREE, BLANK_MATCH, LOW_QUALITY_SUPPORT (lines 203 to 208), describes flags whose identifiers do not exist anywhere in the code (ground truth chapter 04 section 1). I cannot act on a flag I will never see. And the export path File > Export > TaxTriage Batch Report (line 219) with PDF and template options is also wrong: the real exporter is a cross-sample organism-matrix CSV reached from the viewport action bar, no PDF, no templates (ground truth chapter 04 section 1)."

**Accessibility.** "The TaxTriage flag table uses backtick-coded identifiers as the load-bearing column. A screen-reader user would hear LOW underscore BREADTH and have nothing to anchor it to, because the table is the entire explanation and the flags are imaginary. The confidence score is never named (it is the TASS score in the app), so I cannot search the UI for it."

**Net.** "EsViritu's concepts are strong and its controls as documented are mostly invented. TaxTriage has a real, undocumented setup blocker that wasted my day, then describes a workflow (profiles, flags, PDF export) that is largely fictional."

### Persona 3: Dr. Lena Brandt, computational research scientist (advanced, attempting NAO-MGS and BLAST verification)

Lena runs a wastewater surveillance pipeline on a cluster and wants to bring NAO-MGS results into Lungfish for review, and to BLAST-verify candidate signals. She reads the CLI sections closely and expects flags to match `--help`.

**NAO-MGS chapter sent me down a path that does not exist.** "The chapter's lead procedure is Procedure: running NAO-MGS on a fresh sample (line 56) starting with Choose Tools > FASTQ/FASTA Operations > Classification > NAO-MGS. The Classification wizard opens with NAO-MGS preselected (line 58). NAO-MGS is not in that wizard. Ground truth: 'NAO-MGS cannot be run from the wizard. It is import-only ... There is no run NAO-MGS surface anywhere' (chapter 05 section 1). I clicked through the wizard three times looking for an NAO-MGS card before I accepted the chapter is describing software that was never built."

**The entire time-series model is fabricated.** "I was excited by the longitudinal surveillance viewport ... stacked-line chart, one line per pathogen ... weeks along the horizontal axis (line 98), the Sample date and Series fields (lines 66 to 68), and the storage layout `Imports/NAO-MGS/<series-name>/<sample-date>.parquet` with a `series.json` manifest (lines 70, 90). None of it exists. Ground truth: the real viewport is a 'single-import split view: detail pane | taxonomy table' with columns Sample, Taxon, Hits, Unique Reads, Refs, and 'There is no time-series chart' and 'no series, no sample-date, no site, no matrix, no Parquet, no series.json' (chapter 05 section 1). The twelve weeks of MMSD influent worked example (line 114) walks me through a workflow that cannot be performed. This is the single most misleading chapter in the section: it is not slightly off, it is a specification for a tool that does not ship."

**The CLI signature is wrong too.** "It tells me to run `lungfish nao-mgs import --run-dir <path> --project <path>` (line 86). The real command takes a positional `<input-path>` and has no `--run-dir` and no `--project` (ground truth chapter 05 section 1). If I had scripted that into a scheduled cluster job, as the chapter explicitly suggests (line 86), it would have failed in cron at 2am. The import menu path File > Import > NAO-MGS Results (line 76) is also wrong: it is the Import Center, `Classification Results > NAO-MGS Results`."

**Attribution may be wrong.** "The chapter credits the Nucleic Acid Observatory and links naobservatory.org and github.com/naobservatory (lines 108 to 112). The code attributes NAO-MGS to SecureBio (`github.com/securebio/nao-mgs-workflow`) per ground truth (chapter 05 section 1). I would cite the wrong upstream in my methods section if I trusted this."

**BLAST verification: wrong entry point, wrong workflow.** "Chapter 06 says click the BLAST tab in the viewport's top toolbar (line 89). There is no BLAST tab. It is a BLAST Verify button in the classifier action bar, and results land in a bottom drawer (ground truth chapter 06 section 1). The whole single-representative-read workflow, pick a hit ... choose a representative read ... Select the longest read in the list ... Click Send to BLAST (lines 92 to 102) is wrong. The real flow submits a coverage-stratified subsample of N reads (default 20, slider 1 to 50) automatically through a popover titled Verify '<taxon>' via NCBI BLAST. I never pick a read. There is no Send to BLAST button."

**The local-BLAST escape hatch is a trap.** "For routine, large-scale verification, the chapter says install a local BLAST database via the appropriate plugin pack and switch the BLAST tab's database selector to the local path (lines 171 to 173). Ground truth: 'There is no database selector and no local-BLAST option in the UI ... Local BLAST is not implemented' (chapter 06 section 1). The database (`nt`) and program (`blastn`) are hard-coded. As an advanced user this is the worst kind of error: it promises a capability I would architect a workflow around, and it does not exist. I would have told my team we can offload BLAST locally, and we cannot."

**The headline output is missing.** "The chapter frames the result as a hit table of up to 50 NCBI hits (line 115). The real default is 5 hits per submitted read, and the drawer's primary output is a verdict, supported / unsupported / mixed / inconclusive, plus a verification rate (ground truth chapter 06 section 1). The actual point of the feature, what fraction of reads were independently verified, is absent from the chapter. The CLI form `lungfish blast verify` also needs `--kreport`, `--kraken-output`, and `--source` inputs the chapter never names."

**Accessibility.** "Both chapters lean on color in ways the style guide forbids and then the docs do not even reflect the real encoding. Severity is supposed to be Deep Ink weight plus annotation, never red-amber-green (STYLE palette section). The BLAST verdict is the accessible signal that should be foregrounded, and it is missing entirely."

**Net.** "Chapters 05 and 06 are the two I would tell a colleague to skip and read the source instead. Both describe substantial features (a time-series surveillance viewport, an interactive read-picking BLAST tab with a DB selector) that are not in the app. An advanced reader does real damage acting on them: wrong cron scripts, wrong methods citations, wrong architecture decisions."

### Persona 4: Dr. Marcus Aiy... no, Dr. Priya Venkataraman, metagenomics surveillance lead (power-user, expects NVD coverage)

Priya runs a public-health wastewater program doing novel-pathogen surveillance. She has used the app's NVD viewport. She reads the whole section looking for the tools she actually uses day to day.

**The biggest gap: NVD is not in the manual at all.** "I import Novel Virus Diagnostics results constantly. There is an Import Center card called NVD Results, a `launchNvdImport` sheet, a dedicated `NvdResultViewController` that shows contig-keyed BLAST hit rankings, and a CLI: `lungfish nvd import` and `lungfish nvd summary` (ground truth section-wide). I searched all eight chapters for NVD and Novel Virus. Nothing. Ground truth calls it 'the headline gap of this section ... a fully shipped classification-import tool with zero coverage' (section-wide). For a surveillance lead, NVD is exactly the discovery tool that justifies the platform. A new hire on my team would have no idea it exists. This is not a polish item. A whole shipped tool is invisible to the documentation."

**The roster I am handed is wrong.** "Chapter 01 builds everything on the four classifiers Lungfish ships (line 38) and a five-row table (lines 54 to 60). Ground truth: 'The GUI wizard ships THREE runnable classifiers, not four' (fact 2): Kraken2, EsViritu, TaxTriage. NAO-MGS, NVD, and CZ-ID are import-only. So the correct roster is three runnable plus three import-only, and the chapter gets both the count and the categories wrong. As a power-user choosing a tool, the very first decision table in the section misrepresents what is runnable."

**The 'same viewport' premise is false.** "Chapter 01 promises every classifier produces output that opens in the same taxonomy viewport (line 84) with a sunburst. In practice only Kraken2 and imported CZ-ID open the sunburst `TaxonomyViewController`. EsViritu, TaxTriage, NAO-MGS, and NVD each have a distinct table-based viewport (ground truth chapter 01 section 1, section-wide). I know this because I use them and they look nothing alike. Telling a reader they will see a sunburst for EsViritu sets up a real what-am-I-looking-at moment when a strain table appears instead."

**A missing capability I rely on: Bracken.** "The Kraken2 wizard tool is labeled Classify & Profile and estimates community abundance using Kraken2 and Bracken (ground truth chapter 01 section 2). Abundance profiling via Bracken is central to how I read wastewater composition, and the chapter never mentions it. The CLI surface (`--profile`, `--bracken-read-length`, and so on) is also undocumented."

**Internal contradiction on RAM.** "Chapter 01's table says Kraken2 Viral fits in 16 GB (line 56), chapter 02's table says Viral needs 1 GB minimum (line 67), and chapter 05's comparison table repeats 16 GB (line 49). The Viral DB is about 0.5 GB. Ground truth flags this as an internal contradiction and a NEEDS-HUMAN-CHECK on the canonical number (chapter 01 section 1). A power-user planning a fleet of analysis machines cannot size hardware off three different numbers for the same database."

**Composition and build-db are missing.** "I build custom Kraken2 databases. `lungfish build-db kraken2 <result-dir>` builds a SQLite database from a result directory and is never mentioned (ground truth chapter 02 section 2). There is also a `composition` verb in the code (dead, unregistered, per ground truth) but the live `build-db` is a real power-user surface with no documentation."

**What I would keep.** "The two import chapters are the bright spots. Chapter 07 importing CZ-ID is, per ground truth, 'the most accurate in the section' (chapter 07 CZ-ID section 1): the `lungfish import cz-id` form, the `Classifications/<sample>.lungfishtax` output bundle, the Import Center path, all verified correct. Chapter 07 Freyja also 'checks out' end to end (chapter 07 Freyja section 1): the `freyja demix` flags, the dry-run-by-default behavior, the provenance file all match `--help`. These two are the template the rest of the section should be rewritten toward. They are scoped honestly (import-only, command-plan-only) and they match the binary."

**Accessibility.** "Across the section the screenshots are 100% unrendered planned shots. For a section this dense with viewport-reading instruction (read the sparkline, find the breadcrumb, sort by score) the absence of any actual image is a serious accessibility and comprehension gap, not a nice-to-have. And the one place the docs do encode data viz, chapter 05's stacked-line chart, encodes a chart that does not exist."

**Net.** "The section omits an entire shipped tool I use weekly (NVD), miscounts and miscategorizes the tool roster in its opening table, and promises a uniform sunburst viewport that four of the tools do not have. The two import chapters prove the team can write accurate, scoped chapters. The rest of the section needs to be pulled back to that standard."

---

## PART 2: Synthesis and revision plan

Four personas, reading different chapters for different tasks, converged on the same core problem: large stretches of this section describe an app that was never built. The fixes below are ordered by how badly a reader is harmed by acting on the current text.

## Critical fidelity fixes (the app does not work as written)

These are not style or polish. Each one causes a reader to fail at a task, script a broken command, or make a wrong architecture or methods decision. Ground-truth citations are to `../ground-truth/06-classification.md`.

### C1. Fix the "four runnable classifiers" premise (chapters 01, 05)

Ground truth, fact 2 and chapter 01 section 1: the wizard ships exactly three runnable classifiers (Kraken2, EsViritu, TaxTriage). NAO-MGS, NVD, and CZ-ID are import-only. Chapter 01 repeats "four" at lines 38, 42, 44, 46 and in the five-row table (54 to 60); chapter 05 repeats it at line 45.

Corrected framing for chapter 01's roster paragraph and table. Replace the "four classifiers" sentences with a two-category model:

> Lungfish offers three classifiers you run inside the app on a FASTQ bundle: Kraken2 for a broad survey, EsViritu for viral strain calling, and TaxTriage for clinical-surveillance triage. It also imports results produced by tools you ran elsewhere: CZ-ID, NAO-MGS, and NVD (Novel Virus Diagnostics). Imported results are stored, viewed, and verified alongside native runs, but Lungfish does not run those three for you.

The decision table should split into a "runnable in the wizard" group (Kraken2, EsViritu, TaxTriage) and an "imported results" group (CZ-ID, NAO-MGS, NVD), so the reader never tries to find NAO-MGS or NVD in the run wizard.

### C2. Fix the per-tool menu paths everywhere (chapters 01, 02, 03, 04, 05)

Ground truth, fact 3: there is one menu item, `Tools > FASTQ/FASTA Operations > Classification…`, wired to `showFASTQClassificationOperations`. Paths like `> Kraken2`, `> EsViritu`, `> TaxTriage`, `> NAO-MGS` do not exist as menu paths.

Affected front-matter `entry_points` and body text: ch01 line 11/38/108; ch02 line 11/128; ch03 line 11/136; ch04 line 11/136; ch05 line 11/58. Corrected text for every occurrence:

> Open `Tools > FASTQ/FASTA Operations > Classification…`. In the wizard that appears, choose the classifier you want (Kraken2, EsViritu, or TaxTriage).

For NAO-MGS (ch05) the entry point is not this menu at all; see C5.

### C3. Fix the Plugin Manager location (chapters 02, 03)

Ground truth, chapter 02 section 1 and section-wide point 3: the Plugin Manager is at `Tools > Plugin Manager…` (Cmd-Shift-B), not under `Lungfish > Settings`. Affected: ch02 line 108; ch03 line 109. Corrected text:

> Open the Plugin Manager from `Tools > Plugin Manager…` (Cmd-Shift-B).

Chapter 04 already says "from the Tools menu" (line 106), which is correct; align the others to it.

### C4. Fix the `classify` CLI command (chapters 01, 02)

Ground truth, fact 1: there is no top-level `lungfish classify`. The runnable Kraken2 CLI is `lungfish conda classify <fastq> --db <db>`. The chapter front matter at ch02 line 12 (`CLI: lungfish classify`) and any prose pointing to a top-level classify verb is wrong. Do not strike the CLI entirely (a headless run exists), correct the path:

> CLI: `lungfish conda classify <fastq> --db <db>` (with `--preset`, `--profile` for Bracken, `--confidence`, `--min-hit-groups`, `--memory-mapping`, `--quick`).

Also document the adjacent verbs ground truth names: `lungfish import kraken2 <kreport>` and `lungfish build-db kraken2 <result-dir>` (chapter 02 sections 1 and 2). Note for the editor: `composition` is dead code (defined, unregistered, not runnable per fact 1 and section-wide point 2); do not document it.

### C5. Rewrite the NAO-MGS chapter (05) to the import-only reality

This is the most fabricated chapter in the section. Ground truth, chapter 05 section 1, lists the failures: the run-from-wizard procedure (lines 56 to 70), the Sample date / Series / site / matrix model, the Parquet and `series.json` time-series storage (lines 64 to 70, 88 to 94), the longitudinal stacked-line viewport and the twelve-weeks worked example (lines 96 to 118), the wrong CLI signature (line 86), the wrong import menu path (line 76), and the wrong upstream attribution (lines 108 to 112). None of it ships.

The corrected chapter is short and import-shaped, modeled on the accurate CZ-ID chapter (07). It must state:

1. NAO-MGS is import-only. There is no run path in Lungfish. Source the results from an external `securebio/nao-mgs-workflow` run (ground truth: attribute to SecureBio, not naobservatory.org; NEEDS-HUMAN-CHECK but the in-code source is SecureBio).
2. Import via Import Center: `File > Import Center… > Classification Results > NAO-MGS Results`, or the standalone NAO-MGS import sheet. The importer validates only for `virus_hits_final.tsv(.gz)` / `_virus_hits.tsv.gz`. There is no `samples/` / `metadata.tsv` / `manifest.json` / series machinery.
3. CLI: `lungfish nao-mgs import <input-path>` (positional, no `--run-dir`, no `--project`; converts alignments to SAM) and `lungfish nao-mgs summary <input-path> [--top N]`. Also `lungfish import nao-mgs`.
4. The viewport is a single-import split view (detail pane plus taxonomy table) with columns Sample, Taxon, Hits, Unique Reads, Refs, plus per-sample metadata columns and a per-accession coverage sparkline. There is no time-series chart.
5. BLAST Verify is available from the NAO-MGS viewport (coverage-stratified read selection feeds the shared Verify flow).

The audience tier should likely drop from the current `analyst` framing of a live pipeline to a straightforward import walkthrough. Delete the "About the Nucleic Acid Observatory" section or rewrite it as a one-line SecureBio attribution.

### C6. Rewrite the BLAST chapter (06) to the real Verify-button workflow

Ground truth, chapter 06 section 1, documents the gap between the chapter and the feature. The chapter describes a BLAST tab with a representative-read picker, a Send to BLAST button, a database selector, a local-BLAST option, and a 50-hit table. None of those exist. The real feature is:

1. Entry point: a BLAST Verify button in the classifier action bar (`ClassifierActionBar`, title "BLAST Verify") and a row context menu ("BLAST Matching Reads…" / "BLAST Verify…"). There is no BLAST tab. Results appear in a bottom drawer (`BlastResultsDrawerTab`).
2. Submission: a popover titled `Verify "<taxon>" via NCBI BLAST` with a single "Reads to submit" slider (default 20, range 1 to 50) and a "Run BLAST" button. Read selection is coverage-stratified and automatic. There is no representative-read list, no "select the longest read," no per-read preview, no Send to BLAST button.
3. No database or program selector. `nt` and `blastn` (MEGABLAST on) are hard-coded. Default `HITLIST_SIZE` is 5, not 50. Local BLAST is not implemented: delete the entire "install a local BLAST database ... switch the database selector to the local path" passage (lines 171 to 175). Keep the rate-limit etiquette section, which ground truth confirms is directionally correct, but cut the local-BLAST escape hatch.
4. Headline output: a verdict (supported / unsupported / mixed / inconclusive) and a verification rate (percent of submitted reads independently verified). The drawer shows results per submitted read, each with up to about 5 child hits. Foreground the verdict; it is the point of the feature and it is currently absent.
5. Drawer columns: Status, Read ID, Organism, Identity, E-value, Bit score, Accession, Coverage, Align Length, Tax ID, Verdict, plus "Open in NCBI BLAST" and "Re-run BLAST" buttons.
6. CLI: the subcommand is `lungfish blast verify`, and it requires `--kreport`, `--kraken-output` (per-read `.kraken`), and `--source` FASTQ, plus `--taxid`, `--reads` (20), `--max-concurrent` (1), `--include-children`, `--extra-args`. The current `CLI: lungfish blast` front matter (line 12) is too vague.
7. Scope correction: ground truth notes Verify hooks exist in Kraken2, EsViritu, TaxTriage, and NAO-MGS (line 44 undercounts NAO-MGS); NVD wiring is NEEDS-HUMAN-CHECK.

### C7. Fix the Kraken2 wizard options (chapter 02)

Ground truth, chapter 02 section 1. Three fixes in the wizard description (lines 130 to 133):

1. Confidence default is 0.2, not 0.0. Delete the fabricated "which keeps every hit" rationale.
2. Add the Sensitivity preset picker (Sensitive / Balanced / Precise, default Balanced), which is shown prominently above Advanced and is currently omitted entirely.
3. Minimum hit groups default 2 is correct; keep it.

Also note the tool is "Classify & Profile (Kraken2)" and runs Bracken abundance profiling (chapter 01 section 2, chapter 02 section 2); the chapter should mention abundance output exists.

### C8. Document the TaxTriage Nextflow + Docker prerequisite (chapter 04)

Ground truth, chapter 04 section 1 and section-wide point 4: this is a setup blocker, not a footnote. TaxTriage runs the `jhuapl-bio/taxtriage` Nextflow DSL2 pipeline and requires Nextflow plus a container runtime (Docker or Apple Containerization). The wizard checks `nextflowAvailable` / `containerAvailable`. Add to the install section, before the database step:

> TaxTriage is not a single binary. It runs a Nextflow pipeline inside a container, so before you install the database you must have Nextflow and a container runtime (Docker or Apple Containerization) available. Verify both with `lungfish taxtriage check-prerequisites`. Installing the database alone is not enough; the wizard's Run button stays disabled until the runtime is present.

Then correct the fabrications ground truth lists (chapter 04 section 1): delete the Profile step (Clinical / research / wastewater profiles do not exist, lines 145 to 149); delete the manual-review flag table (LOW_BREADTH etc. do not exist, lines 203 to 208); replace the export section (lines 219 to 230) with the real exporter (a cross-sample organism-matrix CSV plus a text summary, reached from the viewport action bar, no PDF, no templates, no File-menu path). Name the confidence score as the TASS score (TaxTriage Aggregate Scoring System) with tiers >=0.8 / 0.4 to 0.8 / <0.4, instead of inventing a four-part weighting (lines 71 to 76). Note the correct CLI run knobs (`--platform`, `--samplesheet`, `--confidence` 0.2, `--top-hits` 10, `--rank` S, `--skip-assembly` default true, `--skip-krona`, `--max-memory`, `--nf-profile` docker, `--revision`).

### C9. Fix the EsViritu CLI and wizard options (chapter 03)

Ground truth, chapter 03 section 1. Four fixes:

1. CLI subcommand is `lungfish esviritu detect ... --sample <sample>`, not `esviritu run` (front matter line 12). Other flags: `--paired`, `--no-qc`, `--db`, `--min-read-length` (default 100), `--extra-args`.
2. Delete `lungfish esviritu db install` (line 125); no such subcommand. Database install is via Plugin Manager / conda.
3. Wizard options are Min Read Length (default 100) and a quality-filter toggle only. Delete the fabricated minimum-breadth and minimum-read-count fields (lines 92 to 94 and 148).
4. Delete the entire strain comparison view section (lines 192 to 214) and the `esviritu-strain-comparison` shot; the feature does not exist in EsViritu. Fix the mini-BAM trigger: it appears automatically in the detail pane on selecting a virus row, there is no "Show reads" button (line 219).

Optionally add the real omitted features ground truth names (chapter 03 section 2): the segment completeness grid for segmented viruses, the row context menu ("Extract Reads…", "BLAST Verify…", "Look Up on NCBI" submenu), and the RPKMF column.

### C10. Resolve the Kraken2 Viral RAM contradiction (chapters 01, 02, 05)

Ground truth, chapter 01 section 1: chapter 01 says Viral "fits in 16 GB" (line 56), chapter 02 says 1 GB (line 67), chapter 05 repeats 16 GB (line 49); the DB is about 0.5 GB. NEEDS-HUMAN-CHECK on the canonical number, but all three tables must agree. Recommend adopting chapter 02's "1 GB minimum" figure (the most conservative plausible value) across all three and flagging for human confirmation against the pack manifest.

## Coverage gaps (real app features missing from the docs)

### G1. NVD (Novel Virus Diagnostics) needs its own chapter (headline gap)

Ground truth, section-wide: NVD is a fully shipped classification-import tool with zero coverage. It has a CLI (`lungfish nvd import <dir> [--output-dir] [--name]`, `lungfish nvd summary <input> [--top N]`, plus `lungfish import nvd`), an Import Center card ("NVD Results"), a standalone import sheet (`launchNvdImport` / `NvdImportSheet`), and a dedicated viewport (`NvdResultViewController`, a contig-keyed taxonomy browser: best-hit contig rows expandable to secondary BLAST hits). Source: the Novel Virus Diagnostics Snakemake pipeline, parsing `*_blast_concatenated.csv(.gz)`.

Add a new chapter `08-importing-nvd-results.md` (or a clearly titled section), modeled on the accurate CZ-ID chapter (07): import-only scope, the Import Center path, the CLI forms, and a description of the contig-keyed viewport. Add NVD to chapter 01's "imported results" group (C1). This is the single highest-value coverage addition in the section.

### G2. Bracken abundance profiling (chapter 02)

The Kraken2 tool is "Classify & Profile" and runs Bracken (ground truth chapter 01 section 2). The chapter never mentions abundance profiling or the `--profile` / `--bracken-*` CLI surface. Add a short subsection on what the profile output is and when to use it.

### G3. `build-db kraken2` and custom-database composition (chapter 02)

`lungfish build-db kraken2 <result-dir>` builds a SQLite database from a Kraken2 result directory (`--force`, `--no-cleanup`) and is unmentioned (ground truth chapter 02 section 2). Document it for the power-user custom-database path. (`composition` is dead code; do not document it.)

### G4. Import of native-tool results (chapter 01)

Kraken2, EsViritu, and TaxTriage results produced outside Lungfish can be imported via the Import Center (ground truth chapter 01 section 2), not only CZ-ID. Chapter 01 frames only CZ-ID as importable. State that native-tool results are importable too.

### G5. Viewport heterogeneity (chapter 01)

Only Kraken2 and CZ-ID open the sunburst `TaxonomyViewController`. EsViritu, TaxTriage, NAO-MGS, and NVD each have a distinct table-based viewport (ground truth section-wide point 5). Chapter 01's "same viewport for every classifier" premise (line 84) is false and should be replaced with an honest statement that the sunburst is the Kraken2 and CZ-ID view, and the other tools have their own table-based viewports described in their chapters.

### G6. Standalone CZ-ID CLI form (chapter 07 CZ-ID)

A second CLI form exists, `lungfish cz-id import <input> [--output-dir]`, which writes to a standalone `./cz-id-{sample}` dir with no `--project` (ground truth chapter 07 CZ-ID section 1). The chapter documents only the project form. Add a one-line note on the standalone form. This is a minor addition to an otherwise accurate chapter.

## Accessibility fixes

### A1. Render the screenshots; supply alt text

Across all eight chapters every screenshot is an unrendered `<!-- planned: ... -->` marker. For a section this dense with viewport-reading instruction (read the sparkline, find the breadcrumb, sort by score, read the verdict), a low-vision or screen-reader user has nothing. When the shots are captured (Round-3 screenshot pass), each needs descriptive alt text. The one good model is chapter 01's `classification-question` illustration, which already carries a full descriptive alt string.

### A2. Do not encode severity by color, and match the real encoding

STYLE palette section forbids red-amber-green in data viz; encode severity with Deep Ink weight and annotation. Two issues. First, the TaxTriage TASS tiers and the chapter's flag taxonomy lean on color and on imaginary identifiers; once rewritten to the real TASS tiers (C8), describe them by weight and label, not color. Second, the BLAST verdict (supported / unsupported / mixed / inconclusive) is the accessible, text-first signal and must be foregrounded (C6); it is currently absent.

### A3. Name UI controls in text a screen-reader user can find

Several controls the reader must operate are unnamed or misnamed: the TASS score is never named (C8), the BLAST Verify button is called a "BLAST tab" (C6), the EsViritu mini-BAM "Show reads" button does not exist (C9). After the fidelity rewrites, every actionable control should be named with the exact label the app uses, so a screen-reader user hears the same string the UI announces.

### A4. Keep tables under the bullet and list caps; convert long enumerations

STYLE caps lists at five items and two lists per H2. The rewrites (especially the NAO-MGS import steps and the BLAST drawer column list) should land as prose or tables, not long bullet runs, to stay within the cap and to read cleanly with assistive tech.

## What to keep

These landed well across personas and should survive the revision:

- **Chapter 01's conceptual framing.** The "what is in this FASTQ?" opening (line 30), the mapping-versus-classification contrast (line 32), and the distribution framing (line 34) oriented the novice persona before any tool was run. This is the strongest teaching writing in the section. Keep it; only the tool roster, viewport claim, and menu path inside it are wrong (C1, C2, G5).
- **Chapter 07 Importing CZ-ID Results.** Ground truth calls it "the most accurate in the section." The `lungfish import cz-id` form, the `Classifications/<sample>.lungfishtax` output, the Import Center path, the provenance fields, and the import-only scope statement all verify against the binary. This is the template every import chapter (including the new NVD chapter) should follow. Keep as-is except the one-line standalone-form addition (G6).
- **Chapter 07 Running Freyja.** Ground truth: "Everything else in this chapter checks out." The `freyja demix` flags, the dry-run-by-default behavior, the `freyja-command-plan.json` plus `.lungfish-provenance.json` outputs, and the `wastewater-surveillance` pack id all match `--help`. Keep it; the only nit is the entry-point overstatement (there is no Freyja menu item, only the Plugin Manager pack), which is minor because the chapter is honest that Freyja runs from the CLI.
- **EsViritu's resolution and sparkline-reading craft (chapter 03).** The align-don't-k-mer explanation (line 41), the H3N2 clade resolution example, and "read the sparkline before the numeric columns" (line 173) are good and accurate conceptual writing. Keep the concepts; fix the invented controls and CLI around them (C9).
- **The BLAST "when it earns its keep" decision table (chapter 06).** The situations-and-outcomes table (lines 70 to 76) and the rate-limit etiquette section are sound and survive the rewrite. Keep them inside the corrected Verify-button workflow (C6).
- **Kraken2's three-pass interpretation guidance (chapter 02).** Dominant signal, long tail, unclassified bin (lines 213 to 233) is accurate and genuinely useful reading guidance independent of the wizard-control errors. Keep it.
