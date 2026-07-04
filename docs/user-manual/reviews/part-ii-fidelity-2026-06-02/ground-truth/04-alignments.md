# Ground-truth reality map: 04-alignments

Scope: the five chapters under `docs/user-manual/chapters/04-alignments/` checked
against the actual Swift source and the built `./.build/debug/lungfish-cli`
help output. Every claim below cites a concrete symbol, file, or flag. Where I
could not find a source, I say so rather than inventing one.

Key cross-cutting fact established up front: **the BAM alignment viewport that
chapter 02 and 04 describe (coverage histogram, pileup, strand colour,
soft-clip dimming, Go to Location, zoom) does NOT live in
`Sources/LungfishAlignmentUI/`.** That module
(`AlignmentResultViewController.swift`) is an explicit stub whose own header
says "This is a foundation stub" and "Full pileup viewer coming soon"; its
`exportResults` throws "Alignment export not yet implemented". The real
rendering lives in `Sources/LungfishApp/Views/Viewer/` (`ReadTrackRenderer.swift`,
`SequenceViewerView+Interaction.swift`). The viewport features the chapters
describe are real, but they are served by `ViewerViewController`, not the
leaf module named for alignments.

---

## Chapter 01: Mapping Reads to a Reference

### Claims that do not match code

1. **Preset display names are wrong (table in "Choosing a preset", lines
   82-88).** The doc presents the GUI preset labels as "Short read (sr)",
   "Map ONT (map-ont)", "Map HiFi (map-hifi)". The actual menu labels come
   from `MappingMode.displayName` in
   `Sources/LungfishWorkflow/Mapping/MappingTool.swift:204-215`:
   `.defaultShortRead` = "Short-read", `.minimap2MapONT` = "Oxford Nanopore",
   `.minimap2MapHiFi` = "PacBio HiFi", `.minimap2Asm5` = "Assembly-to-assembly",
   `.minimap2Splice` = "Spliced CDS/cDNA", `.minimap2MapPB` = "PacBio CLR". The
   strings `sr`, `map-ont`, `map-hifi` are the `--preset` CLI tokens
   (`commandPresetValue`, same file lines 217-227), not GUI labels. The doc
   conflates the two.

2. **The wizard does NOT have a "Reads" section/picker (Procedure step 2,
   lines 137-140; "The wizard has three sections (Reads, Reference, Tool)",
   line 131).** `MappingWizardSheet.swift` builds exactly these sections:
   `referenceSection` ("Reference"), `modeSection` (titled "Preset" for
   minimap2 else "Mode", line 411), `readGroupSection` ("Read Group"),
   `compatibilitySection` ("Input Compatibility"), `advancedSection`
   ("Advanced Settings"). There is no Reads picker and no Tool picker. The
   reads come from the sidebar selection passed in as `inputFiles`
   (`AppDelegate+ToolsMenu.swift` `gatherFASTQOperationInputURLs`), and the
   mapper (`initialTool`) is chosen by which tool row you click in the
   FASTQ operations dialog, not inside the wizard. There is no in-wizard
   "choose your FASTQ bundle" or "choose the mapper" control.

3. **Worked-example track name is invented (line 174).** The doc says the
   adopted track is named `SRR36291587 (minimap2 sr)`. Track names are
   user-supplied: the GUI managed-mapping path names the operation
   `"Map Reads (\(request.tool.displayName))"`
   (`AppDelegate+ToolsMenu.swift:1139`) and the adopted display name is
   `"\(request.tool.displayName) Mapping"` (e.g. "minimap2 Mapping",
   lines 1226/1331). The CLI `bam adopt-mapping --name` is whatever the user
   passes. Nothing generates the parenthetical `(minimap2 sr)` form.

4. **`lungfish map` does not accept the reference being a `.lungfishref`
   bundle path the way the Equivalent CLI block shows (lines 188-192).**
   `MapCommand.swift:140-143` resolves `--reference` through
   `SequenceInputResolver.resolvePrimarySequenceURL` and then *requires*
   `inputSequenceFormat(...) == .fasta`, else it throws
   `formatDetectionFailed`. Pointing `--reference` at a `.lungfishref`
   directory is only valid if the resolver can extract a primary FASTA from
   it; the doc presents `--reference "Reference Sequences/MN908947.3.lungfishref"`
   as routine without that caveat. NEEDS-HUMAN-CHECK whether the resolver
   transparently digs the FASTA out of a `.lungfishref` (it resolves
   "primary sequence URL", which may or may not include bundle interiors).

