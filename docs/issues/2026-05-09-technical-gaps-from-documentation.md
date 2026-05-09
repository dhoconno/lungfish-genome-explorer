# Technical gaps surfaced by documentation work

**Filed:** 2026-05-09
**Source:** Cross-referenced from chapter prose (every "Lungfish does not yet do X" note), the Foundations focus-group synthesis, the Part II focus-group synthesis, and the original pilot focus-group synthesis. Each entry is structured as a GitHub issue with severity, scope, what the documentation needs, and acceptance criteria.

This file is intended to be split into individual GitHub issues by Codex or the next planning round. Severity levels:

- **P0 — Blocks documentation coherence.** A claim the manual makes that isn't backed by current behavior, or a workflow the manual teaches that does not run cleanly.
- **P1 — Feature gap with active documentation impact.** Real readers (per focus groups) cannot complete a workflow without working around a missing capability; the manual currently describes the workaround.
- **P2 — Feature gap with future documentation impact.** A capability adjacent readers want; the manual currently scopes them out, but the scope grows over time.
- **P3 — Polish.** Things that would make the manual cleaner if the app supported them.

Issues are grouped by domain so related work can be batched.

## Bundle and reference handling

### #docs-001: GenBank import does not extract annotations into a bundle

**Severity:** P0

**Where the manual says it:** `02-sequences/02-downloading-from-ncbi.md` line 64: "GenBank is convenient for one-off browsing but Lungfish does not currently extract annotations from a GenBank file into a bundle, so for downstream tooling the GFF3 is the format that carries forward."

**The user-facing behavior:** A GenBank `.gb` record carries a sequence and curated annotations in one file. Today, importing it into Lungfish materializes only the sequence; the annotations stay in the original file but are not attached to the `.lungfishref` bundle. To get annotations attached, the user has to download a separate GFF3 from NCBI and pass it via `--annotation`.

**What the docs need:** The chapter currently teaches "if you want annotations, fetch GFF3 separately" as the recommended path. If GenBank import attached annotations natively, the chapter would teach "fetch GenBank once and you have everything."

**Acceptance criteria:**

- [ ] `lungfish import path/to/MN908947.3.gb` produces a `.lungfishref` bundle whose `manifest.json` lists at least one annotation track derived from the GenBank features
- [ ] The CDS, gene, and mat_peptide features round-trip cleanly into GFF3 form inside the bundle's `annotations/` subdirectory
- [ ] `lungfish variants call --bundle <bundle-from-genbank> --caller ivar` produces a codon-merged VCF (the same behavior as the FASTA + GFF3 path)
- [ ] `02-sequences/02-downloading-from-ncbi.md` is updated to recommend the single-file GenBank path when annotations are needed

**Out of scope:** Round-tripping GenBank-only metadata that has no GFF3 equivalent (LOCUS, FEATURES qualifiers like `/codon_start`, free-text comments). Those can stay in a sidecar.

---

### #docs-002: Multi-user shared projects are not supported

**Severity:** P1

**Where the manual says it:** `appendices/troubleshooting.md` "iCloud, NFS, and shared storage" section: "For team workflows, the right answer is currently: one project per researcher per analysis, on local disk. Multi-user shared projects are not yet supported."

**Where focus groups raised it:** Lab manager persona (Chris Okafor) flagged this hard. Clinical-microbiology technologist (Diana Reyes) flagged that the provenance sidecar records `host machine identity` but not which user account ran each step. The wastewater-surveillance scientist (Sam Okafor) flagged that running 32 samples/month across 8 sites needs at minimum a provenance trail that distinguishes operators.

**The user-facing behavior:** A project is a folder. Two users on the same shared filesystem may open the same project; Lungfish does not lock the project, does not warn about concurrent edits, and does not record which user account performed each operation in the provenance sidecar.

**What the docs need:** A multi-user-projects chapter, plus per-user attribution in every provenance sidecar so an audit trail can answer "who did this." The current chapter on provenance acknowledges the gap implicitly.

**Acceptance criteria:**

- [ ] Provenance sidecars include a `runtime.user` field (in addition to the existing `runtime.host`) recording the OS user account
- [ ] Opening a project that is currently open in another Lungfish process surfaces a clear warning and offers a read-only mode
- [ ] A new shell command `lungfish project lock` and `lungfish project unlock` provide explicit locking for advanced workflows
- [ ] A new chapter `01-foundations/09-shared-projects` (or an appendix) documents the supported multi-user patterns

**Out of scope:** Real-time multi-user editing (Google-Docs-style co-presence). Read/write attribution is enough.

---

### #docs-003: Bundle migration tool for old project versions

**Severity:** P2

**Where the manual says it:** `appendices/troubleshooting.md` "Migrating from older Lungfish versions" section: "If you need to migrate an old project: open the project in the latest Lungfish, run `Project > Migrate Bundles to Current Version` from the menu (when available), or re-create the bundles from their source FASTAs by re-importing."

**The user-facing behavior:** Bundle formats are versioned. Older projects open in current Lungfish but cannot be written to. The "when available" parenthetical in the troubleshooting prose is a placeholder for a feature that does not exist yet.

**Acceptance criteria:**

- [ ] `Project > Migrate Bundles to Current Version` menu item exists and migrates every bundle in a project to the current schema version
- [ ] CLI equivalent: `lungfish project migrate <path>`
- [ ] Migration is non-destructive (originals are renamed `<bundle>.lungfishref.v<old>` rather than deleted)
- [ ] Provenance is preserved through migration

**Out of scope:** Migrating across major bundle-format incompatibilities that require re-running tools. That stays a manual re-import.

---

## NCBI and SRA integration

