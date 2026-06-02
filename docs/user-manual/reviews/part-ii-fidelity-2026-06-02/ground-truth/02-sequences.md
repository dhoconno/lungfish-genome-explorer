# Ground-truth reality map: 02-sequences

Scope: the four Sequences chapters listed below, checked against
`Sources/LungfishCLI/Commands/*`, `Sources/LungfishApp/App/MainMenu.swift`,
`Sources/LungfishApp/Views/*`, and the `.build/debug/lungfish-cli` help output
(binary present, built 2026-06-01). The CLI executable is invoked as
`lungfish` in all `CommandConfiguration` and provenance strings; the binary on
disk is also installed as `lungfish-cli`. Both `--help` and the source agree.

Chapters audited:
- `chapters/02-sequences/01-importing-and-viewing.md`
- `chapters/02-sequences/02-downloading-from-ncbi.md`
- `chapters/02-sequences/03-extracting-and-comparing.md`
- `chapters/02-sequences/04-msa-and-trees.md`

Authoritative cross-cutting facts used throughout this map:
- There is NO `Tools > Infer Tree` menu item anywhere in the app. `grep -rn "Infer Tree" Sources/` returns zero hits. Tree inference is launched from inside the MSA viewport via a context-menu item titled "Build Tree with IQ-TREE…" (`MultipleSequenceAlignmentViewController.swift:1369-1371`), which opens the "Phylogenetic Tree Operations" dialog (`IQTreeInferenceDialog.swift:99-101`).
- There is NO `Tools > Orient` menu item. Orientation is a FASTQ read operation ("Orient Reads") reached through `Tools > FASTQ/FASTA Operations` (`MainMenu.swift` Tools submenu; `OrientWizardSheet.swift:111`).
- The GUI MSA builder lives at `Tools > FASTQ/FASTA Operations > Multiple Sequence Alignment…` (`MainMenu.swift:676`). Its only aligner is MAFFT; the picker is labeled "Strategy" (`FASTQOperationToolPanes.swift:467`), not "Aligner" and not "Mode".
- `lungfish import` is a parent command with REQUIRED subcommands (`fasta`, `bam`, `vcf`, `msa`, `tree`, `fastq`, ...). It has no default subcommand and cannot take a bare file path (`ImportCommand.swift:42-76`; `lungfish import --help`).

---

## Chapter 01: Importing and Viewing a Sequence

### CLAIMS THAT DO NOT MATCH CODE

1. CLI import command is wrong (missing `fasta` subcommand).
   - Doc line 94: ```lungfish import path/to/MN908947.3.gb```
   - Code: `ImportCommand` has no default subcommand; `import` alone prints the subcommand list and errors. The real command is `lungfish import fasta path/to/MN908947.3.gb`. The `fasta` subcommand accepts `.fa/.fasta/.gb/.embl` and `.gz/.bgz/.bz2/.xz/.zst` (`ImportCommand.swift:516-535`, FASTASubcommand `commandName = "fasta"`; confirmed by `lungfish import --help`).
   - Frontmatter `entry_points` line 13 ("CLI: lungfish import") is likewise incomplete; the runnable form is `lungfish import fasta`.

2. GFF3 "must be paired with a matching FASTA in the same import" is not how either path works.
   - Doc lines 58 and 50: GFF3 row says "Must be paired with a matching FASTA in the same import."
   - Code: `lungfish import fasta` takes a single reference argument and no GFF/annotation argument (`ImportCommand.swift:522` `@Argument inputFile`; no `--gff`/`--annotation` option on the subcommand). In the GUI, GFF3/GFF/GTF/BED is a SEPARATE Import Center importer ("Annotation Track") that attaches to an EXISTING reference bundle (`ImportCenterViewModel.swift:528-537`, "Attach GTF, GFF, GFF3, or BED annotations to an existing reference sequence bundle"). There is no single combined FASTA+GFF3 import in this section's tooling.

3. "File > Import Center" menu path omits the real title and shortcut.
   - Doc lines 11, 81, 84, 116: "File > Import Center".
   - Code: the menu item title is "Import Center…" with key equivalent Cmd-Shift-I (`MainMenu.swift:200-206`, `keyEquivalent: "i"`, `modifierMask [.command, .shift]`). The path and shortcut are both unstated. This is minor but load-bearing for a reader looking for the item.

