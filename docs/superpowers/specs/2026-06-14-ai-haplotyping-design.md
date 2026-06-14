# AI Haplotype Analysis And Refinement Design

Date: 2026-06-14

Status: Ready for user review

## Summary

Lungfish currently supports deterministic haplotyping by applying explicit
definition sets to observed genotype calls. That path remains important, but it
does not capture the way an experienced analyst can inspect a genotype CSV,
notice cohort-level patterns, weigh dropout and overcall evidence, and produce a
reviewable Excel-style haplotype report even when no prior definition set exists.

This design adds AI-assisted haplotyping as a scientific data-producing workflow.
Users can choose no haplotyping, deterministic haplotyping, or AI haplotyping
during genotyping. Users can also run post-run AI refinement on an existing
`.lungfishgenotype` bundle, including bundles that already have deterministic or
manual review history.

AI haplotyping writes finalized active haplotype calls, but those calls are not
human overrides and are not silently trusted. Each AI-made or AI-changed call
starts with `needsReview` metadata, evidence references, counterevidence
references, confidence, and provenance. Human confirmation preserves the AI
source and adds reviewer identity. Human edits create normal manual overrides.

The implementation must satisfy the Lungfish provenance policy for scientific
data workflows. Missing provenance is a release-blocking defect.

## Goals

- Add explicit haplotyping modes for genotyping workflows:
  `none`, `deterministic`, and `ai`.
- Add post-run `genotype ai-refine` for existing `.lungfishgenotype` bundles.
- Reuse the existing AI provider/key infrastructure where appropriate, but use a
  dedicated scientific batch runner instead of the conversational AI Assistant.
- Persist AI-generated calls as active haplotype analysis revisions that remain
  manually reviewable.
- Preserve deterministic and manual history when AI refinement runs after a prior
  analysis.
- Generate or update `current.xlsx` as a managed workbook revision when AI calls
  become the active analysis.
- Store request, response, evidence, calls, validation, workbook, sidecar,
  manifest, and provenance artifacts under final bundle paths with checksums and
  sizes.
- Ensure CLI, GUI, imports, exports, and workbook flows preserve final-path
  provenance.

## Non-Goals

- Do not remove deterministic haplotyping.
- Do not treat AI output as a human `CallOverride`.
- Do not claim molecular phase, homozygosity, copy number, absence, inheritance,
  or clinical interpretation from genotype CSV evidence unless the evidence
  explicitly supports that claim.
- Do not send raw FASTQ, BAM, full reads, or unbounded sequence data to a remote
  AI provider in the MVP.
- Do not store raw API keys, key hashes, Authorization headers, provider request
  headers, or provider HTTP bodies in logs, artifacts, or provenance.
- Do not rely on re-calling a remote model as deterministic replay. Stored
  validated outputs and provenance are the reproducible record.

## Expert Review Outcome

Four independent review tracks examined the design: scientific haplotyping,
prompt/schema/evaluation, app/CLI/bundle wiring, and provenance/security. The
first review found blockers around treating AI output as manual overrides,
insufficient call states, underspecified structured output, and incomplete
provenance. The revised design resolves those blockers by adding active analysis
revisions, sidecar AI metadata, strict structured output, deterministic
map/reduce validation, transactional publishing, and release-blocking provenance
tests.

The final review pass accepted the design with refinements incorporated below.

## Approach Options

### Recommended: Dedicated AI Haplotype Workflow Runner

Add `AIHaplotypingRunner` in the workflow layer. It canonicalizes genotype
evidence, calls OpenAI or Anthropic through a structured provider adapter,
validates an inert AI patch, and transactionally publishes an active haplotype
analysis revision plus workbook/sidecar/provenance artifacts.

This preserves the existing AI provider/key code while avoiding the chat
assistant's conversational logging, fallback, and free-form response behavior.
It also gives CLI and GUI one shared scientific mutation path.

### Minimal: AI During Genotyping Only

Add AI mode only to the genotyping pipeline. This would be faster, but it would
not support the important workflow of AI refinement after deterministic/manual
review, and it would force active-analysis revision semantics into the pipeline
before the standalone mutation path is tested.

