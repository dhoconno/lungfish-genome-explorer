# AI Haplotyping Knowledge Pack Design

Date: 2026-06-15

Status: Ready for user review

## Summary

The first AI haplotyping implementation is wired, but its built-in prompts are
too short to simulate a trained macaque MHC analyst. The next prompt iteration
should teach the model how to reason from published macaque MHC immunogenetics,
human analyst examples, assay resolution, population priors, marker
informativeness, and cross-population haplotype relationships.

This design adds a versioned macaque MHC knowledge pack and a curated example
case layer to AI haplotyping. Non-computational staff edit simple CSV and
Markdown source files. Lungfish validates and compiles those files into a
deterministic JSON artifact that the AI runner injects with each request. The
prompt stays procedural: it instructs the model to use the supplied knowledge
pack and examples, cite their IDs, and keep output reviewable.

The v1 knowledge source of truth is published literature and de-identified
historical haplotyping report examples. Sequence databases such as IPD-MHC are
deferred to a later layer because many current genotype labels are deliberate
human-readable simplifications of underlying sequence variation.

## Goals

- Improve AI haplotyping prompts so they model macaque MHC analyst intuition.
- Use published papers as the first authority layer for biological assertions.
- Use de-identified prior reports as examples of analyst decision behavior and
  reporting style.
- Make knowledge-pack updates approachable for non-computational staff.
- Keep population labels as priors, not hard biological barriers.
- Distinguish sequence variation from haplotype novelty.
- Account for assay resolution: short MiSeq exon 2 amplicons, partial cDNA,
  full-length cDNA, full-length genomic data, and unknown/intermediate assays.
- Avoid proliferation of haplotype labels from isolated full-length sequence
  variants that do not change practical matching or study-inclusion decisions.
- Require AI output to cite both sample evidence IDs and knowledge/example IDs.
- Preserve reproducibility provenance for prompt templates, knowledge packs,
  examples, and compiled source checksums.

## Non-Goals

- Do not replace curated haplotype definitions with free-form AI memory.
- Do not import raw sequence databases into v1.
- Do not embed private reports, client workbooks, sample IDs, or identifying
  content in built-in examples.
- Do not make a full in-app knowledge editor in v1.
- Do not require non-computational staff to edit JSON, Swift, or prompt source
  directly.
- Do not treat AI-discovered haplotypes as accepted managed definitions without
  human review and a later definition-curation workflow.

## Current Context

The current built-in prompt registry has two short templates:

- `lungfish.ai-haplotyping.discovery`
- `lungfish.ai-haplotyping.refinement`

Both currently instruct the model to use supplied evidence and cite evidence
IDs, but they do not contain domain-specific macaque MHC reasoning.

The current evidence registry contains samples, loci, observed genotype labels,
read/alignment support, current calls, and manual review evidence. It does not
yet pass explicit assay-resolution context or a biological knowledge artifact.

The current haplotype definition model is intentionally simple:

```text
definition set -> locus definitions -> haplotypes -> diagnostic allele tokens
```

That shape is digestible and matches legacy analyst workflows, but it cannot
directly express genomic block structure, recombination priors,
cross-population homology, marker informativeness, or assertion-level source
citations.

## Source Authority Model

V1 uses three authority layers.

### Published Knowledge Layer

Published papers are the first biological authority layer. They define broad
MHC organization, population frameworks, known haplotypes, recombination
intuition, assay limitations, and cross-population/species relationships.

Initial source anchors:

- Karl et al. 2023 Genome Research, complete M3 MHC haplotype sequence.
- Wiseman, Karl, and O'Connor ILAR review on macaque MHC genetics.
- O'Connor et al. 2007 MCM class II haplotype characterization.
- Budde et al. 2010 MCM class I haplotype characterization.
- O'Connor/Wiseman/Karl-authored rhesus haplotype papers that define
  abbreviated Mamu-A and Mamu-B reporting conventions.

The Karl et al. M3 paper is a structural teaching reference. It should teach the
prompt about landmarks and broad macaque MHC organization, not imply that all
haplotypes should be forced to look like M3.

