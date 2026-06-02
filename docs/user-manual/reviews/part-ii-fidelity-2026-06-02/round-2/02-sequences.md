# Round 2 reader re-review: 02-sequences (Sequences)

Round 2 of the iterative simulated-reader review. The four Sequences chapters
were revised by editors after Round 1. This pass verifies the Round 1 fixes
actually landed in the revised text, re-runs three evolved personas against the
current chapters, and lists what (if anything) still needs fixing before
Round 3.

**Section:** Part II, Sequences (01 importing/viewing, 02 downloading from NCBI,
03 extracting/comparing, 04 MSAs and trees).
**Audience tiers:** bench-scientist (01, 02, 03), analyst (04).
**Method:** Each critical Round 1 fidelity fix was opened in the current chapter
text and checked against `ground-truth/02-sequences.md` and, where the ground
truth left an item NEEDS-HUMAN-CHECK, against the live source under `Sources/`.
Personas then re-read the revised chapters and reported on resolution, new
problems, and residual issues.

---

# PART 1: VERIFICATION TABLE (Round 1 critical fixes)

Numbering follows the Round 1 synthesis "Critical fidelity fixes" list (items 1
to 14). LANDED = corrected in the actual menu path / CLI command / dialog field,
not merely reworded. Each row was confirmed against the revised chapter line and,
where noted, re-verified against source.

