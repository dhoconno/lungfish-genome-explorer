# Appendices focus group synthesis (Round 1)

Round 1 focus-group review + synthesis. Personas cross-checked against the ground-truth reality map.

Standard note: this is a Round-1 simulated-reader focus group plus revision plan for the nine Reference/Appendices chapters, graded against the arbiter-of-truth reality map in `../ground-truth/appendices.md`. Personas quote chapter lines and react to fidelity breaks and accessibility gaps. The synthesis converts those reactions into a prioritized revision plan. No chapters were edited. No em dashes, per `docs/user-manual/STYLE.md`.

**Section under review:** `docs/user-manual/chapters/appendices/`: `cli-reference.md` (highest priority), `file-formats.md`, `keyboard-shortcuts.md`, `primer-schemes.md`, `tool-versions.md`, `06-running-in-ci.md`, `power-user-notes.md`, `shared-projects.md`, `troubleshooting.md`.

**Headline findings:** `cli-reference.md` is the worst-drifted chapter in the manual. Eight documented invocations do not exist or are misnamed, six more carry flags the binary rejects, and 14 real top-level commands (`analyze`, `translate`, `sequence`, `universal-search`, `align`, `orient`, `gatk`, `freyja`, `nvd`, `cz-id`, `metadata`, `haplotypes`, `build-db`, `genotype`) are absent from every appendix. `file-formats.md` invents two bundle formats (`.lungfishvcf`, and `.lungfishtax` mischaracterized as the universal classifier bundle) and omits four real ones. `tool-versions.md` contradicts its own "same as `version --tools`" promise: it lists three tools not in the lock and omits two the command prints. `keyboard-shortcuts.md` has one hard error (Sidebar is Cmd-Ctrl-S, not Cmd-Shift-S). `primer-schemes.md` documents camelCase manifest keys that are snake_case in the shipped manifest and never states the real counts (563 primers, 223 amplicons). The CI, shared-projects, power-user, and troubleshooting chapters are mostly accurate on their command surfaces, with a handful of copy-paste-breaking flag errors and many unverified error strings flagged for a second pass.

---

## PART 1: Reader focus group

Four power-leaning readers, each opening the appendices for a different real task. Quotations are verbatim from the chapters. Reactions are written in persona voice.

### Persona 1: Tomás Reyes, pipeline engineer scripting the CLI (power-user, copy-pastes commands that then fail)

Tomás is wiring Lungfish into a Snakemake pipeline on a headless lab server. He has the GUI open on his laptop and `cli-reference.md` open in a second tab, and he copies commands straight out of it into rules. He expects every documented invocation to match `lungfish <cmd> --help`.

**What worked.** "The framing in the opener is exactly right for me: Every GUI dialog records the equivalent CLI invocation in its provenance sidecar, so a workflow built clickwise can be reproduced in a terminal without rewriting any logic (cli-reference.md:22). That is the whole reason I am here. The global flags table (cli-reference.md:424 to 434) is clean, and ground truth confirms it matches the real binary. The `map` read-group section (cli-reference.md:149) with all the `--rg-*` flags is genuinely well done, and ground truth spot-verified it. The `variants call --caller {ivar,lofreq,medaka,bcftools}` table (cli-reference.md:181 to 192) is the single best entry in the chapter and it is correct."

**First break, and it is the headline feature: `classify` does not exist.** "The Classification section leads with `lungfish classify --tool kraken2 --database <name> --reads <fastq...>` (cli-reference.md:217). I pasted it. `lungfish classify --help` falls straight through to root help. There is no `classify` command. Ground truth: the real command is `lungfish conda classify <fastq...> --db <db>` (appendices.md cli-reference fact 1). The flag shape is different too: it is `--db`, not `--database`, and the FASTQ is positional, not behind `--reads`. The most obvious command a new scripter would reach for, classify a sample, is wrong in both name and every flag."

**It is not one command. It is eight.** "Once the first one failed I tested the rest of the section against `--help`, and it is a graveyard. `lungfish esviritu run --reads <fastq...>` (cli-reference.md:221): no such subcommand, it is `esviritu detect` with `-i/--input` and `-s/--sample`. `lungfish taxtriage run --reads <fastq...> [--profile clinical]` (cli-reference.md:225): `taxtriage run` exists but `--reads` and `--profile` do not, the real flags are `--input`/`--input2`/`--sample` plus `--platform`/`--db`/`--confidence`. `lungfish nao-mgs import --run-dir <path>` (cli-reference.md:229): no such subcommand and no `--run-dir`, the real one is `nao-mgs summary <input-path>`. `lungfish blast <sequence> [--database nt]` (cli-reference.md:233): blast is not free-form, it is `blast verify` with required `--kreport`, `--source`, `--kraken-output`, `--taxid`. Ground truth lists every one of these as nonexistent or misnamed (appendices.md cli-reference, Documented but nonexistent commands, items 1, 6, 7, and Documented flags, items 4, 5). I cannot trust a single line of the Classification section."

**More misnamed commands outside Classification.** "`lungfish extract-contigs --assembly ...` (cli-reference.md:261) is `extract contigs` (a subcommand of `extract`, alongside `sequence` and `reads`). `lungfish extract-annotations --bundle ...` (cli-reference.md:141) is `bundle extract-annotations`. `lungfish bam annotations` (cli-reference.md:169) returns `Error: Unexpected argument 'annotations'`, the real subcommand is the singular `bam annotate` and it needs `--alignment-track` and `--output-track-name`. `lungfish import application <path>` (cli-reference.md:102) is `import application-export <kind> <source-path> --project`. `lungfish msa <command>` lists `add` and `edit` as subcommands (cli-reference.md:408 to 410); those do not exist at that level, the real `msa` subcommands are `actions`/`describe`/`annotate`/`export`/`consensus`/`extract`/`mask`/`trim`/`distance`, and `add`/`edit` live one level deeper under `msa annotate`. That is the full set of eight from ground truth."

