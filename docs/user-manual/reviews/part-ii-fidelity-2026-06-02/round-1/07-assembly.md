# 07-assembly focus group synthesis (Round 1)

Round 1 focus-group review + synthesis. Personas cross-checked against the ground-truth reality map.

Standard note: this is a Round-1 simulated-reader focus group plus revision plan for the four Assembly chapters, graded against the arbiter-of-truth reality map in `../ground-truth/07-assembly.md`. Personas quote chapter lines and react to fidelity breaks and accessibility gaps. The synthesis converts those reactions into a prioritized revision plan. No chapters were edited. No em dashes, per `docs/user-manual/STYLE.md`.

**Section under review:** `docs/user-manual/chapters/07-assembly/` chapters 01 through 04 (`01-when-to-assemble.md`, `02-running-spades.md`, `03-running-flye-or-hifiasm.md`, `04-extracting-contigs.md`).

**Headline findings:** the section is technically the strongest in Part II at the conceptual level (the five-assembler roster is correct and assembly genuinely executes), but it is wrecked by two systemic fabrications repeated in almost every chapter. First, a SPAdes `--viral` mode that does not exist anywhere in the code is presented as the recommended default for the manual's flagship SARS-CoV-2 workflow. Second, every chapter's menu path invents a per-tool submenu (`Assembly > SPAdes`, `> Flye`, `> Hifiasm`) when the app has a single `Assembly...` item. The contig-extraction chapter (04) compounds this with a wrong CLI command name, a wrong GUI affordance (a right-click "Extract Contigs" sheet that is actually a "Create Bundle" button), and an invented `-contig1` naming scheme. The Flye/Hifiasm chapter (03) describes a genome-size field and trio-binning fields the GUI does not have.

---

## PART 1: Reader focus group

Four bench biologists, novice to power-user, each read the chapters that match their task. Quotations are verbatim from the chapters. Reactions are written in persona voice.

### Persona 1: Tomas Reubenstein, second-year graduate student (novice, deciding whether to assemble at all)

Tomas has a clinical swab that mapped poorly against the closest GenBank entry. His advisor said "maybe you need to assemble it" and he has never run a de novo assembler. He reads chapter 01 cover to cover before touching anything.

**What worked.** "Chapter 01 is genuinely good teaching. The core contrast landed for me on the first read: Where reference mapping asks 'where on this known genome does each read fit?', assembly asks 'what sequence must the sample have for these reads to make sense?' (line 34). That is the cleanest one-sentence explanation of assembly I have ever read. The three-situations framing (a sample with no good reference ... a higher-quality consensus ... structural variation, lines 40 to 50) told me exactly which bucket my poorly-mapping swab falls in. And the decision walkthrough with three ordered questions (line 95) is the kind of scaffolding a novice needs. I felt like the chapter was holding my hand without talking down to me."

**First fidelity break: the menu path I am told to click.** "The front matter says the entry point is Tools > FASTQ/FASTA Operations > Assembly (line 11), and the prose says Before you click Assembly (line 60). Fine. But the very next chapter, which 01 sends me to, says to click Assembly > SPAdes. So when 01 says 'click Assembly' I assumed there would be a tool submenu hanging off it. Ground truth is clear that the Assembly menu is a single leaf item, not a submenu: the chapter's sibling chapters extend it to `Assembly > SPAdes` etc., which does not exist (ground truth 01 section 1). As a novice, the ambiguity made me nervous before I even opened the app. Is Assembly a button or a folder of buttons?"

**Second break: the viral-mode recommendation steers me wrong on day one.** "The five-assemblers table tells me SPAdes Has a `--viral` mode tuned for viral coverage profiles. Default for SARS-CoV-2 and similar amplicon work (line 82). My sample is viral. So my entire mental plan became 'use SPAdes in viral mode.' Ground truth says this is false: No `--viral` mode exists ... the GUI wizard offers only Isolate/Meta/Plasmid for SPAdes (ground truth 01 section 1). The one concrete recommendation the table gave me for my exact situation is for a mode I will never find. I would have opened the wizard, hunted for 'Viral' in the mode picker, not found it, and concluded I was using the wrong version of the app or that I had broken something. For a novice that is a confidence-ending moment."

**Third break: the worked example doubles down.** "The SPAdes-versus-MEGAHIT comparison says Run SPAdes in viral mode against the paired FASTQ (line 149). Same non-existent mode, now embedded in a step-by-step I was about to follow. Ground truth: Viral mode is not selectable (ground truth 01 section 1). The chapter also describes the wizard's tool picker showing the five assemblers grouped by read type (planned-shot caption, line 15), but ground truth says the picker is a flat segmented control of all five tools, not grouped by read type (ground truth 01 section 1). So the one screenshot that would have oriented me is captioned describing a layout the app does not have."

**Strength I want to flag.** "The decision walkthrough's worked examples (lines 123 and 134) are excellent. The wastewater-shotgun-to-MEGAHIT reasoning and the Nanopore-bacterial-isolate-to-Flye reasoning both walk the three questions concretely. That editorial guidance is exactly what a novice needs, and ground truth confirms it is not wrong, just not encoded in source (ground truth 01 section 3). Keep every word of the reasoning. Just fix the mode it tells me to pick at the end."