### Rejected: Extend The AI Assistant Tool Registry

The AI Assistant is useful for VCF/gene exploration, but it is intentionally
conversational. It logs prompt previews and supports multi-round natural-language
tool loops. Scientific data mutation needs a bounded batch runner, strict
structured output, transactional rollback, and canonical provenance.

## User Workflows

### Genotyping-Time Haplotyping

The genotyping dialog and CLI expose:

```bash
lungfish-cli fastq genotype ... --haplotyping-mode none
lungfish-cli fastq genotype ... --haplotyping-mode deterministic --haplotype-definition <id-or-path>
lungfish-cli fastq genotype ... --haplotyping-mode ai --ai-provider openai --ai-model <model> --remote-ai-consent
```

Compatibility rules:

- Omitted mode plus `--haplotype-definition` preserves legacy deterministic
  behavior.
- Omitted mode without a definition preserves legacy no-haplotyping behavior.
- `--haplotyping-mode none --haplotype-definition ...` is rejected.
- `--haplotyping-mode deterministic` requires a resolvable definition.
- `--haplotyping-mode ai` requires provider, model, credential source, and
  explicit remote AI consent.

### Post-Run AI Refinement

The post-run CLI surface is:

```bash
lungfish-cli genotype ai-refine --bundle <bundle> --ai-provider openai --ai-model <model> --remote-ai-consent
```

AI refinement can run after:

- a bundle with no prior haplotype analysis, using raw genotype evidence as its
  predecessor state;
- a deterministic haplotype analysis, using that analysis as the predecessor;
- a prior AI revision or manually reviewed current state, using the active
  analysis revision and sidecar review metadata as predecessor context.

The app exposes the post-run action near the existing genotype review/current
workbook update surfaces. It shells through the CLI mutation path, reports
progress through Operation Center, and reloads the bundle after success.

## Architecture

### Core Components

- `AIHaplotypingRunner`: workflow-layer orchestrator for canonical evidence,
  provider calls, validation, artifact staging, and publishing.
- `AIHaplotypingEvidenceBuilder`: converts genotype CSV/bundle data into a
  stable evidence registry.
- `AIHaplotypingPromptTemplate`: versioned prompts for `aiDiscovery` and
  `aiRefinement`.
- `StructuredAIProvider`: extension or adapter around existing providers that
  supports nested JSON schemas, strict result requests, and provider attempt
  metadata.
- `AIHaplotypingPatchValidator`: validates model output against the evidence
  registry and existing bundle state.
- `AIHaplotypingPublisher`: transactionally publishes active analysis, sidecar,
  workbook revision, manifest, and provenance.

### Provider Boundary

The existing `AIProvider` implementations are reusable for authentication and
HTTP transport, but the current `AIToolDefinition` shape is too shallow for this
workflow. The implementation must add a structured-result capability that
supports nested JSON schema and a forced single result channel.

OpenAI requirements:

- Use strict JSON schema response format for the haplotyping result.
- Add request-payload tests that prove the workflow does not fall back to plain
  chat/text response mode.

Anthropic requirements:

- Use exactly one allowed result tool.
- Force `tool_choice` to that result tool.
- Reject responses with text-only terminal output, extra content blocks, missing
  tool use, or multiple result tools.

Both providers return attempt metadata for provenance: provider, model, endpoint
or API version, credential source, whether an API key was available, request ID
if returned, status/stop reason, token usage when available, sanitized error
category, and retry/fallback position.

## Evidence And Prompt Flow

The model does not receive raw CSV text blindly. Lungfish first builds a
canonical evidence registry with stable IDs. Evidence includes:

- sample, locus, genotype, and observation IDs;
- read counts, unique read counts, alignment counts, support fractions, and
  thresholds;
- per-locus assayability and coverage summaries;
- cohort recurrence and co-occurrence summaries;
- deterministic calls when present;
- manual review/current state when present;
- omitted low-support alleles and dropout/overcall signals.