4. Drag-drop target wording: the sidebar import affordance is real but the file lists the entry point loosely.
   - Doc lines 70-76 describe dragging onto "the Reference Sequences folder in the sidebar."
   - Code: sidebar drag import exists, but this map cannot confirm from source that the drop must land specifically on the "Reference Sequences" folder versus the sidebar generally. Flagging as partially unverified (see NEEDS-HUMAN-CHECK).

5. Navigation: "Sequence > Go to Location opens a coordinate field" and accepts "21563-25384".
   - Doc lines 161-168.
   - Code: `Sequence > Go to Location…` exists with shortcut Cmd-L (`MainMenu.swift:583-587`, `goToPosition`). Separately, the coordinate ruler hosts an editable position field whose placeholder is `chr:start-end` (`EnhancedCoordinateRulerView.swift:181`). The doc conflates the menu sheet with the ruler field and asserts a bare `21563-25384` range works; the placeholder implies a `chr:` prefix may be expected. Exact accepted syntax needs a runtime check (see NEEDS-HUMAN-CHECK).
   - `Sequence > Go to Gene…` is real, shortcut Cmd-Shift-G (`MainMenu.swift:590-595`, `goToGene`). The "typing spike jumps to S gene" behavior is plausible but the fuzzy-match specifics are runtime.

### APP FEATURES MISSING FROM THE DOCS

1. `Sequence > Add Annotation…` menu item exists (`MainMenu.swift:617-621`, `addAnnotation`). The chapter lists only Reverse Complement, Translate, Go to Location, Go to Gene, Copy/Extract Visible Region, and Find ORFs, but never Add Annotation.
2. `lungfish import fasta` accepts compressed and additional formats beyond the chapter's table: `.embl`, `.gbff`, and `.bgz/.bz2/.xz/.zst` compression (`ImportCommand.swift:522`, genbankExtensions includes `gbff`/`embl`; compressionExtensions includes `bz2/xz/zst`). The doc's "Accepted formats" table only lists FASTA, GenBank, GFF3, and `.fasta.gz/.fa.gz`.
3. GenBank import materializes an annotation track with id `imported_annotations` (`ImportCommand.swift:761`; `ReferenceBundleImportService.swift:285`). The chapter mentions annotations import "automatically" but does not name the track, which chapter 02 later relies on.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. Exact syntax the ruler position field accepts (bare `21563-25384` vs `chr:21563-25384`). Placeholder is `chr:start-end` (`EnhancedCoordinateRulerView.swift:181`); parsing is delegated via `didRequestPositionInput` and not fully resolvable from this file alone.
2. Whether the annotated GenBank import renders spike `S`, `N`, ORF1ab as "Creamsicle-coloured blocks" (doc lines 134-135). Annotation rendering color is a runtime/style concern.
3. Whether sidebar drag-drop requires the "Reference Sequences" folder specifically as the drop target (doc lines 73-76).
4. The three-pane viewport description (position ruler, base track, annotation track) and the "coverage-style density rendering when zoomed out" (doc lines 142-148). The panes exist (`SequenceViewerView+*`, `EnhancedCoordinateRulerView`), but the exact pane labels rendered at runtime are not literal strings in source.

---

## Chapter 02: Downloading from NCBI

### CLAIMS THAT DO NOT MATCH CODE

1. The GUI NCBI dialog has NO "Format" menu offering FASTA / GenBank / GFF3 / XML.
   - Doc lines 31, 55-64, 74, 89: "The dialog accepts an accession, a format (FASTA, GenBank, GFF3, or XML), and a save location"; "From the Format menu, choose GenBank".
   - Code: the GenBank search pane offers a "Mode" picker with values Nucleotide / Genome / Virus, plus two checkboxes "RefSeq Only" and "Include GFF3 Annotations" (`GenBankGenomesSearchPane.swift:6-8`, `modeTitles = ["Nucleotide","Genome","Virus"]`, `filterTitles = ["RefSeq Only","Include GFF3 Annotations"]`). There is no FASTA/GenBank/GFF3/XML format selector in the GUI. The four-format choice is a CLI-only concept (`--fetch-format`, `FetchCommand.swift:54-58`).

