# Generalist Macaque MHC Haplotyping Prompt Design

## Goal

Develop and evaluate a new generalist macaque MHC haplotyping specialist prompt before wiring anything into Lungfish. The prompt should use the MCM specialist prompt as an example of careful human-style reasoning, but it must not inherit MCM-specific assumptions such as the fixed M1-M7 label set or broad intact-haplotype linkage across MHC-A through MHC-DP.

The first benchmark dataset is:

- `/Users/dho/Downloads/30783_SNPRC22_MHC_Genotype_Report_31Dec24.xlsx`

The fallback benchmark dataset, used only if the outbred prompt remains poor after about five iterations, is:

- `/Users/dho/Downloads/31936_MiSeq260_LCPreclinical37_InitialReport_18Dec25.xlsx`

## Non-Goals

- Do not add app UI, CLI flags, presets, or production workflow integration in this phase.
- Do not add deterministic haplotype-solving logic outside the prompt.
- Do not expose human-curated haplotype calls to the prompt as a priori labels.
- Do not optimize for MCM behavior at the expense of outbred macaque populations.

## Source Workbook Shape

The SNPRC workbook contains:

- `Abbreviated Haplotypes`: sample-level human-curated target calls.
- `Full Sequencing Results 1` and `Full Sequencing Results 2`: per-sample read-count matrices with top rows for curated haplotypes followed by genotype rows.
- `Class I Alleles per Haplotype`, `DRB Alleles per Haplotype`, `DQ-DP Alleles per Haplotype`, and `Common Extended MHC Haplotypes`: reference/context sheets that describe historical labels and observed sharing patterns.

The prompt input should be built from genotype/read-count evidence only. Human-curated haplotype rows and historical haplotype tables are held out for evaluation and discrepancy analysis.

## Report Loci

The generalist prompt reports loci independently:

- `MHC-A`
- `MHC-B`
- `MHC-DRB`
- `MHC-DQA`
- `MHC-DQB`
- `MHC-DPA`
- `MHC-DPB`

Unlike the MCM workflow, `MHC-DQA`, `MHC-DQB`, `MHC-DPA`, and `MHC-DPB` remain separate report targets even when DQ/DP linkage is biologically useful context.

## Prompt Responsibilities

The prompt should act like a human curator performing de novo haplotype definition within one analysis:

1. Separate genotype rows by biologically relevant locus.
2. Identify samples that appear homozygous or near-homozygous at a report locus and use them as initial haplotype seeds.
3. Find heterozygous samples where one haplotype matches an existing seed, then infer the second haplotype from the remaining coherent genotype evidence.
4. Add newly inferred haplotypes to the working set and repeat until no additional defensible haplotypes can be defined.
5. Prefer high-read, repeatedly observed genotypes as defining evidence.
6. Treat low-read, inconsistently observed genotypes as possible dropout/carryover rather than mandatory haplotype-defining evidence.
7. Use DQ and DP adjacency cautiously as supporting context, not as a reason to collapse DQA/DQB/DPA/DPB into one report label.
8. Mark unresolved or over-complex cases rather than forcing a best-two call.

The prompt must output:

- de novo haplotype definitions by report locus,
- sample-level h1/h2 calls by report locus,
- genotype rows used to support each haplotype,
- confidence or review status,
- unresolved cases with concise reasons,
- evidence-to-haplotype assignments that can later drive Excel color coding.

## Naming Scheme

Prompt-defined names must be scalable and informative:

- Use a stable locus prefix, such as `A`, `B`, `DRB`, `DQA`, `DQB`, `DPA`, or `DPB`.
- For `MHC-A`, include an abbreviated `A1` allele where a strong `Mamu-A1*` or equivalent genotype defines the haplotype, for example `A-A1*002-H01` or a similarly compact form.
- For `MHC-B` and `MHC-DRB`, prefer a compact label based on the most informative high-read genotype pattern. The lowest-numbered allele can be useful, but the prompt should not assume that discovery order is biologically primary.
- For class II alpha/beta loci, name each locus-specific haplotype separately.
- Preserve a machine-readable mapping from prompt labels to supporting genotype evidence so labels can change without losing traceability.

## Evaluation Harness

The local evaluation workflow should be outside the app. It can live under a scratch or analysis path until performance is good enough to justify production design.

Allowed deterministic steps:

- extract workbook sheets into normalized genotype evidence,
- hold out human-curated calls as truth data,
- assemble prompt input batches,
- invoke the model,
- parse structured model output,
- map predicted labels to human labels after the run for scoring,
- compute concordance and discrepancy summaries.

Disallowed deterministic steps:

- inferring haplotype definitions,
- choosing h1/h2 calls,
- repairing model calls using hidden truth labels,
- applying hard-coded population-specific rules that are not present in the prompt.

## Scoring

Score each prompt iteration against the held-out human calls:

- per-locus slot concordance after optimal predicted-to-human label mapping,
- per-sample locus-pair concordance,
- homozygous versus heterozygous concordance,
- unresolved-call rate,
- false split rate where one human haplotype is split into multiple prompt haplotypes,
- false merge rate where multiple human haplotypes collapse into one prompt haplotype,
- discrepancy categories with representative samples and supporting genotypes.

The target is at least 90% reconstruction concordance without extra deterministic haplotyping logic.

## Iteration Loop

Each iteration should produce an auditable directory containing:

- prompt version,
- normalized prompt input,
- model output,
- parsed calls and definitions,
- score report,
- discrepancy notes,
- provenance for extraction, model invocation, parsing, and scoring.

After each iteration:

1. Review discrepancy categories.
2. Update only the prompt instructions or output schema guidance.
3. Rerun against the same held-out workbook evidence.
4. Compare score deltas and record why behavior improved or regressed.

If the outbred SNPRC benchmark does not reach reasonable performance after about five prompt iterations, run the same de novo prompt-development process on the MCM workbook without revealing M1-M7 labels to the prompt. The purpose of the fallback is to discover transferable prompt rules from a simpler seven-haplotype population, not to rebuild an MCM-specific prompt.

## Provenance

All generated evaluation artifacts are scientific data products and must satisfy Lungfish provenance expectations. Each iteration output directory must record:

- executed tool or workflow name and version,
- exact argv or reproducible command,
- explicit options and resolved defaults,
- runtime identity where applicable,
- input and output paths,
- checksums and file sizes,
- model/provider identity and generation parameters,
- prompt hash,
- exit status,
- wall time,
- useful stderr or failure diagnostics.

The provenance requirement applies even though this phase is not integrated into the app.

## Verification

The design is ready to implement when the first pass can be run locally and produces:

- a blinded genotype-evidence dataset from the SNPRC workbook,
- a held-out truth table from the human-curated workbook rows,
- a generalist prompt versioned independently from the MCM prompt,
- structured model output suitable for scoring,
- a concordance report and discrepancy review for iteration 1.