Chunking is deterministic:

1. Partition by locus and connected sample/genotype evidence clusters.
2. Give each chunk a closed evidence registry.
3. Require each chunk result to reference only IDs in that registry.
4. Reduce chunk patches deterministically.
5. Reject hallucinated IDs, conflicting calls, duplicate patch operations,
   missing counterevidence, cross-chunk definition collisions, malformed schema,
   truncated responses, or text-only responses.

The model output is an inert patch until local validation succeeds.

## Structured Result Schema

The model returns a schema-constrained payload. The implementation must encode
the exact JSON schema with `additionalProperties: false`, bounded arrays, enums,
and no model-supplied filesystem paths.

Top-level fields:

- `schemaVersion`
- `run`
- `registryDigest`
- `inputSnapshotDigest`
- `chunkID` for chunk outputs
- `discoveredDefinitions`
- `calls`
- `evidence`
- `counterevidence`
- `patch`
- `warnings`

### Run Metadata

`run` includes:

- `mode`: `aiDiscovery` or `aiRefinement`
- `promptTemplateID`
- `promptTemplateVersion`
- `promptHash`
- `provider`
- `model`
- `generationParameters`
- `parentRevisionID`
- `registryDigest`
- `inputSnapshotDigest`

### Proposed Definitions

`discoveredDefinitions` are provisional evidence records, not active managed
definition sets. The model may suggest labels. Lungfish mints stable provisional
IDs after validation.

Fields include:

- `provisionalDefinitionID`
- `suggestedLabel`
- `locus`
- `definitionStatus`: `candidate`, `ambiguous`, `rejected`
- `supportEvidenceRefs`
- `counterevidenceRefs`
- `cohortSupport`

Promotion to a managed haplotype definition is a separate future workflow
through the haplotype definition manager.

### Calls

Each AI call includes:

- `patchOpID`
- `sample`
- `locus`
- `slot`
- `haplotypeLabel`
- `normalizedFamily`
- `source`: `ai`
- `sourceState`: `raw`, `deterministic`, `manual`, or `current`
- `reviewState`: `needsReview`
- `callState`
- `confidenceTier`
- `supportEvidenceRefs`
- `counterevidenceRefs`
- `alternates`
- `rationaleCode`
- `rationale`

`callState` enum:

- `called`
- `novel_candidate`
- `ambiguous_tie`
- `insufficient_evidence`
- `low_support_or_dropout`
- `conflicts_current`
- `conflicts_manual`
- `not_assayed`
- `out_of_scope`
- `unresolved`

Validation blocks claims of molecular phase, absence, homozygosity, copy number,
or inheritance unless the evidence registry contains adequate supporting assay
evidence.

## Active Analysis Revision Model

Existing bundles have one `haplotypeAnalysisPath`. The new model keeps that path
as the active analysis artifact for old-reader compatibility and adds optional
revision metadata.

Manifest additions:

- `activeHaplotypeAnalysisRevisionID: String?`
- `haplotypeAnalysisRevisions: [ONTGenotypeHaplotypeAnalysisRevision]?`

Revision fields:

- `id: String`
- `method: deterministic | aiDiscovery | aiRefinement`
- `path: String`
- `predecessorID: String?`
- `predecessorPath: String?`
- `createdAt: String`
- `reviewState: unreviewed | needsReview | reviewed | confirmed | rejected`
- `sha256: String`
- `sizeBytes: Int64`
- `provenancePath: String`
- `provider: String?`
- `model: String?`
- `promptTemplateID: String?`
- `promptTemplateVersion: String?`
- `promptHash: String?`
- `evidenceSnapshotPath: String?`
- `validationReportPath: String?`

For newly written AI revisions, all revision metadata is mandatory. The manifest
field itself is optional only for backward compatibility.

Old bundles with only `haplotypeAnalysisPath` load as legacy active bundles. On
the first managed analysis-revision write, Lungfish synthesizes a deterministic
legacy revision record for the existing path before appending the new revision.

## Sidecar Review Metadata

AI metadata is separate from human `callOverrides` and
`manualHaplotypeAssignments`.