### Curated Example Layer

Historical reports teach analyst behavior, not biological truth. They calibrate
how analysts decide between:

- known framework assignment;
- known haplotype with a novel variant;
- candidate recombinant;
- candidate novel haplotype;
- insufficient resolution;
- manual review required.

Examples must be de-identified before use. Raw private workbooks and client
reports must not be embedded into built-in prompt assets.

### Sequence Database Layer

Sequence databases and allele repositories are deferred. They will eventually
help connect simplified genotype labels to underlying sequences, but v1 should
avoid letting raw sequence variation overwhelm the practical haplotype
frameworks used by transplantation and infectious-disease researchers.

## Biological Reasoning Model

### Macaque MHC Is Not Human HLA With Renamed Loci

The prompt must understand that human HLA and macaque MHC have important
differences. Human class I haplotypes are usually reasoned around HLA-A, HLA-B,
and HLA-C. Macaque MHC class I regions have duplicated and rearranged MHC-A and
MHC-B genes, variable gene content, pseudogenes, and expression differences.

Class II organization is more conserved, but interpretation still depends on
species, population, assay resolution, and historical naming conventions.

### M3 As Structural Reference

The M3 genomic haplotype is useful because it describes landmarks and broad
organization across the macaque MHC. It should guide priors such as:

- DP and DQ are nearby class II neighborhoods.
- In MCM, discordant DP and DQ haplotypes are unlikely without rare
  recombination or technical/interpretive issues.
- Class I, class II, and recombination blocks should be reasoned about as linked
  genomic regions, not independent row labels.

### Population Priors

Population labels constrain priors. They do not create hard biological walls.

MCM is a well-studied bottleneck population with a constrained M1-M7 framework.
New full extended MCM haplotypes should be rare and require strong evidence.

Other simple-by-history populations may also have a small number of recurring
haplotypes, but the curated framework may be incomplete. Caribbean African
green monkeys are a motivating example for future support.

Complex or sparsely defined populations, such as Cambodian cynomolgus macaques,
should have a higher novelty prior. For these populations, novel haplotypes or
local provisional frameworks may be common, but the prompt should avoid
overclaiming formal labels when literature support is sparse.

### Cross-Population And Cross-Species Relationships

Different populations and species can share markers, ancestral haplotype
blocks, homologous loci, or functionally similar alleles. The prompt should use
relationship evidence to avoid treating MCM, rhesus, and other macaques as
isolated bins.

Relationship evidence can support annotations such as:

- `homologous_to`
- `shares_marker_with`
- `M3-like`
- `ancestral_block_similarity`
- `functional_similarity`

Formal labels should follow the relevant population-specific source framework
unless the knowledge pack explicitly says the same named label is established in
that population.

### Sequence Variation Versus Haplotype Novelty

The prompt must distinguish a novel genotype or sequence variant from a novel
haplotype.

Full-length sequencing exposes many subtle variants. Isolated full-length
variants should usually be annotated within an existing haplotype unless they
change linked marker structure, recur across samples, affect practical
matching/cohort decisions, or are identified by a curated rule as
haplotype-defining.

For example, a novel B22-like sequence that is not part of an existing
definition should not by itself split a known haplotype if the rest of the
haplotype evidence matches the known framework and the difference is unlikely
to alter transplant matching or infectious-disease cohort selection.

MiSeq exon 2 combinations can be more haplotype-informative in historical
definition frameworks because those definitions were built from diagnostic
amplicon marker combinations. The prompt should still respect that exon 2 data
cannot prove full-gene or full-block structure.

## Prompt Behavior

The AI should act like a trainee macaque MHC analyst using supplied evidence and
curated references.

For each run, the prompt receives:

- sample evidence registry;
- run context;
- compiled knowledge pack;
- selected relevant examples;
- expected run metadata;
- structured output schema.

Decision flow:

1. Identify species, population, workflow kind, assay ID, assay resolution, and
   whether the population is well-studied, simple-by-history, complex, or
   sparsely defined.
