# 08-workflows Round 2 review (simulated reader, post-rewrite verification)

Round 2 of the iterative simulated-reader review. Chapters 01 and 02 of
`docs/user-manual/chapters/08-workflows/` were aggressively rewritten after
Round 1. This pass verifies each Round-1 critical fix landed, scrutinizes the
rewrites for re-introduced or new fabrications, and re-reads as three personas.
Every load-bearing claim below was re-checked live against the Swift source and
the built CLI binary (`.build/debug/lungfish-cli`). No chapters were edited. No
em dashes, per `docs/user-manual/STYLE.md`.

**Headline.** The rewrites landed cleanly. Both chapters now describe only what
exists. The invented palette categories, the unbuildable reads-to-variants
example, the "four export targets" error, the fictional Nextflow profiles, the
semantic `params.reads_r1` block, the Snakemake `workflow/` layout, the "red
flash", and the "More inputs drawer" are all gone. The VSP2 chain is the
flagship, export is correctly framed as provenance-driven, and the chapter is
explicit that the Builder is scoped to FASTQ preprocessing. One substantive new
fidelity defect survives: ch01 still describes the typed-port compatibility
check as "the same set of viewport interface classes ... Sequence, Taxonomy,
Alignment, Assembly, and Variant", which is not how the check actually works.
Two minor port-naming and prose nits round out the must-fix list.

---

## PART 1: Verification table

Re-checked against `WorkflowNode.swift`, `WorkflowNodePalette.swift`,
`WorkflowCanvasView.swift`, `WorkflowBuilderPlanCompiler.swift`,
`WorkflowBuilderNativeRunner.swift`, `VSP2WorkflowTemplate.swift`,
`ProvenanceExporter.swift`, `MainMenu.swift`, `WorkflowCommand.swift`, and the
live `lungfish-cli workflow diff --help`.

| # | Round-1 critical fix | Status | Note (current text quoted) |
|---|---|---|---|
| 1 | Real 7 palette categories (Input / Preprocessing / Trimming & Filtering / Decontamination / Read Processing / Analysis / Output) | LANDED | ch01 line 92: "seven categories: Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, and Output." Exact match to `NodeCategory.allCases` (`WorkflowNode.swift` 410-417). The invented Acquire/Align/Trim/Call/Profile/Assemble/Tree are gone. |
| 2 | Real runnable node types only; invented nodes removed | LANDED | The node table (ch01 188-199) lists only real `WorkflowNodeType` cases. Invented Download reference / Map reads / Trim primers / Annotate variants / Profile taxa / Build tree are gone. ch01 201: "There is no download node, no primer-trim node, no annotation node, and no phylogenetics node in the palette." Confirmed against the enum. |
| 3 | Reads-to-variants worked example REMOVED | LANDED | No SARS-CoV-2 reads-to-variants section exists. The only worked example is "Worked example: VSP2 FASTQ bundle workflow" (ch01 281). |
| 4 | VSP2 promoted to flagship | LANDED | ch01 74-75: "The worked example builds the VSP2 FASTQ processing chain, which is the one Workflow Builder graph the native Swift runner executes end to end." ch01 283: "This is the one graph the native runner executes end to end." |
| 5 | Beep, not red flash | LANDED | ch01 110: "Lungfish plays the system alert sound and the connection is dropped." Matches `NSSound.beep()` at `WorkflowCanvasView.swift:1036`. No red flash anywhere. |
| 6 | No "More inputs drawer" | LANDED | ch01 115-116: "Ports are fixed per node type and always visible. There is no collapsing drawer of optional inputs." Grep for drawer/chevron/moreInputs/secondary still returns nothing in source. |
| 7 | "Workflow Builder (Experimental)…" menu name | LANDED | ch01 frontmatter line 11, body 81, 282 all use "Tools > Workflow Builder (Experimental)…". Matches `MainMenu.swift:739` (`"Workflow Builder (Experimental)\u{2026}"`). ch01 50-51 even explains the qualifier. |
| 8 | ch02 SIX export targets incl. Python Script + Full Provenance (JSON) | LANDED | ch02 39: "Six targets are available." Table (42-49) lists all six including "Python Script" and "Full Provenance (JSON)". Matches `ProvenanceExportFormat` six cases (`ProvenanceExporter.swift` 11-17) and `ProvenanceExportMenuModel` (`MainMenu.swift` 1035, 1059). |
| 9 | nextflow.config: docker.enabled only, no profiles | LANDED | ch02 92-97 quotes exactly `process { errorStrategy = 'terminate' }` then `docker.enabled = true`. ch02 99: "There are no `standard` or `slurm` profiles, so do not pass `-profile`." Matches `exportNextflowConfig` (793-803). |
| 10 | params.\<sanitized-filename\> per input | LANDED | ch02 199-203 shows `params.srr12345678_1_fastq_gz = ...` plus `params.outdir = './results'`, and 196-197 explains "names are derived from the input filenames (each dot becomes an underscore and the name is sanitized)." Matches `exportNextflow` 1016-1019. |
| 11 | Flat Snakefile + config.yaml with singularity | LANDED | ch02 230-236: "a single `Snakefile` plus a `config.yaml` in the export root, with no `workflow/` directory and no per-rule conda environment files ... `singularity:` directives that reference `docker://<image>` ... `snakemake --cores 8 --use-singularity`." Matches `exportSnakemake` (1108 usage line, 1110 configfile, 1150-1151 singularity). The `workflow/envs/` conda claim is gone. |
| 12 | Export from provenance, not the Builder graph | LANDED | ch02 33-36: "built from the provenance records the app already keeps for every operation you ran, not from a Workflow Builder graph ... you do not need to have built a workflow in the Builder to export." Confirmed: `ProvenanceExporter.exportBundle` consumes `ProvenanceRunBuilder` / `WorkflowRun`, never `WorkflowGraph`/`WorkflowNode` (grep returns no graph types). |
| 13 | Builder honestly scoped to FASTQ preprocessing | LANDED | ch01 49-62 is a dedicated scope paragraph: "the only operations the native runner executes today are the five FASTQ-preprocessing steps." ch01 205: "The Builder today is scoped to FASTQ preprocessing." frontmatter `task` line 7 also says "Compose a FASTQ-preprocessing workflow". |