2. The GUI dialog is a search-results browser, not an accession+format+save form.
   - Doc lines 72-75, 88-90: "type or paste the accession ... choose GenBank from the Format menu ... Click Run."
   - Code: the dialog (`DatabaseSearchDialogState`) is a tabbed search UI. Its primary button toggles between "Search" and "Download Selected" depending on selection (`DatabaseSearchDialogState.swift:119-121`, `primaryActionTitle`). The button is never labeled "Run". The flow is: enter a query, search, select records, then "Download Selected".

3. The dialog tab/menu names do not match.
   - Doc lines 31, 47, 72: "Tools > Search Online Databases > Search NCBI"; describes a "Pathoplexus tab".
   - Code: the menu items are "Search NCBI...", "Search SRA...", "Search Pathoplexus..." (`MainMenu.swift:752-768`). The dialog's internal tabs are titled "GenBank & Genomes", "SRA Runs", and "Pathoplexus" (`DatabaseSearchDialogState.swift:26-35`). So the NCBI menu opens the dialog on the "GenBank & Genomes" tab, not a tab named "Search NCBI".

4. The GUI download produces a `.lungfishref` bundle directly; "import that GenBank file as a reference bundle" is not a separate GUI step.
   - Doc lines 76, 91, 96-97: step 5 says "Import that GenBank file as a reference bundle"; the worked example shows `Downloads/MN908947.3.gb` plus a separately produced `.lungfishref`.
   - Code: nucleotide and virus downloads "always end as .lungfishref bundles" (`DatabaseBrowserViewController.swift:2655` comment and `genBankVM.buildBundle...` path at 2656-2672). The GUI builds the bundle in one action; there is no manual import-after-download step in the UI. The two-step model (download `.gb`, then import) is only literally true for the CLI form.

5. "If you paste an assembly accession into the NCBI dialog ... the dialog will refuse it."
   - Doc line 49.
   - Code: the GenBank pane explicitly supports a "Genome" mode and genome (assembly) downloads build bundles via the assembly-summary path (`DatabaseBrowserViewController.swift:2617-2653`, "Handle genome downloads: download FASTA + GFF3 and build .lungfishref bundle"). Assembly accessions are NOT refused in this dialog; they are a first-class mode. This claim is inverted.

6. CLI `fetch ncbi` save path and example are correct, but the prose around them overstates GUI parity.
   - Doc lines 104-111 CLI block is accurate: `lungfish fetch ncbi MN908947.3 --fetch-format genbank --save-to ...` and `lungfish import fasta ... --output-dir . --name ...` both match (`FetchCommand.swift:30-78`; `ImportCommand.swift:516-535`).
   - The retry description matches code: HTTP 429 retried up to five times, exponential backoff (`NCBIService` `retryPolicy: .rateLimitDefaults`, `FetchCommand.swift:93-96`; `--no-retry` flag at 72-76). The "starting at 5 seconds and capping at 5 minutes" specifics (doc line 122) are not visible in `FetchCommand.swift` and live in the retry policy definition; treat the exact numbers as needing a check against `NCBIService`/`retryPolicy` source.

7. Pathoplexus organism list is asserted exactly and may drift.
   - Doc line 147 lists CCHF, Sudan ebolavirus, Zaire ebolavirus, HMPV, Marburg, measles, mpox, RSV-A, RSV-B, West Nile.
   - Code: the Pathoplexus pane is `PathoplexusSearchPane.swift` (not read in full here). The exact chip set must be verified against that file; do not trust the doc's list without confirming the source enum.

### APP FEATURES MISSING FROM THE DOCS