2. Fit known curated frameworks first.
3. Weight evidence by marker informativeness and assay resolution.
4. Separate sequence variation from haplotype novelty.
5. Use resolution-aware confidence.
6. Use cross-population/species relationships as similarity evidence, not
   automatic label transfer.
7. Emit reviewable calls, provisional definitions, confidence tiers, warnings,
   and rationales.

For MCM, the prompt should try M1-M7 and known recombinant interpretations
before novelty. For rhesus or other macaques, it should use the curated
framework when available. For sparse populations, it should allow provisional
new haplotypes more readily, but still cite why known frameworks do not fit.

## Editable Knowledge-Pack Sources

Staff-editable source files should be plain CSV and Markdown. They should live
under a dedicated knowledge-pack source directory, for example:

```text
Resources/AIHaplotypingKnowledge/macaque-mhc/v1/
  sources.csv
  population_priors.csv
  haplotype_frameworks.csv
  marker_informativeness.csv
  haplotype_relationships.csv
  assay_resolution_rules.csv
  analyst_decision_rules.md
  examples/
```

Exact location can be finalized during implementation, but the source files
should not require editing compiled JSON.

### `sources.csv`

Records papers and other curated references.

Required columns:

```text
source_id,citation,doi,pmid,authority_tier,notes
```

### `population_priors.csv`

Records the prior expectation for a species/population context.

Example columns:

```text
population_id,species,population_label,simplicity_level,novelty_prior,recombination_prior,default_framework_id,source_ids,curator_note
```

Example row concept:

```text
mcm,Macaca fascicularis,Mauritian cynomolgus macaque,well_studied_bottleneck,very_low,rare_between_class_II_subregions,mcm-m1-m7,paper:wiseman-ilar-2013,Known M1-M7 framework first.
```

### `haplotype_frameworks.csv`

Records curated named frameworks such as MCM M1-M7, rhesus abbreviated
Mamu-A/Mamu-B frameworks, and future simple-population frameworks.

Example columns:

```text
framework_id,population_id,label,framework_type,known_labels,novelty_policy,source_ids,curator_note
```

### `marker_informativeness.csv`

Records how strongly markers should influence haplotype splitting.

Example columns:

```text
marker_id,population_id,assay_resolution,locus_or_gene,marker_pattern,informativeness_tier,split_haplotype_default,source_ids,curator_note
```

Allowed informativeness tiers:

- `block_defining`
- `supporting`
- `variant_annotation`
- `low_weight_or_noisy`

Example row concepts:

```text
mafa-b22-full-length,mcm,full_length_genomic,MHC-B,B22-like,variant_annotation,no,paper:curated-example,Novel B22-like variant alone should annotate, not split.
dp-dq-discordance-mcm,mcm,short_exon_amplicon,MHC-DP/MHC-DQ,discordant_family,block_defining_if_recurrent,review,paper:karl-2023,DP/DQ discordance in MCM suggests rare recombination or review issue.
```

### `haplotype_relationships.csv`

Records overlap across populations or species.

Example columns:

```text
relationship_id,entity_a,entity_b,relationship_type,scope,confidence,source_ids,curator_note
```

Allowed relationship types:

- `same_label`
- `homologous_block`
- `shared_marker`
- `ancestral_similarity`
- `functional_similarity`

### `assay_resolution_rules.csv`

Records what an assay can support.

Example columns:

```text
assay_id,assay_resolution,can_support,should_not_claim,source_ids,curator_note
```

Allowed resolution classes:

- `short_exon_amplicon`
- `partial_cDNA`
- `full_length_cDNA`
- `full_length_genomic`
- `intermediate`
- `unknown`

### `analyst_decision_rules.md`

Markdown captures nuanced analyst instructions that do not fit cleanly into
tables. Each rule should have a stable heading ID that the compiler can turn
into a knowledge assertion ID.

## Example Case Layer

Example cases should be de-identified YAML or CSV-backed records, not raw
private reports.

Example file names:

