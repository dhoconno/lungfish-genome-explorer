# 08-workflows focus group synthesis (Round 1)

Round 1 focus-group review + synthesis. Personas cross-checked against the ground-truth reality map.

Standard note: this is a Round-1 simulated-reader focus group plus revision plan for the two Workflows chapters, graded against the arbiter-of-truth reality map in `../ground-truth/08-workflows.md`. Personas quote chapter lines and react to fidelity breaks and accessibility gaps. The synthesis converts those reactions into a prioritized revision plan. No chapters were edited. No em dashes, per `docs/user-manual/STYLE.md`.

**Section under review:** `docs/user-manual/chapters/08-workflows/` chapters 01 (`01-the-workflow-builder.md`) and 02 (`02-exporting-as-nextflow-or-snakemake.md`).

**Headline findings:** the Workflow Builder is a real node-graph editor with genuinely real machinery (typed ports, semver versioning, run records, the CLI diff), but the chapter describes a palette and a worked example built on node types that do not exist. The seven palette categories (Acquire, Align and map, Trim, Call, Profile, Assemble, Tree) are all invented; the real seven are Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, Output. The flagship "SARS-CoV-2 reads to variants" worked example is not buildable today: the five node types it requires (Download reference, Map reads, Trim primers, Call variants, Annotate variants) are not in `WorkflowNodeType`, the native runner executes only the five FASTQ ops, and the reference fan-out it depends on is rejected by the linear-chain constraint. The only runnable Builder graph is the VSP2 FASTQ chain, which the chapter already documents correctly. Chapter 02 documents the wrong exporter surface: it claims four export targets when there are six, and its Nextflow profiles, parameter block, and Snakemake "modern layout" are all invented relative to what `ProvenanceExporter` actually emits.

---

## PART 1: Reader focus group

Four analysts, novice to power-user, each read the chapters that match their goal. Quotations are verbatim from the chapters. Reactions are written in persona voice.

### Persona 1: Dana Okonkwo, sequencing analyst building her first workflow (novice to the Builder)

Dana processes nanopore wastewater runs and has been doing the same five FASTQ cleanup steps by hand on every sample. Her lead told her "the Workflow Builder will let you save that as a pipeline." She opens chapter 01 and reads it straight through before touching the app.

**What worked.** "The opening sold me. Workflows are the bridge between a one-off analysis and a documented procedure (line 39), and the SOP line, the difference between writing a SOP in a Google Doc and writing one that actually runs (lines 45 to 46), is exactly why my lead wants this. Instead of 'here is what I did', the workflow file says 'here is how to do it again' (lines 43 to 44). That is the clearest statement of provenance-as-executable I have read in this manual. The scope paragraph (lines 48 to 57) also pre-empted my first dumb question, why isn't NAO-MGS in here, by explaining import paths and viewport tools are deliberately out. I trusted the chapter at this point."

**First fidelity break: the menu does not say what the chapter says.** "Front matter and the procedure both say Choose Tools > Workflow Builder (lines 11, 76). I opened the Tools menu and the item is Workflow Builder (Experimental). I hesitated because Experimental was not mentioned anywhere, and for a first-timer that word changes how much I trust the output. Ground truth confirms the real menu item is 'Workflow Builder (Experimental)…' (`MainMenu.swift` line 739) and the chapter omits the qualifier at lines 11, 76, 256, 291. Tell me it is experimental. That is information I need before I build a procedure my lab will rely on."

**Second break: the palette categories are not real.** "The chapter promised the palette groups operations by category, following the Tools menu: Acquire, Align and map, Trim, Call, Profile, Assemble, Tree (lines 86 to 88). I opened the palette and saw completely different headers: Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, Output. Not one of the seven names in the chapter was on screen. Ground truth is blunt: the seven names in the chapter are 'all invented', the real categories are the cases of `NodeCategory` (Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, Output) and 'None of Acquire / Align and map / Trim / Call / Profile / Assemble / Tree exists' (chapter 01 section 1). I spent a minute clicking category headers convinced I had an old build, because the chapter and the app disagreed on the single most visible thing in the window."

**Third break: the node I was told to drag is not in the palette.** "The Common node types table (lines 158 to 175) lists Download reference, Map reads, Trim primers, Call variants, Profile taxa, Assemble, Build tree. Most of those are not in my palette. The only operation nodes I could actually find were the FASTQ ones: deduplicate, trim, human scrub, merge, length filter. Ground truth confirms the FASTQ ops plus a few generics are real and Download reference, Map reads, Trim primers, Annotate variants, Profile taxa, Build tree are 'INVENTED (no enum case, not in palette)' (chapter 01 section 1). For a novice this is the worst kind of table: it looks authoritative, with input and output types and a plugin column, and half of it is fiction."