| # | Round 1 fix | Status | Note (with current line) |
|---|---|---|---|
| 1 | Remove `Tools > Infer Tree`; tree inference is MSA-viewport right-click "Build Tree with IQ-TREE…" → "Phylogenetic Tree Operations" dialog | LANDED | `grep "infer tree"` returns zero hits. Ch04:99 now reads "right-click and choose **Build Tree with IQ-TREE…**. The **Phylogenetic Tree Operations** dialog opens (subtitle \"Configure IQ-TREE for the selected multiple sequence alignment\")". Title + subtitle match source verbatim (`IQTreeInferenceDialog.swift:100,104`; `MultipleSequenceAlignmentViewController.swift:1370`, ellipsis present). |
| 2 | Rewrite NCBI GUI procedure to search-then-download; no Format menu; no Run button; download builds bundle directly | LANDED | Ch02:66-78 steps now: Search NCBI → GenBank & Genomes tab, set Mode Nucleotide, Include GFF3 Annotations, **Search**, select, **Download Selected**. Ch02:53-54 states "no four-way file-format menu" and the four formats are CLI-only. No "Run", no "Format menu", no separate import step. |
| 3 | Fix menu/tab names: items are `Search NCBI...` etc.; tabs are "GenBank & Genomes" / "SRA Runs" / "Pathoplexus" | LANDED | Ch02:31,72 say `Search NCBI…` "opens a search dialog on its 'GenBank & Genomes' tab". Pathoplexus now "**Pathoplexus** tab, reached through the `Tools > Search Online Databases > Search Pathoplexus…` menu item" (Ch02:144). |
| 4 | Reverse the assembly-accession claim (Genome mode handles them; they are not refused) | LANDED | Ch02:49 now: "assembly accessions are a first-class case here, not something the dialog blocks", with Genome mode + `lungfish fetch genome`. The old "the dialog will refuse it" is gone. |
| 5 | MSA wizard control names: "Strategy", "Sequence Type", "Output Order"; no "Aligner"/"Mode" | LANDED | Ch04:67 "Leave **Strategy** on **Auto** (MAFFT is the only aligner...)"; troubleshooting Ch04:217 "switch **Strategy** from Auto to **L-INS-i**". No "Aligner"/"Mode" anywhere. |
| 6 | Drop the MUSCLE/Clustal "select in the Aligner dropdown" promise | LANDED | Ch04:50-52 reframes MUSCLE/Clustal as context only: "They are not selectable in Lungfish... run that tool outside Lungfish and import the resulting alignment as a bundle". No false UI promise. |
| 7 | Fix IQ-TREE bootstrap default (OFF; tick Ultrafast Bootstrap first, else no support values) | LANDED | Ch04:103 "Tick **Ultrafast Bootstrap** to turn on support values, then set the replicate count to `1000`. This step is easy to miss: bootstrap is off by default..." Matches `bootstrapEnabled = false` (source). Silent-failure trap closed. |
| 8 | IQ-TREE dialog labels: no "Method", field is "Model" (default MFP), no "Outgroup" dropdown | LANDED | Ch04:102 "Leave **Model** on **MFP**"; Ch04:104 "There is no outgroup field here. Rooting on an outgroup is a separate step..." No "Method"/"Substitution model"/"Outgroup". |
| 9 | `lungfish import` → `lungfish import fasta` in ch01 (and ch01 frontmatter entry_points) | LANDED | Ch01:112 `lungfish import fasta path/to/MN908947.3.gb`; frontmatter entry_points:13 `CLI: lungfish import fasta`. Re-verified `import fasta` accepts `.gb` (`ImportCommand.swift:541` genbankExtensions includes `gb/gbff/embl`). |
| 10 | Fix ch04 CLI frontmatter and add a tree-inference CLI example with `--project`/`--output` | LANDED | Frontmatter:13 `CLI: lungfish align mafft, lungfish tree infer iqtree`. Inference block added at Ch04:113-119 with `--project .` and `--output ...`, matching the required options (`TreeCommand.swift`). |
| 11 | Fix `Tools > Orient` cross-reference (no such item; Orient Reads is FASTQ-scoped; use `--adjust-direction`) | LANDED | Ch04:217 "There is no `Tools > Orient` for reference FASTA; the FASTQ 'Orient Reads' operation handles reads... run the alignment from the CLI with `lungfish align mafft --adjust-direction fast`". `fast` is a valid value (`AlignCommand.swift:69` "off, fast, accurate"). |
| 12 | Fix GFF3 "must be paired with a matching FASTA in the same import" (it is a separate attach-to-existing-bundle step) | LANDED | Ch01:54-56 + table row Ch01:64 "Attached to an existing reference bundle, not imported on its own." Prose at Ch01:76-78 directs importing the FASTA first, then the separate annotation-track importer. "in the same import" is gone. |
| 13 | Fix Extract dialog: title "Extract Sequence"; only Destination + Name; no coordinate fields | LANDED | Ch03:60-61 "A sheet titled **Extract Sequence** opens... a **Destination** radio group and a **Name** field; there are no coordinate boxes". Title corrected from "Extract Visible Region" where the dialog is referenced. |
| 14 | Minor menu/label fixes: "Import Center…" + Cmd-Shift-I; ch03 ellipses; "Minimum ORF length"; "Track name"/"Track ID" | LANDED | Ch01:98 "Import Center…" + "press Cmd-Shift-I". Ch03 table:47-48 "Reverse Complement…" (Cmd-Shift-R), "Translate…" (Cmd-Shift-T). Ch03:93 "Minimum ORF length", "Track name", "Track ID". All match source (`SequenceORFOperationDialog.swift`, `IQTreeInferenceDialog.swift`). |

## Coverage-gap additions from Round 1 (spot check)