**Accessibility.** "Every screenshot is a planned shot, a `<!-- planned: ... -->` comment with no image. The one real graphic, the assembly-versus-mapping schematic, has a genuinely good descriptive alt string (Mapping with a reference contrasted against de novo assembly from read overlaps into contigs, line 38). That is the model. But for a novice who is a visual learner, having zero rendered screenshots of the wizard I am about to use means I am flying blind into a tool I have never seen."

**Net.** "The concepts earned my full trust. Then the single most specific instruction for my exact use case, use SPAdes viral mode, points at a control that does not exist, and the menu path is ambiguous about whether Assembly is a button or a submenu. A novice does not recover gracefully from 'the thing the manual told me to click is not there.'"

### Persona 2: Dr. Aisha Nwosu, research associate (intermediate, running SPAdes on a SARS-CoV-2 amplicon run)

Aisha runs SARS-CoV-2 amplicon libraries weekly. She is fluent in the GUI, occasionally drops to the CLI, and reads chapter 02 as a procedure to execute, not theory.

**What worked.** "The conceptual opening is solid. The de Bruijn graph explanation (a network of overlapping k-mer fragments, line 31) is accurate and appropriately brief. And the interpretation guidance is the best part: a good SARS-CoV-2 assembly has three properties: one dominant contig of roughly 29.9 kb, even coverage along that contig ... and a GC content near 38 percent (line 93). The GC-content-as-contamination-check tip (A GC content of 50 percent or higher on a 'viral' contig usually means you assembled a host or contaminant fragment, line 83) is genuinely useful bench wisdom. The N50 explanation (line 95) and the per-organism threshold table (line 99) are the kind of reference I would keep open in a second window."

**First break: the menu path is wrong.** "Front matter and step 2 both say Choose `Tools > FASTQ/FASTA Operations > Assembly > SPAdes`. The Assembly wizard opens (line 61). I opened the Tools menu, found FASTQ/FASTA Operations, and there is no SPAdes submenu. There is one item that says Assembly... I clicked it and the wizard opened with a segmented Assembler picker inside. Ground truth confirms: No `> SPAdes` menu item exists. The menu item is `Assembly...`; SPAdes is selected inside the wizard via the Assembler segmented picker (ground truth 02 section 1). I figured it out in ten seconds because I am experienced. A first-timer would not."

**Second break: the entire SPAdes mode table is half-fiction.** "This is the one that cost me real time. The mode table (lines 47 to 53) lists five rows: Isolate, Viral `--viral`, Plasmid, Metagenomic, RNA `--rna`. Step 4 then tells me For the worked example below, choose `Viral` (line 67). I opened the wizard's SPAdes mode picker and it had exactly three entries: Isolate, Meta, Plasmid. No Viral. No RNA. Ground truth: Viral `--viral` does not exist ... RNA `--rna` exists in the enum but the managed pipeline never emits it ... The only user-selectable SPAdes profiles are Isolate, Meta, Plasmid (ground truth 02 section 1). Two of the five rows in the table are for modes I cannot select. And the worked example tells me to pick the one that is most prominently fabricated. The chapter even invents a justification: Viral mode is the right pick for every single-virus dataset in this manual (line 55). I trusted that, looked for Viral, and it was not there. I sat there assuming I had the wrong build."

**Third break: the suggested output name.** "Step 5 says Lungfish suggests `<input-name>-spades` by default (line 69). The wizard's name field showed assembly, not my-input-spades. Ground truth: GUI default project name is `'assembly'` ... There is no `-spades` suffix in code (ground truth 02 section 1). Minor, but it is the third thing in one procedure that did not match my screen, and by then I had stopped trusting the chapter's UI claims entirely."

**A control the chapter never mentions.** "The wizard had a Careful mode toggle for SPAdes that the chapter never names. Ground truth confirms it is real: SPAdes 'Careful mode' toggle in the GUI wizard (`--careful`), undocumented (ground truth 02 section 2). For an intermediate user running clinical samples, careful mode is exactly the kind of accuracy-versus-speed knob I want guidance on, and I got none."

**The CLI section is too thin to use.** "Front matter says CLI: lungfish assemble (line 12) and that is essentially all the detail the chapter gives. When I went to script a batch, I needed the flags and the chapter had none. Ground truth lists the real surface: `--assembler` (default spades), `--read-type`, `--paired`, `--memory-gb`, `--min-contig-length`, `--profile`, `--extra-args` (ground truth 02 section 2). Critically, the mode flag is `--profile`, not `--mode`, and there is no `--viral` value. The chapter implies a `--viral` CLI path that does not exist."

**Accessibility.** "The per-organism threshold table (line 99) is well structured and would read cleanly with a screen reader. Good. But the planned screenshots (assembly-wizard-spades captioned with viral mode chosen, assembly-viewport, contig-inspector) are all unrendered, and the first one is captioned describing a control, viral mode, that does not exist. So even when the screenshots land, that caption is wrong."

**Net.** "The interpretation and troubleshooting writing is the best in the section and I would keep all of it. But the procedure I actually have to execute is wrong at three of its steps, and the headline mode recommendation for my exact workflow, viral mode, is fictional. I run this weekly. I cannot hand this chapter to a new hire."