**Wrong flags on commands that do exist.** "Two utility commands I use constantly take `--in`/`--out` in the docs and reject them in the binary. `lungfish convert --in <path> --out <path>` (cli-reference.md:400) is actually `lungfish convert <input> --to <to>` with positional input. `lungfish markdup --in <path> --out <path>` (cli-reference.md:173) is `lungfish markdup <path>`, a single positional, with `--force`/`--sort-threads`/`--deduplicated-bundle`. Ground truth confirms both (appendices.md cli-reference, Documented flags, items 1 and 2). And `lungfish conda install --pack <name>...` (cli-reference.md:332) is misleading because `--pack` is a boolean toggle, the pack names are positional: `conda install --pack <packages...>`."

**The absences are as bad as the errors.** "I grepped the whole chapter for the commands I needed and they are not there. `lungfish align`, `lungfish orient` (the top-level one, not `fastq orient`), `lungfish gatk` (ground truth says it has ten subcommands), `lungfish freyja demix`, `lungfish nvd`, `lungfish cz-id`, `lungfish metadata`, `lungfish haplotypes` (ten subcommands), `lungfish build-db`, `lungfish genotype` (seven subcommands), `lungfish analyze`, `lungfish translate`, `lungfish sequence`, `lungfish universal-search`. Ground truth lists all 14 as absent from every appendix (appendices.md cli-reference, Real top-level commands MISSING). The chapter says it groups commands by domain, and that grouping is exactly what hides the fact that a third of the real command tree is missing. The binary has 43 top-level commands. This chapter documents a curated, partly-fictional subset and presents it as the reference."

**Accessibility / structure.** "As a reference document the domain grouping fights me. When a command fails I cannot quickly tell whether it was renamed, moved under a parent, or never existed, because there is no flat command index and no mapping to the real tree. A screen-reader user navigating by heading gets domain headings (Classification, Assembly) that do not correspond to anything in `--help`, so they cannot jump to `conda classify` or `extract contigs` by structure. The single biggest usability win would be a flat, alphabetized command list that matches the binary."

**Net.** "This is the chapter I came to the manual for and it is the one I trust least. Eight commands that do not exist, six with rejected flags, and 14 real commands missing. I would tell my team to ignore the CLI reference and run `lungfish <cmd> --help` for everything until it is rewritten against the binary."

### Persona 2: Aiko Tanaka, lab data manager checking file formats and shared projects (analyst)

Aiko owns the lab's shared NFS share and the project-archiving policy. She reads `file-formats.md` to know what each bundle contains before she writes a retention rule, and `shared-projects.md` to set up multi-user coordination. She does not script much; she needs the on-disk reality to be accurate.

**What worked.** "The standard-formats half of `file-formats.md` is excellent and I trust it. The coordinate-convention note, BED is 0-based half-open by spec; GFF3 and VCF are 1-based inclusive ... presents 1-based inclusive coordinates to the user in every UI surface (file-formats.md:67), is the kind of precise statement I want in a reference. The bundle-as-folder model, Finder presents a bundle as a single document; the contents are inspectable from the terminal as ordinary files (file-formats.md:123), is exactly how I explain it to new hires. And the inspect-without-unpacking blocks (file-formats.md:178 to 184) are genuinely useful."

**First break: a bundle format that does not exist on disk.** "I was about to write a retention rule keyed on `.lungfishvcf` bundles, because the chapter gives it a full section: `.lungfishvcf: variant track bundle` with `variants.vcf.gz`/`variants.vcf.gz.tbi`/`consensus.fasta` (file-formats.md:255 to 268), lists it in the bundle table (file-formats.md:133), and even uses it in the terminal-inspection example (`bcftools view variants.lungfishvcf/variants.vcf.gz`, file-formats.md:341). Ground truth: there is no `.lungfishvcf` bundle reader or writer anywhere in LungfishIO, the only occurrence of the string is a workflow-package enum case, and the chapter's own `.lungfishref` layout already stores variants in the reference bundle's `variants/` subdirectory (appendices.md file-formats, item 2). So the variant bundle I was going to archive separately does not exist; variants live inside the reference bundle. A retention rule built on the docs would have matched nothing."

**Second break: the taxonomy bundle is mischaracterized.** "The chapter says `.lungfishtax` stores classifier output (Kraken2, EsViritu, TaxTriage, NAO-MGS) in a normalized form (file-formats.md:209) with a `classifications.tsv`/`abundance.tsv`/`tree.json`/`raw/` layout. Ground truth: `.lungfishtax` is produced only by the CZ-ID import path, and Kraken2/EsViritu/TaxTriage/NAO-MGS results are not stored as `.lungfishtax` bundles at all (appendices.md file-formats, item 1). The claimed multi-classifier scope and the entire file layout are not grounded in source. As the person who decides what to back up, being told four tools write a bundle that only one tool writes is a real problem."

**Third break: four real formats are missing from my reference.** "Ground truth lists the real LungfishIO bundle set, and four of them are nowhere in this chapter: `.lungfishfastq` (FASTQ read bundles, which the chapter itself calls central to import and 12S workflows), `.lungfish12sref` and `.lungfishmhcref` (amplicon reference bundles), and `.lungfishhaplotypedef` (ONT genotyping haplotype definitions) (appendices.md file-formats, item 3 and App features missing). My share is full of `.lungfishfastq` bundles and the format reference does not mention the format. That is the most-used read container in the app and it is invisible here, while two invented formats get full sections."