1. `lungfish fetch search` subcommand (search NCBI and list matching accessions) exists (`FetchCommand.swift:501-590`, `SearchSubcommand`, `commandName = "search"`) and is never mentioned.
2. `lungfish fetch ena` with `search`, `reads`, and `fasta` subcommands exists (`FetchCommand.swift:1091-1326`). The chapter routes ENA only implicitly through SRA fallback and never documents the direct `fetch ena fasta`/`fetch ena reads` path.
3. `lungfish fetch ncbi` accepts MULTIPLE accessions in one call and `--db nucleotide|protein` (`FetchCommand.swift:45-52`, `@Argument accessions: [String]`). The chapter treats it as single-accession only.
4. `lungfish fetch ncbi --api-key <key>` flag exists in addition to the `NCBI_API_KEY` env var (`FetchCommand.swift:66-70`). The chapter mentions only the env var.
5. The GUI offers an "Include GFF3 Annotations" toggle and a "RefSeq Only" toggle for nucleotide/virus searches (`GenBankGenomesSearchPane.swift:7-8`), which the chapter's format discussion never surfaces.
6. The GUI supports importing an accession LIST from a CSV/text file for batch download (`DatabaseBrowserViewController.swift:1302-1334`, `importAccessionList`). Undocumented.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. Exact backoff timing ("5 seconds ... 5 minutes", doc line 122) and the "roughly three requests per second" figure (line 163) live in `NCBIService` retry-policy source, not in `FetchCommand.swift`.
2. Pathoplexus consent flow, large-result-set prompt thresholds (doc lines 146-153), and the "first thousand records" choice. There is a large-result alert in `DatabaseBrowserViewController.swift:682-688`, but the exact wording and the 1000 threshold need source confirmation in the view-model.
3. Provenance sidecar field list (doc lines 113, 133-135). The CLI writes a sidecar via `writeNCBIFetchOutputWithProvenance` with endpoint, accession, checksum, size, retry events, and `apiKeyProvided` boolean (`FetchCommand.swift:279-328`). The exact JSON field names a reader will see are not all literal in the chapter and should be checked against a produced file.

---

## Chapter 03: Extracting and Comparing Sequences

### CLAIMS THAT DO NOT MATCH CODE

1. The Extract dialog does NOT ask you to "confirm the start and end coordinates."
   - Doc lines 59, 101: "name the new bundle and confirm the start and end coordinates. Click Extract."
   - Code: the extraction sheet is titled "Extract Sequence" and contains only a "Destination:" radio group and a "Name:" text field (`FASTASequenceExtractionDialog.swift:31`, `46-76`). There are no start/end coordinate fields in the dialog. Coordinates come from the current visible region before the dialog opens. The dialog title is "Extract Sequence", not "Extract Visible Region".

2. Menu titles use "Visible Region" but the CLI/dialog semantics are visible-range, not a dragged selection box; the doc mixes the two.
   - Doc lines 44-48 table and lines 57, 70: "Drag across the desired range in the ruler, or type coordinates into the range box."
   - Code: menu items are "Copy Visible Region as FASTA" (Cmd-Shift-C) and "Extract Visible Region…" (Cmd-Shift-E) (`MainMenu.swift:600-612`). The viewport context menu also exposes "Copy Visible Region" and "Zoom to Visible Region" (`SequenceViewerView+Interaction.swift:884-899`). A draggable `selectionRange` exists (`SequenceViewerView+Interaction.swift:561,591`), and the ruler has a position field with placeholder `chr:start-end` (`EnhancedCoordinateRulerView.swift:181`). The menu names and shortcuts in the doc table are CORRECT; the "range box" phrasing is acceptable shorthand for the ruler position field but should name it precisely.

3. Reverse Complement and Translate menu items carry an ellipsis and route through the FASTQ/FASTA Operations dialog; the shortcuts are right but the table omits the ellipsis.
   - Doc lines 47-48 table: "Reverse Complement" / "Translate".
   - Code: titles are "Reverse Complement…" (Cmd-Shift-R) and "Translate…" (Cmd-Shift-T) (`MainMenu.swift:568-578`). Both also appear under `Tools > FASTQ/FASTA Operations` (`MainMenu.swift:696-704`). The doc's claim that these "open the standard FASTQ/FASTA Operations dialog" matches the wiring (`SequenceMenuActions.reverseComplement`/`translate`).

4. Find ORFs dialog field labels are close but not exact.
   - Doc line 91: "reading frames, codon table, output track, minimum nucleotide length, and whether partial ORFs or alternative starts."
   - Code: the dialog title is "FIND ORFS" with sections "Reading Frames", "Translation" (fields "Codon table" and "Minimum ORF length"), "Output" (fields "Track name" and "Track ID"), and "Options" (toggles "Include partial ORFs", "Allow alternative starts") (`SequenceORFOperationDialog.swift:146`, `173-207`). The run button is "Run" (`:153`). The doc's "output track" is two fields (Track name + Track ID), and "minimum nucleotide length" is labeled "Minimum ORF length".