### Persona 3: Dr. Henrik Vaszquez, long-read sequencing lead (advanced, running Flye on ONT and evaluating Hifiasm)

Henrik runs a Nanopore platform and an occasional PacBio HiFi project. He reads chapter 03 closely, expects the wizard fields named in the procedure to be on screen, and plans to script the CLI afterward.

**What worked.** "The conceptual framing of why long reads give fewer contigs is correct and well put: a single ONT read can be tens of thousands of bases long ... so the assembly graph collapses into a small number of long, unambiguous paths instead of a forest of short contigs broken at every repeat (line 39). The honesty about Hifiasm being overkill for viral genomes (line 81) is good and accurate guidance, and ground truth does not contest it. The Flye-versus-Hifiasm aspect table (line 72) is the right idea structurally."

**First break: the menu path, again.** "Both procedures say Choose Tools > FASTQ/FASTA Operations > Assembly > Flye (line 96) and > Hifiasm (line 117). Neither submenu exists. Ground truth: No such submenu items. Single `Assembly...` menu; Flye/Hifiasm chosen in the wizard Assembler picker (ground truth 03 section 1). Same systemic error as the SPAdes chapter. By the third chapter I have seen this wrong path four times."

**Second break: the genome-size field I am told to set is not in the GUI.** "This is the one that actually stopped my workflow. Flye step 4 says Set the expected genome size if you know it. For SARS-CoV-2 use `30k`; for a small bacterial genome use `5m` (line 101). The worked example repeats it: set the genome size to `30k` (line 146). I opened the Flye wizard and there is no genome-size field. I opened every disclosure triangle looking for it. Ground truth is unambiguous: The GUI Assembly wizard does NOT expose a genome-size field ... the managed Flye command builder never adds `--genome-size`, and the wizard has no genome-size control (ground truth 03 section 1). A user could only pass it via the advanced options text field. So the chapter sends me to set a parameter that is simply not a control. For an advanced user this is maddening because genome-size is the one Flye knob I actually care about, and the doc tells me it exists as a field when it does not."

**Third break: the polishing toggle is invented.** "Step 5 says Leave the metagenome and polishing toggles at their defaults (line 105) and the worked example says The default polishing pass is one round (line 107). There is a metagenome toggle. There is no polishing toggle. Ground truth: there is NO polishing/iterations toggle in the GUI wizard ... 'Default polishing pass is one round' is a Flye internal default, not a Lungfish control (ground truth 03 section 1). The chapter presents a Flye internal as if it were a wizard control I can see and change."

**Fourth break: the Hifiasm trio-binning fields do not exist.** "Hifiasm step 4 says If you have parental short reads for trio binning, add them on the options page; otherwise leave the trio fields empty (line 120). There are no trio fields. Ground truth: No trio-binning fields exist in the wizard. Hifiasm GUI options are the Profile picker (Diploid / Haploid-Viral) and a 'Primary only' toggle (ground truth 03 section 1). For a HiFi lead this is a real letdown because trio binning is a marquee Hifiasm capability, and the doc tells me the fields are there when the app does not implement them."

**Fifth break: the Flye input-platform claim is wrong.** "The aspect table says Flye accepts Oxford Nanopore (R9, R10) or PacBio CLR (line 74). I have CLR data I considered routing through Flye. Ground truth: The CLI/GUI compatibility model gates Flye to ONT reads only ... PacBio CLR is not an accepted Flye read class in v1 (ground truth 03 section 1). The Flye command builder literally asserts 'Flye expects a single ONT sequence input in v1.' If I had prepped a CLR run for Flye on the strength of this table, the wizard would have rejected it and I would not have known why."

**Features the chapter omits that I needed.** "Two real things are missing. First, the Flye profile picker, Nano HQ (default), Nano Raw, Nano Corrected, which ground truth says maps to `--nano-hq` / `--nano-raw` / `--nano-corr`, with the default being Nano HQ not raw (ground truth 03 section 2). The chapter gestures at this (a recent (Q20+) model ... otherwise leave it on the standard ONT raw setting, line 98) but names neither the three profiles nor the actual default. For my recent-chemistry reads, knowing the default is already Nano HQ would have changed what I clicked. Second, Hifiasm accepts ONT reads too (adds `--ont`), which the HiFi-only framing of the whole chapter hides (ground truth 03 section 2)."

**Accessibility.** "The aspect table is fine structurally. But the procedure leans entirely on named wizard fields, genome size, polishing toggle, trio fields, that a screen-reader user would be told to find and would never hear announced, because they do not exist. Sending any user, sighted or not, hunting for absent controls is an accessibility problem, not just a fidelity one."

**Net.** "The chapter's concepts are right and its honesty about Hifiasm-is-overkill is good. But the procedure is the worst-matched to the actual GUI in the entire section: three of the fields it tells me to set, genome size, polishing, trio binning, are not in the wizard, and it gets Flye's accepted input platforms wrong. An advanced user wastes the most time here because we are the ones who go looking for every advanced knob the doc promises."

### Persona 4: Dr. Priya Subramanian, pipeline engineer (power-user, extracting and scripting contigs)