**The thing that did work end to end was the VSP2 example.** "Once I gave up on the reads-to-variants section and followed the VSP2 FASTQ bundle workflow (lines 252 to 282) instead, it worked exactly as written. I added a FASTQ Bundle Input node, picked my bundle, dragged dedup, trim, scrub, merge, length filter, connected the chain, saved as vsp2-fastq, and clicked Run. It compiled the connected graph into a native FASTQ plan and wrote a derived bundle (lines 277 to 282), just like the chapter said. Ground truth agrees this is 'genuinely buildable and is the one graph the native runner executes' (section-wide). So the chapter contains one real worked example buried under one fake one."

**The red flash that was actually a beep.** "Line 102 to 106 told me the builder draws a thin red flash across an attempted edge if the types do not match. When I tried to wire a FASTA into a FASTQ port, nothing flashed. My Mac just beeped and the connection did not take. Ground truth: the real rejection 'emits NSSound.beep() and logs. There is no red flash, no transient red edge' (chapter 01 section 1). Minor, but I stared at the screen waiting for a visual that never came."

**Accessibility.** "Every screenshot is a planned shot, a `<!-- planned: ... -->` comment with no image. The three I most wanted, the canvas, the palette grouped by category, and a selected node's inspector, are exactly the ones that are missing. For a first-timer a single picture of the real palette would have saved me from the invented-category confusion entirely. And there is no alt text because there is no image."

**Net.** "The concept writing is the best in the manual and then the two most visible facts, the menu name and the palette categories, are both wrong, and the node table is half-invented. I succeeded only because one of the two worked examples happens to be real. A novice cannot tell which one that is in advance."

### Persona 2: Theo Marchetti, pipeline engineer who wants the Nextflow export (intermediate, GUI plus cluster)

Theo runs a SLURM cluster and wants to take a Lungfish pipeline, export it to Nextflow, and run it on his nodes. He reads chapter 02 closely and expects the config and the run command to match what comes out of the app.

**What worked.** "The framing is right. A Lungfish workflow does not have to stay inside Lungfish (line 29), and derived from the same provenance records the app already keeps (lines 34 to 35) is the selling point: the exported pipeline describes the exact tool versions and command lines that ran, not a reconstruction. The spectrum from 'executable on a cluster' to 'ready to paste into a paper' (line 38) is a good way to choose a target. The container and lockfile escape hatches (lines 129 to 154) are exactly the reproducibility plumbing I would want, and ground truth confirms `lungfish bundle export --format container` and `lungfish conda lock --pack` are real (chapter 02 section 3)."

**First break: there are six targets, not four.** "The chapter says Four targets are available (line 32) and the table lists Nextflow, Snakemake, Shell, Methods Section (lines 41 to 46). When I opened File > Export > Provenance, the submenu had six items, including Python Script and Full Provenance (JSON) that the chapter never mentions. Ground truth: the real `ProvenanceExportFormat` enum 'has SIX cases' (Shell Script, Python Script, Nextflow Pipeline, Snakemake Workflow, Methods Section, Full Provenance JSON) 'and the menu builds all six' (chapter 02 section 1). The chapter even has a planned shot captioned 'the four export targets' (front matter), so the screenshot would have contradicted the menu too. The separator between the first four and the last two is probably what fooled the writer, but I see six."

**Second break: the profiles the run command depends on do not exist.** "Step 5 tells me to run `nextflow run main.nf -profile standard` (lines 80 to 82), and the interpretation says nextflow.config declares a standard profile that runs locally and a slurm profile that submits each process as a SLURM job (lines 88 to 92). I generated the export and opened nextflow.config. There were no profiles at all. It was just an errorStrategy and docker.enabled = true. Ground truth quotes the real `exportNextflowConfig` output verbatim: `process { errorStrategy = 'terminate' }` then `docker.enabled = true`, with 'no profiles { } block, no standard profile, and no slurm profile' (chapter 02 section 1). So `-profile standard` fails immediately, and the entire reason I picked Nextflow, the slurm profile, is fictional. This is the break that actually stops me. I cannot submit to my cluster off a config that has no scheduler executor in it."

**Third break: the params block is invented.** "The edit-to-swap-inputs section (lines 184 to 200) shows clean semantic params: params.reads_r1, params.reads_r2, params.reference, params.primer_bed, overridable with `--reads_r1` and friends. The real main.nf had nothing like that. It had one param per input file with a mangled filename, like params.srrxxxxxxx_1_fastq_gz. Ground truth: the real `exportNextflow` emits `params.<sanitized-filename>` per input plus `params.outdir = './results'`, and 'There are no semantic reads_r1 / reference / primer_bed parameters' (chapter 02 section 1). So the one instruction an engineer most needs, how do I point this at my own reads, hands me parameter names that are not in the file."