| Round 1 coverage gap | Status | Note |
|---|---|---|
| Multi-accession + search fetch, ENA path, accession-list CSV (ch02) | LANDED | Ch02:111-132 "From the command line: batch and search fetching" adds multi-accession `fetch ncbi`, `--db`, `--api-key`/`NCBI_API_KEY`, `fetch search`, and `fetch ena {search,fasta,reads}`. ENA subcommand names verified (`FetchCommand.swift:1105-1107`). CSV accession-list import mentioned (Ch02:123). |
| `lungfish msa` transform family: consensus, distance (ch04) | LANDED | Ch04:84-95 "Working with an alignment after you build it" documents `msa consensus`, `msa distance` (TSV, identity/p-distance), and `msa export` formats. Subcommands verified (`MSACommand.swift:678,1645,503`). Correctly notes `lungfish msa` does not build (that is `align mafft`). |
| Import pre-built MSA/tree (ch04) | LANDED | Ch04:192-201 "Importing a pre-built alignment or tree" adds `lungfish import msa` / `lungfish import tree` with `--project`. |
| CLI parity for Sequence menu: extract (flanks), translate, delete-annotation-track (ch03) | LANDED | Ch03:131-145 "From the command line" adds `extract sequence` (`--flank/--flank-5/--flank-3/--reverse-complement`), `translate` (`--frame/--table/--trim-to-stop/--longest-orf`), and the removal command. The "how to remove the ORF track" gap is closed (Ch03:96 + 145 cite `sequence delete-annotation-track`). |
| Subset-to-tree `--rows`/`--columns` (ch04) | LANDED | Ch04:107 "select the rows or columns you want in the MSA viewport... The CLI exposes the same scoping through `--rows` and `--columns`." |
| `Sequence > Add Annotation…` listed (ch03) | LANDED | Ch03 table:50 "Add Annotation" row added; described at Ch03:31. |
| Wider import formats/compression + name `imported_annotations` (ch01) | LANDED | Ch01 table:63-65 adds `.embl`, compression `.bgz/.bz2/.xz/.zst`; Ch01:67-70 names the `imported_annotations` track. |

## Accessibility fixes from Round 1 (spot check)

| Round 1 accessibility fix | Status | Note |
|---|---|---|
| Gloss ORF and codon at first use (ch03) | LANDED | Ch03:29 now glosses both inline: "An open reading frame (ORF) is a stretch that runs from a start codon to a stop codon... a codon is a run of three bases that codes for one amino acid." |
| Replace "Creamsicle-coloured blocks" with plain "orange" (ch01) | LANDED | `grep creamsicle` = zero hits. Ch01:156 "as orange blocks". |
| Gloss "checksum" once; soften provenance density (ch02) | LANDED | Ch02:109 glosses "the output checksum (a fingerprint of the file's exact bytes)". INSDC glossed at Ch02:144. |
| Gloss MFP / ModelFinder Plus (ch04) | LANDED | Ch04:102 "MFP is ModelFinder Plus: it tests a set of substitution models and picks the best-fitting one from your data before inferring the tree." |
| Fix ch02 "Next" link (was skipping ch03, jumping to ch04) | LANDED | Ch02:170 now points to "Extracting and Comparing Sequences" (03), with an optional jump to Reads. Reading order restored. |
| Fence bench-vs-CLI split per chapter | LANDED (soft) | Each CLI subsection now carries an explicit "A bench reader can skip this subsection" signpost (Ch02:113, Ch03:133, Ch04:86). Not a hard structural fence, but it satisfies the intent. |
| Confirm coordinate-field syntax (bare `21563-25384` vs `chr:` prefix) | PARTIAL | Ch01:186-189 now explains the placeholder `chr:start-end` AND states "When the bundle holds one contig, the bare range `21563-25384` resolves to it." This is a reasonable resolution of the NEEDS-HUMAN-CHECK, but it is an asserted runtime behavior I could not confirm from source (parsing is delegated via `didRequestPositionInput`). See Residual issues. |

**Verdict on Part 1:** All 14 critical fidelity fixes LANDED. All seven sampled
coverage-gap additions LANDED. Accessibility fixes LANDED except one PARTIAL
(coordinate syntax is now asserted but unverified). The editors executed the
Round 1 plan faithfully and did not merely paraphrase. Two NEW wrong menu paths
were introduced or left in by the expansion (see personas + synthesis).

---

# PART 2: PERSONA RE-READS

## Persona A: Nadia Okonkwo, first-year virology grad student (novice, bench-scientist)

**(a) Round 1 pain points: resolved.**