```text
examples/
  mcm_known_m1_m3.case.yaml
  mcm_dp_dq_discordance_review.case.yaml
  mcm_novel_b22_variant_no_split.case.yaml
  cambodian_cyno_candidate_novel_haplotype.case.yaml
```

Example schema:

```text
case_id
population_id
species
assay_resolution
input_pattern_summary
human_final_call
human_rationale
decision_type
why_not_alternative
privacy_status
source_report_id
curator_notes
```

Allowed decision types:

- `known_framework_assignment`
- `known_haplotype_with_variant`
- `candidate_recombinant`
- `candidate_novel_haplotype`
- `insufficient_resolution`
- `manual_review_required`

The runner should not inject every example. It should select a small relevant
set based on population, assay resolution, observed decision risk, and prompt
budget. Example selection must be deterministic and recorded in provenance.

Examples should also form an evaluation suite. A de-identified input pattern can
be replayed through the prompt, and the output should match the expected
decision type, uncertainty posture, and rationale style.

## Compiled Runtime Artifact

The compiler produces a deterministic JSON artifact:

```text
MacaqueMHCKnowledgePack
  id
  version
  sources[]
  populationPriors[]
  haplotypeFrameworks[]
  markerInformativeness[]
  haplotypeRelationships[]
  assayResolutionRules[]
  analystDecisionRules[]
  digest
```

Each assertion should include:

```text
assertion_id
source_ids
authority_tier
confidence
curator_note
```

The compiled pack should include enough context for the prompt to reason, but
not full private examples or unbounded text.

## AI Prompt Input

The AI runner should expand the prompt input from:

```text
chunkID
expectedRun
evidenceRegistry
```

to:

```text
chunkID
expectedRun
runContext
knowledgePack
relevantExamples
evidenceRegistry
```

`runContext` should include:

```text
species
population
assayID
assayResolution
workflowKind
definitionSetID
definitionSetDigest
activeFrameworkID
```

If a project or user definition set is active, the runner should include a
compact definition snapshot or digest so the model can avoid rediscovering
known local definitions.

## Prompt Template V2

The v2 prompt should be explicit and procedural. It should include rules like:

- Use only supplied evidence, knowledge-pack assertions, and selected examples.
- Prefer curated known frameworks before proposing novelty.
- Treat population as a prior, not a hard biological barrier.
- Distinguish novel sequence variation from novel haplotypes.
- Do not split haplotypes from isolated full-length variants unless
  informativeness and recurrence evidence support a meaningful split.
- Use assay-resolution rules to limit claims.
- Mark novel haplotypes as provisional unless the knowledge pack establishes the
  name and framework.
- Cite evidence IDs for sample observations.
- Cite knowledge assertion IDs for biological reasoning.
- Cite example case IDs when an example materially influenced the decision.
- Produce outputs for human review, not automatic final scientific conclusions.

The prompt should remain short enough that most biological detail lives in the
compiled knowledge pack.

## Structured Output And Validation

The structured result schema should gain citation fields or reuse existing
rationale fields in a stricter way.

Each proposed call or discovered definition must cite:

- valid sample evidence IDs;
- relevant knowledge assertion IDs when making biological claims;
- relevant example case IDs when selected examples influence the decision.

The validator should reject:

- hallucinated evidence IDs;
- hallucinated knowledge assertion IDs;
- hallucinated example case IDs;
- formal novel haplotype labels when the knowledge pack requires provisional
  review;
- unsupported claims that exceed assay resolution;
- MCM novelty calls that bypass known-framework and recombinant checks;
- isolated full-length variants treated as full haplotype splits without a
  supporting rule.

Some biological checks can start as warnings in v1 where strict validation is
not yet practical, but malformed citations and missing required IDs should be
blocking.

## Curation And Validation

The knowledge compiler should produce plain-language errors and warnings.

Validation checks:

- Required columns are present.
- Every `source_id` exists.
- Controlled vocabulary values are valid.
- Population names, assay IDs, and resolution classes are known.
- Relationship types are valid.
- Rules that permit novel haplotype naming include population context, assay
  resolution, evidence threshold, and review state.