Priya automates assembly-to-reference handoff across hundreds of samples. She reads chapter 04 for the exact CLI command and the exact GUI affordance, and she scripts directly from the front matter.

**What worked.** "The conceptual model is genuinely useful. The decision rule is crisp: if your next step opens a reference picker, extract. If your next step is reading the contig list, do not (line 88). The when-to-extract-versus-keep-the-full-assembly section (line 65) is exactly the framing I would teach a new engineer. And the variant-calling-against-your-own-assembly worked example (line 139) is the canonical workflow, laid out correctly step by step at the conceptual level. The provenance-holds-UUIDs-not-display-names point (line 132) is the kind of detail that saves a scripting engineer from a renaming disaster."

**First break: the CLI command does not exist.** "This is the one that would have broken my pipeline at 2am. Front matter says CLI: lungfish extract-contigs (line 12), and the body gives the full form: `lungfish extract-contigs --assembly <bundle> --contig <id> ... --output <path>` (line 114). I ran `lungfish extract-contigs --help` and got an error. There is no such command. Ground truth: There is no top-level `extract-contigs` command. The real command is `lungfish extract contigs` (subcommand `contigs` of the `extract` command) (ground truth 04 section 1). It is two words, `extract contigs`, not a hyphenated single command. The GUI itself invokes `['extract', 'contigs', '--assembly', ...]`. I would have hardcoded `extract-contigs` into a batch script straight from the front matter, and every single invocation would have failed. For a power-user the front-matter CLI line is load-bearing, and it is wrong."

**Second break: the GUI affordance is a different thing entirely.** "The procedure says Right-click the assembly bundle and choose Extract Contigs ... A sheet opens listing every contig (line 97). I right-clicked the assembly bundle in the sidebar. There is no Extract Contigs item. There is no sheet. Ground truth: There is no 'Extract Contigs' sidebar/right-click/More-menu action and no modal sheet. Contig selection happens in the assembly RESULT viewport's contig table; the extraction trigger is a 'Create Bundle' button in the `AssemblyActionBar` (ground truth 04 section 1). So the affordance is not a right-click sheet at all. It is a Create Bundle button in the result viewport's action bar, enabled when I select contigs in the table. The mental model the chapter builds, right-click then sheet then Run, is wrong from top to bottom. The shot caption (The Extract Contigs sheet with three contigs listed, line 16) describes a sheet that does not exist."

**Third break: the naming convention is fabricated.** "The chapter spends a whole section on naming: the contig tag is `contig1` for a single longest-contig extraction, `contig1+2` for two contigs (line 124), with the worked example accept the default bundle name `SRR36291587-spades-contig1` (line 155). I extracted one contig and the proposed name was my-source-subset, not anything-contig1. Ground truth: the CLI/GUI default bundle name is `<sourceName>-subset` ... not a `-contig1`/`-contig1+2` scheme. No `contig1+2` tag logic exists (ground truth 04 section 1). So the entire Naming derived bundles section describes a scheme that is not in the code. If I built downstream logic that parsed `-contig1` suffixes to know what was extracted, it would never match a real bundle name."

**Fourth break: the synchronous manifest-only claim is wrong.** "The chapter says It is fast and synchronous because no external tool runs ... The operation is a manifest manipulation (line 41), and repeats There is no progress bar because the work is bookkeeping, not computation (line 110). As an engineer I read that as 'safe to call inline, no subprocess, no FASTA work.' Ground truth: Extraction builds a real `.lungfishref` via `ReferenceBundleBuilder` which writes and (by default) bgzip-compresses a subset FASTA and builds a FASTA index. The GUI path shells out to the CLI as a detached task ... the GUI call is asynchronous (ground truth 04 section 1). So it does write and compress a FASTA and build an index, and the GUI spawns a subprocess. It is fast, but it is not a pure manifest copy and it is not synchronous from the GUI. That changes how I would architect calling it in a batch."

**Real CLI flags the chapter hides.** "The chapter shows only `--assembly`, `--contig`, `--output`. Ground truth lists a much richer surface I would actually use for scripting: `--contigs <fasta>` (extract from a bare FASTA, not just a managed `--assembly`), `--contig-file` (one name per line, repeatable), `--bundle` / `--bundle-name` / `--project-root`, `--line-width` (default 60), and stdout output when `--output` is omitted (ground truth 04 section 2). The `--contig-file` flag alone is exactly what I want for batch extraction from a name list, and the chapter never mentions it. Stdout-when-output-omitted is huge for piping. None of it is documented."

**Sibling actions I would have wanted to know about.** "Ground truth notes the same action bar has BLAST Contigs, Copy FASTA, and Export FASTA buttons, all backed by `extract contigs` (ground truth 04 section 2). For a power-user that context, the extraction command is one of four sibling operations on selected contigs, would have helped me understand the surface. The chapter treats extraction as an isolated right-click action."

**What I would keep.** "The conceptual decision framework is excellent and I would preserve it intact: the reference-picker rule (line 88), the when-to-keep-versus-extract reasoning (line 65), and the variant-against-your-own-assembly workflow logic (line 139). Ground truth even confirms one of my favorite claims: the new reference bundle appears in the sidebar under `Reference Sequences/` is ACCURATE (ground truth 04 section 1). The bones are right. Every concrete affordance, the command, the button, the name, is wrong."