**Shared-projects, by contrast, held up.** "`shared-projects.md` is the chapter I expected to be shakiest and it was the most solid. `lungfish project lock`, `unlock`, and `migrate` are real (ground truth: shared-projects, Claims that do not match code: None found). The stale-lock rules (shared-projects.md:62 to 64) and the lock-is-a-coordination-record-not-an-OS-lease framing (shared-projects.md:60) are careful and correct. The note that the source-build binary is `lungfish-cli` and the app ships it at `Lungfish.app/Contents/MacOS/lungfish-cli` (shared-projects.md:30) is exactly the kind of detail `cli-reference.md` should have borrowed and did not. The one caution is that the lock-record JSON pins `0.5.0-alpha6` (shared-projects.md:44) while the build is alpha11, and ground truth flags the exact key set as unverified (shared-projects, needs-human-check 1), so I would confirm `schemaVersion` and the field names before parsing the lock file programmatically."

**A cross-chapter version smell.** "The provenance JSON in `file-formats.md` shows `"version": "0.5.0-alpha6"` (file-formats.md:294), `power-user-notes.md` shows the same plus `"schema_version": 2` (power-user-notes.md:130 to 134), and `shared-projects.md`'s lock record is also alpha6. The build is alpha11. Ground truth flags the version drift and notes file-formats.md shows no `schema_version` while power-user-notes.md does (appendices.md file-formats, needs-human-check 1). For someone diffing real sidecars against the docs, the example version and the schema-version presence need to be consistent and current."

**Accessibility.** "The bundle table (file-formats.md:125 to 133) is the load-bearing summary of the whole chapter, and two of its seven rows are fictional while four real formats are missing, so a reader scanning only the table gets a materially wrong picture. The terminal blocks are good for sighted users but a screen-reader user relying on the table as the index is led to formats that do not exist."

**Net.** "The standard-formats material is reference-grade. The Lungfish-bundle material has two invented formats with full sections, one real format mischaracterized, and four real formats missing, which makes the bundle table unsafe to act on. `shared-projects.md` is the model the rest of the appendices should follow: scoped, verified, honest about the binary name."

### Persona 3: Devin Cole, CI engineer following running-in-ci (power-user)

Devin is standing up a GitHub Actions job that runs a Lungfish workflow on every PR. He follows `06-running-in-ci.md` step by step and cross-checks the conda commands against `power-user-notes.md` and `troubleshooting.md` when something stalls.

**What worked, and it mostly all worked.** "This is the chapter that did not waste my afternoon. Ground truth found no command errors in it (appendices.md running-in-ci, Claims that do not match code: None found). `lungfish run-headless <workflow>` is real and is correctly described as a discoverable alias for `lungfish workflow run --quiet <workflow>` (06-running-in-ci.md:23). The offline-pack pattern is the right CI shape: `lungfish conda offline-export --pack <pack> --output <dir>` (06-running-in-ci.md:34) to build the pack on a networked machine, then `lungfish conda offline-install <pack-directory> --conda-root` (06-running-in-ci.md:43) inside the runner. Ground truth confirms both signatures and the `--conda-root` flag plus `LUNGFISH_CONDA_ROOT` usage all match the real `offline-install` (running-in-ci, Claims that do not match code). The cache-packs-not-live-roots advice (06-running-in-ci.md:27) and the explicit warning not to cache a mutable conda root across jobs (06-running-in-ci.md:137) are exactly the failure mode I would have hit otherwise. The full GitHub Actions and CircleCI YAML both ran."

**The one place I could not verify the docs: the error strings.** "When my first install collided with another step, I expected the chapter's `waiting for conda lock held by pid <n>` message (06-running-in-ci.md:49) and the read-only-root message `conda root is read-only; reinstall as the admin user` (06-running-in-ci.md:49). Ground truth could not locate either string in source this pass and flags them as needs-human-check, along with the `<conda-root>/.install.lock` path (06-running-in-ci.md:48) (appendices.md running-in-ci, Uncertain 1 and 2). My job did block as described, so the behavior is right, but if I write a CI assertion that greps stderr for that exact lock-wait string and the real wording differs, my pipeline gets a brittle false failure. I need the exact strings confirmed before I match on them."

**Cross-check into the conda commands held.** "I leaned on `power-user-notes.md` for the lockfile path and it matched: `lungfish conda lock --pack <name> --output lockfile.yml` then `lungfish conda install --from-lockfile lockfile.yml` (power-user-notes.md:224 to 230), both confirmed by ground truth (power-user-notes, App features missing: the `conda lock`/`install --from-lockfile` references match the real flags). The `lungfish ops stats /path` summary command (power-user-notes.md:201) is real and the description (recursively scans `.lungfish-provenance.json`, ignores failed/cancelled, reports peak RAM) matches the `OpsCommand` abstract per ground truth. For a CI engineer who wants a cost summary as a build step, that is a useful, accurate pointer."

**A snag when I reached for the CI tool table.** "I went to `tool-versions.md` to pin a Nextflow version in my runner image and hit the same problem the next persona will: the chapter says The same table is available from `lungfish version --tools` (tool-versions.md:27), but ground truth says the documented table does not match the command output (appendices.md tool-versions, item 1). Nextflow 25.10.4 (tool-versions.md:47) looks plausible, but if the table is wrong about which tools exist (it lists Clair3/WhatsHap/Freyja, which are not in the lock), I cannot trust it as the pin source. For CI I will read `version --tools` at build time instead of trusting the doc, which is the opposite of what a reference chapter should make me do."

**Accessibility.** "The chapter is well structured for assistive tech: short H2s, real fenced YAML, no color-coding. The only gap is the unverified inline error strings doubling as the troubleshooting cue. If the reader cannot rely on the quoted message matching what their terminal prints, the prose loses its diagnostic value for everyone, sighted or not."

**Net.** "The best chapter in the section for my task. Every command I ran worked and the CI patterns are sound. The only debt is a set of quoted lock/read-only error strings that ground truth could not confirm, which matters specifically because CI scripts grep for exact strings. Confirm the wording and this chapter is done."