- MCM-specific rules default to known framework first.
- Full-length variant rules avoid automatic haplotype proliferation.
- Example cases are marked with privacy status and do not contain obvious raw
  identifiers.

Example compile report:

```text
Compiled macaque-mhc-knowledge 2026-06-15.1
Sources: 8
Population priors: 12
Frameworks: 4
Marker rules: 87
Relationship assertions: 32
Examples: 14
Warnings: 3
Errors: 0
```

Errors block use. Warnings are recorded and may be accepted when the missing
coverage is expected, such as sparse Cambodian cynomolgus marker rules.

## Provenance

AI haplotyping provenance must record:

- prompt template ID, version, and hash;
- knowledge pack ID, version, and digest;
- source file paths, checksums, and sizes;
- compiler version and compile report;
- selected example case IDs and example-pack digest;
- run context, including assay resolution and population;
- provider, model, temperature, max output tokens, and chunking options;
- final evidence snapshot path;
- validation report path;
- final output paths, checksums, file sizes, exit status, wall time, and useful
  stderr.

Provenance must not include raw API keys or private report contents.

## Testing Plan

Knowledge compiler tests:

- Accept valid CSV/Markdown sources.
- Reject unknown source IDs.
- Reject invalid controlled vocabulary values.
- Reject MCM novelty rules without review gates.
- Reject examples without privacy status.
- Produce stable JSON and digest for the same inputs.

Prompt rendering tests:

- Render discovery and refinement prompts with `runContext`, knowledge pack,
  selected examples, and evidence registry.
- Include assay resolution explicitly.
- Include knowledge pack ID/version/digest.
- Do not include raw private report text.

Example selection tests:

- Select MCM examples for MCM runs.
- Select full-length variant/no-split examples when isolated full-length novel
  markers are present.
- Select sparse-population novelty examples for complex or unknown populations.
- Keep selection deterministic under prompt budget limits.

Validator tests:

- Reject hallucinated knowledge IDs.
- Reject hallucinated example IDs.
- Warn or reject overclaiming beyond assay resolution.
- Reject isolated annotation-level full-length variants being emitted as new
  full haplotypes without a supporting rule.
- Reject MCM `M8`-style output unless a knowledge rule explicitly permits
  provisional novelty.

Regression/evaluation tests:

- Replay de-identified historical cases and compare expected decision type,
  uncertainty posture, and citation behavior.
- Include cases where a novel sequence variant should remain attached to a known
  haplotype.
- Include cases where a sparse-population pattern should become a candidate
  novel haplotype.

## Rollout

1. Add knowledge-pack source directory and v1 schema.
2. Add compiler and validator with CLI or test harness entry point.
3. Add a minimal built-in v1 pack from published papers.
4. Add de-identified example case schema and selection logic.
5. Expand AI runner prompt input with `runContext`, `knowledgePack`, and
   `relevantExamples`.
6. Add prompt template v2 for discovery and refinement.
7. Add citation validation for knowledge and example IDs.
8. Add provenance fields for knowledge pack and examples.
9. Add evaluator cases from de-identified historical reports.

## Open Implementation Decisions

- The source directory should be under a repository-tracked resource path; the
  implementation plan should choose the exact SwiftPM/Xcode packaging path that
  keeps the editable CSV/Markdown files visible to maintainers and ships the
  compiled JSON with the app/CLI.
- Knowledge compilation should be available as a CLI command or script for
  curators and tests; the implementation plan should decide whether release
  builds also compile automatically or consume a checked-in compiled artifact.
- Exact structured-output field names for knowledge and example citations.
- How much of active project/user definition sets should be injected versus
  represented by digest and summary.
- Whether v1 validator rejects assay overclaims or records warnings for human
  review while examples mature.

## User Review Notes

The approved v1 direction is source-backed and staff-editable. It should remain
pragmatic: enough structure to make AI behavior reproducible and reviewable,
without trying to solve all macaque MHC nomenclature and sequence-database
integration in the first prompt revision.