Add sidecar fields:

- `aiHaplotypeReviews: [AIHaplotypeReviewEntry]`
- `activeAIHaplotypeReviewID: String?`

Review entry fields:

- `id`
- `analysisRevisionID`
- `createdAt`
- `source: ai`
- `reviewState`
- `callReviews`
- `evidenceSnapshotPath`
- `callsPath`
- `validationReportPath`
- `provenancePath`

Each call review includes sample, locus, slot, call state, confidence tier,
evidence refs, counterevidence refs, and reviewer decisions.

Human confirmation preserves `source=ai` and the AI provenance reference, then
adds reviewer identity, timestamp, and decision. Human edits to the call create
normal manual overrides and audit entries.

## Workbook Revisions

Add a workbook revision role:

- `aiRefinement`

The AI workflow updates `current.xlsx` from the active AI analysis and records a
workbook revision linked to the same provenance run. Existing import, restore,
and manual override roles remain unchanged.

Exports that follow `haplotypeAnalysisPath` must carry `source`, `reviewState`,
and `callState` through the exported workbook/LabKey data, or require an explicit
option to export unreviewed AI calls as final-facing output. They must not
silently recompute deterministic calls over an active persisted AI analysis.

## Resolver Policy

Add a source-aware resolver policy:

- `persistedActive`: use the active persisted analysis revision.
- `deterministicRecompute`: recompute from selected deterministic definitions.
- `legacyCompatible`: use persisted active when present, otherwise preserve
  current fallback behavior.

GUI and export defaults use `persistedActive` for bundles with active AI
analysis. Deterministic recompute is available only through explicit user/CLI
selection.

## CLI And App Integration

### CLI

Add:

```bash
lungfish-cli genotype ai-refine --bundle <bundle>
```

Options include provider, model, credential source, remote consent, analysis
source policy, and unreviewed-export behavior where relevant.

The CLI must never accept raw API keys as arguments. It records only non-secret
credential source metadata such as `environment:OPENAI_API_KEY` or
`keychain:ai.openai.apiKey`.

### App

The genotyping dialog adds a haplotyping mode control. AI mode is visible only
for supported workflows and disabled until provider/model/key source and remote
consent requirements are satisfied.

The app forwards mode/provider/model/consent through existing CLI invocation
builders and workflow execution. Post-run AI refinement uses a service parallel
to the current workbook update execution service, but shells through
`lungfish-cli genotype ai-refine --bundle`.

## Provenance

AI haplotyping and AI refinement are scientific data-writing workflows. They
write canonical `ProvenanceEnvelope` records and are registered in the scientific
provenance policy as data-writing, either through subcommand-aware policy or by
marking `genotype` data-writing once `ai-refine` ships.

Successful provenance must include:

- workflow/tool name and Lungfish version;
- exact argv and durable replay argv;
- reproducible command;
- resolved options and defaults;
- runtime identity;
- provider, model ID, endpoint/API version, request ID if available;
- credential source and API key availability without key values or key hashes;
- sampling parameters/defaults;
- provider fallback sequence with per-attempt metadata;
- stop reason and token usage when available;
- prompt template ID/version/hash;
- evidence selector and validation result;
- final input/output paths;
- checksums and sizes for request, response, calls, evidence, validation,
  active analysis, sidecar, manifest, current workbook, and workbook provenance;
- exit status, wall time, and useful sanitized stderr.

Failed runs:

- If no provider request was sent and no scientific artifact was retained, the
  workflow reports the failure without bundle mutation.
- If a prompt/request was sent or retained, Lungfish writes nonzero failed-run
  provenance and retained failed artifacts under a failed run directory.
- Failed runs do not create a current workbook revision, active analysis
  revision, or manifest update.

## Privacy And Retained Artifacts

For finalized AI calls, Lungfish retains minimized request, structured response,
calls, evidence, and validation artifacts in the bundle. Hash-only retention is
not enough for this scientific workflow.