- The Import Center name and shortcut now match. "Step 2 reads 'choose **File > Import Center…** (or press Cmd-Shift-I)' (Ch01:135-137). The three dots and the shortcut are both there now. I am no longer second-guessing whether I am in the right place."
- The GFF3 confusion is gone. "The table row now says GFF3 is 'Attached to an existing reference bundle, not imported on its own' (Ch01:64), and the prose tells me to 'import the FASTA first' (Ch01:92). I will not try to drag a FASTA and a GFF3 in together anymore."
- The color jargon is fixed. "Ch01:156 says 'as orange blocks'. No more hunting for what Creamsicle means."
- ORF/codon are glossed. "Ch03:29 defines both the first time they appear. That is exactly the one-line gloss I asked for."

**(b) New problems the revision introduced.**

- **`File > Import` in chapter 04 does not exist (NEW residual).** "Ch04:64 step 1 says 'use `File > Import` and select them together.' But chapter 01 just taught me the importer is called **Import Center…**. There is no plain `File > Import` item. I checked the File menu in my head against what ch01 said and they disagree. The fix that corrected ch01 did not reach ch04." (Confirmed against source: `MainMenu.swift:201` has only "Import Center…"; there is no bare "Import" item.) "For a novice this is the same trap you just closed in chapter 01, reopened one chapter later."
- **Mild over-correction on the coordinate field.** "Ch01:186-189 now explains both the `chr:start-end` placeholder and that a bare `21563-25384` works on a single-contig bundle. Good. But it is a dense three-sentence block for a beginner. I understood it, but it is the most technical sentence in an otherwise gentle chapter."

**(c) Residual fidelity issues vs ground truth.**

- The coordinate-syntax claim is asserted, not demonstrated with a screenshot, and the ground truth flagged it NEEDS-HUMAN-CHECK. As a novice I will trust it, but if a bare range silently does the wrong thing on a multi-contig bundle I would not know.

**What she still loves.** "The 'When import fails' section (Ch01:195-220) survived intact, including the Microsoft Word formatting-characters case and the valid-FASTA example block. That is still going in my lab notebook."

---

## Persona B: Marcus Bell, research associate running surveillance pipelines (intermediate, bench-scientist/analyst)

**(a) Round 1 pain points: resolved.**

- The NCBI GUI procedure now matches the app. "Ch02:72-76 is the real flow: Search NCBI lands on the GenBank & Genomes tab, set Mode to Nucleotide, leave Include GFF3 Annotations on, click **Search**, select the record, click **Download Selected**. No Format menu, no Run button. This is what I actually see."
- The phantom import step is gone. "Ch02:77 'There is no separate import step in the GUI. The download produces the bundle directly.' That matches reality. And the worked example (Ch02:93) lists only the one `.lungfishref`, not a loose `.gb` plus a separate import."
- The assembly claim is reversed correctly. "Ch02:49 now says assembly accessions are 'a first-class case here, not something the dialog blocks.' Exactly right. I can stop expecting a refusal that never comes."
- The tab naming is reconciled. "Ch02:31 spells out that Search NCBI opens 'the "GenBank & Genomes" tab'. The window no longer feels like the wrong one."
- Checksum is glossed. "Ch02:109 '(a fingerprint of the file's exact bytes)'. That is the one-line gloss I wanted."

**(b) New problems the revision introduced.**

- **`Reads > Map to Reference` in chapter 03 is a wrong menu path (NEW residual).** "Ch03:105 says 'Map reads to it with `Reads > Map to Reference`.' There is no top-level **Reads** menu in this app, and no item called 'Map to Reference'. Read mapping is `Tools > FASTQ/FASTA Operations > Mapping…`, and the operation is named 'Map Reads'." (Confirmed: `MainMenu.swift` top-level menus are File, Edit, View, Sequence, Tools; the mapping item is "Mapping…" at line 681; the op display name is "Map Reads".) "This is the same class of error Round 1 spent its whole budget killing, the confidently-cited menu path that does not exist, reintroduced in a cross-reference."
- **`File > New Project` is fine, but verify the sibling.** "Ch02:68 'create one first via `File > New Project`' is correct (the item is 'New Project'). I only flag it because the adjacent `File > Import` in ch04 is wrong, so an editor should sweep all the `File >` references at once."