5. **The underlying recipe text is minimap2-specific but presented as
   universal (lines 44-45).** "The pipeline that runs underneath is
   `minimap2 -ax <preset> | samtools sort | samtools index`". That is true
   only for the minimap2 tool. For BWA-MEM2, Bowtie2, and BBMap the command
   is built per-tool by `MappingCommandBuilder.swift` /
   `ManagedMappingPipeline.swift`; the `-ax` form is minimap2 syntax. Minor,
   but the sentence claims it is "the same three-step recipe" for all four.

### App features missing from the docs

1. **`--secondary`, `--no-supplementary`, `--min-mapq` mapping filters.**
   `MapCommand.swift:81-89` exposes keep-secondary, exclude-supplementary,
   and minimum-MAPQ retention; the GUI wizard exposes the same as
   "Secondary alignments", "Supplementary", "Min mapping quality" toggles
   (`MappingWizardSheet.swift:512-537`). The chapter never mentions these.

2. **`--extra-args` passthrough.** Both the CLI (`MapCommand.swift:90-95`)
   and the wizard "Extra arguments" field
   (`MappingWizardSheet.advancedOptionsPlaceholder`, lines 176-187, with
   per-tool examples like `--eqx -N 5`) let users inject raw mapper flags.
   Undocumented.

3. **Input-compatibility detection.** The wizard inspects inputs
   (`MappingInputInspection.inspect`) and auto-selects a preset, shows
   detected format / read class / observed max read length, and can *block*
   Run on an incompatible combination (`compatibilitySection`,
   `MappingCompatibility.evaluate`). The chapter's troubleshooting mentions
   preset mismatch only as a post-hoc low-mapping-rate cause, not as a
   live pre-run gate.

4. **PacBio CLR (`map-pb`), `asm5`, and `splice` presets exist for
   minimap2.** `MappingMode` ships `.minimap2MapPB` (map-pb),
   `.minimap2Asm5` (asm5), `.minimap2Splice` (splice). The chapter table
   lists only sr / map-ont / map-hifi and tells Sanger/contig users to "use
   a different tool", omitting asm5 (assembly-to-assembly) and splice.

### Uncertain / needs-human-check

- **`-ax map-hifi` worked-example interpretation numbers** (mapping rate
  >95%, coverage in hundreds/thousands) are plausible scientific claims, not
  code claims; out of scope for code verification.
- Whether the adopted track lands under a literal sidebar path
  `Reference Sequences > MN908947.3 > Alignments` (line 173) depends on
  bundle/sidebar layout I did not fully trace; the adoption directory is
  `alignments/mapped` inside the bundle (`BAMAdoptMappingSubcommand.swift:59`).

---

## Chapter 02: Reading an Alignment

### Claims that do not match code

1. **Zoom keys are wrong: bare `=` / `-` do not zoom (Procedure step 4,
   lines 89-93).** The doc says "Use `=` to zoom in and `-` to zoom out."
   The viewport zoom shortcut handler
   (`Sources/LungfishKit/ZoomShortcutHandler.swift:26-31`) requires the
   Command modifier: `guard modifiers.contains(.command) else { return false }`.
   So zoom in is `Cmd-=`/`Cmd-+` and zoom out is `Cmd--` (lines 47-53), plus
   keypad +/-. Without Command, the viewport `keyDown`
   (`SequenceViewerView+Interaction.swift:341-378`) only handles arrows, C,
   A, and Escape; a bare `=` falls through to `super.keyDown`. Note the
   menu items are "Zoom In" = `+` and "Zoom Out" = `-` as Cmd-accelerators
   (`MainMenu.swift:483-493`). Arrow Up/Down also zoom
   (`SequenceViewerView+Interaction.swift:352-355`), which the doc omits.

