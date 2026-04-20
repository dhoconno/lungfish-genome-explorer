# Spec Gate 1 — Disposition

Date: 2026-04-19
Status: Closed by spec revision

The original spec was revised before any implementation planning began.

## Revision summary

The revised spec now:

- requires `OperationCenter` registration, bundle locking, cancellation, and Operations Panel visibility
- splits shared work into a resilient `VariantSQLiteImportCoordinator` and a `BundleVariantTrackAttachmentService`
- preserves helper/resume/materialization behavior behind the CLI path
- switches iVar to native `--output-format vcf`
- adds a viral sample-less SQLite import mode with no synthetic sample or genotype rows
- adds strict BAM/reference preflight including contig, length, and optional checksum checks
- turns iVar primer-trim handling into a launch gate
- narrows Medaka to ONT BAMs that can prove model-resolvable metadata
- stages an uncompressed reference FASTA for caller execution
- defines bundle-scoped rerun semantics and real `VCF.gz` / `.tbi` / `.db` artifact paths
- explicitly defers iVar `ANN=` support in v1

Gate 2 re-review is required before planning may begin.