**(c) Residual fidelity issues vs ground truth.**

- None in his lane. The ENA and multi-accession additions (Ch02:111-132) read correctly and the ground truth confirms those subcommands. He spot-checked `fetch ena search` and it is real.

**What he would lift.** "The whole batch/search subsection (Ch02:111-132) is new and exactly what I copy into wikis. And the 'why GenBank' justification (Ch02:33) survived: 'without bundled annotations, the AA columns in your VCF will be empty.'"

---

## Persona C: Dr. Priya Raghavan, postdoc fluent in command-line genomics (advanced, analyst)

**(a) Round 1 pain points: resolved. The tree workflow is finally followable.**

- `Tools > Infer Tree` is gone. "Ch04:97-99 now launches inference correctly: 'right-click and choose **Build Tree with IQ-TREE…**. The **Phylogenetic Tree Operations** dialog opens'. The hard stop is removed. I can actually start a tree from the documented path."
- The CLI frontmatter is fixed and an inference example exists. "Frontmatter now says `lungfish align mafft, lungfish tree infer iqtree`, and Ch04:113-119 gives the real inference command with `--project .` and `--output`. The chapter even warns (Ch04:111) that inference 'requires both `--project` (for staging) and `--output`', unlike the post-inference commands. That is the distinction I had to reverse-engineer last time."
- The wizard control names are right. "Strategy / Sequence Type / Output Order (Ch04:67). No 'Aligner', no 'Mode'."
- The bootstrap trap is closed. "Ch04:103 makes me tick Ultrafast Bootstrap first and explicitly says bootstrap is off by default. The silent failure is gone."
- Model/Outgroup labels fixed (Ch04:102-104). MFP is glossed (Ch04:102). The `--adjust-direction fast` remedy replaced the broken `Tools > Orient` (Ch04:217), and `fast` is a real value.
- The `msa` transform family and `import msa`/`import tree` are now documented (Ch04:84-95, 192-201). "This is the coverage I asked for. `msa distance` writing a p-distance TSV is exactly the command my analysts want."

**(b) New problems the revision introduced.**

- **Subtree-extraction menu title is inconsistent with the app's ellipsis convention (LOW).** "Ch04:179 says right-click and choose `Extract Subtree as New Bundle...` with three literal dots, but Ch04:133's inventory writes 'extract a subtree as a new bundle' in prose. Minor, and I cannot confirm the exact viewport menu title from the chapter, but the ground truth left tree-viewport menu titles as NEEDS-HUMAN-CHECK (`PhylogeneticTreeViewController.swift` was not enumerated). If the editors asserted these titles, someone should confirm them at runtime."
- **`Strategy` value list could mislead on `L-INS-i` casing.** "Ch04:217 says switch Strategy to **L-INS-i**. The CLI value is `linsi` (`AlignCommand.swift:60`), and the GUI label may render 'L-INS-i'. The chapter is GUI-facing here so 'L-INS-i' is defensible, but a reader bouncing to the CLI will not find a `--strategy L-INS-i`; it is `--strategy linsi`. A half-line noting the CLI spelling would prevent a copy-paste miss." (This is a clarity nit, not a fidelity break in the GUI context.)

**(c) Residual fidelity issues vs ground truth.**

- The tree-viewport right-click titles (`Re-root Here`, `Collapse Clade`/`Expand Clade`, `Copy Selected Tip Names`, `Extract Subtree as New Bundle...`) and toolbar controls (`Layout`, `Color`, `Tip labels`) remain NEEDS-HUMAN-CHECK per the ground truth. The CLI equivalents are all confirmed real, but the exact viewport strings should be validated before Round 3 sign-off.
- The `metadata.tsv` id-column names (`id`, `sample`, `sample_id`, `name`, `tip`, Ch04:152) are still asserted from the Round 1 carry-over and were NEEDS-HUMAN-CHECK; not re-confirmed here.

