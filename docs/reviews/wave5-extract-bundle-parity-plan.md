# Wave 5 Extract Bundle Parity Plan

**Goal:** Make sequence extraction bundle output a shared workflow-layer behavior so CLI and app workflows create `.lungfishref` bundles with the same output layout and canonical provenance.

**Root cause:** `SequenceExtractionPipeline` currently owns bundle creation and provenance in `LungfishApp`, while `ExtractSequenceSubcommand` only writes FASTA file output. This creates app-only behavior for `.lungfishref` outputs and prevents CLI parity.

**Plan:**

1. Add a failing CLI regression test that extracts a FASTA region with `--output Extracted.lungfishref` and asserts the result is a reference bundle with root, rollup, and focused genome provenance sidecars.
2. Introduce a workflow-layer `SequenceExtractionBundleBuilder` under `Sources/LungfishWorkflow/Extraction/` that owns extracted-sequence bundle creation, output enumeration, app/CLI command context, and final-payload provenance.
3. Make `SequenceExtractionPipeline` a thin app wrapper that delegates bundle creation to the workflow builder while preserving existing public app call sites and source track types.
4. Teach `ExtractSequenceSubcommand` to route `.lungfishref` output paths through the shared builder and keep existing FASTA output behavior unchanged.
5. Run focused extraction tests, `swift build --product lungfish-cli`, `swift build --product Lungfish`, and `git diff --check`, then commit the scoped remediation.

**Provenance requirements:** Bundle creation must fail if provenance writing fails. Provenance records must include the final stored bundle payloads (`genome/sequence.fa.gz`, `.fai`, optional `.gzi`, `manifest.json`, and transformed annotation/variant DBs when present), not temporary FASTA staging files.
