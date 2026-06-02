# Ground-Truth Reality Map: 07-assembly

Generated 2026-06-02. Arbiter-of-truth comparison of chapter CLAIMS against
actual Swift source and CLI help. No build performed. CLI help captured from
`.build/debug/lungfish-cli` (built Jun 2 06:39).

**Headline finding:** Assembly genuinely executes (not preview). The CLI
`assemble` command and the GUI Assembly wizard both run a real assembler in a
managed conda environment via `ManagedAssemblyPipeline.run` ->
`condaManager.runTool` (`Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift:99-120`).
The real roster is **five assemblers: SPAdes, MEGAHIT, SKESA, Flye, Hifiasm**
(`Sources/LungfishWorkflow/Assembly/AssemblyTool.swift:8-13`). Two recurring
documentation errors dominate: (1) a SPAdes `--viral` mode that does not exist
in code, and (2) a per-assembler menu submenu (`Assembly > SPAdes`) that does
not exist (the menu is a single `Assembly...` item), plus a wrong CLI name for
contig extraction (`extract-contigs` vs the real `extract contigs`).

---

## 01-when-to-assemble.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Frontmatter + prose: entry point `Tools > FASTQ/FASTA Operations >
  Assembly` and "Lungfish runs five assemblers through one wizard" (line 11,
  lines 52-53).** The menu path's first three segments are correct, but the
  chapter's sibling chapters extend it to `Assembly > SPAdes` etc., which does
  not exist. The Assembly menu is a single leaf item.
  Cite: `Sources/LungfishApp/App/MainMenu.swift:639-688` (Tools menu ->
  "FASTQ/FASTA Operations" submenu -> single `addItem(withTitle: "Assembly...",
  action: #selector(...showFASTQAssemblyOperations))`). Roster count (five) is
  correct: `AssemblyTool.swift:9-13`.

- **Table claim: "SPAdes ... Has a `--viral` mode tuned for viral coverage
  profiles. Default for SARS-CoV-2 and similar amplicon work" (line 82).**
  FALSE. No `--viral` mode exists. `SPAdesMode` enum is `isolate`, `meta`,
  `plasmid`, `rna`, `biosyntheticSPAdes (--bio)`; the managed pipeline only
  emits `--isolate`/`--meta`/`--plasmid` and ignores anything else; the GUI
  wizard offers only Isolate/Meta/Plasmid for SPAdes.
  Cite: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift:15-31`,
  `ManagedAssemblyPipeline.swift:181-190` (`default: break`),
  `Sources/LungfishApp/Views/Assembly/AssemblyWizardSheet.swift:820-825`. Grep
  for `"--viral"` across `Sources/` returns zero assembly hits.

- **Worked example: "Run SPAdes in viral mode against the paired FASTQ" (line
  149) and "the wizard's tool picker showing the five assemblers grouped by read
  type" (planned-shot line 15).** Viral mode is not selectable. The wizard tool
  picker is a flat segmented control of all five tools, not grouped by read type
  (read-type gating is a separate segmented Read Type picker).
  Cite: `AssemblyWizardSheet.swift:439-444` (`Picker("Assembler" ...
  pickerStyle(.segmented)` over `AssemblyTool.allCases`), `:458-463` (Read Type
  picker).

### 2. APP FEATURES MISSING FROM THE DOCS

- **SKESA pins `--min_count 2`** by default to avoid zeroing out small
  assemblies, undocumented but materially affects SKESA output.
  Cite: `ManagedAssemblyPipeline.swift:266-270`.

- **Read-type auto-detection and per-tool compatibility gating.** The CLI and
  GUI detect read class and block unsupported tool/read-type pairs ("X is not
  available for Y in v1"), which shapes which tools appear usable.
  Cite: `Sources/LungfishCLI/Commands/AssembleCommand.swift:369-402`,
  `Sources/LungfishWorkflow/Assembly/AssemblyCompatibility.swift`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The decision-walkthrough niches (SPAdes up to ~10 Mb, MEGAHIT unbounded,
  SKESA isolate, Flye/Hifiasm long-read) are editorial guidance not encoded in
  source, so they are not "wrong" but cannot be verified against code. Human
  should confirm the SPAdes "Default for SARS-CoV-2" recommendation given that
  the only SPAdes default profile is `isolate` (`AssemblyWizardSheet.swift:881`),
  not a viral profile.

---

## 02-running-spades.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Frontmatter + procedure: entry points `Tools > FASTQ/FASTA Operations >
  Assembly > SPAdes` (line 11) and "Choose `Tools > FASTQ/FASTA Operations >
  Assembly > SPAdes`. The Assembly wizard opens" (line 61).** No `> SPAdes`
  menu item exists. The menu item is `Assembly...`; SPAdes is selected inside
  the wizard via the Assembler segmented picker.
  Cite: `MainMenu.swift:685-689`, `AssemblyWizardSheet.swift:439-444`.

- **SPAdes modes table (lines 47-53) listing Isolate `--isolate`, Viral
  `--viral`, Plasmid `--plasmid`, Metagenomic `--meta`, RNA `--rna`.** Two rows
  are wrong for what Lungfish actually exposes. (a) **Viral `--viral` does not
  exist** in `SPAdesMode` or the managed pipeline or the GUI. (b) **RNA `--rna`
  exists in the `SPAdesMode` enum but the managed pipeline never emits it**
  (`default: break`) and the GUI does not offer it. The only user-selectable
  SPAdes profiles are Isolate, Meta, Plasmid.
  Cite: `SPAdesAssemblyPipeline.swift:15-31` (enum includes rna and bio),
  `ManagedAssemblyPipeline.swift:181-190` (only isolate/meta/plasmid emitted),
  `AssemblyWizardSheet.swift:820-825` (GUI: Isolate/Meta/Plasmid only).

- **Repeated "viral mode" instructions (lines 33, 37, 55, 67, 79, 149-163).**
  All reference a non-existent mode. The wizard cannot select viral mode; an
  amplicon SARS-CoV-2 run would use the default Isolate profile (or be passed
  `--extra-args` manually).
  Cite: same as above. CLI `assemble` has `--profile` (not `--mode`) and no
  `--viral` value; `assemble --help` shows `--profile <profile>` with example
  "meta-sensitive or nano-hq".

- **Procedure step 5 + naming: "Lungfish suggests `<input-name>-spades` by
  default" (line 69).** PARTIALLY WRONG. The CLI derives the project name from
  the input filename WITHOUT a `-spades` suffix (strips `_R1/_R2/_1/_2` and
  extensions); the output directory is `assembly-<projectName>`. There is no
  `-spades` suffix in code.
  Cite: `AssembleCommand.swift:461-491` (`resolvedProjectName`,
  `resolvedOutputDirectory` -> `assembly-<projectName>`). GUI default project
  name is `"assembly"` (`AssemblyWizardSheet.swift:573` placeholder).

### 2. APP FEATURES MISSING FROM THE DOCS

- **SPAdes "Careful mode" toggle** in the GUI wizard (`--careful`), undocumented.
  Cite: `AssemblyWizardSheet.swift:529`.

- **CLI `assemble` real flags:** `--assembler` (default spades), `--read-type`,
  `--paired`, `--memory-gb`, `--min-contig-length`, `--profile`, `--extra-args`,
  `--extra-arg` (repeatable). The chapter shows only `lungfish assemble` with no
  flag detail.
  Cite: `AssembleCommand.swift:68-110`, `assemble --help`.

- **SPAdes minimum contig length is a Lungfish post-filter, not a SPAdes flag.**
  Worth noting because the GUI exposes a Min Contig stepper for SPAdes.
  Cite: `Sources/LungfishWorkflow/Assembly/AssemblyOptionCatalog.swift:127-128`
  (`.spades: "Lungfish post-filter"`), `AssemblyWizardSheet.swift:508-510`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The worked-example output expectations (~29.9 kb contig, ~38% GC) are
  empirical claims about a fixture run, not code facts. They cannot be verified
  here. Note the fixture `SRR36291587` is referenced but the chapter says
  citation lives in its `README.md`; confirm that fixture/README exists.

- The Inspector "coverage (mean depth SPAdes estimates from the de Bruijn
  graph)" claim (line 83) describes display behavior in
  `AssemblyContigDetailPane`/`AssemblyResultViewController`; human should verify
  the coverage value shown is actually parsed from SPAdes contig headers (e.g.
  `cov_412.7`) versus computed.
  Cite: `Sources/LungfishAssemblyUI/AssemblyContigDetailPane.swift`,
  `AssemblyContigCatalog.swift`.

---

## 03-running-flye-or-hifiasm.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Frontmatter + procedure: entry points `Tools > FASTQ/FASTA Operations >
  Assembly > Flye` / `> Hifiasm` (lines 11-12) and "Choose Tools > FASTQ/FASTA
  Operations > Assembly > Flye" (line 96), "> Hifiasm" (line 117).** No such
  submenu items. Single `Assembly...` menu; Flye/Hifiasm chosen in the wizard
  Assembler picker.
  Cite: `MainMenu.swift:685-689`, `AssemblyWizardSheet.swift:439-444`.

- **Flye procedure step 4: "Set the expected genome size if you know it. For
  SARS-CoV-2 use `30k`; for a small bacterial genome use `5m`" (lines 101-104),
  and worked example "set the genome size to `30k`" (line 146).** The GUI
  Assembly wizard does NOT expose a genome-size field. `--genome-size` exists
  only as an "advanced" catalog entry concept; the managed Flye command builder
  never adds `--genome-size`, and the wizard has no genome-size control. A user
  could only pass it via the advanced options text field.
  Cite: `ManagedAssemblyPipeline.swift:280-298` (Flye command: `--<readMode>`,
  `--out-dir`, `--threads`, then `extraArguments`; no `--genome-size`),
  `AssemblyWizardSheet.swift:70-79` (state has memory/minContig/profile/
  flyeMetagenomeMode but no genome size).

- **Flye procedure step 5 + worked example: "Leave the metagenome and polishing
  toggles at their defaults" / "The default polishing pass is one round" (lines
  105-107).** There is a Flye Metagenome toggle (`--meta`), but there is NO
  polishing/iterations toggle in the GUI wizard, and the managed Flye command
  does not set `--iterations`. "Default polishing pass is one round" is a Flye
  internal default, not a Lungfish control.
  Cite: `AssemblyWizardSheet.swift:533-534` (only `flyeMetagenomeMode` toggle),
  `ManagedAssemblyPipeline.swift:280-298` (no `--iterations`).

- **Hifiasm procedure step 4: "If you have parental short reads for trio
  binning, add them on the options page; otherwise leave the trio fields empty"
  (lines 120-122).** No trio-binning fields exist in the wizard. Hifiasm GUI
  options are the Profile picker (Diploid / Haploid-Viral) and a "Primary only"
  toggle (`--primary`). The managed command supports `--ont`, profile args, and
  `extraArguments` only.
  Cite: `AssemblyWizardSheet.swift:537` (`assembly-hifiasm-primary-only-toggle`),
  `:840-844` (profile options Diploid / Haploid-Viral),
  `ManagedAssemblyPipeline.swift:301-325` (Hifiasm command: `-o`, `-t`,
  optional `--ont`, profile args, extras; no trio flags).

- **Flye table row: "Input platform: Oxford Nanopore (R9, R10) or PacBio CLR"
  (line 74).** The CLI/GUI compatibility model gates Flye to ONT reads only
  (`resolvePreMaterializationReadType`/`AssemblyCompatibility`), and the Flye
  command builder asserts "Flye expects a single ONT sequence input in v1."
  PacBio CLR is not an accepted Flye read class in v1.
  Cite: `AssembleCommand.swift:438-444` (Flye topology),
  `ManagedAssemblyPipeline.swift:280-285`, `AssembleCommand.swift:394-401`
  (`.flye -> .ontReads`).

### 2. APP FEATURES MISSING FROM THE DOCS

- **Flye profile picker (Nano HQ default, Nano Raw, Nano Corrected)** maps to
  `--nano-hq` / `--nano-raw` / `--nano-corr`. The chapter's "recent (Q20+)
  model -> set read-type accordingly; otherwise leave on standard ONT raw"
  (lines 98-100) gestures at this but does not name the three profiles or note
  that the DEFAULT is Nano HQ (not raw).
  Cite: `AssemblyWizardSheet.swift:836-838, 887`,
  `ManagedAssemblyPipeline.swift:286` (`request.selectedProfileID ?? "nano-hq"`).

- **Hifiasm `--ont` mode.** Hifiasm accepts ONT reads (adds `--ont`) in addition
  to PacBio HiFi, which the chapter (HiFi-only framing) does not mention.
  Cite: `ManagedAssemblyPipeline.swift:313-315`,
  `AssembleCommand.swift:445-450` ("Hifiasm expects a single ONT or PacBio
  HiFi/CCS sequence input").

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The chapter is explicit that the ONT worked example is "hypothetical" and not
  byte-reproducible (lines 132-138), so its run numbers are not code-verifiable.
  Flagged only so reviewers do not treat them as fixtures.

- Hifiasm GFA-to-FASTA conversion: native output is `<prefix>.bp.p_ctg.gfa`
  (`AssemblyTool.swift:49`), normalized to FASTA by the output normalizer.
  Human should confirm the chapter's "primary plus haplotype-resolved contigs"
  description matches what the normalizer actually surfaces.
  Cite: `Sources/LungfishWorkflow/Assembly/GFASegmentFASTAWriter.swift`,
  `AssemblyOutputNormalizer.swift`.

---

## 04-extracting-contigs.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Frontmatter + body: CLI is `lungfish extract-contigs` (line 12) and
  "`lungfish extract-contigs --assembly <bundle> --contig <id> ... --output
  <path>`" (line 114), and entry point "CLI: lungfish extract-contigs" (line
  12).** WRONG command name. There is no top-level `extract-contigs` command.
  The real command is `lungfish extract contigs` (subcommand `contigs` of the
  `extract` command, command name literally "contigs").
  Cite: `Sources/LungfishCLI/Commands/ExtractContigsCommand.swift:17-19`
  (`commandName: "contigs"`), `Sources/LungfishCLI/Commands/ExtractCommand.swift:25`
  (`ExtractContigsSubcommand.self`). Verified: `extract contigs --help` works;
  `extract-contigs --help` is not a command. The GUI itself invokes
  `["extract", "contigs", "--assembly", ...]`
  (`Sources/LungfishAssemblyUI/AssemblyContigMaterializationAction.swift:82-85`).

- **GUI entry point: "Sidebar: Extract Contigs action on an assembly bundle"
  (line 11) and procedure "Right-click the assembly bundle and choose Extract
  Contigs, or select the bundle and use the same action from the toolbar's More
  menu. A sheet opens listing every contig" (lines 97-99).** WRONG affordance.
  There is no "Extract Contigs" sidebar/right-click/More-menu action and no
  modal sheet. Contig selection happens in the assembly RESULT viewport's contig
  table; the extraction trigger is a **"Create Bundle"** button in the
  `AssemblyActionBar` (enabled when contigs are selected), which calls
  `AssemblyContigMaterializationAction.createBundle`.
  Cite: `Sources/LungfishAssemblyUI/AssemblyActionBar.swift:13,48,67`
  (`bundleButton = NSButton(title: "Create Bundle" ...)`, accessibility "Create
  bundle from selected contigs", "Select contigs to materialize"),
  `AssemblyContigMaterializationAction.swift:48-66`. Grep for "Extract Contigs"
  string across `Sources/LungfishApp/` and the leaf returns zero hits.

- **Procedure step 5: "the new reference bundle appears in the sidebar under
  `Reference Sequences/`" (lines 108-110).** ACCURATE. The bundle is written
  into the project's Reference Sequences folder via
  `ReferenceSequenceFolder.ensureFolder`.
  Cite: `ExtractContigsCommand.swift:308` (`ReferenceSequenceFolder.ensureFolder
  (in: projectRootURL)`). No discrepancy; recorded as verified-correct.

- **Naming claim: default name `<assembly-name>-<contig-tag>` with `contig1`,
  `contig1+2` tags, e.g. `SRR36291587-spades-contig1` (lines 119-133).** NOT
  SUPPORTED by code. The CLI/GUI default bundle name is `<sourceName>-subset`
  (or the source assembly's name with a uniqueness counter), not a
  `-contig1`/`-contig1+2` scheme. No `contig1+2` tag logic exists.
  Cite: `ExtractContigsCommand.swift:346-353` (`resolvedBundleName` ->
  `"\(source.sourceName)-subset"`), `:356-374` (uniqueness via `" 2"`, `" 3"`
  suffix). The GUI passes `--bundle-name <suggestedName>`
  (`AssemblyContigMaterializationAction.swift:59`); the suggested name is
  whatever the result VC supplies, not a `contigN` tag generated by the
  extraction command.

- **Claim: "It is fast and synchronous because no external tool runs ... a
  manifest manipulation" (lines 41-45).** PARTIALLY WRONG. Extraction builds a
  real `.lungfishref` via `ReferenceBundleBuilder` which writes and (by default)
  bgzip-compresses a subset FASTA and builds a FASTA index. The GUI path shells
  out to the CLI as a detached task. It is not a pure manifest copy and the GUI
  call is asynchronous (CLI subprocess), though it is fast.
  Cite: `ExtractContigsCommand.swift:303-344` (writes `subset.fa`, builds bundle,
  `compressFASTA: true`), `AssemblyContigMaterializationAction.swift:33-37`
  (`Task.detached ... LungfishCLIRunner.run`).

### 2. APP FEATURES MISSING FROM THE DOCS

- **CLI `extract contigs` real flags beyond `--contig`:** `--contigs <fasta>`
  (extract from a bare FASTA, not just a managed `--assembly`), `--contig-file`
  (one name per line, repeatable), `--bundle` / `--bundle-name` /
  `--project-root`, `--line-width` (default 60), and stdout output when
  `--output` is omitted. The chapter shows only `--assembly`/`--contig`/
  `--output`.
  Cite: `ExtractContigsCommand.swift:22-48`, `extract contigs --help`.

- **GUI sibling actions on selected contigs:** the same action bar also has
  "BLAST Contigs", "Copy FASTA", and "Export FASTA" buttons, all backed by
  `extract contigs`. Relevant context for the extraction chapter.
  Cite: `AssemblyActionBar.swift:10-13`,
  `AssemblyContigMaterializationAction.swift:39-66`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The claim "CLI parity is exact: the GUI sheet and the CLI produce identical
  bundles for the same selection" (lines 116-117) is effectively TRUE in
  mechanism (the GUI literally shells out to `extract contigs`), but the framing
  ("GUI sheet") is wrong since there is no sheet. Human should reword to "the
  Create Bundle button runs the CLI." Whether the default bundle NAME is
  identical depends on what suggested name the result VC supplies vs the CLI's
  `-subset` default; needs a human check of the result-VC name suggestion.
  Cite: `AssemblyContigMaterializationAction.swift:48-59`.

- SPAdes contig identifier example `NODE_1_length_29812_cov_412.7` (line 115) is
  a plausible real SPAdes header but should be confirmed against
  `AssemblyContigCatalog` parsing.

---

## Section-wide

- **Execution reality:** Assembly is fully executed, not preview. Both the CLI
  `assemble` (`AssembleCommand.swift:261-271`) and the GUI wizard
  (`AssemblyRunner.run` -> `ManagedAssemblyPipeline.run` ->
  `condaManager.runTool`, `ManagedAssemblyPipeline.swift:99-120`) launch the
  real assembler in its `gatk-style` managed conda env and write provenance and
  a `.lungfishref` bundle.

- **Real assembler roster (verified):** SPAdes, MEGAHIT, SKESA, Flye, Hifiasm
  (`AssemblyTool.swift:8-13`). The chapters' five-assembler claim is correct;
  Canu/Trinity/etc. are correctly described as not shipped. Real per-assembler
  profiles the GUI exposes: SPAdes {Isolate, Meta, Plasmid}; MEGAHIT {Default,
  Meta Sensitive, Meta Large}; Flye {Nano HQ, Nano Raw, Nano Corrected};
  Hifiasm {Diploid, Haploid/Viral}; SKESA has no profile picker
  (`AssemblyWizardSheet.swift:818-889`).

- **Two systemic doc errors to fix everywhere:** (1) The Assembly menu is a
  single `Tools > FASTQ/FASTA Operations > Assembly...` item, NOT a per-tool
  submenu (`Assembly > SPAdes` / `> Flye` / `> Hifiasm` do not exist;
  `MainMenu.swift:685-689`). (2) SPAdes has NO `--viral` mode anywhere in code;
  every "viral mode" instruction in chapters 01-02 is unactionable
  (`SPAdesAssemblyPipeline.swift:15-31`, `ManagedAssemblyPipeline.swift:181-190`,
  `AssemblyWizardSheet.swift:820-825`).

- **Contig extraction corrections:** CLI is `lungfish extract contigs` (not
  `extract-contigs`); GUI trigger is a "Create Bundle" button in the assembly
  result action bar (not a right-click "Extract Contigs" sheet); default bundle
  name is `<source>-subset` (not `-contig1`/`-contig1+2`). All three are
  user-blocking inaccuracies (`ExtractContigsCommand.swift:17-19, 346-353`;
  `AssemblyActionBar.swift:13,48`;
  `AssemblyContigMaterializationAction.swift:82-85`).