**Fourth break: the source pipeline cannot be built.** "Chapter 02 opens by assuming I completed the SARS-CoV-2 reads-to-variants workflow from chapter 01 (lines 65 to 71) and exports that. But I could not build that workflow in chapter 01 at all (the nodes are not in the palette). Ground truth nails the framing problem: the export menu renders 'from a WorkflowRun provenance record, NOT from a saved .lungfishflow Builder graph', so the chapter 'pretends its input is the reads-to-variants workflow from The Workflow Builder, a graph that cannot be built or run' (chapter 02 intro). So the export chapter is anchored to a worked example that does not exist, which means I cannot reproduce the walkthrough even before I hit the config errors."

**Net.** "The export concept and the container/lockfile plumbing are real and good. But the two things I touch first, the menu (four versus six) and the Nextflow config (profiles that are not generated), are both wrong, and the run command in the chapter fails on a fresh export. I would have told my team we can submit this to SLURM out of the box, and we cannot."

### Persona 3: Dr. Aisha Rahman, reproducibility-focused PI (advanced, methods and provenance)

Aisha runs a surveillance group and cares about whether an exported pipeline truly reproduces what ran. She reads both chapters for the provenance and versioning guarantees, and she is the persona most sympathetic to the chapter's thesis.

**What worked, and it is the heart of the section.** "The provenance-as-executable thesis is exactly the standard I hold my group to. A workflow takes that record and makes it executable (line 42). The versioning section is real and excellent: every saved .lungfishflow carries a semver-style workflow version (line 198), the versions/history.json append (lines 201 to 204), and the CLI diff, `lungfish workflow diff ... --format json` (lines 206 to 218). Ground truth confirms all of it: 'semver versioning + versions/history.json ... and the lungfish workflow diff [--format json] CLI ... all exist as described' (section-wide). The run record guarantees are real too: graph checksum, sample/project bindings, per-node status, error state (lines 232 to 235) map to the real `WorkflowBuilderRunRecord` with `graphChecksumSHA256` and per-node status (chapter 01 section 3). This is the audit surface I want, and it is genuinely there."

**First break: the headline reproducibility claim is overstated.** "Chapter 02 says the exported pipeline describes the exact tool versions and command lines that ran, not a reconstruction (lines 34 to 35). That absolute is not true for every step. Ground truth: the exporter 'can SYNTHESIZE provenance for reference downloads that were never recorded as steps ... stamping toolVersion: unknown' (chapter 02 section 1). So for some steps the export is exactly a reconstruction with an unknown version, which is the opposite of the guarantee. For a methods section that is a material distinction. I would be asserting an exact-version claim in a paper that the artifact does not back for those steps."

**Second break: the provenance copy is described as less than it is, in a way that undersells the tool.** "The chapter says every export contains a provenance/ subdirectory holding the original provenance sidecars copied verbatim (lines 48 to 50). The reality is more rigorous than the chapter claims, which is unusual: ground truth says `expandProvenanceChain` 'walks input dependencies (including enclosing .lungfishref bundles and their manifests) and merges them, copying each discovered sidecar into provenance/source/...', so 'copied verbatim from the project understates this transitive collection' (chapter 02 section 2). And every artifact is cryptographically signed when a signer is configured, writing `.signature.json` + `.pub` files (chapter 02 section 2), which the chapter never mentions. The signing and the transitive chain are the two features I would most want foregrounded for an auditor, and they are absent."

**Third break: the worked example I would hand a student does not run.** "Both chapters are organized around the reads-to-variants pipeline. As a PI I would assign that walkthrough to a new student as the canonical example. Ground truth is unambiguous that it is 'NOT buildable today' with 'Three independent blockers' (section-wide). So my student would fail at the first lesson, and worse, would not be able to tell whether they did something wrong or the manual is wrong. The reproducibility section should be anchored to the VSP2 chain, which actually runs and actually produces the run.json and provenance.json I am teaching them to read."

**A real guarantee the chapter states well.** "One thing I want to keep: the output bundle is only published after provenance has been written, so an interrupted run cannot leave a final-looking FASTQ bundle without reproducibility metadata (lines 249 to 250). Ground truth confirms the runner uses atomic staging, writes to a hidden `.staging-<uuid>` bundle, then moves it into place, deleting both on error (chapter 01 section 2). The chapter even understates this. The atomic-rename and cleanup-on-failure are stronger than the prose, and they are exactly the kind of guarantee a reproducibility reader wants. Surface the staging mechanism."

**Accessibility.** "The version surface and the diff are text-first and screen-reader friendly, which is good. But the run-state model (parent workflow row plus one child row per node, first failing node marks the run failed and leaves downstream nodes skipped, lines 232 to 235) is described only in prose with no rendered Operation Center shot, and the failed/skipped states are exactly where a low-vision user needs a clear text signal rather than an inferred color. State the per-node status vocabulary (running, succeeded, failed, skipped) explicitly as text."