5. CLI backing command name is correct.
   - Doc line 92: "calls lungfish-cli sequence annotate-orfs".
   - Code: matches (`SequenceCommand.swift:23-27`, `AnnotateORFs` `commandName = "annotate-orfs"`). Defaults match the doc's later examples: `--min-length` default 100, frames default `+1,+2,+3,-1,-2,-3`, `--table` default 1 (`SequenceCommand.swift:42-54`). The worked example using `300` nucleotides and "all six frames" is consistent.

6. Copy-as-FASTA header format is asserted with specific fields.
   - Doc lines 72, 114: header reads `>MN908947.3-spike:38-59 source=MN908947.3:21600-21621 strand=+`.
   - Code: the copy path is `copySelectionFASTA` (`MainMenu.swift:600-604`); the exact header string is generated at runtime and not a literal in the files read here. Treat the precise header tokens as unverified (see NEEDS-HUMAN-CHECK).

### APP FEATURES MISSING FROM THE DOCS

1. The CLI `lungfish extract sequence` offers `--flank`, `--flank-5`, `--flank-3`, `--reverse-complement`, and `--line-width` (`ExtractCommand.swift:62-96`). The chapter is GUI-only for extraction and never mentions the CLI extract command or its flanking options, even though extracting a region with flanks is a common bench need.
2. `lungfish extract sequence` can write either a plain FASTA or a `.lungfishref` bundle depending on the output extension (`ExtractCommand.swift:256-315`). Undocumented CLI parity for the "Extract Visible Region" GUI action.
3. `lungfish translate` standalone CLI command exists with `--frame`, `--table`, `--trim-to-stop`, `--no-stop-asterisk`, and `--longest-orf` (`TranslateCommand.swift:31-68`). The chapter mentions Translate only as a GUI menu item.
4. The Extract dialog's "Destination:" radio offers more than one destination kind (`FASTASequenceExtractionDialog.swift:50`, iterates `DialogDestination.allCases`); the chapter describes only "new bundle". The other destination option(s) are undocumented.
5. The CLI `sequence delete-annotations` and `sequence delete-annotation-track` subcommands (`SequenceCommand.swift:149-254`) let you remove ORF/annotation tracks added by Find ORFs. The chapter says the ORF track "persists with the bundle until you remove it" but never says how.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. Exact copied FASTA header format including `source=` and `strand=` tokens (doc lines 72, 114).
2. Whether the "range box" the doc references is the ruler position field (`EnhancedCoordinateRulerView`) and whether typing a bare `38-59` works without a `chr:` prefix.
3. The right-click ORF actions "copy its range, extract it, or translate it" (doc line 94). The viewport has rich context menus (`SequenceViewerView+Interaction.swift`), but the exact ORF-row menu items are not enumerated in the files read.
4. The stated extracted spike length "3,822 bases" (doc line 103) for `21563-25384` is a data fact (inclusive span = 25384 - 21563 + 1 = 3822), arithmetically consistent, but depends on the reference; leave for the data reviewer.

---

## Chapter 04: Multiple Sequence Alignments and Phylogenetic Trees

### CLAIMS THAT DO NOT MATCH CODE

1. `Tools > Infer Tree` does not exist.
   - Doc lines 11, 36, 84, 86: "Open an MSA bundle, then Tools > Infer Tree"; "Tools > Infer Tree runs IQ-TREE"; "run Tools > Infer Tree. The tree wizard opens."
   - Code: no such menu item (`grep -rn "Infer Tree" Sources/` returns nothing; `MainMenu.swift` Tools submenu has no Infer Tree). Tree inference is a context-menu action inside the MSA viewport titled "Build Tree with IQ-TREE…" (`MultipleSequenceAlignmentViewController.swift:1369-1371`, `inferTreeFromMenu`). The dialog it opens is titled "Phylogenetic Tree Operations" with subtitle "Configure IQ-TREE for the selected multiple sequence alignment" (`IQTreeInferenceDialog.swift:99-104`). This is the single most consequential error in the chapter.