### Coverage gaps from Round 1 (G-series) now also addressed

| Round-1 gap | Status | Note |
|---|---|---|
| G1 fastp fusion | LANDED | ch01 320-325 documents the fusion explicitly: "Adjacent fastp-backed steps ... are fused into a single fastp invocation for provenance accounting. The run record will therefore show fewer fastp invocations than nodes." Matches `isFusibleFastpBuilderStep` (Runner 411-431). |
| G2 VSP2 template generator | LANDED | ch01 307-310: "Lungfish ships a built-in VSP2 template that generates the same chain programmatically ... with stable node identifiers." Matches `VSP2WorkflowTemplate.makeGraph` (25). |
| G3 atomic staging | LANDED | ch01 336-342 names the hidden staging bundle, the rename-into-place, and the cleanup-on-failure. Matches Runner 98/130/132-133, staging name pattern at 213. |
| G4 Python + Full Provenance targets | LANDED | ch02 table + 244, 252-254 describe both. |
| G5 signing + transitive chain | LANDED | ch02 261-272 ("Interpretation: signing and the transitive provenance chain") covers `signReportArtifacts` (`.signature.json` + `.pub`, self-verify) and `expandProvenanceChain` copying into `provenance/source/...`. Both verified (Exporter 253-268, 280-345, 621). |
| G6 not-runnable provenance argv | LANDED | ch01 273-278 warns that argv beginning `workflow builder-run --graph-id …` or `workflow builder-step run …` are "audit records, not user-invocable commands." Matches the compiler argv at 181-188 and 301-305, which are not registered subcommands. |
| C8 softened exact-versions claim | LANDED | ch02 126-130: "some derived steps are reconstructed rather than recorded. In particular, a reference acquisition that was never captured as its own operation is synthesized into the export with a tool version of `unknown`." Matches `synthesizedReferenceProvenanceEnvelope` stamping `toolVersion: "unknown"` (440, 466, 481). |

### Did the rewrites re-introduce any fabrication? Newly found defects