**Net.** "The provenance-as-executable thesis, the semver versioning, the diff, and the run records are real and are the best argument for this whole feature. Two things undercut it: the absolute exact-versions claim is false for synthesized steps, and the canonical worked example does not run. Anchor the section to the VSP2 chain and soften the exact-version guarantee to match the synthesized-provenance reality."

### Persona 4: Marco Bianchi, power user testing the reads-to-variants example (power-user, stress-testing the docs)

Marco is the analyst who reads a manual by trying to break it. He sat down specifically to build the SARS-CoV-2 reads-to-variants workflow from chapter 01, node by node, exactly as written, to see whether it runs.

**The attempt, step by step, and where it dies.** "I opened Workflow Builder (Experimental) and went to the worked example at lines 284 to 322. Step 1: Download reference, with the accession MN908947.3 (line 297). I scrolled the entire palette. There is no Download reference node and no Acquire category to put it in. Ground truth: 'Download reference (Acquire)' is INVENTED, 'There is no accession/download node type ... anywhere in WorkflowNodeType' (chapter 01 section 1). I cannot even place node one."

**It is not one missing node, it is all five.** "Map reads (minimap2) (line 298): not in the palette. Trim primers, with the primer scheme set to ARTIC v3 (line 299): not in the palette, and ground truth confirms 'no primer-trim node type ... only primerSchemeBundle exists as a PORT data type, never as a node' (chapter 01 section 1). Call variants (iVar), with Minimum allele frequency set to 0.5 (line 298): the chapter elsewhere promises iVar's Minimum allele frequency parameter (line 130), but ground truth says the generic variantCalling node 'expose[s] only the two hidden metadata params ... they have no MAF/preset/--meta fields' (chapter 01 section 1), and there is no Call variants node anyway. Annotate variants (line 300): no annotation node type exists. Five for five, none of them in the palette. Ground truth's bottom line: the five node types 'do not exist in WorkflowNodeType' (section-wide)."

**Even if the nodes existed, the topology is illegal.** "The chapter's wiring instruction is the interesting part: Download reference's reference output goes into Map reads's reference input, into Call variants's reference input, and into Annotate variants's reference input (one output port can fan out to many input ports) (lines 302 to 308). That fan-out is the crux of a reference-based pipeline. Ground truth says the native compiler 'requires outgoing.count == 1 per node' and rejects fan-out with `nonLinearGraph` (chapter 01 section 1). I verified the constraint is in `WorkflowBuilderPlanCompiler`. So even in a hypothetical build where the nodes were added, the documented graph shape violates the linear-chain rule the runner enforces. The example is wrong at two independent levels: the nodes and the topology."

**The runner only knows five operations.** "I wanted to confirm the runner could not execute these even if I forced them in. Ground truth: `recipeOperation(for:)` returns nil for every node type except the five FASTQ ops, and `validateSupportedNodes` throws `unsupportedNode` for anything else (chapter 01 section 1). I read the source. `recipeOperation` has cases for exactly fastpDedup, fastpTrim, deaconHumanScrub, fastpMerge, seqkitLengthFilter, and returns nil otherwise. So mapping, primer-trim, variant-calling, and annotation are not executable by the native runner under any arrangement. The reads-to-variants worked example is three-ways dead: missing node types, illegal fan-out, unsupported operations."

**What I could break that was actually documented honestly.** "I pivoted to the VSP2 chain and tried to break that instead. I could not. dedup, trim, scrub, merge, length-filter connected as a linear chain, the default params matched (quality threshold 15, trim window 5, Deacon database deacon-panhuman, merge minimum overlap 15, minimum length 50, lines 273 to 274), and it ran to a derived bundle. Ground truth confirms these defaults and that this is the one runnable graph (section-wide). The CLI form `lungfish-cli workflow builder-run --workflow ... --project ... --run-directory ...` (lines 239 to 244) is also real: ground truth confirms --workflow, --project, --run-directory, --threads, --dry-run all exist (chapter 01 section 3)."

**Two undocumented behaviors I hit that a power user should know.** "First, the runner fuses adjacent fastp steps. Ground truth: `WorkflowBuilderNativeRunner` 'collapses consecutive fastpDedup/fastpTrim builder steps into a single fastp invocation for provenance accounting' (chapter 01 section 2). My provenance had fewer fastp invocations than nodes, which confused me until I read the source. The chapter presents each step as independent and never mentions fusion. Second, there is a built-in VSP2 template generator, `VSP2WorkflowTemplate.makeGraph(...)`, that builds the whole chain programmatically with stable UUIDs (chapter 01 section 2). The chapter tells me to drag five nodes by hand and never mentions the template path. A power user wants the template, not the drag."