2. **The sidebar track name `SRR36291587-minimap2.bam` is invented (step 1,
   lines 74-76).** Same issue as chapter 01: no code generates that exact
   filename or display name. Adopted/managed track display names are
   `"<tool> Mapping"` or user-supplied.

3. **"After primer trimming ... the primer-derived ends become hard-clipped
   and disappear from the view entirely" (lines 50-51) contradicts chapter
   03 and the code.** The primer-trim pipeline soft-clips (CIGAR `S`), it
   does not hard-clip. Chapter 03 itself says "It changes their CIGAR flag
   from `M` ... to `S` (soft-clipped, present but excluded from pileups). The
   reads keep their original length." and "The primer footprints stay visible
   in the viewport as short, lighter ticks". `ReadTrackRenderer.swift:92`
   defines a `softClipColor` and dims clipped segments via alpha; there is no
   hard-clip-and-remove behaviour for primer trim. The two chapters
   disagree; chapter 03 matches the code, chapter 02 does not.

4. **Inspector summary field set is partially overstated (step 5 and the
   table, lines 96-150).** The aggregate alignment stats the Inspector shows
   come from `ReadStyleSection.swift` and the flagstat-style counters; total
   reads, mapped reads, mean coverage, and primary/supplementary split are
   real. "Provenance sidecar (which mapper, which preset, which input FASTQ)"
   is real (`MappingProvenance`, surfaced in the Inspector
   "Primer-trim Derivation" / mapping provenance sections). NEEDS-HUMAN-CHECK
   on the exact field label "primary vs supplementary" as a single Inspector
   row versus separate flagstat lines.

### App features missing from the docs

1. **The "Analysis" section exposes more than two actions.** The chapter
   names only "Primer-trim BAM" and "Call Variants". The alignment Analysis
   subsection (`ReadStyleSection.swift`) buttons are: "Primer-trim BAM…"
   (line 2404), "Call Variants…" (line 2431), "Mark Duplicates in Bundle
   Tracks" (line 1965), "Create Deduplicated Bundle" (line 2451), "Create
   Filtered Alignment" (line 2105), "Convert Mapped Reads to Annotations"
   (line 2245), and "Extract Consensus…" (line 2376). At least five of these
   are undocumented here.

2. **Read colour modes beyond strand.** `ReadTrackRenderer` supports
   colouring by pair (`firstInPairColor`/`secondInPairColor`, lines 107-108),
   insert size (`insertTooSmall`/`insertTooLarge`/`insertInterchromosomal`/
   `insertAbnormalOrientation`, lines 96-104), split-read
   (`splitReadColor`, line 111), and read-group
   (`readGroupColorMap`, `readColors(...)` line 177). The chapter presents
   strand colour as the only channel.

3. **The coverage track is a forward/reverse stacked area at zoom, not a
   single histogram (`ReadTrackRenderer.swift:14-17` rendering-mode table,
   `forwardCoverageColor`/`reverseCoverageColor` lines 75-77).** The doc's
   "coverage histogram" is correct at a coarse level but omits that coverage
   is split by strand.

### Uncertain / needs-human-check

- **Position 21618 pileup narrative (lines 123-131): "SARS-CoV-2 spike
  L452R-adjacent region", reference `C`, reads `T`.** This is a
  data/scientific claim about the SRR36291587 fixture, not verifiable from
  code. NEEDS-HUMAN-CHECK against the actual fixture.
- Whether clicking a coverage column jumps to that position (step 3) is a
  plausible interaction I did not find an explicit handler for; the
  confirmed jump path is `Go to Location…` = Cmd-L (`MainMenu.swift:584`).

---

## Chapter 03: Primer Trimming a BAM

### Claims that do not match code

1. **Wrong amplicon and primer counts for the built-in scheme ("Primer
   schemes" table line 99; Procedure step 3 line 137).** The doc says
   QIASeqDIRECT-SARS2 has **422 amplicons** and "~250 bp" inserts. The
   shipped manifest
   (`Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/manifest.json`)
   says `"primer_count": 563`, `"amplicon_count": 223`. So 223 amplicons,
   563 primers, not 422 amplicons.

2. **Built-in scheme display name differs (lines 99, 135).** The doc and
   picker step call it "QIASeqDIRECT-SARS2". That is the manifest `name`;
   the GUI picker shows `display_name` = "QIAseq Direct SARS-CoV-2 with
   Booster A" suffixed " (Built-in)" (`PrimerOption.title` pattern,
   e.g. `ViralReconWizardSheet.swift:986`; same `BuiltInPrimerSchemeService`
   feeds the BAM primer-trim picker). The doc never mentions Booster A.