**What she would lift.** "The 'What this chapter does not cover' scope fence (Ch04:203-213) survived. And the post-inference CLI blocks (`tree reroot`/`relabel`/`extract-subtree`) are still accurate."

---

# Round 2 fixes for editors

The section is in strong shape. Every Round 1 critical fix landed in the real
menu path / command / dialog field, and the large coverage-gap and accessibility
additions are accurate against source. The work that remains is small and
concentrated: two wrong menu paths that the chapter-by-chapter expansion either
reintroduced or never swept, plus a few low-priority clarity items and the
runtime-verification debts the ground truth already flagged.

## Must fix (fidelity)

1. **Chapter 04, line 64: `File > Import` does not exist.** Change "use
   `File > Import` and select them together" to `File > Import Center…`
   (Cmd-Shift-I), the only import menu item (`MainMenu.swift:201`). Chapter 01
   was corrected to "Import Center…" in Round 1 but the same fix did not reach
   chapter 04. This is the same novice trap (Persona A) reopened one chapter
   later. While here, sweep all `File >` references in the section for
   consistency; `File > New Project` (Ch02:68) is correct and can stay.

2. **Chapter 03, line 105: `Reads > Map to Reference` is a non-existent menu
   path.** There is no top-level **Reads** menu (`MainMenu.swift` top-level menus
   are File, Edit, View, Sequence, Tools) and no item titled "Map to Reference".
   Read mapping is `Tools > FASTQ/FASTA Operations > Mapping…`
   (`MainMenu.swift:681`); the operation's display name is "Map Reads". Reword to
   the real path, or soften to a forward-reference such as "map reads to it (see
   the Reads chapter)". Persona B flagged this as exactly the class of error
   Round 1 was dedicated to eliminating.

## Should fix (clarity / style)

3. **Chapter 04: note the CLI spelling of the L-INS-i strategy.** Troubleshooting
   (Ch04:217) tells GUI readers to pick **L-INS-i**, but the CLI value is
   `linsi` (`--strategy linsi`, `AlignCommand.swift:60`). A half-clause giving
   the CLI spelling prevents a copy-paste miss for readers who jump to the shell
   (Persona C).

4. **Chapter 01: lighten the coordinate-syntax paragraph.** Ch01:186-189 is now
   correct but dense for the bench tier (Persona A). Consider splitting the
   single/range explanation into two shorter sentences, or moving the
   multi-contig caveat to a parenthetical.

## Verify at runtime (carried-over NEEDS-HUMAN-CHECK, not blockers)

5. **Coordinate field accepts a bare `21563-25384`.** Ch01:188-189 and the
   ch03 worked examples (Ch03:102, 114) now assert this. The ground truth left
   it NEEDS-HUMAN-CHECK and the parse is delegated (`didRequestPositionInput`),
   so it is unverified from source. Confirm in the running app before Round 3,
   since several worked examples depend on it.

6. **Tree-viewport right-click titles and toolbar labels (Ch04:133, 137, 173,
   179).** `Re-root Here`, `Collapse Clade`/`Expand Clade`, `Copy Selected Tip
   Names`, `Extract Subtree as New Bundle...`, `Layout`/`Color`/`Tip labels`
   were asserted but the ground truth could not enumerate
   `PhylogeneticTreeViewController.swift`. Confirm the exact strings at runtime.
   (The CLI equivalents are all verified real.)

7. **`metadata.tsv` id-column names (Ch04:152).** `id/sample/sample_id/name/tip`
   carried over from Round 1; was NEEDS-HUMAN-CHECK and not re-confirmed here.

## Style / bullet-cap

No violations. Scanned all four chapters: zero em dashes, zero banned hype words,
no "Creamsicle" in reader-facing prose. No H2 section exceeds five list items or
two lists (the largest are the five-item numbered procedures in ch02/ch04 and the
five-item "What this chapter does not cover" list in ch04, all at the cap, none
over). The primer-before-procedure structure holds in every chapter.
