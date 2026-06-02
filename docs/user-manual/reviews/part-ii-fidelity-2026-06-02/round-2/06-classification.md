# 06-classification fidelity re-review (Round 2)

Round-2 simulated-reader review of the nine Classification chapters after the
Round-1 editor pass. Scope: confirm the Round-1 critical fidelity fixes landed,
scrutinize the two rewrites (NAO-MGS import-only, BLAST Verify-button) and the
brand-new NVD chapter, and catch residual or newly introduced problems. Graded
against `../ground-truth/06-classification.md` and re-verified against live
Swift source where the rewrites and the new chapter assert facts the ground
truth did not already pin. No chapters were edited. No em dashes, per
`docs/user-manual/STYLE.md`.

Chapters re-read in full:
`01-what-is-classification.md`, `02-running-kraken2.md`,
`03-running-esviritu.md`, `04-running-taxtriage.md`, `05-running-nao-mgs.md`
(rewritten), `06-blast-verification.md` (rewritten), `07-running-freyja.md`,
`07-importing-cz-id-results.md`, `08-novel-virus-detection.md` (new).

**Headline:** the Round-1 plan landed almost completely. All ten critical
fidelity fixes (C1 through C10) are present, both rewrites match the binary, and
the new NVD chapter is accurate and invents nothing. Source re-verification even
resolved one ground-truth NEEDS-HUMAN-CHECK in the docs' favor (NVD does ship a
`BLAST Verify` action-bar button). Two small fidelity defects remain, both new
or carried-over CLI-form errors: the EsViritu CLI uses `--input`, not a
positional FASTQ, and the Kraken2 "Standard-8 / 16 GB Mac" framing reintroduces
a borderline RAM claim. Everything else is clarity or style polish.

---

## PART 1: Verification table

Each row is a Round-1 critical fidelity fix. Status is LANDED, PARTIAL, or
MISSED, with current quoted text. Source citations are to the live tree
(re-verified for this round), not just the ground truth.

| # | Round-1 fix | Status | Note (current text quoted) |
|---|---|---|---|
| C1 | Three-runnable-not-four premise | **LANDED** | Ch01 heading "Three runnable classifiers, three import-only tools" and "Lungfish runs three classifiers you launch inside the app ... It also imports results produced by tools you ran elsewhere: CZ-ID, NAO-MGS, and NVD". Grep for "four classifiers"/"four runnable": none in any file. |
| C2 | Single `Classification…` menu item (no per-tool submenu) | **LANDED** | Ch01: "This is a single menu item, not a submenu: there is no `Classification > Kraken2` or `Classification > EsViritu` path." Ch02: "This is one menu item, not a submenu." Ch03/04 use `Tools > FASTQ/FASTA Operations > Classification…` then "choose ... in the wizard's tool picker". |
| C3 | Plugin Manager at `Tools > Plugin Manager…` | **LANDED** | Ch01/02/03/04 all say "from `Tools > Plugin Manager…` (Cmd-Shift-B)". Grep for "Settings > Plugin Manager": none. |
| C4 | `lungfish conda classify` (not top-level `classify`) | **LANDED** | Ch02 front-matter `CLI: lungfish conda classify`; body "The runnable command lives under `conda`, not as a top-level verb" then `lungfish conda classify reads.fastq.gz --db Viral`. Adjacent `import kraken2` and `build-db kraken2` both documented. Re-verified: `ClassifyCommand` takes a positional `@Argument` for input, so `reads.fastq.gz` positional is correct. |
| C5 | NAO-MGS rewritten to import-only, crediting SecureBio | **LANDED** | Title now "Importing NAO-MGS Results", audience `analyst`. "This is an import-only tool. There is no NAO-MGS option in the run wizard and no 'run NAO-MGS' surface anywhere in the app." CLI `lungfish nao-mgs import /path/...` (positional). Attribution: "built by SecureBio ... cite the upstream pipeline at `https://github.com/securebio/nao-mgs-workflow`". All confirmed against `NaoMgsCommand.swift`. |
| C6 | BLAST rewritten to Verify-button workflow | **LANDED** | Title "BLAST Verification", entry "Click **BLAST Verify** in the viewport's action bar", popover `Verify "<taxon>" via NCBI BLAST`, "Reads to submit" slider "defaults to 20 and ranges from 1 to 50", verdict-first output, `nt`/`blastn` "both fixed", "Lungfish does not offer a local-BLAST escape hatch". All confirmed against `ClassifierActionBar.swift`, `BlastConfigPopoverView.swift`, `BlastVerdict`. |
| C7 | Kraken2 confidence 0.2 + Sensitivity preset | **LANDED** | Ch02: "a **Sensitivity** preset picker (Sensitive, Balanced, or Precise; default Balanced)" and "a **Confidence** threshold (default 0.2) and a **Minimum hit groups** field (default 2)". The fabricated "0.0 keeps every hit" rationale is gone. Bracken also added ("Classify & Profile"). |
| C8 | TaxTriage Nextflow + Docker prerequisite | **LANDED** | Ch04 dedicated section "Set up the runtime first: Nextflow and a container": "before you install the database you must have two things available: **Nextflow** and a **container runtime** ... Verify both at once with `lungfish taxtriage check-prerequisites`". Profile picker, flag table, and PDF/template export all removed; TASS named; exporter corrected to "cross-sample organism matrix" CSV from the action bar. |
| C9 | EsViritu CLI/wizard options | **PARTIAL** | Wizard fixed ("two controls ... **Min Read Length** (default 100 nt) ... and a quality-filter toggle ... There is no minimum-breadth or minimum-read-count field"), strain-comparison section deleted, mini-BAM "appears automatically ... no separate 'Show reads' button". BUT the CLI form is still wrong: chapter writes `lungfish esviritu detect <fastq> --sample <name>` (positional FASTQ); the real flag is `--input`/`-i` (an `@Option`, `EsVirituCommand.swift:65`). See must-fix M1. |
| C10 | Kraken2 Viral RAM contradiction resolved | **PARTIAL** | The "16 GB" contradiction is fixed: ch02's table now reads "Viral ~0.5 GB / 1 GB minimum RAM" and ch01 no longer carries a conflicting figure. NEEDS-HUMAN-CHECK on the canonical pack-manifest numbers remains open, and a new borderline claim appeared in the Standard-8 row (see should-fix S1). |

