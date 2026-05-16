# Wave 1 Provenance Materialization Plan

## Scope

Worker A owns the assembly path only in this wave. The blocking defect is that managed assembly can receive a derived virtual FASTQ bundle and then fall back to the root payload through `SequenceInputResolver`, changing the scientific dataset under analysis. `lungfish assemble` also needs canonical reproducibility provenance for the output directory it creates.

## Implementation Plan

1. Add assembly-specific virtual FASTQ detection in workflow code so both CLI and app can tell when an input bundle must be materialized before execution.
2. Add an async CLI assembly input resolver that materializes virtual derived `.lungfishfastq` bundles with `FASTQCLIMaterializer`; keep physical bundles, full materialized derivatives, FASTA bundles, reference bundles, and raw sequence files on the existing direct path.
3. Update the GUI managed assembly runner to materialize virtual derived FASTQ inputs before calling `ManagedAssemblyPipeline`, using `FASTQDerivativeService` and preserving the existing request fields.
4. Write canonical `.lungfish-provenance.json` for successful `lungfish assemble` outputs, including workflow/tool versions, exact argv, resolved options/defaults, runtime identity, input/output descriptors with checksums and sizes, exit status, wall time, and useful stderr when supplied.
5. Audit classify/map derived FASTQ handling. Both currently use `SequenceInputResolver.resolvePrimarySequenceURL` through local `resolveExecutionInputURLs` helpers and can therefore inherit the same root-payload fallback for virtual derived FASTQ bundles. A follow-up should extract the async materializing resolver into a shared helper with workflow-specific topology rules: classify should materialize single/mixed read inputs as classifier-ready FASTQ/FASTA, while map should preserve paired-end topology and materialize each virtual mate bundle before staging.

## Tests First

Add regression tests proving that:

- CLI assemble materializes a virtual derived bundle instead of passing the root FASTQ.
- GUI managed assembly request preparation materializes a virtual derived bundle before pipeline execution.
- CLI assemble writes canonical provenance with required argv, options/defaults, runtime identity, file checksums/sizes, exit status, wall time, and stderr.