**Accessibility.** "The chapter is prose-heavy and reads fine structurally. But like the rest of the section, every screenshot is an unrendered planned shot, and the two captions here (extract-contigs-sheet, derived-bundle-in-sidebar) describe a sheet and a naming scheme that do not exist. A screen-reader user told to find a Create Bundle button would instead be told to right-click for an Extract Contigs item that is not in the menu."

**Net.** "This is the most dangerous chapter for a power-user because everything I script from is wrong: the CLI command name errors out, the GUI affordance is a different control in a different place, the naming convention is invented, and the synchronous-manifest claim misrepresents what the operation actually does. The conceptual teaching is first-rate and worth keeping. Every executable detail needs to be corrected against the binary."

---

## PART 2: Synthesis and revision plan

Four personas, reading different chapters for different tasks, converged on the same shape of problem: the conceptual writing in this section is excellent and should be largely preserved, but almost every concrete instruction, the menu path, the SPAdes mode, the Flye and Hifiasm fields, the contig-extraction command and button and name, points at something the app does not have. The fixes below are ordered by how badly a reader is harmed by acting on the current text. Ground-truth citations are to `../ground-truth/07-assembly.md`.

## Critical fidelity fixes (the app does not work as written)

These are not style or polish. Each one causes a reader to fail at a task, script a broken command, or hunt for a control that does not exist.

### C1. Remove the SPAdes `--viral` mode everywhere (chapters 01, 02)

This is the single most damaging error in the section because the manual's flagship workflow is viral and the chapter makes viral mode the recommended default. Ground truth, 01 section 1 and 02 section 1: No `--viral` mode exists. `SPAdesMode` enum is `isolate`, `meta`, `plasmid`, `rna`, `bio`; the managed pipeline only emits `--isolate`/`--meta`/`--plasmid`; the GUI wizard offers only Isolate/Meta/Plasmid. Section-wide point 2 confirms grep for `"--viral"` returns zero assembly hits.

Affected occurrences. Chapter 01: the table row (line 82), the worked example Run SPAdes in viral mode (line 149). Chapter 02: the modes table Viral row (line 50), the choosing notes (line 55), the so-what guidance Pick viral mode for any single-virus isolate (line 37), the procedure step 4 choose `Viral` (line 67), the worked example with viral mode selected (line 79), and the planned-shot caption viral mode chosen (line 16). Also delete the RNA `--rna` row (line 53): ground truth confirms the enum has it but the managed pipeline never emits it and the GUI does not offer it (ground truth 02 section 1).

Corrected SPAdes modes table (chapter 02, replacing lines 47 to 53) to the three modes the wizard actually exposes:

> | Mode | Flag | Use when |
> |---|---|---|
> | Isolate (default) | `--isolate` | Single viral or bacterial isolate, Illumina paired-end |
> | Metagenomic | `--meta` | Shotgun metagenome, multiple organisms at varying abundance |
> | Plasmid | `--plasmid` | Plasmid-only sequencing, or extracting plasmids from an isolate |

Corrected viral-workflow guidance (replacing the viral-mode recommendation). For a single-virus SARS-CoV-2 amplicon run, the SPAdes profile to use is the default Isolate. There is no viral profile in Lungfish. If a reader needs SPAdes' upstream `--viral` pipeline specifically, the only path is to pass it through the wizard's advanced options text field or the CLI `--extra-args`; it is not a selectable mode. NEEDS-HUMAN-CHECK (ground truth 01 section 3): confirm the editorial recommendation that Isolate is the right default for SARS-CoV-2 amplicon work, since Isolate is the only SPAdes default profile available.

### C2. Fix the per-tool Assembly menu path everywhere (chapters 01, 02, 03)

Ground truth, section-wide point and 01/02/03 section 1: the menu is a single `Tools > FASTQ/FASTA Operations > Assembly...` item (`MainMenu.swift:685-689`). Paths like `Assembly > SPAdes`, `> Flye`, `> Hifiasm` do not exist. The assembler is chosen inside the wizard via a flat segmented Assembler picker over all five tools.

Affected. Chapter 01: front-matter entry point (line 11, the first three segments are correct, just do not extend it). Chapter 02: front-matter entry point (line 11) and procedure step 2 (line 61). Chapter 03: front-matter entry points (lines 11 to 12) and procedure steps (lines 96 and 117). Corrected text for every occurrence:

> Choose `Tools > FASTQ/FASTA Operations > Assembly...`. The Assembly wizard opens. Select your assembler (SPAdes, MEGAHIT, SKESA, Flye, or Hifiasm) from the Assembler picker at the top of the wizard.

Also fix the planned-shot caption in chapter 01 (line 15): the tool picker is a flat segmented control of all five tools, not grouped by read type (ground truth 01 section 1). Recaption to the five assemblers in a segmented Assembler picker, with a separate Read Type control.

### C3. Remove the Flye genome-size field and polishing toggle (chapter 03)

Ground truth, 03 section 1. The GUI Assembly wizard does NOT expose a genome-size field; the managed Flye command builder never adds `--genome-size`. There is also NO polishing/iterations toggle in the GUI wizard.