### New NVD chapter (`08-novel-virus-detection.md`) verification

Verified against `NvdCommand.swift`, `NvdResultViewController.swift`,
`ImportCommand.swift` (NvdSubcommand), and `ViewerViewController+Nvd.swift`.

| Claim in chapter | Reality | Status |
|---|---|---|
| Import-only; "Lungfish does not run it" | `NvdCommand` has only `import`/`summary` subcommands; GUI is an Import Center card. | **ACCURATE** |
| Source is the "Novel Virus Diagnostics (NVD) ... external Snakemake pipeline" | `NvdCommand.swift` discussion: "Novel Virus Diagnostics (NVD) Snakemake pipeline". | **ACCURATE** |
| Main file `*_blast_concatenated.csv(.gz)` read from `05_labkey_bundling/` | `ImportSubcommand` literally checks `inputURL.appendingPathComponent("05_labkey_bundling")` then `NvdResultParser.isBlastConcatenatedCSV`. | **ACCURATE** |
| CLI `lungfish nvd import /path/ --output-dir ... --name ...` (default `nvd-<experiment>`) | Matches: positional `inputPath`, `--output-dir`/`-o`, `--name` "default: nvd-{experiment}". | **ACCURATE** |
| `lungfish import nvd` family form | `ImportCommand` registers `NvdSubcommand` (`commandName: "nvd"`). | **ACCURATE** |
| `lungfish nvd summary` accepts a run dir or a single CSV | `SummarySubcommand` is the `defaultSubcommand`; example `100_blast_concatenated.csv.gz`. | **ACCURATE** |
| Contig-keyed viewport; expand a row to see secondary BLAST hits | `NvdResultViewController` is a contig outline; `byTaxon`/`bySample` modes build Taxon -> Contig -> Hit hierarchy. | **ACCURATE** |
| Columns: Sample, Contig, Length, Classification, Rank, Accession, Identity %, E-value, Bit Score, Mapped Reads, RPB (reads per billion) | All column titles confirmed verbatim, incl. `rpbCol.title = "RPB"` and `readsPerBillion`. | **ACCURATE** |
| Grouping control "By Sample" / "By Taxon" | `NSSegmentedControl(labels: ["By Sample", "By Taxon"])`, accessibility label "NVD Grouping Mode". | **ACCURATE** |
| Mini-BAM viewer in detail pane | `miniBAMController`, `buildMiniBAMPanel(for: hit)`; ASCII doc shows "[MiniBAM viewer]". | **ACCURATE** |
| Action bar `BLAST Verify` submits the contig sequence; `Export` button | `actionBar = ClassifierActionBar()`; `onBlastVerification = { hit, sequence in ... }` submits the contig; `onExportFASTARequested`. **This resolves the ground-truth NEEDS-HUMAN-CHECK** (ground truth ch06 section 3: "NVD wiring was not confirmed"). It is wired. | **ACCURATE** |