### Persona 4: Dr. Hannah Brandt, clinical validation lead checking tool versions and primer schemes (power-user)

Hannah validates Lungfish for a CLIA-adjacent surveillance assay. She reads `tool-versions.md` and `primer-schemes.md` against the actual binary because a validation document has to match what the software does, exactly, or the validation is void. She also reads `power-user-notes.md` for the tool flags she has to cite in a methods section.

**What worked.** "`primer-schemes.md` gets the concept and the workflow right. The bundle-travels-together rationale, so the coordinates, reference accession, display name, and provenance travel together (primer-schemes.md:26), is exactly why I want bundles over loose BED files in a validated pipeline. The BED-expectations section (primer-schemes.md:60 to 68), including the warning that a scheme built against one reference and applied to a BAM mapped against a different coordinate system can trim zero primers without producing an obvious visual error (primer-schemes.md:68), is a real validation hazard stated clearly. Ground truth confirms the CLI flag set is fully accurate (appendices.md primer-schemes, Uncertain 1: the CLI flag set is accurate ... No change). And `tool-versions.md`'s provenance rule, If the two disagree, cite the sidecar for the analysis (tool-versions.md:75), is precisely the right discipline."

**First break: the manifest field names are wrong, and I document field names.** "My validation references the manifest schema by exact key. The chapter's field table lists `displayName`, `referenceAccessions`, `primerCount`, `ampliconCount`, `created`, `imported`, `attachments` (primer-schemes.md:49 to 57). Ground truth: the shipped manifest uses snake_case: `display_name`, `reference_accessions`, `primer_count`, `amplicon_count`, `source`, `source_url`, `version`, `created`. There is no `imported` field and no `attachments` field in the shipped manifest, and `schema_version`/`description`/`organism`/`source_url` are present and undocumented (appendices.md primer-schemes, item 1). So every key I would cite is in the wrong case, two keys I would cite do not exist, and four real keys are missing. A validation document that references `primerCount` when the file says `primer_count` fails review on the first audit."

**Second break: the reference-accession shape is wrong.** "The chapter describes `referenceAccessions` as Canonical accession plus equivalent accessions (primer-schemes.md:52), which reads like a list of strings. Ground truth: it is an array of objects, `[{"accession": "MN908947.3", "canonical": true}, {"accession": "NC_045512.2", "equivalent": true}]` (appendices.md primer-schemes, item 2). I would have written a parser expecting strings and gotten objects."

**Third issue: the chapter never gives me the numbers I have to validate against.** "For the shipped SARS-CoV-2 scheme I need the concrete counts to confirm the bundle loaded correctly. The chapter names the scheme `QIASeqDIRECT-SARS2` (primer-schemes.md:28) and stops there. Ground truth has exactly what I need and the chapter omits it: `primer_count` = 563, `amplicon_count` = 223, `display_name` = QIAseq Direct SARS-CoV-2 with Booster A, `source` = built-in, canonical `MN908947.3` with equivalent `NC_045512.2` (appendices.md primer-schemes, App features missing). Those five numbers are the anchor of my scheme-validation step and none of them are in the reference."

**Then `tool-versions.md` failed the one thing it promises.** "This chapter exists so my methods section can cite shipped versions, and it says the table equals `lungfish version --tools` (tool-versions.md:27). It does not. Ground truth: the table lists three tools that are NOT in the managed-tool lock, Clair3 1.0.10, WhatsHap 2.3, Freyja 2.0.0 (tool-versions.md:55 to 57), and the lock has no `clair3`/`whatshap`/`freyja` environment and the command does not print them (appendices.md tool-versions, item 1). Worse for me, it omits two tools the command actually prints: `openpyxl` 3.1.5 and `pysam` 0.24.0 (appendices.md tool-versions, item 2). So if I copy this table into a validation appendix, I am asserting the assay ships Clair3 and Freyja when it does not, and I am failing to declare pysam, which is in the lock. That is a falsifiable claim in a regulated document and it is false."

**A casing and column mismatch on top.** "Ground truth notes the live table prints Fastp (the chapter says fastp) and that the live `version --tools` shows only Tool/Version/Source/Environment/Executables, with no License column, while the chapter adds License and Source-value columns and implies they come from the command (appendices.md tool-versions, item 3). It also flags the License values themselves as unverified against the lock's `license` fields (tool-versions, needs-human-check 1). For a validation lead, a License column that does not come from the cited command and is not verified is a column I have to strip out and re-derive."

**The methods-section flags I would cite are unverified.** "I copy `power-user-notes.md`'s canonical flags into methods text: samtools mpileup `-aa -A -d 600000 -B -Q 20 -q 0` (power-user-notes.md:34 to 44) and ivar `-p -q 20 -t 0.05 -m 10 -r -g` (power-user-notes.md:60 to 68), plus the LoFreq `indelqual --dindel` and `call-parallel --pp-threads 4 --no-default-filter` steps (power-user-notes.md:93 to 110). Ground truth did not trace any of these into the variant-calling pipeline source this pass and marks them needs-human-check (appendices.md power-user-notes, Uncertain 1 and 2). The prose is confident (Numbers and flag values match the current Lungfish build, power-user-notes.md:24), so I would cite them verbatim, but in a validation context I cannot cite a flag set the reviewer flagged as unconfirmed. These need a source trace before they go in a methods section."

**One more copy-paste trap I would hit in troubleshooting.** "`troubleshooting.md` tells me to recover a dropped track with `lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir>` (troubleshooting.md:78). Ground truth: the real signature requires `--name`, so that exact command fails with a missing-required-option error (appendices.md troubleshooting, item 1). The same `--in`/`--out` markdup error from the CLI reference shows up here and in power-user-notes too, so it is consistent across the section, consistently wrong."

