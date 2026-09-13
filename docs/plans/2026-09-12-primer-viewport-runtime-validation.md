# Primer viewport and managed runtime validation

The Primer3 viewport now displays each alternative pair on its saved template, with separate product, forward, reverse and optional probe rows. Both Overview and Results use the same map, selection and context actions. Binding inspection is capability-gated and unavailable for Primer3. The invocation dialog uses the selected project inputs without Refresh or Add FASTA/MSA controls.

The reported runtime failure was reproduced with Debug's managed PrimalScheme receipt at `3.3.0+lge.1` while the application manifest required `3.3.0+lge.2`. Both primer workflows now prepare only the selected engine before scientific snapshots, use the existing pinned installer with rollback, then acquire an environment lease and recheck readiness. The lease fixes the runtime location through execution and provenance publication. Installation cancellation is checked before discarding the previous environment.

A live repair initially failed its installed-file inventory validation and correctly restored the prior runtime without publishing an analysis or modifying Primer3. An instrumented retry verified all 37,399 installed files and completed the upgrade. Review identified that the former process helper could stop reading large JSON output after a fixed post-exit delay. Managed Python now uses the existing EOF-draining native runner. A separate regression reproduced cancellation immediately before PID assignment; the runner now reapplies cancellation after launch.

## Verification evidence

- `.build/primer-viewport-runtime-final.log`: 204 tests, zero failures; one opt-in live-repair test skipped in this batch. Includes a fresh pinned installation in the isolated validation environment and an 8 MB complete-JSON capture.
- `.build/primer-runtime-repair-diagnostics.log`: three passing tests, including the actual selected Debug runtime repair, cancellation rollback and optional-pack inventory check.
- `.build/primer-runtime-launch-green.log`: 13 passing tests covering startup cancellation, concurrent output draining, process-tree cancellation and runtime preparation. The startup and installation cancellation regressions failed before their respective fixes.
- Offscreen AppKit renders in `.build/primer-viewport-runtime-visual` checked Primer3 Overview and Results at 650 and 1,000 points, native MHC results, and the project-input invocation interface. No real app was launched for these checks.
- Managed human A, DPA1 and DPB1 combined PrimalScheme run: 141 saved amplicon spans across three references, all within the requested 150–250 bp bounds (actual 151–250); four discovery workers per MSA.
- Managed Primer3 human and macaque class I run: five candidate pairs and five probes per template.
- `.build/primer-viewport-runtime-validation/bundle-verification.json`: 84 manifest descriptors and 82 published output descriptors independently checked for size/hash integrity and final paths across the two native bundles. Native execution retains the managed runtime identity, version, exact commands, options, exit status and timing.
- Debug's existing Primer3 executable and conda metadata hashes and modification times remained unchanged during PrimalScheme repair and subsequent design.

The live fixtures are existing human and macaque MHC inputs and MAFFT bundles under `.build/mhc-primer-validation`; they are not shipped as invocation examples. Native calculations validate software behavior and saved coordinate bounds, not laboratory assay performance.