**A subcommand trap in the provenance strings.** "Ground truth flags that the plan compiler emits internal argv like `workflow builder-run --graph-id ... --input-bundle ...` and a phantom `workflow builder-step run` argv that 'are NOT registered subcommands ... provenance strings only, not runnable' (chapter 01 section 3). If a power user copies an argv out of a provenance file expecting to re-run it, it will not work. The chapter should warn that the in-provenance argv are records, not a runnable CLI."

**Net.** "I set out to build the documented reads-to-variants workflow and could not place a single one of its five nodes, and the graph shape it teaches is illegal under the runner's linear-chain rule. The example is unbuildable three different ways. The VSP2 chain, by contrast, is solid and I could not break it. The fix is not to patch the reads-to-variants example, it is to delete it and promote VSP2 to the flagship, while documenting the fastp fusion, the template generator, and the not-runnable provenance argv."

---

## PART 2: Synthesis and revision plan

Four personas, reading for four different goals, converged on one conclusion: the Workflow Builder is a real and well-designed feature whose documentation describes a substantially larger app than the one that ships. The runnable surface is FASTQ-preprocessing workflows via the VSP2 chain, plus a genuine export, versioning, and run-record system. The fixes below are ordered by how badly a reader is harmed by acting on the current text. Ground-truth citations are to `../ground-truth/08-workflows.md`.

## Critical fidelity fixes (the app does not work as written)

This section needs the most aggressive rewrite in the section. Each fix below corresponds to a place where a reader fails at the task, runs a command that errors, or builds a graph that cannot be assembled or run.

### C1. Rewrite chapter 01's palette categories to the seven real ones

Ground truth, chapter 01 section 1 and section-wide: the seven category names at lines 86 to 88 (Acquire, Align and map, Trim, Call, Profile, Assemble, Tree) are all invented. The real categories are the cases of `NodeCategory` in `WorkflowNode.swift`, rendered directly from `NodeCategory.allCases`: Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, Output. Replace the sentence at lines 86 to 88:

> The palette groups operations by category. The seven categories are Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, and Output. Click a category header to expand or collapse its contents. Hovering a node shows a one-line description.

Delete the claim that categories "follow the same structure as the Tools menu" (they do not) and the parenthetical that "both iVar and LoFreq can call variants" (no variant-caller plugin nodes exist; see C3). Also delete the false claim that hovering shows "the plugin that provides it": ground truth confirms nodes carry only a `category`, not a plugin (chapter 01 section 1).

### C2. Delete the reads-to-variants worked example and promote VSP2 to flagship

This is the central over-claim of the section. Ground truth, section-wide: the SARS-CoV-2 reads-to-variants worked example (lines 284 to 322) is "NOT buildable today" with "Three independent blockers": (1) the five node types it requires do not exist in `WorkflowNodeType`; (2) the native FASTQ runner supports only the five fastp/deacon/seqkit ops and rejects everything else; (3) the reference fan-out it depends on is rejected by the linear-chain constraint (`outgoing.count == 1`).

Do not patch this example. Delete the entire "Worked example: SARS-CoV-2 reads to variants" section (lines 284 to 322), the `nextflow-export-main-nf` framing that depends on it, and the cross-reference promising parity with the variants chapter. Promote the existing "Worked example: VSP2 FASTQ bundle workflow" (lines 252 to 282) to be the single, flagship worked example. That section is already correct: ground truth confirms the dedup, trim, scrub, merge, length-filter chain "is genuinely buildable and is the one graph the native runner executes" with the stated defaults (section-wide). Keep it essentially as written, and add the missing detail that a built-in template generator (`VSP2WorkflowTemplate`) can produce the same graph programmatically (see G2).

The chapter's own "What you will learn" section (lines 65 to 71) already names the VSP2 chain as "the first Workflow Builder graph backed by the native Swift runner." Align the whole chapter to that honest scope: the Builder today runs FASTQ-preprocessing workflows, not arbitrary reads-to-variants pipelines.

### C3. Rewrite the "Common node types" table to the real node types

Ground truth, chapter 01 section 1 and section-wide: the only node types that exist are the cases of `WorkflowNodeType`. The table at lines 158 to 175 mixes real nodes with invented ones. Cut every invented row and the entire "Plugin" column (nodes have no plugin attribute).

Delete these invented rows: Download reference (Acquire), Map reads (Align and map / minimap2), Trim primers (Trim), Call variants (Call / iVar), Annotate variants (Call), Profile taxa (Profile / Kraken2), Build tree (Tree / IQ-TREE). Ground truth confirms each is "INVENTED (no enum case, not in palette)" (chapter 01 section 1).