**Accessibility.** "The tool-versions and primer-schemes tables are the entire deliverable of those chapters, and a screen-reader user reading the tool table row by row hears three tools that do not ship and never hears two that do. The style guide's no-red-amber-green rule is honored (these are plain tables), which is good, but correctness of the table content is the accessibility issue here: a non-visual reader has no way to sanity-check a wrong row against a screenshot."

**Net.** "Both of my validation-anchor chapters fail at the exact point I depend on. `primer-schemes.md` documents the manifest in the wrong case with invented and missing keys and never states the scheme's real counts. `tool-versions.md` breaks its own promise to match `version --tools`, asserting three tools that do not ship and omitting two that do. For a validation document, those are not nitpicks; they are the difference between an audit passing and failing. The concepts and the provenance discipline in both chapters are sound, which makes the factual errors more frustrating, not less."

---

## PART 2: Synthesis and revision plan

Four readers, opening the appendices for four different power tasks, converged on one structural problem: the reference chapters were written from an earlier or imagined version of the binary, and the highest-traffic reference, the CLI, has drifted furthest. The fixes below are ordered by how badly a reader is harmed by acting on the current text. Ground-truth citations are to `../ground-truth/appendices.md`.

## Critical fidelity fixes (the app does not work as written)

These cause a reader to paste a command that errors, archive a bundle that does not exist, cite a tool that does not ship, or press a key chord that does nothing. The CLI reference needs by far the biggest correction.

### C1. `cli-reference.md`: remove or rename the 8 nonexistent / misnamed commands

Ground truth, cli-reference, Documented but nonexistent commands (items 1 to 8). Each of these exact invocations fails against the binary. Correct them in place:

| Documented (wrong) | Line | Real command |
|---|---|---|
| `lungfish classify --tool kraken2 --database <name> --reads <fastq...>` | 217 | `lungfish conda classify <fastq...> --db <db>` |
| `lungfish esviritu run --reads <fastq...> [--database <path>]` | 221 | `lungfish esviritu detect -i <fastq> -s <sample>` (also `--paired`, `--no-qc`, `--db`, `--min-read-length`) |
| `lungfish nao-mgs import --run-dir <path>` | 229 | `lungfish nao-mgs summary <input-path>` (project import is `lungfish import nao-mgs`) |
| `lungfish blast <sequence> [--database nt]` | 233 | `lungfish blast verify --kreport <r> --kraken-output <k> --source <fastq> --taxid <id>` |
| `lungfish extract-contigs --assembly <path> --contig <id>...` | 261 | `lungfish extract contigs ...` |
| `lungfish extract-annotations --bundle <bundle> --track <id>` | 141 | `lungfish bundle extract-annotations ...` |
| `lungfish bam annotations --bundle <bundle> --alignment-track <id>` | 169 | `lungfish bam annotate --bundle <b> --alignment-track <t> --output-track-name <n>` |
| `lungfish import application <path>` | 102 | `lungfish import application-export <kind> <source-path> --project <project>` |
| `lungfish msa <command>` listing `add`/`edit` | 408 to 410 | real `msa` subcommands: `actions`, `describe`, `annotate`, `export`, `consensus`, `extract`, `mask`, `trim`, `distance`; `add`/`edit` are under `msa annotate` |

`taxtriage run` (item 7 / Documented flags item 4) is also in this cluster: the verb is correct but `--reads`/`--profile` do not exist (see C2).

### C2. `cli-reference.md`: fix the 6 wrong-flag signatures

Ground truth, cli-reference, Documented flags / signatures that do not match (items 1 to 6). These commands exist; the documented flags are rejected:

| Documented (wrong) | Line | Real signature |
|---|---|---|
| `lungfish convert --in <path> --out <path>` | 400 | `lungfish convert <input> --to <to>` (`--to-format` default `fasta`); no `--in`/`--out` |
| `lungfish markdup --in <path> --out <path>` | 173 | `lungfish markdup <path>` with `--force`, `--sort-threads`, `--deduplicated-bundle` |
| `lungfish import vcf <path> [--reference <bundle>]` | 98 | `lungfish import vcf <input-file> [--output-dir <dir>]`; `--reference` does not exist |
| `lungfish taxtriage run --reads <fastq...> [--profile clinical]` | 225 | `taxtriage run --input/--input2/--sample` or `--samplesheet`, plus `--platform`, `--db`, `--confidence`; no `--reads`/`--profile` |
| `lungfish blast <sequence> [--database nt]` | 233 | `lungfish blast verify` (see C1); not free-form, no `--database nt` |
| `lungfish conda install --pack <name>...` | 332 | `--pack` is a boolean toggle; pack names are positional: `conda install --pack <packages...>` |

The same `markdup --in/--out` error recurs in `troubleshooting.md` and `power-user-notes.md` (ground truth, cli-reference, Documented flags item 2). Fix all occurrences together.

### C3. `cli-reference.md`: add the 14 missing top-level commands

Ground truth, cli-reference, Real top-level commands MISSING and Section-wide finding 1. The binary has 43 top-level commands; the chapter's domain grouping hides that 14 are absent from every appendix. At minimum, name each with a one-line description (the editor can expand later):