Retained artifacts use allowlisted schemas. They must not include raw API keys,
key hashes, Authorization headers, provider HTTP headers, raw provider HTTP
bodies, hidden chain-of-thought, prompt previews in logs, or unbounded sequence
payloads. Prompt and response artifacts contain only the minimized scientific
request/structured result needed for audit.

Operation Center and OS logs must not include prompts, responses, evidence
bodies, provider bodies, provider headers, or raw tool payloads.

## Transactionality

AI refinement publishes atomically:

1. Stage request/evidence artifacts under a bundle-owned staging directory.
2. Call provider and stage the allowlisted structured model response artifact.
3. Validate schema and semantic constraints.
4. Stage normalized calls, validation report, active analysis JSON, sidecar,
   patched current workbook, manifest, workbook revision, and provenance.
5. Verify staged checksums and sizes.
6. Publish final artifacts with atomic renames.
7. Publish manifest last.

If any step fails, restore the previous manifest, active analysis, sidecar, and
current workbook state. No manifest revision may point at missing or incomplete
provenance.

## Error Handling

Provider missing-key, missing-consent, rate-limit, timeout, context overflow,
refusal, malformed response, text-only response, schema mismatch, hallucinated
IDs, missing evidence, missing counterevidence, low confidence, or
cross-chunk conflicts do not create active calls.

The user sees an actionable failure. If a provider request was sent, failed-run
provenance records the sanitized failure.

## Testing Plan

Provider and schema tests:

- OpenAI request payload uses strict JSON schema response format.
- Anthropic request forces exactly one result tool and rejects text-only or extra
  content responses.
- Nested schema rejects hallucinated samples/loci/evidence IDs, duplicate slots,
  missing counterevidence, malformed nested objects, truncated responses, and
  model-supplied paths.
- OpenAI and Anthropic mocked responses produce equivalent validated patches for
  the same evidence registry.

Scientific fixtures:

- Definition-free cohort fixture with clear candidate haplotype grouping.
- Deterministic baseline fixture where AI refinement preserves high-confidence
  deterministic calls.
- Dropout fixture with expected `low_support_or_dropout`.
- Overcall fixture with expected ambiguity or unresolved state.
- Mixed class II linkage fixture.
- Novel candidate fixture with repeated genotype pattern and provisional label.

Bundle and resolver tests:

- Manifest round-trips `activeHaplotypeAnalysisRevisionID` and
  `haplotypeAnalysisRevisions`.
- Old bundles synthesize or preserve legacy active revision behavior.
- `haplotypeAnalysisPath` points at the active AI artifact after AI refinement.
- Source-aware resolver uses persisted active AI analysis unless deterministic
  recompute is explicitly requested.
- Exports carry or gate AI `source`, `reviewState`, and `callState`.

CLI and app tests:

- `none + --haplotype-definition` rejects.
- Omitted mode plus definition resolves to deterministic.
- AI mode requires provider/model/key source and remote consent.
- App dialog forwards mode/provider/model/consent to CLI builders.
- Post-run app operation invokes `genotype ai-refine --bundle` and reloads.

Provenance and security tests:

- Successful AI refinement provenance includes required AI/provider metadata,
  final bundle paths, checksums/sizes, runtime, argv/replay argv, exit status,
  wall time, and sanitized stderr.
- Secret scans cover provenance, retained artifacts, Operation Center logs, and
  error diagnostics.
- Provider failure, invalid schema, and provenance-write failure do not mutate
  manifest/current workbook/sidecar/active analysis.
- GUI and CLI staging paths are rehydrated to final stored payload paths.
- Current workbook revision links to AI provenance and predecessor revision.

## Rollout

Implement in phases:

1. Schema and resolver foundations.
2. Structured AI provider capability and tests.
3. AI evidence builder, prompt templates, validator, and mocked provider evals.
4. `genotype ai-refine` transactional CLI path.
5. Genotyping-time AI mode.
6. App workflow mode selector and post-run refinement action.
7. Export/review polish and release-gate tests.

Deterministic haplotyping remains the default stable path until AI performance
and review outcomes justify changing defaults in a future version.