| Severity | Location | Defect |
|---|---|---|
| MUST-FIX (fidelity) | ch01 110-113 | The type-compatibility mechanism is misdescribed. The chapter: "The compatibility check is the same set of viewport interface classes that organises the rest of the app: Sequence, Taxonomy, Alignment, Assembly, and Variant." The real `PortDataType.isCompatible(with:)` (`WorkflowNode.swift` 501-512) does NOT reference any viewport interface class. It is a structural check on `PortDataType` cases: returns true if either side is `.any`, allows `referenceBundle ↔ assemblyBundle` cross-compatibility, otherwise requires exact equality. There is no Sequence/Taxonomy/Variant interface-class machinery behind it. This is a carried-over embellishment from the Round-1 ground-truth aside (the reviewer's framing, not a code fact) and should be replaced with the real rule. |
| SHOULD-FIX (accuracy) | ch01 109 | Port-type example names are not literal. "A `FASTQ` output port can only connect to a `FASTQ` input port, a `FASTA` to a `FASTA`". The real data types are `fastqBundle` and `referenceBundle`; there is no `FASTA` port type (a FASTA Input node emits a `referenceBundle`, `WorkflowNode.swift:200`). Acceptable as illustrative shorthand, but a reader who inspects a port tooltip will see different names. Either soften to "a reads port only connects to a reads port" or use the real type labels. |
| SHOULD-FIX (clarity) | ch01 84-88, 246-251 | The "legacy pinned Sample input / Project output anchors" plus the explicit FASTQ Bundle Input node coexist in the prose, and a first-timer may not grasp which path the VSP2 example uses. The text is accurate (both paths are real: the run-binding sheet exists for the legacy anchor, `WorkflowBuilderRunService`), but the dual model is introduced before the reader has a graph, which adds load. Consider deferring the legacy-anchor discussion to a single note. |

Everything else in both chapters is faithful. No invented categories, node types,
config blocks, params, file layouts, menu paths, or CLI flags were
re-introduced. The CLI command (ch01 267-273) `lungfish-cli workflow builder-run
--workflow … --project … --run-directory …` with the stated real flags
`--workflow / --project / --run-directory / --threads / --dry-run` matches
`WorkflowBuilderRunSubcommand` (`WorkflowCommand.swift` 40-53) exactly. The
provenance filename `.lungfish-provenance.json` (ch01 279, 338) matches
`ProvenanceRecorder.provenanceFilename` (189). The output path "under the run's
`outputs/` folder" (ch01 318) matches Runner 194-197. The diff CLI (ch01
233-242) matches the live `--help` (values text, json, tsv).

---

## PART 2: Three persona re-reads

### Persona A: Dana Okonkwo, analyst building her first workflow

Dana is the novice who, in Round 1, burned a minute convinced she had an old
build because the palette categories on screen did not match the manual. She
re-reads the rewritten ch01 before touching the app.

**The two facts that broke her trust last round now hold.** "I opened Tools and
the item said Workflow Builder (Experimental), and the chapter told me to expect
exactly that: Choose Tools > Workflow Builder (Experimental)… (line 81). The
chapter even explained why the word is there: the menu item is labelled Workflow
Builder (Experimental) for a reason (line 50). Then I opened the palette and the
seven headers on screen, Input, Preprocessing, Trimming & Filtering,
Decontamination, Read Processing, Analysis, Output, are the exact seven the
chapter promised at line 92. Last round not one of the seven names matched. This
round all seven did. That is the difference between trusting the manual and
not."

**The node table is now honest, and the runnable/export-only split is the part
she needed.** "The table at lines 181 to 199 has a Runnable natively column.
That is exactly the thing I could not tell last round: which nodes actually do
something inside the app. Now I can see the five FASTQ ops marked yes and the
Analysis nodes marked export-only. And the prose backs it up: the only
operations the native runner executes today are the five FASTQ-preprocessing
steps listed below (lines 52 to 53). I am not going to drag an Alignment node
expecting it to run."

**The VSP2 example ran, and the template note saved her the drag.** "I followed
the worked example at lines 281 to 318. FASTQ Bundle Input, pick my bundle,
stored as @/Imports/<sample>.lungfishfastq (line 290), then dedup, trim, scrub,
merge, length-filter in a straight line, save as vsp2-fastq, Run. It compiled to
a native FASTQ plan and wrote a derived bundle, exactly as written. And the note
at lines 307 to 310 told me I did not have to drag all five by hand, there is a
built-in VSP2 template. Next time I will use the template."