3. **Second entry point is wrong: `Tools > FASTQ/FASTA Operations >
   Trimming & Filtering > Primer Trimming` is the FASTQ-level trim, not the
   BAM-level iVar trim (front-matter `entry_points`, line 12).** The
   "Trimming & Filtering" menu (`MainMenu.swift:655-657`) opens the FASTQ
   operations dialog whose `.primerTrimming` tool
   (`FASTQOperationDialogState.swift:1614`,
   "Trim PCR primer sequence from reads.", line 1700) does a k-mer/BBDuk-style
   FASTQ trim with fields `primerTrimmingKmerSize` / `minKmer` /
   `hammingDistance` (lines 64-68) -- this is the FASTQ-level trim chapter 03
   itself contrasts against (lines 47-53). The BAM-level iVar trim has only
   two real entry points: `Inspector > Analysis > Primer-trim BAM…`
   (`ReadStyleSection.swift:2404`, confirmed) and CLI `lungfish bam
   primer-trim`. The Tools-menu path in the front matter points at the wrong
   feature.

4. **CLI `lungfish primers import` is CORRECT as written (lines 115-117).**
   Confirmed via `./.build/debug/lungfish-cli primers import --help`:
   `--bed <bed>` (required), `--fasta <fasta>` (optional primer FASTA),
   `--output <output>` (.lungfishprimers bundle). The doc's
   `lungfish primers import --bed <bed> --fasta <ref> --output <name>.lungfishprimers`
   matches. Note `--fasta` is described in help as "Optional primer FASTA",
   not a reference FASTA; the doc's `<ref>` placeholder is slightly
   misleading but the flag is right.

5. **iVar trim is the engine, but the dialog defaults wording slightly
   over-specifies (Procedure step 4, lines 134-141).** The defaults the doc
   lists (min length 30, min quality 20, sliding window 4, primer offset 0)
   exactly match `BAMPrimerTrimSubcommand.swift:67-77` and the dialog
   placeholders in `BAMPrimerTrimToolPanes.swift:49-52`. This part is
   correct. The dialog field labels are "Minimum read length after trim",
   "Minimum quality", "Sliding window width", "Primer offset" (same lines),
   which the doc paraphrases acceptably.

### App features missing from the docs

1. **`--target-reference` override.** `bam primer-trim` exposes
   `--target-reference` to override the `@SQ SN` used to resolve the scheme
   (`BAMPrimerTrimSubcommand.swift:62-65`); defaults to the scheme's
   canonical accession. Useful when the BAM contig name differs from the
   scheme accession. Undocumented.

2. **The output track lands in `alignments/primer-trimmed` and the parent is
   preserved.** `BAMPrimerTrimSubcommand.swift:325` plus the rollback
   discipline confirm the trimmed BAM is a *new* track; the chapter says the
   unclipped BAM is "preserved as a parent track" (line 44) which is true,
   but does not mention the bundle subdirectory or the provenance-sidecar
   write-before-attach rollback behaviour.

3. **JSON event stream / `--format json`.** The CLI emits structured
   `PrimerTrimEvent` objects (`BAMPrimerTrimSubcommand.swift:30-41`) under
   `--format json`. Not mentioned (acceptable for a bench chapter, noted for
   completeness).

### Uncertain / needs-human-check

- **The `(Primer-trimmed)` suffix on the new track name (lines 36, 147).**
  The CLI `--name` is whatever the user passes; nothing auto-appends
  "(Primer-trimmed)". The GUI `outputTrackName` default may add a suffix, but
  I did not find the defaulting logic in `BAMPrimerTrimDialogState`. NEEDS-
  HUMAN-CHECK whether the GUI pre-fills a "(Primer-trimmed)" name.