Keep and correct the real rows, using the real category names from C1. The genuinely runnable nodes are: FASTQ Bundle Input (Input), FASTP deduplicate, FASTP trim, Deacon human scrub, FASTP merge, SeqKit length filter (the five FASTQ ops). The real-but-export-only generic nodes are: Quality Control, Trimming, Alignment, Variant Calling, Quantification, Assembly, Report, plus the FASTA Input, BAM Input, and Sample Sheet inputs (chapter 01 section 1, section-wide). Mark the generic Alignment/Variant Calling/Assembly nodes clearly as export-only: ground truth says they "are export-only (Nextflow text) and run only if a separate nextflow binary is present and the graph uses no fastqBundleInput" (section-wide). The reader must not believe these run inside the app.

Also correct lines 130 to 133, which promise iVar "Minimum allele frequency," a minimap2 preset, and SPAdes `--meta`. Ground truth: the real `alignment`, `variantCalling`, and `assembly` nodes expose only two hidden metadata params and "have no MAF/preset/--meta fields" (chapter 01 section 1). The nodes with real typed parameters are the FASTQ ops and the generic `trimming`/`qualityControl` nodes. Rewrite the parameter examples to use FASTQ-op parameters that exist (quality threshold, trim window, minimum length, Deacon database, merge minimum overlap).

### C4. Fix the "red flash," the "More inputs" drawer, and the menu name

Three concrete UI fabrications in chapter 01, all from chapter 01 section 1.

First, the type-mismatch feedback. Lines 102 to 106 say "the builder draws a thin red flash across an attempted edge." The real rejection in `WorkflowCanvasView.createConnection(...)` emits `NSSound.beep()` and logs; "There is no red flash, no transient red edge." Corrected text:

> Each port is typed. A BAM output port can only connect to a BAM input port. If you attempt an edge between incompatible ports, Lungfish plays the system alert sound and the connection is dropped.

Keep the typed-port concept itself: ground truth confirms `WorkflowConnection` does check `dataType.isCompatible(with:)` and the typed ports are real.

Second, the "More inputs" drawer. Lines 115 to 119 describe optional secondary inputs collapsing into a "More inputs drawer ... click the drawer chevron." Ground truth: a grep for "More inputs / moreInputs / drawer / chevron / secondary" returns nothing; ports are fixed per node type and always visible. Delete the drawer paragraph. Where a node takes a second input (alignment takes reads plus reference; variantCalling takes alignments plus reference), state that both ports are shown directly on the node.

Third, the menu name. Lines 11, 76, 256, 291 say "Tools > Workflow Builder." The real menu item is "Workflow Builder (Experimental)…" (`MainMenu.swift` line 739). Add the "(Experimental)" qualifier everywhere, and add one sentence early in the chapter noting the feature is marked experimental so a reader knows the scope is still narrowing.

### C5. Correct chapter 02's target count: six targets, not four

Ground truth, chapter 02 section 1: the chapter says "Four targets are available" (line 32) and lists four (lines 41 to 46), but `ProvenanceExportFormat` has six cases and the menu builds all six. Rewrite the count and the table to include all six: Shell Script, Python Script, Nextflow Pipeline, Snakemake Workflow, Methods Section, and Full Provenance (JSON). The chapter omits Python Script (`reproduce.py`, a subprocess driver) and Full Provenance (JSON) (`provenance.json`, the raw envelope) entirely (chapter 02 section 2). Update the `export-provenance-submenu` planned-shot caption, which currently says "the four export targets," to "the six export targets." Note: the submenu separates the first four from the last two with a visual separator (chapter 02 section 1), which is the likely source of the "four" error, but six items render.

### C6. Rewrite the Nextflow export details around what `ProvenanceExporter` actually emits

Ground truth, chapter 02 section 1. The Nextflow walkthrough describes config and params the export does not generate.

First, the profiles. Lines 88 to 92 claim `nextflow.config` declares a `standard` profile and a `slurm` profile. The real `exportNextflowConfig` emits only:

```
process {
    errorStrategy = 'terminate'
}
docker.enabled = true
```

There is no `profiles { }` block. Delete the standard/slurm profile sentences. The run command at lines 80 to 82 and the "switch the Nextflow profile" line (176) reference profiles that do not exist; change the run command to plain `nextflow run main.nf` and remove the `-profile standard` flag throughout (also lines 167, 199, 213, 217).

Second, the params block. Lines 184 to 200 show semantic params (`params.reads_r1`, `params.reference`, `params.primer_bed`) overridable via `--reads_r1`. The real `exportNextflow` emits one `params.<sanitized-filename>` per input file plus `params.outdir = './results'` (chapter 02 section 1). Replace the groovy block with the real shape, for example `params.srrxxxxxxx_1_fastq_gz = ...`, and explain that parameter names are derived from input filenames, not semantic roles. The override example must use the real mangled names.

Third, the emitted-files table. Line 43 lists Nextflow as `main.nf`, `nextflow.config`, `provenance/`. The real Nextflow export also writes `containers/manifest.json` (tool/version/image/digest entries) (chapter 02 section 1). Add it to the table row.