**One thing still trips her.** "Line 110 says the connection check is the same
set of viewport interface classes ... Sequence, Taxonomy, Alignment, Assembly,
and Variant. I have no idea what a viewport interface class is at this point in
the manual, and I do not need to. When I wired a wrong port, my Mac just beeped
(line 110 also says that, correctly). The interface-class sentence added a
concept I could not act on and that, per the source, is not even how the check
works. Cut it. Tell me reads connect to reads and the rest beeps."

**Accessibility.** "Still three planned-shot comments, no rendered images
(`<!-- planned: workflow-builder-palette -->` etc., lines 90, 156). The palette
shot is the one that would have prevented my entire Round-1 confusion, and the
caption already promises the seven real headers (frontmatter line 17). Capture
it. No image means no alt text yet."

**Net.** "The two most visible facts, the menu name and the palette, are now
correct, the node table tells me what runs, and the one real worked example is
the one the chapter centers on. This is a chapter I can hand a new hire. Drop the
viewport-interface-class sentence and render the palette shot."

### Persona B: Theo Marchetti, pipeline engineer doing the Nextflow export

Theo runs a SLURM cluster. In Round 1 his export failed: the chapter promised a
`slurm` profile and semantic `params.reads_r1` that the generated files did not
contain. He re-reads ch02 and regenerates an export.

**The two breaks that stopped him cold are fixed.** "The config section now
quotes what actually comes out: process { errorStrategy = 'terminate' } then
docker.enabled = true (lines 92 to 97), and then says it plainly: There are no
standard or slurm profiles, so do not pass -profile (line 99). That is the
correction I needed. Last round I would have told my team we could submit to
SLURM out of the box. This round the chapter tells me the truth: To target a
specific scheduler you edit nextflow.config yourself and add an executor or a
profile block (lines 99 to 100). Annoying, but honest, and it matches the file."

**The params block now matches the file.** "The swap-inputs section (lines 192
to 217) shows params.srr12345678_1_fastq_gz, derived from the input filename,
and explicitly warns the names are derived from the input filenames ... not from
semantic roles (lines 196 to 197). The override example uses the real mangled
names (lines 208 to 212), and line 214 tells me to Open main.nf to read the exact
parameter names before overriding them. That is exactly right. Last round the
chapter handed me parameter names that were not in the file. This round it tells
me to read the file. I generated an export and the params matched the documented
shape."

**Six targets, and the table now lists the manifest.** "File > Export >
Provenance had six items, and the chapter's table (lines 42 to 49) has all six,
including Python Script and Full Provenance (JSON). The Nextflow row correctly
lists containers/manifest.json (line 46), which last round's table omitted. I
generated the export and the manifest was there with tool/version/image/digest.
The chapter even explains the submenu separator: The submenu draws a visual
separator between the first four targets and the last two, but all six render
(lines 51 to 52). That is the exact thing that fooled the last writer, called out
correctly."

**The framing problem is gone.** "Last round the export chapter was anchored to a
reads-to-variants workflow I could not build. This round line 33 says the export
is built from the provenance records the app already keeps ... not from a
Workflow Builder graph, and line 68 to 72 re-anchors the walkthrough to any
completed run, using the VSP2 chain as the example. I confirmed in source that the
menu exporter reads provenance records, not the graph. So the walkthrough is
reproducible now: run anything, export its provenance."

**New nit, minor.** "The container escape-hatch command (lines 145 to 151) uses
`MN908947.3.lungfishref` as the bundle. That is a SARS-CoV-2 reference, a leftover
flavor from the deleted reads-to-variants example. It is a real CLI form and
ground truth confirms the flags, so it runs, but a reader following the VSP2 FASTQ
narrative has no `MN908947.3.lungfishref` in hand. Either pick a bundle the
narrative produced or label it clearly as an illustrative reference bundle."

**Net.** "The two things I touch first, the menu and the Nextflow config, are now
correct, and the run command in the chapter is plain `nextflow run main.nf` with
no fictional profile. I could submit this. The only residual is a stray SARS ref
in a CLI example that does not match the FASTQ narrative."

### Persona C: Dr. Aisha Rahman, reproducibility-focused PI

