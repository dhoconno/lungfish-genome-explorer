# Wave 1 Provenance Materialization Plan

## Scope

Address assembly execution only. Managed assembly must receive the exact dataset selected by the user, so virtual `.lungfishfastq` derivatives such as subset, trim, demuxed virtual, and orient-map bundles must be materialized before `ManagedAssemblyPipeline` sees them. Physical FASTQ/FASTA files, physical `.lungfishfastq` bundles, reference bundles, and already materialized full FASTQ/FASTA derivatives may continue to resolve to their stored sequence payloads.

## Implementation Plan

1. Add an assemble-specific input materialization helper that detects derived FASTQ bundles whose manifest resolves to a virtual state.
2. Update `lungfish assemble` to use the async materializing resolver before building `AssemblyRunRequest`, while preserving the existing synchronous resolver for non-virtual regression coverage.
3. Update the GUI managed assembly path to materialize virtual derived FASTQ inputs with `FASTQDerivativeService` before launching `ManagedAssemblyPipeline`.
4. Add canonical `.lungfish-provenance.json` writing for successful `lungfish assemble` output directories. Capture workflow/tool names and versions, top-level argv or reproducible command, options/defaults/resolved values, runtime identity with managed environment, original and execution input paths, checksums and sizes, primary output files, exit status, wall time, and stderr when present.
5. Keep legacy assembly result sidecars intact; the canonical provenance sidecar supplements them and satisfies the scientific provenance policy for CLI-created output directories.

## TDD Targets

- CLI resolver test: a virtual derived bundle should call a materializer and return the materialized FASTQ, not the root FASTQ.
- CLI resolver regression: physical bundles and full FASTA/full FASTQ derivatives should still resolve directly.
- CLI provenance test: a fake successful assembly result should write `.lungfish-provenance.json` with assemble workflow identity, argv, options, runtime identity, input/output checksums, exit status, and wall time.
- App helper test or source-level regression: GUI managed assembly should route virtual derived inputs through `FASTQDerivativeService` before `ManagedAssemblyPipeline`.

## Classify/Map Audit

`ClassifyCommand.resolveExecutionInputURLs` and `MapCommand.resolveExecutionInputURLs` use the same `SequenceInputResolver.resolvePrimarySequenceURL` fallback and therefore have the same virtual-derived risk. Both commands should move to a shared async sequence-input materialization helper that accepts a materializer dependency and workflow-specific topology rules. That helper should live below CLI/App-specific services only if it models decisions, not materialization mechanics; CLI can use `FASTQCLIMaterializer`, while the app can use `FASTQDerivativeService`.

This wave implements assemble first because assembly is the highest-priority blocker and has both CLI and GUI managed-pipeline call sites. Classify/map should be handled as a follow-up slice with separate tests because their paired-end, database/reference, and mapping-reference semantics need independent validation.