Fourth, re-anchor the walkthrough. Lines 65 to 71 assume the reads-to-variants workflow from chapter 01, which cannot be built (C2). Re-anchor the export walkthrough to the VSP2 FASTQ workflow, or, more accurately, to a provenance record from any completed run. Ground truth, chapter 02 intro: the menu exporter renders "from a WorkflowRun provenance record, NOT from a saved .lungfishflow Builder graph." State plainly that export draws from provenance records of operations you have run, not from a Builder graph. This also resolves the conceptual mismatch the whole chapter carries.

### C7. Rewrite the Snakemake export to the real flat layout

Ground truth, chapter 02 section 1: lines 219 to 224 claim the Snakemake export "uses the modern workflow/ directory convention," writes a `config/config.yaml`, and writes per-rule conda environments into `workflow/envs/`. The real `exportBundle` for `.snakemake` writes a flat `Snakefile` plus a flat `config.yaml` in the export root. There is no `workflow/` directory, no `config/config.yaml`, no `workflow/envs/`. Per-rule isolation uses `singularity:` directives (`"docker://<image>"`), not conda environment files. Rewrite the Snakemake paragraph (lines 219 to 224) and the table row (line 44) to the flat `Snakefile` + `config.yaml` + `provenance/` layout, and replace the conda-envs claim with singularity directives. Correct the parameterization note at lines 202 to 203 to match the flat `config.yaml`.

### C8. Soften the "exact versions, not a reconstruction" guarantee

Ground truth, chapter 02 section 1: lines 34 to 35 assert the export captures "the exact tool versions and command lines that ran, not a reconstruction." The exporter can synthesize provenance for reference downloads that were never recorded as steps, stamping `toolVersion: "unknown"` (`synthesizedReferenceProvenanceEnvelope`). Soften the absolute. State that the export captures recorded tool versions and command lines for steps that ran as operations, and that some derived steps (notably reference acquisition) may be synthesized with an unknown version. This matters for the methods-section use case (Persona 3) where the claim would otherwise be cited as exact.

## Coverage gaps (real app features missing from the docs)

### G1. The native runner fuses adjacent fastp steps

Ground truth, chapter 01 section 2: `WorkflowBuilderNativeRunner` collapses consecutive `fastpDedup`/`fastpTrim` builder steps into a single fastp invocation for provenance accounting (`isFusibleFastpBuilderStep`). The chapter presents each step as an independent operation and never mentions fusion, which surprised the power-user persona when the provenance showed fewer fastp invocations than nodes. Add a short note in the VSP2 worked example or the interpretation section explaining that adjacent fastp steps are fused into one invocation in the run record.

### G2. The built-in VSP2 template generator

Ground truth, chapter 01 section 2: `VSP2WorkflowTemplate.makeGraph(...)` programmatically builds the full FASTQ chain (input through length-filter to Project output) from the `vsp2-target-enrichment` built-in recipe, with stable node UUIDs. The chapter tells the reader to drag five nodes by hand and never mentions the template path. Add a sentence to the VSP2 worked example noting the chain can be generated from the built-in template rather than dragged node by node.

### G3. Atomic staging on output publication

Ground truth, chapter 01 section 2: the runner writes to a hidden `.staging-<uuid>` bundle, writes provenance there, then `moveItem`s into place, deleting both staging and target on any error. The chapter says only "the output bundle is only published after provenance has been written" (lines 249 to 250), understating the mechanism. The reproducibility-PI persona specifically wanted this surfaced. Expand the sentence to name the atomic-staging-and-rename behavior and the cleanup-on-failure guarantee, since it is exactly the durability property a reproducibility reader is auditing for.

### G4. Two undocumented export targets

Ground truth, chapter 02 section 2: Python Script (`reproduce.py`, a subprocess driver) and Full Provenance (JSON) (`provenance.json`, the raw envelope) are shipped menu items the chapter never mentions. Once the target count is corrected (C5), add a one-line description of each: Python for a portable subprocess driver, Full Provenance (JSON) for the raw machine-readable envelope.

### G5. Export signing and the transitive provenance chain

Ground truth, chapter 02 section 2: every export is cryptographically signed when a signer is configured (`signReportArtifacts` writes `.signature.json` + `.pub` next to each artifact and self-verifies), and `expandProvenanceChain` walks input dependencies transitively (including enclosing `.lungfishref` bundles) and copies each discovered sidecar into `provenance/source/...`. The chapter mentions provenance copying but not signing, and describes the copy as "verbatim from the project" (line 49), understating the transitive collection. Both are high-value for the reproducibility audience. Add a short subsection on signing and on the transitive provenance chain.

### G6. The not-runnable provenance argv

