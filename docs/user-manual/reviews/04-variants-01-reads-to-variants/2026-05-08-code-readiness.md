# Code readiness review: 04-variants/01-reads-to-variants
Date: 2026-05-08

## Review scope

Codex reviewed the current chapter plan, screenshot recipes, fixture
regeneration path, and the CLI/app workflows needed to run the documented
SARS-CoV-2 reads-to-variants example end to end. The review focused on places
where Claude needs stable behavior and exact UI/CLI facts, plus Lungfish's
blocking provenance requirements for scientific data workflows.

## Code changes applied

- `lungfish bam adopt-mapping` now reads `mapping-result.json` and adopts the
  sample-specific BAM/BAI paths that `lungfish map` actually emits. The
  adopt provenance records the controlling `mapping-result.json` sidecar with
  checksum and size, and the fixture regeneration script no longer needs to
  hard-link `sorted.bam` and `sorted.bam.bai` as a workaround.
- `lungfish bam primer-trim` now records richer provenance: workflow name and
  version, reproducible command, resolved options, input and output file
  checksums and sizes, runtime identity, per-step commands, per-step exit
  status, wall time, and stderr where available. When the CLI attaches the
  trimmed BAM to a bundle, it rewrites the provenance sidecar so top-level
  output paths point at the final bundle-owned payload rather than temporary
  staging files. If the workflow API cannot write its sidecar, it removes the
  BAM and BAI it just produced rather than leaving transformed data without
  provenance.
- `lungfish fetch ncbi ... --save-to ...` now writes a file-specific Lungfish
  provenance sidecar for saved FASTA/GenBank outputs, including the resolved
  fetch options, endpoint, pseudo-input accession, output checksum, size, and
  command line. The save path stages output and provenance together, then
  promotes both into place with rollback of newly written files on failure.
- `docs/user-manual/features.yaml` now defines all feature refs used by the
  chapter (`fetch.ncbi`, `fetch.sra`, `map`) and points the variant/browser
  sources at current files. `ARCHITECTURE.md` now names
  `04-variants/01-reads-to-variants` and the `sarscov2-srr36291587` fixture.

## Claude-facing documentation corrections

- The chapter and shot list still use old UI paths for downloading data:
  `File > Download from NCBI/SRA` should be revised to the current database
  search/import flow, principally `Tools > Search Online Databases > Search
  NCBI/SRA...` and `File > Import Center...` where applicable.
- The Inspector actions for alignment tracks are under `Analysis`, not the old
  `Read Style` or `Duplicate Handling` sections. The visible buttons are
  `Primer-trim BAM...` and `Call Variants...`.
- CLI examples should include the options needed for reproducibility, especially
  `fetch ncbi --save-to`, `bundle create --name`, `bam primer-trim --name`,
  and the resolved `.lungfishprimers` scheme path.
- Tool provisioning prose should use the current pack command:
  `lungfish conda install --pack read-mapping variant-calling`. Do not describe
  `lungfish conda list` as a pack status command.
- Check iVar prose against the executable defaults before Claude finalizes it:
  the CLI exposes 0.05 as the iVar minimum AF default, while some draft prose
  still says 3 percent. The generated fixture script also needs an explicit
  decision on strand-bias handling if the expected VCF keeps `sb` filters.
- In the variant table UI, the caller column is currently labeled `Source`, not
  `Caller`. Smart-filter tokens start empty rather than preloading `PASS`.
- The narrative should avoid saying position `26060` is LoFreq-only unless the
  regenerated iVar fixture confirms that; earlier fixture output also contained
  an iVar call at that position.

## 2026-05-09 follow-up

- Mapping provenance now records schema version 2, the `lungfish map` workflow
  name, per-file input and output records with checksums and sizes, runtime
  identity, top-level exit status/stderr, and explicit mapper, reference-index,
  `samtools view`, `samtools sort`, `samtools index`, and `samtools flagstat`
  steps where those steps run.
- `bundle create`, GUI SRA import, and `lungfish import fastq` now write
  bundle-level `.lungfish-provenance.json` records. The records include
  resolved user options/defaults, reproducible commands, input/output file
  records, step exit status, wall time, stderr when available, and final
  bundle-owned payload paths rather than temporary staging paths.
- Variant-calling provenance now represents the iVar pipeline as the actual
  `samtools mpileup | ivar variants` handoff. The mpileup step records the
  reference FASTA, BAM, and BAM index inputs with checksums/sizes, and the iVar
  step records the pipe input plus reference/GFF inputs.
- The screenshot runner now has a non-stubbed `execute` mode for safe local
  work: recipe validation, fixture path resolution, dependency checks,
  checksum/size reporting, `open` command execution, dry runs, and JSON reports.
  The 04-variants recipes now target `04-variants/01-reads-to-variants` and
  `sarscov2-srr36291587`.

## Remaining code and fixture gaps

- The screenshot runner still records UI-only steps such as `wait_ready`,
  `resize_window`, `scroll_to`, clicks, picker selections, and screenshot
  capture as manual/post-processing work. Dialog recipes that need a full
  `.lungfishref` project remain blocked until
  `docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh` is run locally
  or the runner gains pipeline-driving actions.
- Claude should continue treating old review files under
  `docs/user-manual/reviews/04-variants/` as historical notes. They still
  describe the retired `04-variants/01-reading-a-vcf` chapter and the legacy
  `sarscov2-clinical` fixture.

## Verification performed

- `swift test --filter BAMPrimerTrimProvenanceTests`
- `swift test --filter BAMPrimerTrimPipelineTests`
- `swift test --filter PrimerTrimProvenanceLoaderTests`
- `swift test --filter BAMAdoptMappingIntegrationTests`
- `swift test --filter FetchNCBIProvenanceTests`
- `swift test --filter BAMVariantCallingAutoConfirmTests`
- `swift test --filter SRADownloadFallbackTests`
- `swift test --filter VariantsCommandTests`

## Status

code_readiness_reviewed: true