- **"15% to 30% of bases soft-clipped" expected trim rate (line 174)** is a
  scientific expectation, not a code claim.
- **The LoFreq caveat (lines 178-180).** Whether LoFreq is even an available
  caller in the BAM variant-calling dialog is a chapter-05 concern; the
  variants feature (`features.yaml` `variants.call`) lists "LoFreq, iVar,
  Medaka, or bcftools", so LoFreq exists. The claim about LoFreq re-
  introducing primer bases is scientific, not verifiable here.

---

## Chapter 04: Alignment Quality

### Claims that do not match code

1. **`lungfish markdup` invocation is wrong: there is no `--in` / `--out`
   (Procedure "Decide on duplicate marking", lines 67-71; front-matter
   line 11).** The doc shows
   `lungfish markdup --in path/to/alignment.bam --out path/to/alignment.markdup.bam`.
   The real command (`MarkdupCommand.swift:35-48`, confirmed via
   `./.build/debug/lungfish-cli markdup --help`) takes a *positional*
   `<path>` (a BAM file or a directory of BAMs) and marks **in place** (it
   replaces the input via `fm.replaceItemAt(bamURL, withItemAt: tempBamURL)`,
   line 312). There is no `--out`; the only output-redirecting flag is
   `--deduplicated-bundle <path>` (creates a sibling `.lungfishref` with
   duplicates removed). The doc's claim "The output is a new BAM track
   adopted onto the same reference; the original is preserved" (line 71) is
   false for `markdup` -- it mutates the input. (Preservation + a new track
   is the behaviour of the *GUI* "Create Deduplicated Bundle", a different
   action.)

2. **The wrapped pipeline order is paraphrased but close.** Doc: "name-
   sorted, fixmate'd, position-sorted, then marked, then indexed" (line 71).
   The CLI's provenance step labels are sort -> markdup -> index
   (`MarkdupCommand.swift:672-686`), and the underlying
   `AlignmentMarkdupPipeline` runs the samtools collate/fixmate/sort/markdup
   chain. Directionally correct; the exact stage list is not enumerated in
   `MarkdupCommand` (it delegates to `AlignmentMarkdupPipeline`). NEEDS-
   HUMAN-CHECK on the precise stage sequence if that detail matters.

3. **"launch Mark Duplicates from the Inspector's Analysis section" (line 65)
   is correct in spirit but the button is bundle-wide.** The Inspector button
   is "Mark Duplicates in Bundle Tracks" (`ReadStyleSection.swift:1965`) and
   it runs `AlignmentDuplicateService.markDuplicatesInBundle(bundleURL:)`
   (`InspectorViewController+TrimDuplicateWorkflows.swift:643`) across the
   bundle's tracks, not a single selected track. The doc implies a per-BAM
   action. Minor but worth flagging.