Affected. Procedure step 4 Set the expected genome size ... For SARS-CoV-2 use `30k` (lines 101 to 104), step 5 the polishing toggles ... The default polishing pass is one round (lines 105 to 107), and the worked example set the genome size to `30k` (line 146). Corrected Flye procedure (replacing steps 4 and 5):

> 4. Choose the Flye read-quality profile. The default is Nano HQ, for reads basecalled with a recent (Q20+) model. Use Nano Raw for older or noisier ONT chemistries, or Nano Corrected if your reads were error-corrected upstream.
> 5. Leave the Metagenome toggle off unless your sample is a mixed community. Flye polishes internally; there is no polishing control in the wizard.

Optional advanced note: a genome-size hint can still be passed through the wizard's advanced options text field or the CLI `--extra-args`, but it is not a first-class field. Remove the `30k` instruction from the worked example and replace with selecting the Nano HQ (or appropriate) profile.

### C4. Remove the Hifiasm trio-binning fields (chapter 03)

Ground truth, 03 section 1: No trio-binning fields exist in the wizard. Hifiasm GUI options are the Profile picker (Diploid / Haploid-Viral) and a 'Primary only' toggle (`--primary`).

Affected. Hifiasm procedure step 4 If you have parental short reads for trio binning, add them on the options page; otherwise leave the trio fields empty (lines 120 to 122). Corrected step 4:

> 4. Choose the Hifiasm profile: Diploid for a heterozygous genome where you want haplotype-resolved output, or Haploid/Viral for a haploid or viral target. Enable Primary only if you want just the primary assembly without the alternate haplotigs. Hifiasm has no genome-size parameter; it infers structure from the reads.

The existing step 3 sentence Hifiasm has no genome-size parameter; it infers structure from the reads (line 119) is correct and can fold into the rewritten step 4.

### C5. Fix the contig-extraction CLI command (chapter 04)

Ground truth, 04 section 1 and section-wide: there is no top-level `extract-contigs`. The real command is `lungfish extract contigs` (subcommand `contigs` of `extract`). The GUI itself invokes `["extract", "contigs", "--assembly", ...]`.

Affected. Front-matter entry point CLI: lungfish extract-contigs (line 12) and the body form (line 114). Corrected front matter and body:

> CLI: `lungfish extract contigs`

> The CLI form is `lungfish extract contigs --assembly <bundle> --contig <id> [--contig <id> ...] --output <path>`.

Also document the real flags the chapter omits (ground truth 04 section 2): `--contigs <fasta>` to extract from a bare FASTA, `--contig-file` (one name per line, repeatable), `--bundle-name`, `--project-root`, `--line-width` (default 60), and that omitting `--output` writes FASTA to stdout. The `--contig-file` and stdout behaviors are the highest-value additions for the scripting persona.

### C6. Fix the contig-extraction GUI trigger (chapter 04)

Ground truth, 04 section 1: there is no Extract Contigs right-click action and no modal sheet. Contig selection happens in the assembly RESULT viewport's contig table; the trigger is a Create Bundle button in the `AssemblyActionBar`, enabled when contigs are selected.

Affected. Front-matter entry point Sidebar: Extract Contigs action on an assembly bundle (line 11), procedure step 2 Right-click the assembly bundle and choose Extract Contigs ... A sheet opens (lines 97 to 99), procedure step 5 Click `Run`. The sheet closes (line 108), the CLI-parity claim the GUI sheet and the CLI produce identical bundles (line 117), the worked-example step 3 Right-click the assembly bundle and choose Extract Contigs (line 153), and both planned-shot captions (lines 15 to 18, the extract-contigs-sheet shot). Corrected procedure (replacing steps 2 through 5):

> 2. Open the assembly bundle so its result viewport is showing. The contig table lists every contig with its length, coverage, and GC content.
> 3. Select the contigs you want in the table. Click rows to toggle selection. For a typical viral assembly you select the single longest contig; for a bacterial isolate you may select a chromosome plus one or two plasmids.
> 4. Click the Create Bundle button in the assembly result action bar. (The same action bar also offers BLAST Contigs, Copy FASTA, and Export FASTA on the current selection.)
> 5. The new reference bundle is written into `Reference Sequences/` and appears in the sidebar. The button runs the `extract contigs` CLI under the hood, so the bundle is identical to what the command produces.

Correct the CLI-parity framing (ground truth 04 section 3): the GUI does not present a sheet; the Create Bundle button shells out to `extract contigs`. Reword line 117 to the Create Bundle button runs the CLI rather than the GUI sheet and the CLI produce identical bundles.

Also soften the synchronous-manifest claim (ground truth 04 section 1). Extraction is fast but it is not a pure manifest copy: it writes and bgzip-compresses a subset FASTA and builds a FASTA index via `ReferenceBundleBuilder`, and the GUI path runs it as a detached subprocess (asynchronous), not inline. Replace It is fast and synchronous because no external tool runs ... a manifest manipulation (lines 41 to 45) and There is no progress bar because the work is bookkeeping, not computation (line 110) with an accurate it is fast because it only subsets the contigs you chose, writing a compressed FASTA and index into a new bundle, framing.

### C7. Fix the derived-bundle default name (chapter 04)

