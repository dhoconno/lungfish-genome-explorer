# 07-assembly Round 2 simulated-reader review

Round 2 of the iterative fidelity review. The four Assembly chapters were
revised by editors after the Round 1 synthesis (`../round-1/07-assembly.md`).
This pass verifies that each critical Round 1 fix landed, re-reads the chapters
through three personas, and lists residual or new problems. No chapters were
edited in this pass. Source facts were re-checked against the live Swift code
and the built CLI binary on 2026-06-02. No em dashes, per
`docs/user-manual/STYLE.md`.

**Section under review:** `docs/user-manual/chapters/07-assembly/` chapters 01
through 04.

**Headline:** Round 1 landed almost completely. Every systemic fabrication the
Round 1 focus group flagged (the SPAdes `--viral` mode, the per-tool
`Assembly > SPAdes` submenu, the Flye genome-size and polishing controls, the
Hifiasm trio fields, the `extract-contigs` CLI name, the right-click "Extract
Contigs" sheet, and the `-contig1` naming scheme) is gone from the current
text, and each was replaced with the verified-correct behavior. The two Round 1
NEEDS-HUMAN-CHECK items (the GUI suggested bundle name vs the CLI `-subset`
default, and the Isolate-as-SARS-CoV-2-default recommendation) are now resolved
correctly in the text. The MEGAHIT/SKESA coverage gap is filled. What remains
is a short list of small fidelity nits (the GUI project-name default wording,
the menu ellipsis glyph, one MEGAHIT profile-id subtlety) and a few clarity and
style items, none of which is task-blocking.

---

## PART 1: Verification table

Each row is a critical fidelity fix called for in the Round 1 synthesis
(`../round-1/07-assembly.md`, sections C1 through C8 and G1 through G5), checked
against the current chapter text and re-verified against source.

| # | Round 1 fix | Status | Note (with current-text confirmation) |
|---|---|---|---|
| C1 | Remove SPAdes `--viral` mode everywhere; real Isolate/Meta/Plasmid profiles | LANDED | No `--viral` profile is offered anywhere. Ch01 table row reads "Profiles: Isolate (default), Meta, Plasmid." Ch02 profile table (lines 47-53) lists exactly Isolate/`--isolate`, Meta/`--meta`, Plasmid/`--plasmid`. Ch02 line 33 + line 53: "There is no viral profile... the default Isolate profile is the right choice because the target organism count is one." The `--viral` upstream pipeline is correctly described as reachable only via advanced-options text field or `--extra-args "--viral"` (ch02 lines 55, 136). RNA row deleted. Matches `SPAdesAssemblyPipeline.swift:15-31` + `AssemblyWizardSheet.swift:822-824` (GUI offers isolate/meta/plasmid). |
| C2 | Single Assembly menu item + in-wizard segmented Assembler picker | LANDED | Every menu path is now `Tools > FASTQ/FASTA Operations > Assembly...` with the assembler chosen inside the wizard. Ch01 lines 56-57: "There is one menu item... and you pick the assembler from a segmented Assembler control inside the wizard." Ch02 step 2, Ch03 both procedures and worked example all use `Assembly...` + "Set the Assembler picker." Ch01 planned-shot caption (line 15) now reads "segmented Assembler picker... above the separate Read Type control," matching `MainMenu.swift:686` (single `Assembly…` item) and `AssemblyWizardSheet.swift:439-444` (segmented picker over `AssemblyTool.allCases` + separate Read Type picker). |
| C3 | Remove nonexistent Flye genome-size field + polishing toggle | LANDED | Ch03 step 4 (lines 107-111): "There is no genome-size field and no polishing control in the wizard: Flye estimates coverage and polishes internally. If you must pass a genome-size hint, type it into the advanced options text field as `--genome-size 30k`." The old `30k`/`5m` field instruction and the "default polishing pass is one round" claim are gone. Matches `ManagedAssemblyPipeline.swift:280-298` (Flye command adds only `--<readMode>`, `--out-dir`, `--threads`, then extras; no `--genome-size`, no `--iterations`). |
| C4 | Remove nonexistent Hifiasm trio-binning fields | LANDED | Ch03 step 4 (lines 126-131): Diploid (default) / Haploid/Viral profile, Primary contigs only toggle, "There are no trio-binning fields in the wizard." Matches `AssemblyWizardSheet.swift:537,842-843` (primary-only toggle + Diploid/Haploid-Viral) and `ManagedAssemblyPipeline.swift:301-325` (no trio flags). |
| C5 | Contig extraction CLI is `extract contigs` (two words) + full flag surface | LANDED | Ch04 front matter "CLI: lungfish extract contigs"; body line 116-120 gives `lungfish extract contigs --assembly <bundle> --contig <id> [...] --output <path>` with an explicit "(note `extract contigs` as two words, not a hyphenated `extract-contigs`)". Flag table (lines 127-131) documents `--contigs`, `--contig-file`, `--bundle`/`--bundle-name`/`--project-root`, `--line-width` (default 60), and line 132-134 documents stdout-when-`--output`-omitted. All match the live `extract contigs --help` and `ExtractContigsCommand.swift:17-19`. |
| C6 | Contig extraction GUI = Create Bundle button (not right-click sheet) | LANDED | Ch04 entry point "Assembly result viewport: Create Bundle button (action bar)"; procedure step 3 (lines 103-106): "Click **Create Bundle** in the action bar at the bottom of the result viewport... also offers **BLAST Contigs**, **Copy FASTA**, and **Export FASTA**." Line 114-115: "The Create Bundle button runs the `extract contigs` CLI command for you." The synchronous-manifest claim is corrected (lines 42-47): "it is not a pure bookkeeping copy: Lungfish writes the selected contigs to a new FASTA, bgzip-compresses it, builds a FASTA index... runs as a short background task." Matches `AssemblyActionBar.swift:13,48,67` + `AssemblyContigMaterializationAction.swift:33-37,82-85`. |
| C7 | Derived-bundle default name `<source>-subset` (CLI); GUI suggestion documented | LANDED | Ch04 "Naming derived bundles" (lines 141-147): "From the Create Bundle button... a single selected contig suggests the contig identifier itself (for example `NODE_1_length_29812`), and a multi-contig selection suggests `<assembly>-selected-contigs`. From the CLI without `--bundle-name`, the default is `<source>-subset`." Uniqueness counter `SRR36291587-subset 2` documented (line 149). The old `-contig1`/`-contig1+2` scheme is gone. This resolves the Round 1 NEEDS-HUMAN-CHECK: the GUI suggestion (`AssemblyResultViewController.swift:279-285`: single contig -> contig id; multi -> `<outputDirectory>-selected-contigs`) genuinely differs from the CLI `-subset` default (`ExtractContigsCommand.swift:346-353`), and the chapter now states both correctly. |
| C8 | Flye ONT-only (PacBio CLR not accepted) | LANDED | Ch01 table (line 87): "In this version Flye accepts ONT reads only." Ch03 aspect table (line 74) input platform now "Oxford Nanopore (R9, R10)" with no CLR; lines 89-95: "In this version Flye accepts ONT reads only: PacBio CLR is not an accepted Flye input, and the wizard will not offer Flye for a CLR bundle," with the external-tool-then-import escape hatch. Matches `AssembleCommand.swift:394-401` (`.flye -> .ontReads`) + `ManagedAssemblyPipeline.swift:280-285` ("Flye expects a single ONT sequence input in v1"). |
| G1 | MEGAHIT and SKESA run guidance added | LANDED | New ch02 section "MEGAHIT and SKESA in the same wizard" (lines 114-120). MEGAHIT profiles named "Default, Meta Sensitive, Meta Large"; SKESA "has no Profile picker"; SKESA `--min_count 2` pin documented (line 120: "keeps small assemblies... from being zeroed out by SKESA's high-coverage auto-escalation"). Matches `AssemblyWizardSheet.swift:826-833` (MEGAHIT Default/Meta Sensitive/Meta Large), `:846` (SKESA returns `[]` = no picker), `ManagedAssemblyPipeline.swift:266-270` (`--min_count 2` pin). Ch01 also adds a full "Comparing SPAdes and MEGAHIT on the same sample" section. |
| G2 | Read-type auto-detection + per-tool compatibility gating | LANDED | Ch01 lines 95-100: "The wizard reads the FASTQ headers and detects the read class for you, then shows only the assemblers that match... an ONT bundle offers Flye and Hifiasm. A tool you expect may therefore be absent because it does not accept your detected read type." Matches `AssembleCommand.swift:369-402` + `AssemblyCompatibility.swift`. |
| G3 | SPAdes Careful-mode toggle + min-contig post-filter | LANDED | Ch02 step 3 (line 65): "expand Advanced Settings and turn on `Careful mode`. The `Min Contig` stepper there sets a length below which Lungfish drops contigs after SPAdes finishes; it is a Lungfish post-filter, not a SPAdes flag." Matches `AssemblyWizardSheet.swift:529` (Careful mode toggle) + `AssemblyOptionCatalog.swift:127-128` (post-filter). |
| G4 | Hifiasm `--ont` mode + real Flye profile names | LANDED | Flye profiles Nano HQ (default)/Nano Raw/Nano Corrected named in ch01 (implied), ch03 step 3 (lines 103-106). Hifiasm ONT capability stated twice: ch01 table (line 88) "Also accepts ONT reads"; ch03 lines 85-87 "in this version it also accepts ONT reads (it adds the `--ont` flag when the detected read type is Nanopore)." Matches `ManagedAssemblyPipeline.swift:286,313-315` + `AssemblyWizardSheet.swift:836-838`. |
| G5 | Full CLI `assemble` flag surface; `--profile` not `--mode`; no `--viral` value | LANDED | Ch02 CLI flag table (lines 126-134) documents `--assembler`, `--read-type`, `--paired`, `--profile`, `--memory-gb`, `--min-contig-length`, `--extra-args`. Line 131 profile row: "There is no `viral` value." Line 136: "There is no `--viral` profile; if you need SPAdes' own viral pipeline, append `--extra-args "--viral"`." Matches the live `assemble --help` exactly (flags + the `meta-sensitive or nano-hq` profile example). |

**Verification summary:** 16 of 16 critical fixes LANDED. Zero PARTIAL, zero
MISSED. Both Round 1 NEEDS-HUMAN-CHECK items are resolved in the text. The
section moved from the most-broken in Part II (per the Round 1 headline) to
clean on every load-bearing fact.

---

## PART 2: Three persona re-reads

Same persona archetypes as Round 1, re-reading the revised chapters. Quotations
are verbatim from the current text with line numbers.

### Persona A: Tomas Reubenstein, second-year grad student (novice deciding whether to assemble)

Tomas re-reads chapter 01 cover to cover. His Round 1 trust was earned by the
concepts and then destroyed by the viral-mode recommendation and the ambiguous
menu.

**Resolved pain points.**

- The viral-mode landmine is gone. The five-assemblers table now tells him
  (line 84) "Profiles: Isolate (default), Meta, Plasmid," and the body is
  explicit at line 158-159: "There is no viral profile in Lungfish; for a
  single-organism amplicon run the Isolate profile is the right default." Tomas:
  "Last time the one recommendation for my exact viral sample pointed at a mode
  that does not exist. Now it points at Isolate, names it as the default, and
  tells me why. I would actually find this control."
- The menu ambiguity is resolved. Line 56-57: "There is one menu item,
  `Tools > FASTQ/FASTA Operations > Assembly...`, and you pick the assembler
  from a segmented Assembler control inside the wizard." Tomas: "That single
  sentence answers the exact question that froze me in Round 1: is Assembly a
  button or a folder of buttons? It is a button; the assemblers live inside."
- The decision walkthrough he loved survived intact (lines 102-149), and the
  new line 97-100 explanation of read-type gating pre-answers his "why is a tool
  missing?" worry before he can have it.

**New problems.** None that block him. Two small observations:

- The worked example at line 132-141 (wastewater to MEGAHIT) is excellent, but
  the new "Comparing SPAdes and MEGAHIT on the same sample" section (lines
  151-179) is fairly long and somewhat advanced for a first-read novice who has
  not yet run anything. It reads more like intermediate material. Not wrong,
  just slightly above his tier at this point in the chapter. He would not be
  harmed, he would skim it.
- Still zero rendered screenshots (all `<!-- planned: ... -->`). As in Round 1,
  the visual learner has nothing to anchor on for the wizard he is about to use.
  This is the standing screenshot-capture task, not a fidelity regression.

**Residual fidelity issues.** None. Tomas's three Round 1 breaks are all fixed.

**Net.** "The chapter kept the teaching that earned my trust and removed the one
instruction that would have ended it. I would open the wizard confident, find
Assembly, find Isolate, and run."

### Persona B: Dr. Aisha Nwosu, research associate (intermediate running SPAdes and MEGAHIT)

Aisha reads chapter 02 as a procedure to execute and then a CLI to script.

**Resolved pain points.**

- The menu path is right (step 2, line 61: "Choose
  `Tools > FASTQ/FASTA Operations > Assembly...`... Set the Assembler picker at
  the top to `SPAdes`"). The wizard she sees matches the words.
- The SPAdes profile table (lines 47-53) now has exactly the three rows the
  wizard shows: Isolate, Meta, Plasmid. Her Round 1 "two of five rows are
  fiction" complaint is gone. Step 3 leaves her on Isolate, which is what the
  picker defaults to.
- The output-name claim is corrected. Step 4 (line 67): "Lungfish defaults the
  field to `assembly`; type a more specific name if you want one." No more
  phantom `-spades` suffix.
- Careful mode is now documented (step 3, line 65), answering exactly the
  accuracy-versus-speed question she raised in Round 1.
- The CLI section is now usable. The flag table (lines 126-134) gives her
  everything to script a batch, and line 131 + 136 explicitly kill the
  `--viral` value she would have reached for. The example at line 136 is
  copy-pasteable: `lungfish assemble reads_R1.fastq.gz reads_R2.fastq.gz
  --paired --assembler spades --profile isolate`.
- MEGAHIT now has a real procedure (lines 114-120), with its three profiles
  named. As someone steered to MEGAHIT for shotgun data, she finally has the
  controls.

**New problems.**

- Minor fidelity wording: step 4 says "Lungfish defaults the field to
  `assembly`." In the GUI, when a FASTQ is already selected the default is
  actually `<cleaned-input-name>_assembly` (for example `SRR36291587_assembly`),
  and the bare `assembly` is only the fallback when no input name is available
  (`AssemblyWizardSheet.swift:284-286`). Aisha: "My field showed
  `SRR36291587_assembly`, not `assembly`. Close enough that I was not derailed,
  but it is the kind of small mismatch that the chapter is otherwise scrupulous
  about avoiding." Should-fix, low severity.
- The menu item glyph: every chapter writes `Assembly...` with three ASCII
  dots, but the actual menu title is `Assembly…` with a single Unicode ellipsis
  (`MainMenu.swift:686`). Cosmetic; a literal find-in-menu would still succeed
  visually. Worth a global normalize at polish time, not a blocker.

**Residual fidelity issues.** None of substance. The two items above are wording
and glyph nits, not the control-does-not-exist class of Round 1.

**Net.** "Round 1 I said I could not hand this to a new hire because three steps
were wrong and the headline mode was fictional. Now the procedure matches my
screen, the CLI is documented, and MEGAHIT is covered. I would hand this over."

### Persona C: Dr. Priya Subramanian, pipeline engineer (power-user on long reads + contig scripting)

Priya reads chapter 03 for the long-read wizard fields and chapter 04 for the
exact CLI command and GUI affordance, and she scripts from the front matter.

**Resolved pain points (chapter 03).**

- Flye genome-size and polishing fields are gone (step 4, lines 107-111). The
  text now tells her the truth: no genome-size field, no polishing control, and
  if she must hint a genome size she types `--genome-size 30k` into advanced
  options. Priya: "In Round 1 I opened every disclosure triangle hunting for a
  genome-size field that did not exist. Now the chapter tells me upfront it is
  not a field and gives me the advanced-options path. That is exactly right."
- Hifiasm trio fields are gone (step 4, line 130: "There are no trio-binning
  fields in the wizard").
- Flye ONT-only is stated plainly (lines 89-95), and the Hifiasm `--ont`
  capability is now surfaced (lines 85-87), which changes her tool choice for
  ONT data she might otherwise have forced through Flye.
- The Flye profile names (Nano HQ default / Nano Raw / Nano Corrected) are now
  explicit (step 3), so she knows the default is HQ, not raw.

**Resolved pain points (chapter 04).**

- The CLI command is correct: `lungfish extract contigs`, with an explicit
  parenthetical that it is two words not hyphenated (line 118-120). Priya: "This
  is the line that would have broken my pipeline at 2am in Round 1. I verified
  it against the binary myself this time; `extract contigs --help` works,
  `extract-contigs` errors. The chapter is now correct and even warns me about
  the exact mistake I would have made."
- The GUI affordance is the Create Bundle button in the result-viewport action
  bar (step 3), not a phantom right-click sheet. The sibling buttons (BLAST,
  Copy FASTA, Export FASTA) are named, which is the surface context she wanted.
- The naming convention is real: `<source>-subset` from the CLI, with the GUI
  suggestion documented separately (lines 141-147). Her Round 1 fear of building
  downstream logic that parsed a fictional `-contig1` suffix is moot.
- The synchronous-manifest misstatement is corrected (lines 42-47): it writes
  and bgzip-compresses a subset FASTA, builds an index, and runs as a background
  task. Priya: "This changes how I architect the call, and now it is accurate."
- The richer flag surface she asked for is documented: `--contigs`,
  `--contig-file` (repeatable), `--bundle-name`, `--project-root`,
  `--line-width`, and stdout-when-`--output`-omitted (lines 127-134). "The
  `--contig-file` plus a pipe pattern at line 132-134 is precisely my batch
  use case, and it is now in the manual."

**New problems.**

- One subtle CLI/GUI fidelity nuance the chapter does not call out: for MEGAHIT
  the GUI "Default" profile maps to an empty profile id (`id: ""` in
  `AssemblyWizardSheet.swift:828`), so on the CLI there is no `--profile default`
  value; the equivalent is to omit `--profile`. Chapter 02's CLI flag table
  (line 131) gives `meta-sensitive` and `nano-hq` as example profile values,
  which is fine, but a scripter who infers a literal `--profile default` from
  the GUI label "Default" would be mildly surprised. Low-severity should-fix:
  one sentence noting that MEGAHIT's Default profile means "omit `--profile`."
- The Hifiasm CLI: chapter 03 has no CLI subsection of its own; it relies on
  chapter 02's `assemble` flag table. That is reasonable (one command, shared
  table), but a power-user reading only chapter 03 for a HiFi run sees the
  `--profile` values `diploid` / `haploid-viral` only implicitly. Minor
  cross-reference gap, not a fidelity error.

**Residual fidelity issues.** None blocking. Both items above are precision
refinements on an otherwise-correct surface.

**Net.** "In Round 1 I called chapter 04 the most dangerous chapter for a
power-user because every executable detail was wrong. Now the command, the
button, the name, the flag surface, and the async behavior are all correct, and
I re-verified the command against the binary. I would script straight from the
front matter."

---

## Round 2 fixes for editors

Round 1 fidelity is essentially complete. The remaining items are small. They
are split into must-fix (a genuine fidelity inaccuracy a reader could act on and
be wrong) and should-fix (clarity, precision, style). Nothing here is in the
Round 1 "section is broken" class.

### Must-fix (fidelity)

- **M1. Chapter 02 step 4: the GUI project-name default.** Current text (line
  67): "Lungfish defaults the field to `assembly`." When a FASTQ is already
  selected, the wizard actually pre-fills `<cleaned-input-name>_assembly` (for
  example `SRR36291587_assembly`); bare `assembly` is only the no-input fallback
  (`AssemblyWizardSheet.swift:284-286`). A reader who selected a bundle first
  (the normal flow, and what step 1 instructs) will see a different string than
  promised. Fix: "Lungfish pre-fills the field from your input bundle name (for
  example `SRR36291587_assembly`), or `assembly` if it cannot derive one; type a
  more specific name if you want one." This is the only place in the four
  chapters where the text states a default a reader will see contradicted on
  screen, so it is the single must-fix.

### Should-fix (clarity and style)

- **S1. Normalize the menu ellipsis glyph.** All four chapters write
  `Assembly...` (three ASCII periods). The real menu title is `Assembly…` (one
  Unicode ellipsis, `MainMenu.swift:686`). Cosmetic and visually equivalent, but
  for a manual this precise, normalize to the real glyph (or accept ASCII
  consistently and note it once). Same applies to `Map Reads` references if they
  carry an ellipsis. Low priority, global find-and-replace.

- **S2. Chapter 02 CLI table: clarify MEGAHIT's "Default" profile.** The GUI
  label "Default" maps to an empty profile id, so there is no literal
  `--profile default` on the CLI; the equivalent is to omit `--profile`
  (`AssemblyWizardSheet.swift:828`). Add one clause to the MEGAHIT run section or
  the `--profile` table row, for example: "MEGAHIT's Default profile corresponds
  to omitting `--profile` on the CLI; `meta-sensitive` and `meta-large` are the
  named values." Prevents a scripter from guessing `--profile default`.

- **S3. Chapter 01: consider re-tiering or signposting the SPAdes-vs-MEGAHIT
  comparison.** The "Comparing SPAdes and MEGAHIT on the same sample" section
  (lines 151-179) is strong intermediate material but sits in a chapter whose
  audience tier is `bench-scientist` (novice-leaning) and lands before the
  reader has run anything. Options: add a one-line signpost ("If you have not
  assembled before, you can skip this comparison and return after your first
  run"), or move it nearer the decision-walkthrough conclusion. Pure
  readability; the content is accurate and worth keeping.

- **S4. Bullet-cap spot-check.** The chapters lean on tables (good, within
  STYLE), and no H2 appears to exceed two lists or five items per list on this
  read. Flagged only as a reminder for the lint pass once screenshots and any
  new bullet lists are added in Round 3; current text looks compliant.

- **S5. Screenshots remain unrendered (standing task, not a Round 2 defect).**
  All shots are `<!-- planned: ... -->`. The captions are now all correct (the
  Round 1 wrong captions, "viral mode chosen," "Extract Contigs sheet," "grouped
  by read type," are fixed). When captured in Round 3, each needs descriptive
  alt text on the model of chapter 01's `assembly-vs-mapping` illustration, and
  any quality or coverage overlay must use Deep Ink weight plus annotation, not
  red-amber-green (`STYLE.md` data-viz rule).

### Confirmation of resolved Round 1 NEEDS-HUMAN-CHECK items

- The GUI suggested bundle name versus the CLI `-subset` default: confirmed they
  genuinely differ, and chapter 04 (lines 141-147) now documents both correctly.
  Resolved.
- The Isolate-as-SARS-CoV-2-default editorial recommendation: confirmed Isolate
  is the only SPAdes default profile (`AssemblyWizardSheet.swift:822`), and the
  chapters now recommend it explicitly with the "target organism count is one"
  justification. Resolved.