### #docs-004: Auto-retry rate-limited NCBI fetches

**Severity:** P1

**Where the manual says it:** `02-sequences/02-downloading-from-ncbi.md` troubleshooting: "If you scripted a batch of fetches and several rows in the Operations Panel turn yellow with a 429, wait a minute and re-run; Lungfish does not currently auto-retry rate-limited fetches."

**The user-facing behavior:** Hitting NCBI's `eutils` rate limit (~3 requests/sec unauthenticated, 10 with API key) returns HTTP 429. Lungfish surfaces the failure to the Operations Panel and stops. The user has to wait and re-run by hand.

**Acceptance criteria:**

- [ ] On 429, `lungfish fetch ncbi` waits with exponential backoff (start 5s, double, cap at 5 min) and retries up to 5 times before failing
- [ ] The Operations Panel row shows a `Retrying (attempt N/5)` status during backoff
- [ ] A `--no-retry` flag opts out for scripted use cases that prefer to fail fast
- [ ] The provenance sidecar records the number of retries and their timing
- [ ] If an `NCBI_API_KEY` environment variable or Settings entry is present, requests are rate-limited at the higher 10/sec ceiling

**Out of scope:** Retrying every kind of HTTP failure. Just 429.

---

### #docs-005: NCBI API key configuration through Settings

**Severity:** P2

**Where the manual says it:** `appendices/troubleshooting.md` Network and download failures section: "To run many fetches in succession, register for an NCBI API key (free, takes 30 seconds) and configure it in `Settings > General > NCBI API key`."

**The user-facing behavior:** No Settings panel currently exposes the API key field. The manual writes to a feature that needs to exist.

**Acceptance criteria:**

- [ ] `Settings > General` includes a secure NCBI API Key field, stored in the macOS Keychain
- [ ] When set, every `lungfish fetch ncbi` and `lungfish fetch sra` request includes the key
- [ ] Provenance sidecars record only `apiKeyProvided: true|false`, never the key itself
- [ ] The CLI also reads `NCBI_API_KEY` from the environment as a fallback

---

### #docs-006: Pathoplexus search dialog documentation

**Severity:** P2

**Where the manual says it:** `02-sequences/02-downloading-from-ncbi.md` references Pathoplexus search as an alternative to NCBI: "Pathoplexus and SRA: when not to use this dialog." The Tools menu currently has `Search Pathoplexus...` but the help-ids.yaml maps it to a documentation anchor that does not yet have a procedure section.

**Where focus groups raised it:** Surveillance personas wanted Pathoplexus first-class for viral genomic surveillance use cases.

**Acceptance criteria:**

- [ ] Pathoplexus search dialog is feature-complete with the same accession-and-format pattern as NCBI search
- [ ] Pathoplexus results land in `Downloads/` with a provenance sidecar that records the source database explicitly (Pathoplexus accession format, source URL)
- [ ] A new chapter or section walks through a Pathoplexus search end-to-end with a worked example
- [ ] The "Pathoplexus and SRA: when not to use this dialog" forward-pointer in `02-sequences/02` resolves to the new section

**Out of scope:** Submitting sequences to Pathoplexus from inside Lungfish. Read-only retrieval only.

---

## Variant calling

### #docs-007: Phased variant calling (HaplotypeCaller / WhatsHap)

**Severity:** P2

**Where the manual says it:** `appendices/power-user-notes.md` codon-merge mechanics section: "The merge is not phase-aware: iVar does not know whether the two changes are on the same molecule. The single-row representation makes the codon boundary visible in the table; for haplotype-phased calls you need a tool that consumes phased BAMs (HaplotypeCaller, WhatsHap), which Lungfish does not currently wrap."

**Where focus groups raised it:** Year 4 virology PhD (Daniel Okafor, flu reassortment) wants phased calls for influenza segments. Year 3 genetics PhD (Rachel Sturm) flagged that the chapter's codon-merge framing implies positional rather than phased merging and wanted clarity.

**The user-facing behavior:** The codon-merge in iVar's pipeline is positional. Two SNPs in one codon get merged because they're at adjacent positions in a coding region, not because they're on the same molecule. For most viral isolate work this is fine because AF near 1.0 means most reads carry both changes. For mixed-population samples or true haplotype work, the user needs a phased caller that Lungfish does not wrap.

**Acceptance criteria:**