Ground truth, 04 section 1: the default bundle name is `<sourceName>-subset` (or the source name with a uniqueness counter `" 2"`, `" 3"`), not a `-contig1`/`-contig1+2` scheme. No `contig1+2` tag logic exists.

Affected. The entire Naming derived bundles section (lines 119 to 137), the worked-example default-name claims `SRR36291587-spades-contig1` (lines 130 and 155), and the planned-shot caption named after the source assembly with a contig suffix (line 18). Corrected naming section:

> Lungfish proposes a default name for the new bundle derived from the source: `<source>-subset`. For an assembly named `SRR36291587` the default is `SRR36291587-subset`. If that name is already taken in the project, Lungfish appends a counter (`SRR36291587-subset 2`, and so on). You can overwrite the proposed name in the name field. Renaming the bundle later does not break provenance, because the provenance record holds bundle UUIDs, not display names.

Delete the `contig1` / `contig1+2` tag scheme entirely. Update the worked example to accept `SRR36291587-subset` (or whatever the result viewport suggests) rather than `SRR36291587-spades-contig1`. NEEDS-HUMAN-CHECK (ground truth 04 section 3): the GUI passes `--bundle-name <suggestedName>` where the suggested name comes from the result viewport; confirm whether that suggestion matches the CLI's `-subset` default or differs.

### C8. Correct the Flye accepted-input-platform claim (chapter 03)

Ground truth, 03 section 1: the compatibility model gates Flye to ONT reads only; the Flye command builder asserts "Flye expects a single ONT sequence input in v1." PacBio CLR is not an accepted Flye read class in v1.

Affected. The aspect table Input platform: Oxford Nanopore (R9, R10) or PacBio CLR (line 74). Corrected cell: Oxford Nanopore (R9, R10). Note that in v1 Flye accepts ONT reads only; PacBio CLR is not a supported Flye input. If a reader has CLR data, point them to the external-tool-then-FASTA-import path the chapter already describes (line 88).

## Coverage gaps (real app features missing from the docs)

### G1. MEGAHIT and SKESA are in the roster but never get a procedure

Ground truth confirms the five-assembler roster is correct (SPAdes, MEGAHIT, SKESA, Flye, Hifiasm; `AssemblyTool.swift:8-13`), and chapter 01 names all five. But only SPAdes (chapter 02) and Flye/Hifiasm (chapter 03) get a how-to-run procedure. MEGAHIT and SKESA, both short-read assemblers a reader is explicitly steered toward by the decision walkthrough (metagenomic work belongs on MEGAHIT ... a bacterial isolate ... SKESA, chapter 01 lines 62 and 84), have no run instructions anywhere. A reader sent to MEGAHIT or SKESA by chapter 01 then has no chapter telling them which wizard controls those tools expose.

Two real details ground truth surfaces that should be documented when this gap is filled. First, the GUI profiles each exposes (ground truth section-wide): MEGAHIT offers Default, Meta Sensitive, Meta Large; SKESA has no profile picker. Second, SKESA pins `--min_count 2` by default to avoid zeroing out small assemblies, which materially affects SKESA output and is undocumented (ground truth 01 section 2). Recommendation: extend chapter 02 (or add a short sibling section) to cover MEGAHIT and SKESA runs, since they share the short-read wizard with SPAdes. At minimum, chapter 02 should note its procedure generalizes to MEGAHIT and SKESA with the profile differences above.

### G2. Read-type auto-detection and per-tool compatibility gating

Ground truth, 01 section 2: the CLI and GUI detect read class and block unsupported tool/read-type pairs ("X is not available for Y in v1"). This shapes which tools appear usable and is exactly what would explain the Flye-rejects-CLR behavior (C8) to a reader. The section never mentions that the wizard gates tools by detected read type. Add a short note in chapter 01 that the wizard auto-detects read type and disables assemblers incompatible with it, so a reader understands why a tool may appear unavailable.

### G3. The SPAdes Careful-mode toggle and the min-contig post-filter (chapter 02)

Ground truth, 02 section 2: the GUI wizard exposes a SPAdes Careful mode toggle (`--careful`), undocumented. Separately, the Min Contig stepper the GUI shows for SPAdes is a Lungfish post-filter, not a SPAdes flag (`AssemblyOptionCatalog.swift:127-128`). Both are real controls a reader will see in the wizard and the chapter explains neither. Document careful mode (accuracy-versus-runtime trade) and clarify that minimum contig length is applied by Lungfish after SPAdes runs.

### G4. Hifiasm `--ont` mode and the real Flye profile names (chapter 03)

Ground truth, 03 section 2: Hifiasm also accepts ONT reads (adds `--ont`), not just PacBio HiFi, which the HiFi-only framing of the chapter hides. And the Flye profile picker (Nano HQ default, Nano Raw, Nano Corrected) is never named, though the chapter gestures at it. Both are folded into the corrected procedure in C3 and C4; flagged here as coverage additions so the editor names the three Flye profiles explicitly and notes Hifiasm's ONT capability.

### G5. The full CLI `assemble` flag surface (chapter 02)

