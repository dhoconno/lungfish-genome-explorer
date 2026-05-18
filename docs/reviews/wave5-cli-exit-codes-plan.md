## Wave 5 CLI Exit Codes Plan

### Scope

Remediate `P1-cli-parity-specific-exit-codes-unused` in the targeted scientific CLI commands by replacing generic `ExitCode.failure` throws in validation and runtime error paths with existing typed `CLIExitCode` values.

### Exit-Code Mapping

- Missing user-supplied input paths, missing projects/bundles, invalid numeric/range options, missing catalog entries: `CLIExitCode.inputError` (`3`).
- Unsupported or unreadable scientific data formats and parse failures: `CLIExitCode.formatError` (`5`).
- Output destination conflicts or write/materialization failures: `CLIExitCode.outputError` (`4`).
- Scientific workflow/import execution failures after outputs may have started: `CLIExitCode.workflowError` (`64`), preserving already-written provenance sidecars.

### Test Strategy

- Add process-level regression coverage for representative command families so scripts observe the numeric status:
  - `import bam` missing input returns `3`.
  - `import vcf` parse failure returns `5`.
  - `orient` invalid option validation returns `3`.
  - `cz-id summary` missing input returns `3`.
- Run focused CLI tests, then build `lungfish-cli` and run `git diff --check`.

### Provenance Note

This work only changes exit status classification. It must not remove or mask provenance for workflows/imports that have already written partial scientific outputs.