| Command | One-line description |
|---|---|
| `analyze` | Sequence statistics (length, composition, GC). |
| `translate` | Translate DNA/RNA to protein (CLI counterpart of the `Cmd-Shift-T` GUI verb). |
| `sequence` | Annotate ORFs and delete annotations / annotation tracks on a bundle. |
| `universal-search` | Search across a whole project: `lungfish universal-search <project-path>`. |
| `align` | Create a native MSA bundle from input sequences. |
| `orient` | Top-level FASTQ orient (distinct from `fastq orient`). |
| `gatk` | GATK lane: 10 subcommands (`haplotype-caller`, `joint-genotype`, `filter`, `select`, `variants-to-table`, `bqsr`, `markdup`, `validate-sam`, `leftalign`, `collect-metrics`). |
| `freyja` | Wastewater lineage demixing: `freyja demix`. |
| `nvd` | Novel Virus Diagnostics result import/view. |
| `cz-id` | CZ-ID result import/view. |
| `metadata` | Attach FASTA/FASTQ sample metadata. |
| `haplotypes` | ONT genotyping haplotype definitions: 10 subcommands. |
| `build-db` | Build TaxTriage / EsViritu / Kraken2 SQLite databases. |
| `genotype` | MHC genotyping: 7 subcommands (`list-samples`, `list-cohorts`, `apply-annotations`, `export`, `export-xlsx`, `export-pivot-xlsx`, `export-labkey`). |

The strongest structural fix is to reorganize the chapter (or add a leading table) as a flat command index mirroring the real 43-command tree, so a reader can confirm whether a command exists, was renamed, or moved under a parent. Ground truth notes whole subcommand families are also undocumented: `fetch ena` (a real fifth fetch subcommand), the seven real `bundle` subcommands (the chapter shows three), and 30+ `fastq` subcommands (the chapter names six) (cli-reference, App features missing). Also resolve the `markdup` / `bam markdup` duplication, which exists in parallel and is unexplained, and decide whether to note the source-build binary name `lungfish-cli` (cli-reference, Uncertain 1; `shared-projects.md` already documents this).

### C4. `file-formats.md`: remove the 2 invented bundle formats, add the 4 real ones

Ground truth, file-formats, items 1 to 3 and App features missing.

Remove or rewrite:

1. `.lungfishvcf` (file-formats.md:133, 255 to 268, plus the `bcftools view variants.lungfishvcf/...` example at 341). There is no LungfishIO reader/writer for it; the only occurrence in source is a workflow-package enum case. Variants live in the `.lungfishref` bundle's `variants/` subdirectory, which the chapter's own `.lungfishref` layout already shows (file-formats.md:173 to 175). Delete the standalone section and the table row; point readers to `variants/` inside the reference bundle.
2. `.lungfishtax` (file-formats.md:130, 207 to 223). It is produced only by the CZ-ID import path, not by Kraken2/EsViritu/TaxTriage/NAO-MGS. Rewrite the section to scope it to CZ-ID import output and drop the unsourced `classifications.tsv`/`abundance.tsv`/`tree.json`/`raw/` layout unless verified against the CZ-ID import writer.

Add to the bundle table and give each a short section, mirroring the accurate `.lungfishref` treatment:

- `.lungfishfastq`: FASTQ read bundles, central to import and 12S workflows (the most-used read container, currently absent).
- `.lungfish12sref`: 12S amplicon reference bundle, produced by `fastq 12s-reference-bundle`.
- `.lungfishmhcref`: MHC amplicon reference bundle, produced by `fastq mhc-reference-bundle`.
- `.lungfishhaplotypedef`: ONT genotyping haplotype definition set, managed by `haplotypes`.

The verified real LungfishIO bundle set is exactly: `.lungfishref`, `.lungfishfastq`, `.lungfishmsa`, `.lungfishtree`, `.lungfishprimers`, `.lungfish12sref`, `.lungfishmhcref`, `.lungfishhaplotypedef` (ground truth, Verification baseline). The chapter's table should list these and only these. The `.lungfishflow` workflow bundle is referenced in `cli-reference.md` (`workflow diff`) but not described here; add a short note (file-formats, App features missing). While here, reconcile the example provenance `version` to the shipping `0.5.0-alpha11` and the `schema_version` presence across this chapter and `power-user-notes.md` (file-formats, needs-human-check 1).

### C5. `tool-versions.md`: make the table match `version --tools`

Ground truth, tool-versions, items 1 to 3 and App features missing. The chapter promises The same table is available from `lungfish version --tools` (tool-versions.md:27) and then disagrees with it.

1. Remove the three tools that are not in the managed lock and that the command does not print: Clair3 1.0.10, WhatsHap 2.3, Freyja 2.0.0 (tool-versions.md:55 to 57). These ship via plugin packs, not the bundled managed-tool lock; if the chapter wants to mention them, do so in a clearly separate "available via plugin packs" note, not in the managed-tools table that claims to equal `version --tools`.
2. Add the two tools the command actually prints: `openpyxl` 3.1.5 (env `openpyxl`) and `pysam` 0.24.0 (env `pysam`), both in the lock.
3. Align the table to the live command's columns and casing: the command prints Tool/Version/Source/Environment/Executables (no License column) and prints "Fastp" and "BCFtools". Either drop the License column or stop implying it comes from `version --tools`, and verify any License values against the lock's `license` fields before keeping them (tool-versions, needs-human-check 1).

The real 17-row `version --tools` set is: micromamba (bundled), BBTools, BCFtools, Cutadapt, Deacon, Fastp, HTSlib, Nextflow, openpyxl, pigz, pysam, Samtools, SeqKit, Snakemake, SRA Tools, UCSC bedGraphToBigWig, VSEARCH (ground truth, App features missing). Reconcile the table to exactly this set. The nf-core/viralrecon 3.0.0 default pin (tool-versions.md:71) is unverified in source; confirm it (tool-versions, needs-human-check 2).

### C6. `keyboard-shortcuts.md`: fix the Sidebar chord and the Find-Previous claim

Ground truth, keyboard-shortcuts, items 1 and 2.