- [ ] Add a `--phase-aware` flag to `lungfish variants call --caller ivar` that warns when codon-merged rows have meaningfully different AFs across the merged positions (a sign that they're on different molecules)
- [ ] (Future) Wrap WhatsHap as a `lungfish variants phase` operation
- [ ] (Future) Wrap GATK HaplotypeCaller as a separate caller in the variant-calling dialog (analyst tier)
- [ ] Documentation chapter or appendix on phased variant calling for users who need it

---

### #docs-008: Clair3 as an alternative ONT variant caller

**Severity:** P2

**Where the manual says it:** `05-variants/04-nanopore-variant-calling.md` line 138: "Clair3 is a separate neural-network ONT variant caller that has gained ground for human germline variant calling and for some viral applications. It is not currently bundled with Lungfish."

**Where focus groups raised it:** Year 5 epidemiology PhD (Tomás Herrera, SARS-CoV-2 lineages) wanted Clair3 as an alternative to Medaka for ONT amplicon work. Power-user persona (Lin Patel, tool developer) noted that Medaka is moving to maintenance mode at ONT and Clair3 is the active alternative.

**Acceptance criteria:**

- [ ] `lungfish variants call --caller clair3` is supported with a similar UX to Medaka (basecaller-model selection, primer-trim acknowledgement, etc.)
- [ ] A clair3 plugin pack ships with the variant-calling pack family
- [ ] Documentation chapter `05-variants/04-nanopore-variant-calling.md` is extended to compare Medaka and Clair3 with a tool-choice table

**Out of scope:** Wrapping every ONT variant caller. Medaka and Clair3 cover the practical regime.

---

### #docs-009: GATK HaplotypeCaller for non-viral / human work

**Severity:** P3

**Where focus groups raised it:** Year 3 genetics PhD (Rachel Sturm) and clinical bioinformatics consultant (Sara Linhardt) both flagged the absence of GATK as disqualifying for their respective workflows. The manual currently scopes to viral genomics, so this is genuinely out of scope today; if scope expands, GATK becomes a real ticket.

**The user-facing behavior:** Lungfish's three callers (iVar, LoFreq, Medaka) are all viral-focused. Human germline variant calling, multi-sample joint genotyping, and somatic calling are not supported.

**Acceptance criteria** (only if scope expansion is approved):

- [ ] `lungfish variants call --caller gatk-haplotype` runs HaplotypeCaller against an alignment track
- [ ] `lungfish variants joint-genotype` performs GenotypeGVCFs across multiple samples
- [ ] A separate Part of the manual covers human / non-viral variant calling
- [ ] A scope section in `01-foundations/01-what-is-a-genome.md` clarifies which audiences are out of scope until then

---

### #docs-010: Bcftools as an orthogonal caller for cross-validation

**Severity:** P2

**Where focus groups raised it:** Bioinformatics consultant (Sara Linhardt) and viral surveillance PI (James Okonkwo) both wanted bcftools as a third caller for clinical cross-validation. The current cross-caller chapter compares iVar and LoFreq, both of which are amplicon-flavored. A truly orthogonal caller would strengthen the cross-validation argument.

**Acceptance criteria:**

- [ ] `lungfish variants call --caller bcftools` runs `bcftools mpileup | bcftools call`
- [ ] The Variant Calling dialog adds a fourth tab for bcftools
- [ ] The cross-caller comparison chapter is extended to a three-way comparison

---

## Classification

### #docs-011: Freyja for wastewater lineage demixing

**Severity:** P1

**Where focus groups raised it:** Surveillance PI (James Okonkwo) flagged Freyja's absence as a critical gap: "If your audience is viral surveillance and Lungfish doesn't have a Freyja chapter or even a Freyja mention, you're missing the dominant tool in our space. Pangolin is for clinical isolates. Freyja is for wastewater."

**The user-facing behavior:** NAO-MGS handles wastewater classification at the metagenome level. Freyja handles lineage demixing within a single wastewater sample (estimating the relative abundance of SARS-CoV-2 lineages). They solve different problems and Lungfish only wraps one.

**Acceptance criteria:**

- [ ] A Freyja plugin pack ships with the classification or surveillance pack family
- [ ] A `Tools > FASTQ/FASTA Operations > Lineage Demixing > Freyja` menu item exists
- [ ] A new chapter `06-classification/07-running-freyja` covers the workflow
- [ ] The "what Lungfish does not target" note in `06-classification/01` updates to remove Freyja from the not-yet list

---

### #docs-012: Database update tracking for classifiers

**Severity:** P2

**Where focus groups raised it:** Multiple personas across PhD and power-user groups flagged that classifier databases (Kraken2, EsViritu, TaxTriage, NAO-MGS) drift over time and the manual does not say how a re-run handles the change. Year 5 epidemiology PhD wanted a "vertical guideline at any week where `manifest.json` reports a different database" for surveillance series.

**The user-facing behavior:** A classifier database installed today and the same-name database installed in six months are not the same database. Lungfish records the database version in the provenance sidecar, but does not surface database-change events in the surveillance viewport.

**Acceptance criteria:**

- [ ] Plugin Manager shows the date a database was installed and offers an "Update available" indicator when a newer version exists upstream
- [ ] NAO-MGS surveillance viewport draws a vertical guideline at any sample whose `manifest.json` references a different database version than the previous sample
- [ ] `lungfish conda info <pack>` shows installation date, current version, and whether an update is available

---

### #docs-038: First-class CZ-ID results import

**Severity:** P1

**Where focus groups raised it:** Power-user persona (David Okafor, sequencing-company bioinformatician) flagged CZ-ID as the dominant production-scale metagenomics platform in industry, on equal billing with Kraken2 in his community. Lungfish currently has no path to view a CZ-ID run's outputs. Putting CZ-ID alongside NAO-MGS and NVD as a first-class importable result type closes a meaningful adoption gap for clinical and public-health labs that already run CZ-ID upstream.

**The user-facing behavior:** Many labs already pay for or use the free tier of CZ-ID (Chan Zuckerberg Initiative's hosted metagenomics platform) for their primary classification work. They want to bring CZ-ID outputs into Lungfish so the classification result lives alongside the rest of the project's bundles, with provenance, and is viewable in a Lungfish-native viewport rather than requiring a CZ-ID web login.

**The pattern to follow:** NAO-MGS and NVD are already implemented as first-class importable result types. The file layout is consistent across both:

- `Sources/LungfishApp/Views/Metagenomics/<Name>ImportSheet.swift` — guided import dialog
- `Sources/LungfishApp/Views/Metagenomics/<Name>DataConverter.swift` — normalizes upstream output to Lungfish's classification result schema
- `Sources/LungfishApp/Views/Metagenomics/<Name>ResultViewController.swift` — viewport that renders the imported results
- `Sources/LungfishApp/Views/Metagenomics/<Name>ProvenanceView.swift` — provenance disclosure for a result bundle
- `Sources/LungfishCLI/Commands/<Name>Command.swift` — CLI mirror with `import` subcommand

NAO-MGS additionally has `NaoMgsChartViews.swift` because it is a longitudinal time-series; CZ-ID is per-sample so it more closely resembles NVD's shape. Build CZ-ID's import to NVD parity by default, with optional time-series charts only if a user imports many CZ-ID runs into one project.

**What CZ-ID exports:** CZ-ID's per-sample download bundle includes (at minimum):

- A taxon report TSV with per-taxon read count, RPM, percent identity to reference, NT/NR rank, alignment length, e-value
- Hit summary at NT and NR (nucleotide and protein) levels
- Coverage visualization data per taxon (when the user pulled it)
- Sample metadata (sample name, host, collection date, project ID)
- The pipeline version and reference databases used

The CZ-ID web UI lets users download these as a zipped bundle per sample. Plan to accept either the zipped bundle or an extracted folder.

**What the docs need:**

- A new chapter `06-classification/07-importing-cz-id-results` walks through importing a CZ-ID download into a Lungfish project, viewing it in the result viewport, and combining it with Lungfish-native classification runs on the same FASTQ
- The "what Lungfish does not target" note in `06-classification/01` is updated to remove CZ-ID from the not-yet list
- The classifier comparison table in `06-classification/01` is updated to add CZ-ID with a clear "imported, not native" marker

**Acceptance criteria:**

- [ ] `Sources/LungfishApp/Views/Metagenomics/CzIdImportSheet.swift` provides a guided import dialog matching the NVD pattern: file picker accepting a CZ-ID zipped bundle or an extracted folder, sample-name preview, project destination
- [ ] `Sources/LungfishApp/Views/Metagenomics/CzIdDataConverter.swift` parses the CZ-ID taxon report TSV and any included coverage data; normalizes to Lungfish's per-taxon classification result schema
- [ ] `Sources/LungfishApp/Views/Metagenomics/CzIdResultViewController.swift` renders the imported result with the same controls available to Kraken2 / EsViritu results (sortable taxon table, breadcrumb bar, taxon-extraction action)
- [ ] `Sources/LungfishApp/Views/Metagenomics/CzIdProvenanceView.swift` shows the CZ-ID pipeline version, reference database versions, and source filename(s) in the standard provenance pane
- [ ] `Sources/LungfishCLI/Commands/CzIdCommand.swift` exposes `lungfish cz-id import --bundle <path-or-zip> --project <path>` and (if useful) `lungfish cz-id summary` for headless workflows
- [ ] `File > Import > CZ-ID Results` menu item lives alongside the existing NAO-MGS and NVD entries
- [ ] `Tools > FASTQ/FASTA Operations > Classification` continues to NOT offer CZ-ID as a fresh-run option (CZ-ID is hosted; Lungfish only imports), and the wizard explains this in a one-line note when the user clicks the CZ-ID entry from elsewhere
- [ ] Provenance sidecar records the CZ-ID `pipeline_version`, the `nt_db` and `nr_db` versions when present in the upstream metadata, and the source archive's SHA-256
- [ ] Read-extraction by taxon works against an imported CZ-ID result the same way it works against Kraken2 (the user picks a taxon, Lungfish extracts the matching reads from the FASTQ bundle the CZ-ID run was derived from, when that FASTQ bundle is present in the project)
- [ ] `help-ids.yaml` registers `dialog.CzIdImportSheet` and `viewport.CzIdResultViewer` mapped to the new chapter

**Edge cases to handle:**

- **CZ-ID bundle with no upstream FASTQ in the project.** Permit import; the read-extraction action is greyed out with a tooltip explaining why
- **CZ-ID bundle from a different host genome subtraction step than Lungfish's local Deacon scrub.** Record the upstream host-removal step in provenance verbatim; do not re-run Deacon on imports
- **CZ-ID's NT and NR result tables for the same sample.** Treat them as two layers of the same result so the user can toggle between them in the viewport rather than viewing two separate result bundles
- **Updated CZ-ID schema versions.** Include a `cz_id_schema_version` field on the converter so future schema changes do not silently mis-parse

**Tests to add:**

- `Tests/LungfishAppTests/CzIdDataConverterTests.swift` — unit tests against committed sample CZ-ID outputs at the smallest viable size
- `Tests/LungfishCLITests/CzIdImportTests.swift` — CLI roundtrip with a fixture archive
- A documentation fixture under `docs/user-manual/fixtures/cz-id-sample/` containing one anonymized CZ-ID download (with permission) for the worked example in the new chapter

**Out of scope:**

- Running CZ-ID inside Lungfish (CZ-ID is a hosted platform; Lungfish only imports its outputs)
- Submitting sequences to CZ-ID from inside Lungfish
- Real-time sync with a user's CZ-ID account

**References:** CZ-ID public docs at https://chanzuckerberg.zendesk.com/hc/en-us/categories/360001029192-CZ-ID

---

### #docs-013: BLAST verification rate-limiting and queueing

**Severity:** P2

**Where the manual says it:** `06-classification/06-blast-verification.md` notes that NCBI BLAST has shared queue limits and that runs can take 30 seconds to ten minutes during peak hours. Power-user persona (Lin Patel) wanted explicit rate-limit handling.

**Acceptance criteria:**

- [ ] `lungfish blast` respects NCBI's published BLAST etiquette (no more than one submission every ten seconds, no more than 50 sequences per hour for unauthenticated traffic) by default
- [ ] When the queue stalls, the Operations Panel shows the BLAST request ID and the upstream queue position when available
- [ ] A `--max-concurrent` flag caps in-flight BLAST submissions per process

---

## Mapping and alignment

### #docs-014: Read-group (RG) configuration in Mapping dialog

**Severity:** P1

**Where focus groups raised it:** Bioinformatics consultant (Sara Linhardt) flagged the absence of read-group documentation as disqualifying for clinical pipelines: "Any clinical pipeline needs `@RG\tID:\tSM:\tLB:\tPL:` set correctly. Without this, joint variant calling is impossible."

**The user-facing behavior:** `lungfish map --sample-name` exists but only sets a partial RG. There is no exposed UI or CLI for setting `@RG ID`, `@RG LB`, `@RG PL`, or `@RG PU`.

**Acceptance criteria:**

- [ ] Mapping dialog exposes RG fields in an Advanced Options disclosure: `ID`, `SM` (sample name), `LB` (library), `PL` (platform), `PU` (platform unit)
- [ ] CLI: `lungfish map --rg-id <id> --rg-lb <lib> --rg-pl <platform> --rg-pu <unit>` (in addition to the existing `--sample-name` for SM)
- [ ] Default RG values are derived sensibly when the user does not provide them, with the derivation logged in provenance
- [ ] Documentation chapter `04-alignments/01-mapping-reads-to-a-reference.md` adds a section on read groups for clinical readers

---

### #docs-015: BAM CIGAR display fidelity

**Severity:** P2

**Where focus groups raised it:** Senior staff scientist (Margaret Chen) flagged: "Soft-clipped bases retain their original base calls. The current CIGAR example with embedded N's is the most concrete error in the alignment files chapter." This was fixed in the chapter prose during the revision pass, but the underlying behavior (BAM viewport showing soft-clipped bases as lighter rather than as N) is correct in the app today.

This issue is closed; left here for traceability.

**Status:** Closed. Documentation fixed in F04 during the revision pass.

---

### #docs-016: viralrecon (nf-core) wizard documentation

**Severity:** P1

**Where the manual says it:** `04-alignments/01-mapping-reads-to-a-reference.md` mentions "the viral recon wizard" without context. The Mapping dialog has a Viral Recon entry in the tool picker, but no chapter walks through the workflow.

**Where focus groups raised it:** Year 4 virology PhD (Daniel Okafor) flagged this gap: "That's the chapter I'd read first and it doesn't exist."

**Acceptance criteria:**

- [ ] A new chapter `04-alignments/05-viral-recon-wizard` covers the nf-core viralrecon integration end-to-end
- [ ] The mapping chapter cross-references it cleanly
- [ ] The wizard's behavior (which viralrecon profile, which reference, what outputs) is documented

---

## Workflows and reproducibility

### #docs-017: NAO-MGS profiling node missing from Workflow Builder palette

**Severity:** P1

**Where the manual says it:** `08-workflows/01-the-workflow-builder.md` line 51: "the Phylogeny tool [does] not yet have palette entries, so a workflow that needs those steps still has to be assembled by hand at the CLI."

**Acceptance criteria:**

- [ ] NAO-MGS profiling has a Workflow Builder palette node with the same input/output type contracts as other classification nodes
- [ ] Phylogeny (IQ-TREE) inference has a palette node
- [ ] Tree re-rooting has a palette node
- [ ] The "missing palette entries" note in the chapter is removed

---

### #docs-018: Container image export for full environment pinning

**Severity:** P1

**Where the manual says it:** `08-workflows/02-exporting-as-nextflow-or-snakemake.md` and `appendices/power-user-notes.md` both reference an OCI container export as the path to bit-identical reproducibility. The export menu lists `Container Image` as a target, but the implementation may be partial.

**Where focus groups raised it:** Bioinformatics consultant (Sara Linhardt) flagged the Plugin Manager + conda env model as insufficient for clinical reproducibility: "CAP/CLIA inspectors will ask 'what package versions did this run use' and 'plugin pack 0.3.2' is not an answer. You need to lock the environment lockfile (full conda lock or OCI image digest) or the audit trail won't fly."

**Acceptance criteria:**

- [ ] `File > Export > Provenance > Container Image` produces an OCI image with every plugin pack baked in at content-addressed digests
- [ ] The Nextflow export option to use the OCI image (rather than conda) is supported and documented
- [ ] CLI: `lungfish bundle export <bundle> --format container --output <image-tarball>`
- [ ] The image is reproducible (re-running the export produces the same digest given the same plugin pack versions)
- [ ] Documentation chapter `08-workflows/02` is extended with a worked example

---

### #docs-019: Conda lockfile generation

**Severity:** P1

**Where focus groups raised it:** Postdoc / Snakemake builder (Aiko Tanaka) wanted: "If Lungfish workflows are going to be portable assets, they need a schema in a public repo with semver guarantees... Plugin pack version pins recipe; does NOT pin every transitive dependency."

**Acceptance criteria:**

- [ ] `lungfish conda lock --pack <name> --output lockfile.yml` produces a conda-lock-compatible lockfile pinning every transitive dependency
- [ ] `lungfish conda install --from-lockfile lockfile.yml` reproduces the exact environment
- [ ] The Nextflow and Snakemake exports include the relevant lockfiles by default
- [ ] Documentation in `appendices/power-user-notes.md` references the lockfile workflow

---

### #docs-020: Workflow versioning and diff view

**Severity:** P2

**Where focus groups raised it:** Tool developer (David Okafor): "If I save a workflow today and edit it tomorrow, can I see the diff? Can I tag a workflow as v1.0 and run a regression test against v1.1? The `runs/` folder with per-run records is good but workflow-level versioning is missing."

**Acceptance criteria:**

- [ ] Workflow files (`.lungfishflow` or equivalent) carry a semver-style version field
- [ ] The Workflow Builder shows version history for a saved workflow with a diff view
- [ ] A `lungfish workflow diff <v1> <v2>` CLI command compares two saved workflows
- [ ] Documentation chapter `08-workflows/01` adds a section on workflow versioning

---

### #docs-021: Pass-through arguments for arbitrary tool flags

**Severity:** P2

**Where the manual says it:** `appendices/power-user-notes.md` "Pass-through arguments" section: "Most Lungfish dialogs do not expose every flag of the underlying tool. To pass arbitrary flags through, use the CLI: `lungfish variants call --caller ivar --extra-args "--gff annotations.gff3 --pass_only"`. Not every command supports `--extra-args`; check the per-command help."

**Acceptance criteria:**

- [ ] `--extra-args` is supported on every command that wraps an external tool (map, primer-trim, variants call, classify, esviritu run, taxtriage run, assemble, blast)
- [ ] The wrapped command embeds the extra args verbatim and records them in the provenance sidecar
- [ ] Documentation table lists which commands support `--extra-args` (currently scattered)

---

### #docs-022: Headless / batch CI mode for the GUI

**Severity:** P2

**Where focus groups raised it:** Tool developer (David Okafor): "No mention of headless / batch mode for the GUI — can the app be invoked from CI?"

**Acceptance criteria:**

- [ ] `lungfish` CLI is sufficient for every operation the GUI exposes (true today for most operations)
- [ ] If a GUI-only operation exists, document the gap explicitly
- [ ] `lungfish run-headless <workflow.yaml>` confirms the app does not need a display server
- [ ] Documentation chapter or appendix on running Lungfish in CI

---

## File handling

### #docs-023: Sample sheet support for batch import and processing

**Severity:** P1

**Where focus groups raised it:** Multiple early-career and surveillance personas flagged the absence of sample-sheet-driven workflows. ONT runs already accept a sample sheet (`03-reads/07`); Illumina batch import does not.

**Acceptance criteria:**

- [ ] Import Center accepts a CSV sample sheet for paired-Illumina batches with columns `sample`, `r1`, `r2`, plus optional metadata columns
- [ ] CLI: `lungfish import-fastq --samplesheet <csv>`
- [ ] The Workflow Builder accepts a sample sheet as input to fan out a workflow across many samples
- [ ] Documentation chapter on multi-sample workflows references this prominently

---

### #docs-024: Multi-sample VCF rendering

**Severity:** P2

**Where the manual says it:** `05-variants/06-importing-existing-vcfs.md` line 46: "Multi-sample VCFs are supported: each sample column becomes a separately filterable source in the variant browser."

**Where focus groups raised it:** Year 3 genetics PhD (Rachel Sturm) flagged that this single-sentence treatment is the entire support for multi-sample VCFs. Joint-genotyped human VCFs have hundreds or thousands of sample columns; the variant browser may not handle them well at scale.

**Acceptance criteria:**

- [ ] Variant browser handles >100-sample VCFs without UI degradation (lazy column rendering)
- [ ] Sample-level filtering operates on per-sample GT/AF/DP fields
- [ ] CLI: `lungfish variants extract-sample <vcf> --sample <name> --output <file>` derives a per-sample VCF
- [ ] Documentation extends `05-variants/06` and possibly a new chapter on multi-sample VCFs

---

### #docs-025: VCFv3 import support or explicit rejection

**Severity:** P3

**Where the manual says it:** `05-variants/06-importing-existing-vcfs.md`: "Older VCFv3 files are not accepted directly (see Troubleshooting)."

**Acceptance criteria:**

- [ ] Either: `lungfish import vcf` upconverts VCFv3 to VCFv4.x using a known-good translator
- [ ] Or: the import dialog rejects VCFv3 with a clear error and a link to a converter
- [ ] Documentation chapter clarifies which path Lungfish takes

---

## Provenance and audit

### #docs-026: Signed provenance sidecars (sigstore / in-toto)

**Severity:** P2

**Where focus groups raised it:** Tool developer (David Okafor): "Nowhere does the manual discuss signing or attestation. If Lungfish is going to claim audit-trail-grade provenance, the sidecars should be signed (sigstore, in-toto). Otherwise a malicious user can rewrite history and the audit trail can't tell."

**Acceptance criteria:**

- [ ] Provenance sidecars can be optionally signed with sigstore (cosign) at write time
- [ ] `lungfish provenance verify <file>` checks signatures against the public key
- [ ] Settings panel exposes signing-key configuration with Keychain integration
- [ ] Documentation chapter or appendix on signed provenance for clinical/regulatory readers

---

### #docs-027: User account in provenance sidecar

**Severity:** P1

**Where focus groups raised it:** Clinical-microbiology technologist (Diana Reyes): "The provenance sidecar records 'host machine identity' per `03-reads/01-importing-fastq`, but does it record *which user account* did the import? If Tech A imports and Tech B calls variants, the audit trail needs both names."

This is a subset of #docs-002 (multi-user shared projects) but can ship independently.

**Acceptance criteria:**

- [ ] Every provenance sidecar's `runtime` block includes a `user` field with the OS user account that ran the operation
- [ ] CLI provenance display surfaces the user
- [ ] Documentation in `01-foundations/08-provenance-and-reproducibility.md` is updated to describe the field

---

### #docs-028: Methods Section export draft warning

**Severity:** P2

**Where focus groups raised it:** Multiple power-user personas (Marcus Chen PI, Sara Linhardt consultant) independently flagged that the Methods Section export will get pasted verbatim into papers and validation packets without review.

**Acceptance criteria:**

- [ ] The Methods Section export prepends a banner: `<!-- This is an automatically-generated draft. Read it before submitting. -->` (or equivalent in non-Markdown contexts)
- [ ] The banner is removable but visually obvious
- [ ] Documentation acknowledges the banner exists and recommends a human review pass

---

## Tool-version pinning

### #docs-029: Tool-version reference table per release

**Severity:** P1

**Where focus groups raised it:** Three of five PhD personas and three of five power-user personas independently asked for tool-version pinning at the chapter level. The Power User Notes appendix has a generic mention; chapters do not.

**Acceptance criteria:**

- [ ] Per-release notes file (or section in `appendices/power-user-notes.md`) lists every tool that ships with the current Lungfish build, with version numbers
- [ ] CLI: `lungfish version --tools` prints the table
- [ ] CI job updates this file at every release so it does not rot
- [ ] Chapters reference the table by anchor rather than embedding versions in body prose

---

### #docs-030: Tool-paper bibliography

**Severity:** P2

**Where focus groups raised it:** Multiple PhD and power-user personas wanted DOIs/citations for upstream tools. The manual cites tools by name but no chapter links to the canonical paper for any of them.

**Acceptance criteria:**

- [ ] A `bibliography.md` (or chapter-level `references:` frontmatter) collects DOIs/links for: Quick 2017 (ARTIC), Grubaugh 2019 (iVar), Wilm 2012 (LoFreq), Li 2018 (minimap2), Li 2009 (BWA), Bankevich 2012 (SPAdes), Nakamura 2018 (MAFFT), Minh 2020 (IQ-TREE), Wood 2019 (Kraken2), Ewing & Green 1998 (Phred), VCFv4 spec, SAM/BAM spec
- [ ] Chapter prose references the bibliography by anchor on first tool mention
- [ ] CLI: `lungfish provenance bibliography <bundle>` generates citation list for a project's actual tools

---

## Network and offline

### #docs-031: Offline plugin pack installation

**Severity:** P1

**Where focus groups raised it:** Clinical-microbiology technologist (Diana Reyes): "Our lab subnet blocks bioconda mirrors and NCBI Entrez at the firewall. `05-variants/01` says `lungfish conda install --pack read-mapping variant-calling` — that's our blocker."

**Acceptance criteria:**

- [ ] `lungfish conda install --offline --from-bundle <local-archive>` installs from a pre-downloaded archive
- [ ] `lungfish conda export-pack --pack <name> --output <archive>` generates an offline-installable archive on a connected machine
- [ ] HTTPS proxy support honors `HTTPS_PROXY` and `https_proxy` environment variables
- [ ] Documentation chapter or appendix on offline installation

---

### #docs-032: Shared `~/.lungfish/conda` across machines

**Severity:** P2

**Where focus groups raised it:** Genomics core manager (Chris Okafor): "On a multi-user workstation, every user installs their own copy of every plugin pack? That is going to fill our scratch volume in a month."

**Acceptance criteria:**

- [ ] `LUNGFISH_CONDA_ROOT` environment variable overrides `~/.lungfish/conda`
- [ ] Read-only shared installs are supported (one administrative user installs, all users on the host can run)
- [ ] Lock-file semantics prevent two users from installing into the same shared root simultaneously
- [ ] Documentation in `01-foundations/07-plugin-packs.md` covers the shared-install pattern

---

## Hardware and performance

### #docs-033: Per-operation runtime estimates

**Severity:** P2

**Where focus groups raised it:** Genomics core manager (Chris Okafor): "I bill compute. I want a table per chapter: 'this operation, this input size, this expected runtime, this RAM peak.' `05-variants/01` gives 'about five minutes of wall clock on a recent Apple Silicon Mac' for one sample. What about a 96-sample batch?"

**Acceptance criteria:**

- [ ] Each Operations Panel row records its peak RAM and wall time, surfaced in the provenance sidecar
- [ ] A reference table in `appendices/power-user-notes.md` gives expected ranges for common operations on common input sizes
- [ ] CLI: `lungfish ops stats` aggregates runtime/memory across all completed operations in a project

---

### #docs-034: Hardware floor declaration

**Severity:** P2

**Where focus groups raised it:** Genomics core manager flagged the "recent Apple Silicon Mac" assumption. Research associate (Maya Chen) flagged Intel Mac compatibility.

**Acceptance criteria:**

- [ ] Settings or About window declares supported hardware: minimum macOS version, minimum CPU architecture, minimum RAM for default workflows
- [ ] Operations that would not fit in available RAM (e.g., Kraken2 Standard database on 16 GB) warn before running
- [ ] Documentation in `01-foundations/07-plugin-packs.md` and the per-classifier chapters declares minimum RAM per operation

---

## Format-specific gaps

### #docs-035: GFF3 with no annotations should still write a manifest entry

**Severity:** P3

**Where the manual says it:** `02-sequences/02-downloading-from-ncbi.md` troubleshooting: "If you asked for GFF3 and got an XML error document, the upstream record probably does not have annotations in GFF3 form. Fall back to GenBank."

**Acceptance criteria:**

- [ ] `lungfish fetch ncbi --fetch-format gff3` returns an empty-but-valid GFF3 (just `##gff-version 3` header) when the upstream record has no annotations, and warns rather than errors
- [ ] The bundle creation step accepts an empty GFF3 and notes "no annotations" in the manifest

---

### #docs-036: Custom primer scheme builder

**Severity:** P1

**Where the manual says it:** `04-alignments/03-primer-trimming.md`: "Custom primer schemes drop into the project's `Primer Schemes/` folder as `.lungfishprimers` bundles. See [Primer Schemes](../06-bundles/03-primer-scheme-bundles.md) for the layout and for the steps to build one from a published BED."

The chapter referenced (`06-bundles/03-primer-scheme-bundles.md`) does not exist. The bundle layout is documented in `appendices/file-formats.md`, but there is no end-to-end "build a custom scheme from a BED" workflow.

**Where focus groups raised it:** Bench scientists across early-career and PhD groups asked how to bring their own primer scheme.

**Acceptance criteria:**

- [ ] `lungfish primers import --bed <bed> --fasta <ref> --output <name>.lungfishprimers` is documented and works end-to-end
- [ ] A new chapter or appendix walks through the workflow with a worked example
- [ ] The forward reference in `04-alignments/03` resolves to the new chapter

---

### #docs-037: Adapter-removal vs primer-trim FASTQ-level guidance

**Severity:** P3

**Where the manual says it:** `03-reads/04-trimming-and-filtering.md` notes that primer trim has FASTQ-level and BAM-level flavors, with BAM-level being default for variant calling. Power user (Marcus Chen) flagged that fastp does adapter+quality in one pass and the chapter's "order matters" rule overstates the case.

**Acceptance criteria:**

- [ ] The trim chapter is updated to say "fastp does adapter and quality in one pass via the combined dialog checkbox; order only matters when chaining separate operations"
- [ ] The combined operation in the dialog is the default

---

## Summary table

| ID | Severity | Domain | Title |
|---|---|---|---|
| docs-001 | P0 | Bundles | GenBank import does not extract annotations |
| docs-002 | P1 | Bundles | Multi-user shared projects |
| docs-003 | P2 | Bundles | Bundle migration tool |
| docs-004 | P1 | NCBI/SRA | Auto-retry rate-limited fetches |
| docs-005 | P2 | NCBI/SRA | NCBI API key in Settings |
| docs-006 | P2 | NCBI/SRA | Pathoplexus search dialog documentation |
| docs-038 | P1 | Classification | First-class CZ-ID results import |
| docs-007 | P2 | Variants | Phased variant calling |
| docs-008 | P2 | Variants | Clair3 ONT caller |
| docs-009 | P3 | Variants | GATK HaplotypeCaller (scope expansion) |
| docs-010 | P2 | Variants | Bcftools as orthogonal caller |
| docs-011 | P1 | Classification | Freyja for wastewater |
| docs-012 | P2 | Classification | Database update tracking |
| docs-013 | P2 | Classification | BLAST rate-limit handling |
| docs-014 | P1 | Mapping | Read-group (RG) configuration |
| docs-015 | — | Mapping | (closed) BAM CIGAR display fidelity |
| docs-016 | P1 | Mapping | viralrecon wizard documentation |
| docs-017 | P1 | Workflows | NAO-MGS / Phylogeny palette nodes |
| docs-018 | P1 | Workflows | OCI container image export |
| docs-019 | P1 | Workflows | Conda lockfile generation |
| docs-020 | P2 | Workflows | Workflow versioning + diff |
| docs-021 | P2 | Workflows | Pass-through arguments |
| docs-022 | P2 | Workflows | Headless / batch CI mode |
| docs-023 | P1 | Files | Sample sheet for batch import |
| docs-024 | P2 | Files | Multi-sample VCF rendering at scale |
| docs-025 | P3 | Files | VCFv3 import or explicit reject |
| docs-026 | P2 | Provenance | Signed provenance sidecars |
| docs-027 | P1 | Provenance | User account in sidecar |
| docs-028 | P2 | Provenance | Methods Section draft warning |
| docs-029 | P1 | Versioning | Tool-version reference table |
| docs-030 | P2 | Versioning | Tool-paper bibliography |
| docs-031 | P1 | Network | Offline plugin pack installation |
| docs-032 | P2 | Network | Shared conda root across machines |
| docs-033 | P2 | Performance | Per-operation runtime estimates |
| docs-034 | P2 | Performance | Hardware floor declaration |
| docs-035 | P3 | Formats | Empty GFF3 handling |
| docs-036 | P1 | Formats | Custom primer scheme builder docs |
| docs-037 | P3 | Formats | Adapter+quality combined trim |

**Counts by severity:**
- P0 (blocks docs coherence): 1
- P1 (active doc impact): 13
- P2 (future doc impact): 18
- P3 (polish): 5
- Closed: 1

**Recommended next sprint:** Pick all P0 + 4-5 P1 issues that cluster (e.g., the workflow-export trio: #docs-018, #docs-019, #docs-020). Defer P2 and P3 to subsequent sprints.

## Suggested issue sequence for Codex

If Codex picks these up serially, suggested order:

1. **#docs-001** (GenBank import → annotations) — single P0, narrow scope, unblocks a chapter recommendation
2. **#docs-027** (user in provenance) — small, cleanly-scoped, dependency for several other items
3. **#docs-029** (tool-version reference table) — small, but unblocks chapter cross-references
4. **#docs-014** (RG configuration) — narrow scope, opens clinical-pipeline adoption
5. **#docs-018, #docs-019** (OCI export + conda lockfile) — best done together
6. **#docs-031** (offline conda install) — narrow scope, unblocks clinical labs
7. **#docs-004** (auto-retry NCBI) — small, polish but visible
8. **#docs-016** (viralrecon docs) — narrow scope, mostly chapter writing
9. **#docs-017** (workflow palette nodes) — UI-only, narrow scope
10. **#docs-023** (sample sheet) — larger scope, anchors the multi-sample chapter
11. **#docs-038** (CZ-ID import) — full first-class import; mirrors NVD's shape, documented chapter, larger scope but contained

After that, the remaining P1s and P2s can be batched by domain.