Ground truth, 02 section 2: the CLI `assemble` command exposes `--assembler` (default spades), `--read-type`, `--paired`, `--memory-gb`, `--min-contig-length`, `--profile`, `--extra-args`, `--extra-arg` (repeatable). The chapter shows only bare `lungfish assemble`. The mode flag is `--profile`, not `--mode`, with no `--viral` value. Document the flag surface for the scripting reader, and make explicit that there is no `--viral` profile value (this reinforces C1 on the CLI side).

## Accessibility fixes

### A1. Render the screenshots; supply alt text; fix captions that describe absent UI

Every screenshot across all four chapters is an unrendered `<!-- planned: ... -->` marker. The section is dense with viewport-reading instruction (read the contig list, find N50, check GC content, read coverage), so a low-vision or screen-reader reader has nothing to anchor to. Worse, several captions describe UI that does not exist and must be corrected before capture: the SPAdes shot captioned viral mode chosen (chapter 02 line 16, no viral mode, C1), the extract-contigs-sheet shot (chapter 04 line 16, no sheet, C6), and the tool-picker shot captioned grouped by read type (chapter 01 line 15, flat segmented picker, C2). When the shots are captured in the Round-3 pass, each needs descriptive alt text. The model already in the section is chapter 01's `assembly-vs-mapping` illustration, which carries a full descriptive alt string (line 38).

### A2. Name every actionable control with the exact app label

A screen-reader user navigates by the strings the app announces. Several controls the procedures tell the reader to operate are misnamed or invented: the contig-extraction trigger is called Extract Contigs (a right-click sheet) when the real control announces as Create Bundle (C6); the Flye procedure tells the reader to set a genome size field and a polishing toggle that are not in the UI (C3); the Hifiasm procedure references trio fields that do not exist (C4); the SPAdes mode picker is described with Viral and RNA entries the picker does not contain (C1). After the fidelity rewrites, every control named in a procedure must use the exact label the app uses (Create Bundle, the Nano HQ/Nano Raw/Nano Corrected profile names, Diploid/Haploid-Viral, Primary only, Careful mode), so the reader hears the same string the UI announces.

### A3. Keep tables under the bullet and list caps; convert long enumerations

STYLE caps lists at five items and two lists per H2. The rewrites should land the SPAdes flag surface (C5, G5) and the contig-extraction CLI flags as prose or a table rather than a long bullet run, both to stay within the cap and to read cleanly with assistive technology. The existing per-organism threshold table (chapter 02 line 99) and the Flye-versus-Hifiasm aspect table (chapter 03 line 72) are good models: they read well with a screen reader and should stay as tables.

### A4. Do not encode contig quality by color

STYLE forbids red-amber-green in data viz; encode severity with Deep Ink weight and annotation. The section's interpretation guidance (good-assembly thresholds, GC-content contamination checks, coverage uniformity) is text-first and accessible today, which is correct. When the assembly-viewport and contig-inspector screenshots are captured, any quality or coverage encoding in the captured UI overlays must follow the weight-and-annotation rule, not color coding, and the alt text must carry the same signal in words.

## What to keep

These landed well across personas and should survive the revision:

- **Chapter 01's conceptual framing of assembly versus mapping.** The where-does-each-read-fit versus what-sequence-explains-these-reads contrast (line 34), the three-situations framing (lines 40 to 50), and the decision walkthrough's three ordered questions (line 95) oriented the novice persona before any tool was run. This is the strongest teaching writing in the section. Keep it; only the SPAdes viral-mode recommendation, the menu path, and the tool-picker caption inside it are wrong (C1, C2).
- **Chapter 01's worked examples and the SPAdes-versus-MEGAHIT comparison logic.** The wastewater-to-MEGAHIT and Nanopore-isolate-to-Flye walkthroughs (lines 123 and 134) and the identical-input-different-assembler-assumption reasoning (line 167) are exactly the editorial guidance a reader needs, and ground truth confirms the niches are reasonable editorial guidance, just not encoded in source (ground truth 01 section 3). Keep the reasoning; fix only the viral-mode instruction at the end of the SPAdes branch (C1).
- **Chapter 02's interpretation and troubleshooting.** The three-properties-of-a-good-SARS-CoV-2-assembly summary (line 93), the N50 explanation (line 95), the per-organism threshold table (line 99), the GC-content contamination check (line 83), and the two-failure-modes troubleshooting (lines 110 to 116) are accurate, useful bench guidance independent of the wizard-control errors. Keep all of it.
- **Chapter 03's long-read concepts and honest scoping.** The why-long-reads-give-fewer-contigs explanation (line 39), the Hifiasm-is-overkill-for-viral-genomes guidance (line 81), and the run-others-externally-and-import escape hatch (line 88) are correct and ground truth does not contest them. Keep the concepts; fix the invented wizard fields around them (C3, C4).
- **Chapter 04's extraction decision framework.** The reference-picker rule (line 88), the when-to-keep-versus-extract reasoning (line 65), the variant-against-your-own-assembly workflow logic (line 139), and the provenance-holds-UUIDs-not-names point (line 132) are first-rate and accurate. Ground truth explicitly confirms the bundle lands in `Reference Sequences/` (ground truth 04 section 1). Keep the framework; fix the command, the button, the name, and the synchronous-manifest claim (C5, C6, C7).
