# Bare-run writer parity facts

This folder holds the facts of what eleven Lungfish Genome Explorer (LGE) writers recorded before Phase 2.4 moved them from a bare run file to a provenance envelope. Each file is what `ProvenanceCompatFacts` projects from one scenario, captured once from the writer as it stood before the move.

The folder belongs to Phase 2.4, lane W2B. The compatibility corpus in `Tests/Fixtures/provenance-compat` is closed to write-side lanes, so these files sit beside it and not inside it.

## Rules

- A file is captured once, on unchanged code, and never replaced. A recapture is its own reviewed commit.
- The suites run each writer again in a temporary `.lungfish` project and project the new sidecar with `ProvenanceCompatFacts`. They compare it with the file through `differences(from:ignoring:)` and the documented sets in `ProvenanceCompatFacts`. No suite keeps a list of allowed differences of its own.
- The facts hold no value of the Mac that captured them. `BareRunWriterParity` replaces the app version, the operating system, the host name and the tool versions that the tools lock pins with tokens. It clears the times a real clock decides, the host values under `recorded`, and the checksum of a file whose bytes depend on the host, such as a SQLite database. The same rules run when the facts are compared.
- No file here holds an account home path, a macOS per-user cache path or a system temporary path. A test fails when one does.

## Scenarios

A scenario is one run of one writer. The corpus case `s3-gatk-container-bare-run` covers the containerized GATK run, so it has no file here.

| Scenario | Writer | Suite |
|---|---|---|
| gatk-executor-failed | `GATKPipelineExecutor`, a command that exits 7 | `BareRunWriterParityWorkflowTests` |
| bundle-variant-track-attach | `BundleVariantTrackAttachmentService`, the sidecar of `variants call` | `BareRunWriterParityWorkflowTests` |
| gatk-bundle-variant-attach | `GATKBundleVariantAttachmentService` | `BareRunWriterParityWorkflowTests` |
| conda-lockfile-export | `CondaLockfileService` | `BareRunWriterParityWorkflowTests` |
| conda-offline-export | `CondaOfflinePackService`, export | `BareRunWriterParityWorkflowTests` |
| conda-offline-install | `CondaOfflinePackService`, install | `BareRunWriterParityWorkflowTests` |
| conda-offline-install-failure | `CondaOfflinePackService`, an install that is refused | `BareRunWriterParityWorkflowTests` |
| bundle-container-export-archive-entry | `BundleContainerExportService`, the provenance entry inside the archive | `BareRunWriterParityWorkflowTests` |
| variants-extract-sample | `VariantsCommand.writeProvenance` | `BareRunWriterParityCLITests` |
| variants-query | `VariantsCommand.writeProvenance` | `BareRunWriterParityCLITests` |
| variants-phase-dry-run | `VariantsCommand.writeCommandPlanProvenance` | `BareRunWriterParityCLITests` |
| variants-phase-execute | `VariantsCommand.writeCommandPlanProvenance`, with two scripted tool steps | `BareRunWriterParityCLITests` |
| freyja-demix-dry-run | `VariantsCommand.writeCommandPlanProvenance`, called by Freyja | `BareRunWriterParityCLITests` |
| project-migrate-browser-summary | `ProjectCommand.writeMigrationProvenance` | `BareRunWriterParityCLITests` |
| sra-download-toolkit-fallback | `SRADownloadSubcommand.writeSRADownloadProvenance`, ENA down | `BareRunWriterParityCLITests` |
| sra-download-ena-paired | `SRADownloadSubcommand.writeSRADownloadProvenance`, ENA serves the run | `BareRunWriterParityCLITests` |
| sra-window-toolkit-after-failed-ena | `writeGUISRAFASTQImportProvenance`, a failed toolkit attempt then ENA | `BareRunWriterParitySRAWindowTests` |
| sra-window-keeps-cli-record | `writeGUISRAFASTQImportProvenance`, over the record the import CLI wrote | `BareRunWriterParitySRAWindowTests` |
| bam-adopt-mapping | `BAMCommand.AdoptMappingSubcommand`, which needs a real samtools | `BAMAdoptMappingIntegrationTests` |

`BareRunWriterParityFixtureTests` checks that this list and the folder agree, that every file is the canonical encoding of its facts, and that none holds a machine path or a value of the Mac that captured it.

## Capturing and reviewing

```
LUNGFISH_CAPTURE_PROVENANCE_FACTS=1 swift test --filter BareRunWriterParity
```

The command writes the files that are missing and compares the rest. It never replaces a file. To read the facts against the bytes, set `LUNGFISH_PARITY_DUMP_DIR` to a folder outside the checkout, and each scenario copies the sidecar it wrote there. The gate sets neither variable.