Aisha cares whether the export truly reproduces what ran, and whether the
versioning and run-record guarantees are real. She re-reads both chapters.

**The overstated guarantee is now softened correctly.** "Last round ch02 claimed
the export captures the exact tool versions and command lines that ran, not a
reconstruction, an absolute that was false for synthesized steps. This round the
chapter states the limit plainly: some derived steps are reconstructed rather than
recorded ... a reference acquisition that was never captured as its own operation
is synthesized into the export with a tool version of unknown (lines 126 to 129),
and then the actionable instruction: If you are citing exact versions in a methods
section, check that the steps you are citing carry a real version string and not
unknown (lines 129 to 131). That is precisely the caveat I would add myself. I
verified in source that synthesizedReferenceProvenanceEnvelope stamps unknown. The
claim now matches the code."

**Signing and the transitive chain are surfaced, which is what I most wanted.**
"Last round these two were absent. This round there is a dedicated subsection,
Interpretation: signing and the transitive provenance chain (lines 261 to 272):
when a signer is configured, Lungfish cryptographically signs each generated
export artifact, writing a .signature.json and a .pub next to it, and verifies the
signature locally, and the provenance/ folder ... walks input dependencies,
including enclosing .lungfishref bundles and their manifests, and copies each
discovered record into provenance/source/. Both verified in source
(signReportArtifacts self-verifies, expandProvenanceChain writes provenance/source).
For an auditor this is the strongest part of the chapter and it is finally
documented."

**The atomic-staging durability property is now explicit.** "ch01 336 to 342:
The runner writes the derived bundle and its .lungfish-provenance.json into a
hidden staging bundle first, then renames the staging bundle into place only after
provenance has been written. On any error it deletes both the staging bundle and
the target. An interrupted run therefore cannot leave a final-looking
.lungfishfastq bundle without reproducibility metadata. That last sentence is the
exact durability guarantee I audit for, and last round it was understated to one
clause. Verified against the runner's staging/move/cleanup logic. Keep this
verbatim."

**The canonical example my student would run now actually runs.** "Both chapters
are organized around the VSP2 FASTQ chain, which is buildable and produces the
run.json and provenance.json I teach students to read (ch01 346 to 350). Last
round the canonical example was the unbuildable reads-to-variants pipeline. This
is the single most important fix for a teaching context: the lesson works."

**The per-node status vocabulary is now stated as text.** "ch01 259 to 262:
Per-node status is one of running, succeeded, failed, or skipped, written as text
in the record (the Operation Center shows the same words, not a colour cue alone).
That is exactly the accessibility fix I asked for. A low-vision student hears the
status word, not an inferred color, which also matches the STYLE rule against
encoding severity by color."

**Residual concern, minor.** "ch01 110 to 113 still invokes viewport interface
classes for the port check, which a reproducibility reader does not need and which
is not the real mechanism. It does not harm an audit, but it is an inaccuracy in a
chapter that is otherwise scrupulous. Fix it for consistency with the chapter's own
standard."

**Net.** "The provenance-as-executable thesis, the semver versioning, the diff,
the run records, the atomic staging, the softened exact-versions claim, and the
signing/transitive-chain subsection are all real and now all documented. This is
the audit surface I want. One stray inaccurate sentence (the interface classes)
and one stray SARS ref in a CLI example are the only blemishes."

---

## Round 2 fixes for editors

Prioritized. Must-fix items are fidelity defects where the text disagrees with the
shipped code. Should-fix items are clarity or consistency improvements.

### Must-fix (fidelity)

1. **ch01 110-113: replace the "viewport interface classes" port-check
   description with the real rule.** The compatibility check is not the
   Sequence/Taxonomy/Alignment/Assembly/Variant interface-class set. The real
   `PortDataType.isCompatible(with:)` (`WorkflowNode.swift` 501-512) returns true
   when either side is `any`, additionally allows a reference bundle to connect to
   an assembly bundle (and vice versa), and otherwise requires the two port data
   types to be identical. Suggested replacement: "Each port carries a data type.
   A port connects only to another port of the same data type, with one
   exception: a reference output may feed an assembly input and vice versa. A
   port typed `any` (such as the Project output input) accepts anything. If you
   attempt an incompatible edge, Lungfish plays the system alert sound and the
   connection is dropped." Delete the interface-class sentence entirely.