4. **`samtools flagstat` equivalence (lines 53-54).** The doc says Mapped
   reads and Properly paired "match the equivalent rows of `samtools
   flagstat`". The Inspector counters are computed by Lungfish's own
   alignment-metadata path, not by shelling out to `flagstat`; values should
   correspond but the wording implies flagstat is the source. Cosmetic.

### App features missing from the docs

1. **`markdup --deduplicated-bundle` (CLI) and "Create Deduplicated Bundle"
   (GUI).** The chapter only covers in-place marking. The actual
   duplicate-*removal*-into-a-new-bundle path
   (`MarkdupCommand.swift:45-48`; `CLIDeduplicatedBundleSupport`;
   `ReadStyleSection.swift:2451`) is undocumented in this chapter.

2. **`lungfish bam filter` covers most QC-driven subsetting.** The chapter's
   QC framing (mapped-only, primary-only, MAPQ floor, exclude/remove
   duplicates, exact-match / percent-identity) maps almost 1:1 onto
   `bam filter` flags (`BAMCommand.swift:1033-1052`): `--mapped-only`,
   `--primary-only`, `--min-mapq`, `--exclude-marked-duplicates`,
   `--remove-duplicates`, `--exact-match`, `--min-percent-identity`. None of
   this is mentioned, even though it is the natural "validate before variant
   calling" toolset.

3. **`markdup` on a directory and NAO-MGS auto-materialization.**
   `markdup <dir>` scans for BAMs (`collectBAMFiles`) and, if it finds a
   NAO-MGS `hits.sqlite`, materializes BAMs from SQLite first
   (`MarkdupCommand.swift:768-801`). Out of scope for this chapter but worth
   noting the command does more than single-file marking.

### Uncertain / needs-human-check

- **Coverage threshold numbers** ("200x", "50x at every position", "100x
  floor", duplicate rates 80-95% for amplicon) in the Thresholds table and
  Interpretation sections are scientific defaults, not code constants. The
  chapter even states they are "working defaults, not regulatory minima"
  (line 75). NEEDS-HUMAN-CHECK only if any are meant to mirror a hardcoded
  preflight threshold (e.g. variant-calling minimum-coverage gates in
  `BAMVariantCallingPreflight`).
- **Worked example: "mean coverage near 800x and >99% mapped" for the
  primer-trimmed SRR36291587** (line 116) is a fixture/data claim, not
  verifiable from code. Also note the doc calls the fixture "SARS-CoV-2 ARTIC
  v3" here (line 116) while chapter 03 trims the same fixture with the
  QIASeqDIRECT scheme (lines 124-126); these two scheme attributions are
  inconsistent with each other. NEEDS-HUMAN-CHECK which scheme the fixture
  actually uses.

---

## Chapter 05: Viral Recon Wizard

### Does the wizard exist? YES, with major scope and entry-point errors.

A Viral Recon wizard genuinely exists:
`Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`
(`struct ViralReconWizardSheet`), wired to `ViralReconWorkflowExecutionService`
(`AppDelegate+ToolsMenu.swift:114-132`), with an accessibility-identified UI
(`ViralReconAccessibilityID`). The CLI `lungfish workflow run nf-core/viralrecon`
also exists (`WorkflowCommand.swift`, confirmed via
`./.build/debug/lungfish-cli workflow run --help`). So the chapter is not
describing a phantom feature. But several specifics are wrong.

### Claims that do not match code

1. **GUI entry point is wrong: there is no `Tools > Workflows > Viral Recon`
   (front-matter line 11; Procedure step 2 line 71; chapter 01 line 253).**
   There is no "Workflows" menu in `MainMenu.swift`. Viral Recon is a *tool*
   (`FASTQOperationToolID.viralRecon`,
   `FASTQOperationDialogState.swift:1639/1681`) inside the **Mapping**
   category of the FASTQ/FASTA Operations dialog
   (`.mapping` tools list includes `.viralRecon`, line 1070). The real path
   is `Tools > FASTQ/FASTA Operations > Mapping…`, then select the
   "Viral Recon" tool. (There is a separate top-level "Workflow Operations…"
   item, `MainMenu.swift:709-714`, gated on
   `workflowFeatureAvailability.hasWorkflowOperations` -- that is the generic
   Nextflow/Snakemake runner, not the Viral Recon SARS-CoV-2 wizard.)

2. **The wizard is SARS-CoV-2-specific, not general "viral" (What it is,
   lines 27-31; tags say "amplicon, consensus" broadly).** The header
   literally reads `section("Viral Recon")` with subtitle "SARS-CoV-2
   consensus and variant analysis from FASTQ bundles."
   (`ViralReconWizardSheet.swift:152-156`). The reference modes are
   "SARS-CoV-2 Genome" (default accession `MN908947.3`, line 24) and
   "Local FASTA" (lines 189-192). The primer section only loads SARS-CoV-2
   schemes and shows "No SARS-CoV-2 primer schemes are available." when empty
   (line 250). The tool description is "Run SARS-CoV-2 viral consensus and
   variant analysis." (`FASTQOperationDialogState.swift:1725`). The chapter
   frames it as a general viral pipeline.

3. **The GUI wizard does NOT take a samplesheet; it builds one (Inputs
   section, lines 35-44 frame the GUI as analogous to the CLI samplesheet
   requirement).** The wizard takes FASTQ bundles/files and *generates* the
   samplesheet internally
   (`ViralReconSamplesheetBuilder.writeIlluminaSamplesheet` /
   `stageNanoporeInputs`, lines 466-471). The "exactly one samplesheet"
   constraint is a CLI-only rule (`WorkflowCommand.swift:549`,
   "Exactly one --input samplesheet is required for nf-core/viralrecon").
   The doc's Inputs table conflates GUI and CLI input models.

4. **The protocol is hardcoded to amplicon (Reference and Primers, lines
   55-64; CLI example uses `--param protocol=amplicon`).** The wizard always
   sends `protocol: .amplicon` (`ViralReconWizardSheet.swift:483`). There is
   no shotgun/metagenomic mode in the GUI. The chapter's general phrasing
   ("For amplicon protocols, choose a primer scheme") implies amplicon is
   optional; in the GUI a primer scheme is *required* to run (readiness gate
   "Select a SARS-CoV-2 primer scheme.", lines 874/1016).

5. **Platform handling: "Platform auto" does not pass `platform=...`; it
   infers from the reads (Inputs table, lines 41-44).** The GUI override is
   `PlatformOverride.auto` whose `.platform` is `nil`
   (`ViralReconWizardSheet.swift:926-928`), meaning "let the resolver detect"
   (`ViralReconWizardInputPolicy.resolveInputs`). Illumina/Nanopore force the
   platform. The doc's table mapping "Platform auto -> let the wizard infer"
   is right; "Illumina -> Pass `platform=illumina`" is right; but the wizard
   refuses mixed-platform bundles entirely (`mixedPlatforms` error, lines
   637/653), which the doc does not mention.

6. **Default skip toggles are specific (Procedure step 3, line 79).** The doc
   says the wizard "defaults to skipping workflow branches Lungfish does not
   currently surface directly." The actual default is
   `skipOptions = [.assembly, .kraken2]` (`ViralReconWizardSheet.swift:34`).
   The full skip-option set is Assembly, Variants, Consensus, FastQC, Kraken2,
   fastp, Cutadapt, iVar trim, MultiQC (`ViralReconSkipOption.displayName`,
   lines 1076-1097). Worth naming the two real defaults.

7. **Default executor and version (Execution, line 78; CLI defaults).** GUI
   defaults: executor `.docker` (line 31), version `"3.0.0"` (line 31),
   minimum mapped reads `1000` (line 31), memory `"8.GB"` (line 31). CLI
   default executor is also docker (`workflow run --help`). The doc lists
   Docker/Conda/Local as choices (correct, `executors` line 645) but does not
   state the defaults.

8. **`--timeout` unsupported claim is correct (line 126).**
   `WorkflowCommand.swift:373-374` throws "--timeout is not supported for
   nf-core/viralrecon runs yet". Accurate. Keep.

9. **Caller choices: iVar and BCFtools, correct (line 79).**
   `ViralReconVariantCaller` = {ivar, bcftools},
   `ViralReconConsensusCaller` = {ivar, bcftools}
   (`ViralReconWizardSheet.swift:1053-1073`). Defaults: variant `.ivar`,
   consensus `.bcftools` (lines 32-33). Accurate; the doc could name the
   defaults.

### App features missing from the docs

1. **GFF annotation staging for local references.** Local-FASTA mode offers
   a "Choose GFF…" button (`ViralReconWizardSheet.swift:214`) and stages the
   GFF (`.local(fastaURL:gffURL:)`, line 507). The doc mentions "optionally
   stages a matching GFF" in the table (line 62) but the procedure never
   shows the GFF picker.

2. **Genome-accession / primer-scheme compatibility validation.** The wizard
   validates that the entered accession is compatible with the chosen scheme
   (`ViralReconWizardPrimerCompatibility.validateGenomeAccession`, lines
   735-763; readiness rejects unknown accessions). Undocumented.

3. **Primer-FASTA derivation when a scheme lacks bundled FASTA.** If the
   selected scheme has no `primers.fasta`, the wizard requires a local
   reference to *derive* primer sequences
   (`primerRequiresLocalReference`, lines 63-67; `stageGenomePrimerSelection`).
   This is a real, surprising input requirement the doc omits.

4. **CPU/memory steppers bounded by host core count** (lines 282-291), and
   minimum-mapped-reads stepper (1...1,000,000). The doc lists "CPUs, memory,
   minimum mapped reads" in passing (line 79) without the bounds or that
   these become `max_cpus`/`max_memory` params (`advancedParams`, lines
   556-563).

### Uncertain / needs-human-check

- **CLI `--bundle-root` vs `--bundle-path` vs `--prepare-only` semantics
  (CLI Procedure table, lines 96-109).** The flags all exist in
  `workflow run --help` (confirmed: `--results-dir`, `--executor`, `--input`,
  `--expected-output`, `--bundle-root`, `--bundle-path`, `--version`,
  `--workdir`, `--param`, `--params-file`, `--cpus`, `--memory`, `--resume`,
  `--dry-run`, `--prepare-only`, `--timeout`). The doc's table is accurate on
  flag names. NEEDS-HUMAN-CHECK only on the prose distinction between
  `--prepare-only` and `--dry-run` (help: dry-run "Validate workflow without
  executing"; prepare-only "Create the Lungfish run bundle and command
  preview without launching Nextflow") -- the doc treats prepare-only as the
  bundle-writing path, which matches.

- **`lungfish provenance bibliography <bundle>` (line 132) is CORRECT.**
  Confirmed via `./.build/debug/lungfish-cli provenance --help`: the
  `bibliography` subcommand exists ("Generate a citation list from a bundle's
  provenance"). No action needed.

- **`.lungfishrun` bundle contents (Outputs and Provenance, line 130).** The
  bundle-writing path exists (`--bundle-path`/`--bundle-root`), but I did not
  open the run-bundle writer to confirm it records exactly "workflow name,
  requested workflow release, executor, bundle paths, inputs, parameters, and
  output surfaces." Plausible; NEEDS-HUMAN-CHECK against the run-bundle model.

---

## Section-wide

1. **The leaf module `LungfishAlignmentUI` is a stub, not the alignment
   viewport.** `Sources/LungfishAlignmentUI/AlignmentResultViewController.swift`
   is an explicit placeholder ("foundation stub", "Full pileup viewer coming
   soon", export throws "not yet implemented"). Every viewport behaviour
   chapters 02 and 04 describe (coverage, pileup, strand colour, soft-clip
   dimming, zoom, Go to Location) is served by `ViewerViewController` and
   `Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift` /
   `SequenceViewerView+Interaction.swift`. Reviewers should not cite
   `LungfishAlignmentUI` as the source of any documented alignment-viewport
   feature.

2. **Recurring invented filenames/track names.** Chapters 01, 02, and 03 each
   assert specific sidebar track names (`SRR36291587 (minimap2 sr)`,
   `SRR36291587-minimap2.bam`, `SRR36291587 vs MN908947.3 (Primer-trimmed).bam`,
   `SRR36291587 vs MN908947.3.bam`). None of these are code-generated;
   track display names are user-supplied (`--name`) or default to
   `"<tool> Mapping"`. The chapters also disagree with each other on the
   naming convention. This should be reconciled to a single, code-true
   pattern.

3. **Two recurring soft-clip vs hard-clip and ARTIC vs QIASeq
   contradictions between chapters.** (a) Chapter 02 says primer trim
   hard-clips and removes; chapter 03 (matching code) says it soft-clips and
   keeps. (b) Chapter 03 trims SRR36291587 with QIASeqDIRECT-SARS2; chapter
   04 calls the same fixture "ARTIC v3". Pick one truth per fixture.

4. **CLI surface is broadly accurate where it overlaps; GUI menu paths were
   the weak spot.** `map`, `bam primer-trim`, and `workflow run` flag tables
   largely match the built CLI help. Resolved 2026-07-04: the mapping inventory
   now points at `Tools > FASTQ/FASTA Operations > Mapping…`. Remaining
   historical concerns in this review were the old Viral Recon and BAM primer
   trim entry-point wording plus the `markdup --in/--out` CLI claim.

5. **features.yaml is mostly trustworthy.**
   `bam.primer-trim` entry points
   (`Inspector > Analysis > Primer-trim BAM…`, `CLI: lungfish bam primer-trim`)
   match the code exactly. Resolved 2026-07-04: the `map` feature entry point
   was refreshed to the current mapping menu path.