Ground truth, chapter 01 section 3: the plan compiler emits internal argv such as `workflow builder-run --graph-id ... --input-bundle ...` and a phantom `workflow builder-step run` argv that are not registered subcommands; they are provenance strings only, not runnable. A power user who copies an argv out of a provenance file expecting a runnable command will be misled. Add a one-line caution that argv recorded in provenance are audit records, and the user-invocable CLI is `lungfish-cli workflow builder-run` with `--workflow`/`--project`/`--run-directory` (lines 239 to 244, which are correct).

## Accessibility fixes

### A1. Render the screenshots; supply alt text

Both chapters carry only unrendered `<!-- planned: ... -->` markers. The three most load-bearing shots in chapter 01 (the canvas, the palette grouped by category, the node inspector) are exactly the ones that would have prevented the novice persona's invented-category confusion. The chapter 02 submenu shot would have exposed the four-versus-six error directly. When the shots are captured (Round-3 screenshot pass), each needs descriptive alt text. In particular, the palette shot must show the seven real category headers so the image cannot drift back to the invented names.

### A2. State the per-node run-status vocabulary as text, not inferred color

The run model (parent workflow row plus one child row per node; the first failing node marks the run failed and leaves downstream nodes skipped, lines 232 to 235) is real (chapter 01 section 3, `WorkflowBuilderNodeRunStatus` includes `.skipped`). A low-vision user needs the status words, not a color cue, in the Operation Center. State the status vocabulary explicitly in prose (running, succeeded, failed, skipped) so a screen-reader user hears the same string the UI uses. This also aligns with the STYLE rule against encoding severity by color.

### A3. Name UI controls with the exact labels the app uses

After the fidelity rewrites, every actionable control should carry its real label. The menu is "Workflow Builder (Experimental)…" not "Workflow Builder" (C4). The type-mismatch feedback is the system alert sound, not a "red flash" (C4). The export menu is "File > Export > Provenance" with six named items (C5). A screen-reader user must hear the same string the UI announces, so the corrected labels matter for navigation, not just accuracy.

### A4. Keep tables and lists under the STYLE caps

STYLE caps lists at five items and two lists per H2. The rewritten node-types table (C3) and export-targets table (C5) should stay as tables, not bullet runs. The VSP2 five-step chain is a genuine parallel five-item enumeration and may remain a list. The corrected Nextflow/Snakemake details should land as prose or table to stay within the cap and read cleanly with assistive tech.

## What to keep

These landed well across personas and should survive the revision:

- **The provenance-as-executable thesis (chapter 01).** "Instead of here is what I did, the workflow file says here is how to do it again" (lines 43 to 44) and the SOP framing (lines 45 to 46) are the strongest argument for the feature and were praised by every persona, including the skeptical power user. Keep the entire "What it is" framing; only the menu name, palette categories, and node table inside the chapter are wrong (C1 to C4).
- **The scope paragraph (chapter 01, lines 48 to 57).** The explanation that result-import paths (NAO-MGS, NVD, CZ-ID) and result-viewport tools (re-rooting, BLAST verify) are deliberately out of the Builder pre-empts a real reader question and is accurate. Keep it.
- **The VSP2 FASTQ worked example (chapter 01, lines 252 to 282).** Ground truth confirms it "is genuinely buildable and is the one graph the native runner executes," with the stated default parameters (section-wide). This is the template the whole chapter should be rebuilt around (C2). Keep it as the flagship, plus the fusion and template notes (G1, G2).
- **The versioning and diff machinery (chapter 01, lines 198 to 218).** Semver `.lungfishflow` versions, the `versions/history.json` append, and the `lungfish workflow diff [--format json]` CLI all verify against the binary (section-wide). The reproducibility PI called this the best argument for the feature. Keep it verbatim.
- **The run-record guarantees (chapter 01, lines 229 to 250).** Graph checksum, sample/project bindings, per-node status, error state, `run.json` plus `provenance.json` under `runs/<run-id>/`, parent-plus-child Operation Center rows, and the `lungfish-cli workflow builder-run` CLI form are all real (chapter 01 section 3). Keep them, and expand the publish-after-provenance sentence into the atomic-staging guarantee (G3).
- **The export concept and the container/lockfile plumbing (chapter 02).** The "does not have to stay inside Lungfish" framing (line 29), the target-as-a-spectrum idea (line 38), and the `lungfish bundle export --format container` and `lungfish conda lock --pack` commands (lines 129 to 154) are sound and verify against the CLI (chapter 02 section 3). Keep the concept and the commands; fix the count, the Nextflow config, and the Snakemake layout around them (C5 to C7).
- **The honest-limits section (chapter 02, lines 96 to 124).** The candid list of what the export does not capture (OCI registry availability, host CPU microarchitecture, SRA-sourced reads) is exactly the right tone for a reproducibility chapter and is directionally accurate. Keep it, and pair it with the softened exact-versions claim (C8) so the chapter's honesty is consistent throughout.