2. **ch01 109: stop naming `FASTA` as a port type.** There is no `FASTA` port
   type. A FASTA Input node emits a `referenceBundle`. Either soften to reads/
   reference/alignments language or use the real type labels. This is the only
   place a reader inspecting a port would see a name the chapter does not predict.

### Should-fix (clarity, consistency, accessibility)

3. **ch02 145-151: replace or relabel the `MN908947.3.lungfishref` container
   example.** It is a leftover SARS-CoV-2 reference from the deleted reads-to-
   variants example and does not match the VSP2 FASTQ narrative the chapters now
   center on. The CLI form and flags are real (verified against
   `BundleCommand.swift`), so the fix is cosmetic: use a bundle the narrative
   actually produced, or add one clause noting it is an illustrative reference
   bundle, not an artifact of the VSP2 walkthrough.

4. **ch01 84-88 and 246-251: tighten the legacy-anchor vs explicit-input
   exposition.** Both the pinned Sample input / Project output anchors and the
   explicit FASTQ Bundle Input node are real and the prose is accurate, but
   introducing the dual model before the reader has built anything adds load for
   the novice. Consider one consolidated note: "Native FASTQ graphs use an
   explicit FASTQ Bundle Input node; the pinned Sample input anchor is a legacy
   path that prompts for a sample at run time." Then the VSP2 example only needs
   the explicit node.

5. **Render the three planned shots and supply alt text (Round-3 screenshot
   pass).** ch01 carries `workflow-builder-canvas`, `workflow-builder-palette`,
   `workflow-builder-node-inspector` as `<!-- planned -->` comments (lines 13-19,
   90, 156); ch02 carries `export-provenance-submenu` and `nextflow-export-main-nf`
   (lines 14-18, 74, 84). The palette shot is the highest value: its frontmatter
   caption already commits to the seven real headers (ch01 17), which guards
   against the category names drifting back to the invented set. The submenu shot
   should show six items so the image cannot reintroduce the "four" error. Each
   needs descriptive alt text when captured.

6. **Style and caps: clean.** Both chapters are em-dash-free (verified: 0
   occurrences each) and carry no banned hype words. Lists stay within the 5/2 cap
   (the VSP2 five-step chain at ch01 294-298 is a genuine parallel five-item
   enumeration and is fine as a list). The two large tables (node types ch01
   181-199; export targets ch02 42-49) are correctly tables, not bullet runs. No
   action needed.

### What to keep (verified faithful, do not touch)

- The "What it is" / provenance-as-executable framing (ch01 28-66), including
  "Instead of 'here is what I did', the workflow file says 'here is how to do it
  again'" (43-44) and the SOP line (45-47).
- The scope paragraph (ch01 49-62): import paths (NAO-MGS, NVD, CZ-ID) and
  result-viewport tools deliberately excluded. Accurate.
- The VSP2 worked example (ch01 281-325) as the single flagship, including the
  fusion note (320-325) and the template note (307-310).
- The versioning + diff machinery (ch01 221-242) and the run-record guarantees
  (ch01 244-279), including the atomic-staging durability paragraph (336-342) and
  the explicit running/succeeded/failed/skipped status vocabulary (259-262).
- All of ch02's corrected surface: six targets, the real `nextflow.config`, the
  `params.<sanitized-filename>` block, the flat Snakemake layout with singularity,
  the provenance-not-graph framing, the softened exact-versions caveat, and the
  signing + transitive-chain subsection (261-272).

---

## Bottom line

The Round-1 rewrite was a success. Every one of the 13 critical fidelity fixes
plus all six coverage gaps and the softened-guarantee fix landed and verify
against the shipped code. The chapters now describe only what exists, center on
the one runnable graph (VSP2 FASTQ), and frame export honestly as
provenance-driven. The single remaining must-fix is one inaccurate sentence in
ch01 (the "viewport interface classes" port-check description), plus a `FASTA`
port-type naming nit. Two cosmetic should-fixes (a stray SARS reference in a ch02
CLI example, and tightening the legacy-anchor exposition) and the deferred
screenshot pass complete the list. None of these block a reader from succeeding;
the chapters are now accurate and actionable.