1. The Sidebar toggle is **Cmd-Ctrl-S, not Cmd-Shift-S** (keyboard-shortcuts.md:46). `MainMenu.swift` sets `keyEquivalent: "s"` with `[.command, .control]` ("Control-Command-S per macOS standard"). This also breaks the "Memorizing chords" claim (keyboard-shortcuts.md:117) that `Cmd-Shift-letter` toggles the Sidebar; correct that sentence too, since Sidebar is the one panel that uses Ctrl, not Shift.
2. `Cmd-Shift-G` does **not** step to the previous find match (keyboard-shortcuts.md:101). "Find Previous" has no key equivalent; `Cmd-Shift-G` is only "Go to Gene." "Find Next" is `Cmd-G`. Delete the "overloaded" sentence and state that Find Previous has no default chord.

### C7. `primer-schemes.md`: fix the manifest keys, the accession shape, and add the real counts

Ground truth, primer-schemes, items 1 to 2 and App features missing.

1. Convert the manifest field table (primer-schemes.md:49 to 57) to the real snake_case keys: `display_name`, `reference_accessions`, `primer_count`, `amplicon_count`, `source`, `source_url`, `version`, `created`. Remove the invented `imported` and `attachments` fields (the shipped built-in has neither). Add the present-but-undocumented keys `schema_version`, `description`, `organism`, `source_url`.
2. Show the real `reference_accessions` object shape, not a string list: `[{"accession": "MN908947.3", "canonical": true}, {"accession": "NC_045512.2", "equivalent": true}]` (primer-schemes.md:52).
3. State the shipped scheme's concrete numbers, which the chapter currently omits: `primer_count` = 563, `amplicon_count` = 223, `display_name` = "QIAseq Direct SARS-CoV-2 with Booster A", `source` = "built-in", canonical `MN908947.3` with equivalent `NC_045512.2`.

Confirm whether the importer writes `source: imported` for CLI/GUI imports (primer-schemes.md:56), since the shipped built-in uses `"built-in"` and the importer's value was not traced (primer-schemes, needs-human-check 2). The CLI flag set is already correct; leave it.

### C8. `troubleshooting.md`: fix the `bam adopt-mapping` recovery command

Ground truth, troubleshooting, item 1. The recovery command `lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir>` (troubleshooting.md:78) omits the required `--name` and fails with a missing-required-option error on copy-paste. Correct to `lungfish bam adopt-mapping --bundle <bundle> --mapping-result <dir> --name <name>`. The same fix applies to the `cli-reference.md` entry (line 161), where `--name` is shown as optional in the same way it should not be.

## Coverage gaps (real app features missing from the docs)

### G1. The CLI reference omits a third of the command tree (headline gap)

Covered as a fidelity fix in C3 because the absences actively mislead, but it is also the largest coverage gap in the section: 14 top-level commands with no entry anywhere in the appendices, plus undocumented subcommand families (`fetch ena`, four of seven `bundle` subcommands, 25+ `fastq` subcommands). Beyond C3's one-liners, the highest-value expansions are `gatk` (10 subcommands, the entire GATK variant lane), `genotype` (7 subcommands, the MHC export surface), and `haplotypes` (10 subcommands, ONT genotyping), since each is a whole workflow with no CLI documentation today.

### G2. Four real bundle formats are undocumented (file-formats)

Covered in C4. `.lungfishfastq`, `.lungfish12sref`, `.lungfishmhcref`, and `.lungfishhaplotypedef` each need a short section. `.lungfishfastq` is the priority: it is the central read container for the import and 12S workflows and is the format a data manager encounters most. The `.lungfishflow` workflow bundle also needs at least a sentence (it is referenced by `workflow diff` but never described).

### G3. View and Window keyboard shortcuts are missing (keyboard-shortcuts)

Ground truth, keyboard-shortcuts, App features missing. The chapter omits real, useful chords: Focus Viewer `Cmd-Opt-F`, Restore Side Panes `Cmd-Ctrl-Opt-F`, Zoom In `Cmd-+` / Zoom Out `Cmd--` / Zoom to Fit `Cmd-0`, Show as RNA `Cmd-Shift-U`, Taxonomy Expand All / Collapse All `Cmd-Shift-RightArrow` / `Cmd-Shift-LeftArrow`, and Window menu's New Window for Current Project `Cmd-Opt-N`. Add a View-zoom row group and a Taxonomy-navigation note; both are everyday operations for the bench-scientist audience this chapter targets. Mind the five-per-list / two-lists-per-H2 cap (STYLE); the zoom and taxonomy chords likely belong in the existing View table or a small new table, not a third bullet list.

### G4. Managed-tool table is missing openpyxl and pysam (tool-versions)

Covered in C5. Both are in the lock and printed by `version --tools`; both are absent from the chapter. This is a coverage gap as much as a fidelity one, since a validation reader enumerating shipped dependencies would under-declare two real tools.

### G5. Unverified error strings and tool-flag sets need a source-trace pass (power-user-notes, troubleshooting, running-in-ci, shared-projects)

Ground truth, Section-wide, Cross-cutting reliability note. The command surfaces and shortcuts were verified against the live binary and `MainMenu.swift`, but many quoted error strings, provenance-schema fields, and internal tool-invocation flags were not traceable to source this pass. The ones a reader will act on most directly: the conda lock-wait and read-only messages plus the `.install.lock` path (running-in-ci.md:48 to 49); the canonical mpileup / ivar / LoFreq flag sets cited as methods text (power-user-notes.md:34 to 110); the provenance schema `schema_version: 2` and `peakMemoryBytes` (power-user-notes.md:128 to 196); the lock-record key set and `schemaVersion` (shared-projects.md:42 to 56); and the SRA-fallback and lock error strings in troubleshooting (troubleshooting.md:30 to 32, 60, 134). This is not a rewrite, it is a verification sweep, but it is load-bearing for the CI and validation personas who grep or cite these strings verbatim.

### G6. The GUI "Migrate Bundles" menu item may not exist (troubleshooting)