2. The MSA wizard has no "Aligner" dropdown and no "Mode" control; the picker is "Strategy".
   - Doc lines 58, 67, 179: "select the tool in the MSA wizard's Aligner dropdown"; "Leave Aligner set to MAFFT and Mode set to Auto"; "switch the wizard's Mode from Auto to L-INS-i".
   - Code: the MAFFT pane has pickers "Strategy" (`FASTQOperationToolPanes.swift:467`), "Sequence Type" (`:473`), and "Output Order" (`:480`). MAFFT is the only aligner; there is no aligner selector and no "Mode" control. The strategy values include "Auto" and "L-INS-i" (`FASTQOperationToolPanes.swift:772,793`). So the doc's "set Mode to Auto" should read "leave Strategy on Auto", and "switch Mode to L-INS-i" should read "switch Strategy to L-INS-i".

3. MUSCLE and Clustal Omega are not selectable in the wizard.
   - Doc lines 50-58: comparison table implies "install the plugin pack that provides them and select the tool in the MSA wizard's Aligner dropdown."
   - Code: the only MSA alignment tool wired in the GUI and CLI is MAFFT (`AlignCommand.swift:9` `subcommands: [MAFFTSubcommand.self]`; `FASTQOperationToolPanes.swift:466-489` `.mafft` case only). There is no aligner-selection affordance for MUSCLE/Clustal Omega anywhere in the read sources. The "select the tool in the Aligner dropdown" instruction is unsupported.

4. The CLI builder command is `lungfish align mafft`, not `lungfish msa`.
   - Doc line 13 frontmatter: "CLI: lungfish msa, lungfish tree".
   - Code: building an alignment from FASTA is `lungfish align mafft <inputs> --project <dir>` (`AlignCommand.swift:5-31`, `commandName = "align"`, default subcommand `mafft`). `lungfish msa` is a TRANSFORM/INSPECT command (subcommands: actions, describe, annotate, export, consensus, extract, mask, trim, distance) and cannot build an alignment from unaligned FASTA (`MSACommand.swift:7-22`). The frontmatter conflates the two.

5. `lungfish tree` inference requires `--project`; the doc never shows it and implies a bare invocation.
   - Doc lines 14, 36 imply "CLI: lungfish tree" builds a tree; the chapter's CLI blocks only show reroot/relabel/extract-subtree.
   - Code: `lungfish tree infer iqtree` REQUIRES `--project <dir>` and `--output <bundle>` plus the MSA bundle argument (`TreeCommand.swift:363-371`, `@Option --project projectPath` is non-optional; `@Argument msaBundlePath`). Any documented `lungfish tree infer` example must include `--project`. The chapter provides no inference CLI example at all, which is an omission given it documents reroot/relabel/extract-subtree CLI.

6. Bootstrap is OFF by default in both the dialog and the CLI; the doc treats 1000 as a pre-filled default to confirm.
   - Doc lines 90: "Set Bootstrap replicates to 1000 for ultrafast bootstrap support values."
   - Code: in the dialog, `bootstrapEnabled` defaults to `false` (the replicate field defaults to 1000 only once you tick the "Ultrafast Bootstrap" checkbox) (`IQTreeInferenceDialog.swift:85-86`, `bootstrapEnabled = false`, `bootstrapReplicates = 1000`). In the CLI, `--bootstrap` is optional with no default (`TreeCommand.swift:387-388`, `var bootstrap: Int?`). So by default IQ-TREE runs WITHOUT ultrafast bootstrap. The doc should say to enable the "Ultrafast Bootstrap" checkbox first, otherwise no support values are produced. The chapter's later claim that the tree shows "support values" assumes the user enabled bootstrap.

7. Dialog field labels differ from the doc's "Method" / "Substitution model" wording.
   - Doc line 89: "Leave Method set to IQ-TREE and Substitution model set to MFP."
   - Code: the dialog has no "Method" field (IQ-TREE is the only method; the tool sidebar item is "Build Tree with IQ-TREE", `IQTreeInferenceDialog.swift:72`). The model field is labeled "Model", defaulting to "MFP" (`IQTreeInferenceDialog.swift:260`, `labeledTextField("Model", ...)`; default `model = "MFP"` at `:84`). The substitution-model concept is right; the field label is "Model", not "Substitution model".