The NVD chapter invents nothing. Its one defensible simplification: the
action-bar Export is labelled "Export" and the row context menu offers "Export
FASTA…"; the chapter says "The action bar's **Export** button writes the
displayed results out", which is correct and does not overclaim FASTA.

---

## PART 2: Three persona re-reads

### Persona A: Wendy Okafor, first-year tech (novice, running her first Kraken2)

Re-reads ch01 then ch02. In Round 1, three wrong navigation/parameter facts in a
row spent her trust.

**The three Round-1 breaks are gone.** "Last time the menu path said
`Classification > Kraken2` and there was no such submenu. Now ch02 says open
`Tools > FASTQ/FASTA Operations > Classification…` and 'This is one menu item,
not a submenu. ... In the **Classifier** picker, choose **Kraken2**.' That is
exactly what I see on screen. The Plugin Manager is now 'from `Tools > Plugin
Manager…` (Cmd-Shift-B)', which is where the postdoc had to point me before. And
the confidence default finally matches: 'a **Confidence** threshold (default
0.2)'. The slider says 0.20 and so does the manual."

**The control that made her freeze is now documented.** "The Sensitivity preset
that was on screen with no explanation is here: 'a **Sensitivity** preset picker
(Sensitive, Balanced, or Precise; default Balanced) ... Balanced suits most
samples.' I would not freeze now. I would leave it on Balanced because the manual
told me that is fine."

**New, and good for a novice:** "Ch02 explains the tool is 'Classify & Profile
(Kraken2)' and 'runs Kraken2 to assign reads and then Bracken to estimate
community abundance.' I did not know what Bracken was; now I at least know a
second number exists and where it comes from."

**One residual snag, mild.** "The database table row says Standard-8 is for when
'You are on a 16 GB Mac and want a broader screen than Viral', and the prose
right under it says 'Standard and PlusPF will not run on a laptop with 16 GB of
memory.' As a novice I read those two lines back to back and could not tell
whether my 16 GB MacBook can run anything bigger than Viral. The Standard-8 row
implies yes, the prose talks only about the giant Standard. It is not wrong, but
it made me hesitate on the one decision the table exists to make." (See S1.)

**Accessibility.** "Still no rendered screenshots, only `<!-- planned: ... -->`
markers, so I have nothing to look at. The one real illustration in ch01 has a
full alt string. Everything else is a promise." (Carried from Round 1; Round-3
screenshot pass owns this.)

**Net.** "The chapter earned my trust this time and kept it. The Standard-8
versus 16 GB wording is the only place I paused."

### Persona B: Raj Mehta, research associate (EsViritu, then TaxTriage, then NAO-MGS)

Comfortable in the GUI, occasionally on the CLI. In Round 1 he lost an afternoon
to the undocumented TaxTriage runtime and chased EsViritu controls that did not
exist.

**EsViritu wizard is now honest.** "Step 5 used to list 'minimum breadth 10%,
minimum read count 50' fields that were not on screen. Now: 'EsViritu exposes two
controls here: **Min Read Length** (default 100 nt) ... and a quality-filter
toggle ... There is no minimum-breadth or minimum-read-count field.' I did not
hunt for phantom fields. The strain-comparison section I read two pages of last
time is gone, and the mini-BAM note is right: 'The mini-BAM appears automatically
in the detail pane ... There is no separate "Show reads" button.'"

**But the EsViritu CLI line would fail if I pasted it.** "The headless form reads
`lungfish esviritu detect <fastq> --sample <name>`. I ran `lungfish esviritu
detect sample.fastq.gz --sample MySample` and it errored: the FASTQ has to go
behind `--input` (or `-i`). The chapter writes the input as a bare positional,
but the tool wants `--input sample.fastq.gz`. Same shape of bug as Round 1's
`esviritu run`, just one level down. An intermediate user copies that line
verbatim." (Must-fix M1.)

**TaxTriage no longer ambushes me.** "The runtime blocker that cost me an
afternoon is now the first setup section: 'TaxTriage is not a single binary. It
runs the `jhuapl-bio/taxtriage` Nextflow pipeline inside a container, so before
you install the database you must have two things available: **Nextflow** and a
**container runtime** ... Verify both at once with `lungfish taxtriage
check-prerequisites`.' That is the sentence I needed in Round 1. The fictional
Profile step, the LOW_BREADTH flag table, and the PDF/template export are all
gone, and the score is named: 'That score is the TASS score (the TaxTriage
Aggregate Scoring System).' The export section now matches what the app writes:
'a **cross-sample organism matrix** as a CSV ... There is no PDF and there are no
report templates.'"

**NAO-MGS finally tells me it is import-only up front.** "Round 1 walked me into
a wizard card that did not exist. The rewrite opens 'This is an import-only tool.
There is no NAO-MGS option in the run wizard.' The CLI is right now too:
`lungfish nao-mgs import /path/to/nao-mgs-output/` with 'The argument is
positional', plus `--sample-name`, `--output-dir` (`-o`), and `--min-bitscore`.
I checked all three against `--help` in my head and they line up. The viewport
columns ('**Sample**, **Taxon**, **Hits** ... **Unique Reads**, and **Refs**')
match what I see, and the chapter is explicit there is no time-series chart,
which was the single most misleading thing about the old version."

**Accessibility.** "The TASS tiers are now described 'by bar weight and the
numeric value, not by color, so they remain legible without relying on a
red-amber-green scheme.' That is the right call and it matches the style guide.
A screen-reader user can act on 'at or above 0.8 is a strong call' without seeing
a green bar."

**Net.** "Three of my four Round-1 disasters are fully fixed. The only thing that
would still bite me is the EsViritu `--input` CLI line."

### Persona C: Dr. Priya Venkataraman, surveillance lead (BLAST verification + NVD)

Power-user. In Round 1 the BLAST chapter promised a representative-read picker, a
database selector, and a local-BLAST escape hatch that do not exist, and NVD had
zero coverage.

**BLAST is now the real feature.** "The old chapter had me 'Select the longest
read in the list' and 'Click Send to BLAST'. The rewrite is correct: 'You do not
pick individual reads; Lungfish chooses them for you ... Click **BLAST Verify** in
the viewport's action bar ... a popover ... titled `Verify "<taxon>" via NCBI
BLAST` ... Set the **Reads to submit** slider. It defaults to 20 and ranges from
1 to 50 ... There is no representative-read list to scroll and no database or
program to choose.' I verified the popover title and the 1-to-50 range against
`BlastConfigPopoverView` and they are exact."

**The trap I would have architected around is explicitly closed.** "Round 1 told
me to 'install a local BLAST database ... and switch the database selector to the
local path.' The rewrite says the opposite, correctly: 'Lungfish does not offer a
local-BLAST escape hatch: the database and program are fixed at NCBI `nt` and
`blastn`, so there is no local path to switch to.' That single sentence saves a
team from planning a local-offload workflow that cannot exist."

**The headline output is finally the headline.** "'The drawer leads with the
verdict and the verification rate. Read those first: they are the answer.' Then
the four verdicts (Supported / Unsupported / Mixed / Inconclusive) and the
per-read hit columns 'up to about five per read, the fixed hit-list size.' This
matches `BlastVerdict` and the 5-hit default. The CLI section names the three
inputs the GUI hides: 'the Kraken2 report, the per-read Kraken2 output, and the
source FASTQ', with the right flags (`--kreport`, `--kraken-output`, `--source`,
`--taxid`, `--reads`, `--include-children`, `--max-concurrent`, `--extra-args`).
I confirmed every flag against `BlastCommand.swift`."

**NVD exists now, and it is right.** "The tool I use weekly has a chapter. It is
import-only ('Lungfish does not run it'), it names the `05_labkey_bundling/`
folder and the `*_blast_concatenated.csv(.gz)` file, and the viewport
description is precise: contig-keyed, expandable to secondary hits, with the
'By Sample' / 'By Taxon' grouping control and the RPB (reads per billion) column.
Those are the exact labels in the app. It even gets the BLAST-Verify behavior
right: on NVD it 'submits the contig sequence to NCBI BLAST', which is different
from the read-based flow on the other tools, and the chapter does not blur the
two. A new hire could find and use NVD from this chapter alone."

**One thing I would tighten, not a fidelity bug.** "The BLAST chapter says the
Verify flow 'is available from the Kraken2, EsViritu, TaxTriage, and NAO-MGS
viewports' (the procedure's scope line). NVD also has a `BLAST Verify` action-bar
button, and the NVD chapter documents it. The BLAST chapter's scope list omits
NVD. It is a small undercount, and arguably defensible because NVD verifies a
contig rather than a read sample, but a power-user cross-referencing the two
chapters will notice the asymmetry." (See S2.)

**Net.** "Both of my Round-1 catastrophes are gone. The BLAST chapter is now
something I would hand to my team, and NVD is documented to the same standard as
CZ-ID. I have no must-fix here, only the cross-reference nit."

---

## Round 2 fixes for editors

Distinguishing must-fix (fidelity: a reader fails a task, scripts a broken
command, or sizes hardware wrong) from should-fix (clarity or style).

### Must-fix (fidelity)

**M1. EsViritu CLI uses `--input`, not a positional FASTQ (ch03).**
Current (line 152): `lungfish esviritu detect <fastq> --sample <name>`. The real
flag is `--input`/`-i` (an `@Option`, `EsVirituCommand.swift:65`); a positional
FASTQ errors. This is the same class of defect Round 1 flagged (`esviritu run`)
one level down, and it is the only broken command line left in the section.
Correct to:

> `lungfish esviritu detect --input <fastq> --sample <name>`, with `--paired`
> for paired reads, `--db` to point at a specific database, `--min-read-length`
> (default 100), `--no-qc` to skip the quality screen, and `--extra-args`.

(For contrast, leave the Kraken2 and NAO-MGS CLI lines alone: `conda classify`
and `nao-mgs import` both take a genuine positional argument, verified in source,
so `lungfish conda classify reads.fastq.gz --db Viral` and `lungfish nao-mgs
import /path/...` are correct as written.)

### Should-fix (clarity and style)

**S1. Resolve the Standard-8 / "16 GB Mac" tension in the Kraken2 RAM table
(ch02).** The Standard-8 row's "Use when" says "You are on a 16 GB Mac and want a
broader screen than Viral", while the prose immediately below says "Standard and
PlusPF will not run on a laptop with 16 GB of memory." Both are individually
true (the prose means the full Standard/PlusPF, not the -8 caps), but read
together they push a 16 GB-laptop reader in opposite directions on the exact
decision the table exists to make. Tighten the prose to name the full builds
explicitly, e.g. "The full Standard and PlusPF builds will not run on a laptop
with 16 GB; the -8 and -16 capped builds are the laptop path." This also keeps
the open C10 NEEDS-HUMAN-CHECK honest: the per-database RAM figures
(Standard-8 8 GB, Standard 67 GB, PlusPF 72 GB) remain unverified against the
pack manifest and should be confirmed in the Round-3 pass.

**S2. Add NVD to the BLAST chapter's scope list (ch06).** The procedure's scope
sentence (line 87) reads "The same flow is available from the Kraken2, EsViritu,
TaxTriage, and NAO-MGS viewports." NVD also exposes a `BLAST Verify` action-bar
button (confirmed: `ClassifierActionBar` in `NvdResultViewController`, wired via
`onBlastVerification` in `ViewerViewController+Nvd.swift`), and the NVD chapter
documents it. Either add NVD to the list or add a half-sentence noting NVD
verifies a contig sequence rather than a read sample so the two chapters agree.
This is the inverse of the Round-1 "undercounts NAO-MGS" note, now narrowed to
NVD only.

**S3. (Optional) CZ-ID chapter procedure list runs to five numbered steps plus
two follow-on code blocks (ch07 CZ-ID).** Within the STYLE 5-item cap, but the
single H2 ("Procedure") carries the 5-step list and then two additional fenced
commands and a third. It reads fine and stays under cap; flagging only so the
Round-3 linter pass does not treat the trailing standalone-form note as a sixth
item. No change required unless `bullet-cap.js` warns.

### Confirmed clean (no action)

- No em dashes in any of the nine files.
- No banned hype words; no body sentence ends in `!`.
- No "four classifiers", no "Lungfish > Settings", no bare "lungfish classify",
  no "esviritu run"/"esviritu db install" residue anywhere.
- Ch07 CZ-ID and ch07 Freyja remain accurate (the Round-1 "keep" set);
  CZ-ID gained the standalone `cz-id import --output-dir` form (G6 landed:
  "A second CLI form exists ... `lungfish cz-id import <input> --output-dir
  <dir>`"). Freyja's only nit (no menu item) is handled honestly: "There is no
  Freyja menu item: the GUI's role here is installing the pack".
- Ch01 viewport-heterogeneity fix landed (G5): "Kraken2 and imported CZ-ID
  results open the sunburst taxonomy viewport ... EsViritu, TaxTriage, NAO-MGS,
  and NVD each have their own table-based viewport."
- Ground-truth NEEDS-HUMAN-CHECK on NVD BLAST wiring is now resolved in source:
  the button and callback exist. The docs are correct to claim it.

### Verdict

The Round-1 plan executed cleanly. Both rewrites and the new NVD chapter are
accurate, scoped honestly, and match the binary; the section now reads at the
standard the CZ-ID and Freyja chapters set. One genuine must-fix remains (the
EsViritu `--input` CLI line, M1) plus two minor clarity nits (S1, S2). After M1,
this section is fidelity-clean.