Ground truth, troubleshooting, needs-human-check 2. The chapter tells readers to run `Project > Migrate Bundles to Current Version` from the menu (troubleshooting.md:142), but no top-level "Project" menu was seen in `MainMenu.swift` (verified menus: App, File, Edit, View, Sequence, Operations, Tools, Window, Help). Migration is CLI-exposed (`project migrate`, documented in `shared-projects.md`). Confirm whether the GUI menu item exists; if not, point readers to the CLI command instead of a nonexistent menu path.

## Accessibility fixes

### A1. Give the CLI reference a flat, navigable command index

The domain grouping is an accessibility barrier as well as a fidelity one: a screen-reader user navigating by heading lands on domain headings (Classification, Assembly) that do not map to anything in `--help`, so they cannot jump to `conda classify` or `extract contigs` by structure. A flat alphabetized command index (C3) keyed to the real 43-command tree lets any reader, assistive-tech or not, confirm a command by name. This is the single highest-value structural and accessibility change in the section.

### A2. Make the load-bearing reference tables correct, because non-visual readers cannot cross-check them

In the appendices the tables are the deliverable: the bundle table (`file-formats.md:125`), the tool table (`tool-versions.md:45`), and the manifest field table (`primer-schemes.md:49`). A sighted reader can sometimes catch a wrong row against a screenshot; a screen-reader user reading row by row cannot. So correctness of table content is an accessibility requirement here, not just a fidelity one. The C4, C5, and C7 fixes are what make these tables safe for a non-visual reader to trust. The style guide's no-red-amber-green rule is already honored across these plain tables; keep it that way when adding rows.

### A3. Name controls and keys with the exact label the app uses

After C6, the Sidebar chord must read `Cmd-Ctrl-S` exactly (a reader who tries the documented `Cmd-Shift-S` and gets nothing has no way to know which is wrong). The new View/Window rows (G3) should use the exact menu titles ("Focus Viewer", "Show as RNA", "Zoom to Fit") so a VoiceOver user hears the same string the menu announces. The chapter's existing "click the menu bar entry; the chord appears on the right side of the row" advice (keyboard-shortcuts.md:117) is a good accessible fallback; keep it.

### A4. Keep enumerations within the bullet and list caps

STYLE caps lists at five items and two lists per H2. Several rewrites push past that if done as bullets: the missing-command list (C3), the four new bundle formats (C4), and the new shortcut rows (G3). Land these as tables (as this synthesis does) or prose, not long bullet runs, which both satisfies the cap and reads more cleanly with assistive tech.

## What to keep

These landed well across personas and should survive the revision:

- **The CLI reference's framing and global-flags table.** The "reproduce a clickwise workflow in a terminal" opener (cli-reference.md:22) and the global-flags table (cli-reference.md:424 to 434) are correct and well-pitched; ground truth confirms the flags table matches the binary. The deterministic-reruns note (cli-reference.md:436) is good craft. Keep the framing; rebuild the command body under it (C1 to C3).
- **The correct CLI entries.** Ground truth spot-verified a long list that must not be touched: `version --tools`, the `fetch` family, `import fastq`/`--samplesheet`, `bundle export --format container`, the entire `map` read-group surface, the `variants call --caller` table (the best entry in the chapter), `bam adopt-mapping`/`primer-trim`, `assemble`, `extract reads`, the six documented `fastq` ops, the `workflow` family, `run-headless`, the `conda` lock/offline surface, and the `provenance` family (cli-reference, Documented commands that ARE correct). Preserve these verbatim.
- **`file-formats.md`'s standard-formats half.** The standard sequence/annotation/alignment/variant/tree sections, the coordinate-convention note (file-formats.md:67), the bundle-as-folder model, and the terminal-inspection blocks are reference-grade and verified. Keep them; the damage is isolated to the Lungfish-bundle table and the two invented sections (C4).
- **`06-running-in-ci.md` end to end.** Ground truth found no command errors. The `run-headless` alias, the offline-pack pattern, the cache-packs-not-roots discipline, and both the GitHub Actions and CircleCI YAML are accurate and ran for the CI persona. Keep as-is; only confirm the quoted lock/read-only error strings (G5).
- **`shared-projects.md` end to end.** Ground truth found no command-surface errors. The lock/unlock/migrate commands, the stale-lock rules, the coordination-record-not-OS-lease framing, and the `lungfish-cli` binary-name note are all correct and careful. This chapter is the template the rest of the appendices should follow. Keep as-is; only verify the lock-record key set (G5).
- **`primer-schemes.md`'s concepts and CLI.** The bundle-travels-together rationale, the BED-expectations hazard note (zero-trim against a mismatched coordinate system, primer-schemes.md:68), and the fully-correct CLI flag set are sound. Keep the prose and the CLI; fix only the manifest field table and add the counts (C7).
- **`power-user-notes.md`'s reproducibility discipline and verified surfaces.** The determinism tables, the plugin-pack-pins-the-recipe-not-the-transitive-deps explanation, the OCI-for-clinical / pack-version-for-research split, the Operations-Panel-as-debug-tool section, and the verified `conda lock`/`--from-lockfile` and `ops stats` references are accurate and genuinely useful. Keep them; the only debt is the unverified tool-flag sets (G5) and the alpha6 version string (reconcile to alpha11).
- **`tool-versions.md`'s provenance rule.** "Use the provenance sidecar for methods sections ... If the two disagree, cite the sidecar" (tool-versions.md:75) is exactly the right discipline and should anchor the corrected table (C5).
- **`troubleshooting.md`'s symptom tables and most fixes.** The symptom-to-cause tables, the conda-repair guidance, the NCBI/SRA retry explanation (the `--no-retry` flag is verified), the iCloud/NFS warnings, and the diagnostics-collection checklist are solid and accurate. Keep them; fix only the `adopt-mapping` command (C8), confirm the quoted error strings (G5), and verify the Migrate-Bundles menu path (G6).