8. "Outgroup" dropdown is not present in the IQ-TREE dialog.
   - Doc line 91: "Optionally set an outgroup tip from the dropdown."
   - Code: the IQ-TREE dialog fields are Output Name, Model, Sequence Type, Branch Support (Ultrafast Bootstrap, SH-aLRT), Seed, Threads, Safe mode, Keep identical sequences, and an Advanced disclosure (Executable path, IQ-TREE Parameters) (`IQTreeInferenceDialog.swift:256-303`). There is no outgroup picker. Rooting on an outgroup is a post-inference `tree reroot` operation (`TreeCommand.swift:228-260`), not an inference-dialog field.

9. `tree reroot` / `extract-subtree` / `relabel` CLI examples match code; `extract subtree` (export) is the legacy path.
   - Doc lines 114-121 (`tree reroot --bundle --on --output`): matches (`TreeCommand.swift:228-260`, options `--bundle`, `--on`, `--output`).
   - Doc lines 136-140 (`tree relabel --bundle --column --output`): matches (`TreeCommand.swift:314-345`).
   - Doc lines 156-163 (`tree extract-subtree --bundle --node --output`): matches (`TreeCommand.swift:271-302`). The doc's example `--node node-12` uses a normalized node id, which the option accepts ("Normalized node ID or unique node label", `TreeCommand.swift:280`).
   - Doc line 163 ("lungfish tree export subtree still writes a plain Newick export"): matches the legacy `tree export subtree` path (`TreeCommand.swift:31-44`), which takes `--node` OR `--label` and `--output`. Accurate.

10. Reroot, relabel, collapse, extract-subtree are described as tree-viewport right-click actions; only some are verifiable here.
    - Doc lines 106-152 describe right-click "Re-root Here", "Collapse Clade"/"Expand Clade", "Copy Selected Tip Names", "Extract Subtree as New Bundle…", and a `Tip labels` control fed by `metadata.tsv`.
    - Code: the tree viewport is `PhylogeneticTreeViewController.swift` (`LungfishPhylogeneticsUI`), not read line-by-line here. The CLI equivalents all exist (`TreeCommand.swift`), and `relabel` reads `metadata.tsv` with an id column (`TreeCommand.swift:314-345`; the chapter's accepted id-column names `id/sample/sample_id/name/tip` are a workflow detail to verify against `relabeledBundle`). The exact viewport menu-item titles need confirmation in `PhylogeneticTreeViewController.swift` (see NEEDS-HUMAN-CHECK).

11. "Tools > Orient" for reorienting before alignment does not exist as written.
    - Doc line 179: "reorient them with Tools > Orient against a shared reference before aligning."
    - Code: orientation is "Orient Reads", a FASTQ operation under `Tools > FASTQ/FASTA Operations` (`AppDelegate+ToolsMenu.swift:1413`; `OrientWizardSheet.swift:111`; `FASTQOperationDialogState.swift:1667` `case .orientReads: "Orient Reads"`). It orients FASTQ reads, not reference FASTA records destined for an MSA. The cross-reference is both mis-pathed and arguably mis-scoped.

### APP FEATURES MISSING FROM THE DOCS

1. `lungfish msa` transform suite is entirely undocumented: `consensus`, `extract`, `mask columns`, `trim`, `distance`, `annotate {add,edit,delete,project}`, `export`, `actions`, `describe` (`MSACommand.swift:11-21`). For example `lungfish msa consensus` builds a consensus FASTA or `.lungfishref` (`MSACommand.swift:676-733`), and `lungfish msa distance` writes an identity or p-distance TSV matrix (`msa distance --help`; `MSACommand.swift:DistanceSubcommand`). None are mentioned.
2. MSA export supports many formats: fasta, aligned-fasta, phylip, nexus, clustal, stockholm, a2m, a3m (`MSACommand.swift:510`, ExportSubcommand `--output-format`). The chapter only mentions exporting "the MSA FASTA" and a Newick.
3. `lungfish align mafft` exposes strategy, sequence-type, output-order, adjust-direction, symbols, deterministic-threads, and verbatim `--extra-mafft-options`/`--extra-args` (`AlignCommand.swift:60-93`). The chapter mentions only Auto/L-INS-i.
4. The IQ-TREE dialog/CLI expose SH-aLRT support (`--alrt`), `--seed`, `--safe`, `--keep-identical`, `--sequence-type`, and `--extra-iqtree-options` (`TreeCommand.swift:384-417`; `IQTreeInferenceDialog.swift:271-303`). The chapter documents only model, bootstrap, and outgroup.
5. `lungfish import msa` and `lungfish import tree` import existing alignment/tree files as bundles (`ImportMSATreeSubcommands.swift:6-9,104-107`). The chapter never mentions importing a pre-built MSA or Newick tree, only building them in-app.
6. Tree inference can be scoped to a row/column subset via `--rows`/`--columns` (`TreeCommand.swift:372-376`), matching the MSA viewport's selection-to-tree flow (`MultipleSequenceAlignmentViewController.swift:289-329`, `MultipleSequenceAlignmentTreeInferenceRequest` carries rows/columns). Undocumented.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. Exact tree-viewport right-click menu titles ("Re-root Here", "Collapse Clade", "Expand Clade", "Extract Subtree as New Bundle…", "Copy Selected Tip Names") and the toolbar controls ("Layout", "Color", "Tip labels"). Source is `PhylogeneticTreeViewController.swift`, not enumerated here.
2. Accepted `metadata.tsv` id-column names (`id`, `sample`, `sample_id`, `name`, `tip`, doc lines 125, 128). The CLI `relabel` reads a column (`TreeCommand.swift:323`), but the id-column resolution lives in `relabeledBundle` (not read).
3. The MSA viewport region labels (row picker, alignment grid, column ruler with "1-based column index and conservation track") and the "Annotations" toggle (doc lines 76-80). The MSA VC exists (`MultipleSequenceAlignmentViewController.swift`) but the exact rendered labels are runtime.
4. The default MAFFT strategy when the GUI opens (doc says "Auto"). CLI default is `auto` (`AlignCommand.swift:61`); the GUI default `state.mafftStrategy` initial value is not confirmed from the files read.
5. Whether the IQ-TREE default model "MFP (ModelFinder Plus)" picks the best model from data (doc line 89). Default model string is "MFP" (`IQTreeInferenceDialog.swift:84`; CLI `--model` default "MFP", `TreeCommand.swift:382`); the ModelFinder behavior is an IQ-TREE runtime fact.

---

## Section-wide: app features in this domain entirely absent from the manual

These are present in code across the Sequences domain but unmentioned in any of the four chapters.

1. The `lungfish msa` transform/inspection family (consensus, distance matrix, extract, mask, trim, annotate, multi-format export) (`MSACommand.swift`). This is a large CLI surface the MSA chapter never references.
2. `lungfish import msa` and `lungfish import tree` for importing pre-built alignments and Newick/Nexus trees as native bundles (`ImportMSATreeSubcommands.swift`).
3. `lungfish convert` for FASTA/GenBank/GFF3/FASTQ interconversion with `--include-annotations` (`convert --help`; `ConvertCommand.swift`). Relevant to the import and extract chapters but never cited.
4. `lungfish fetch search`, `lungfish fetch ena {search,reads,fasta}`, and multi-accession `fetch ncbi` (`FetchCommand.swift:501-590,1091-1326,45-52`). The NCBI chapter documents only single-accession `fetch ncbi`.
5. CLI parity for the Sequence menu: `lungfish extract sequence` (with flanks), `lungfish translate`, and `lungfish sequence {annotate-orfs,delete-annotations,delete-annotation-track}` (`ExtractCommand.swift`, `TranslateCommand.swift`, `SequenceCommand.swift`). The extract/compare chapter is GUI-only and omits all of these.
6. The real entry-point names the section should use: `Tools > FASTQ/FASTA Operations > Multiple Sequence Alignment…` for the MSA builder, "Build Tree with IQ-TREE…" (MSA viewport context menu) for tree inference, and "Import Center…" (Cmd-Shift-I) for the importer (`MainMenu.swift:676,200-206`; `MultipleSequenceAlignmentViewController.swift:1369`). The chapters use `Tools > Infer Tree`, "File > Import Center", and an "Aligner dropdown" that do not exist.
