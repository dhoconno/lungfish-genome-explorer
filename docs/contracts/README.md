# Contracts

These documents are the written rules for extending Lungfish Genome Explorer (LGE). Read the one that matches the change before opening any Swift file. Each names the files to edit, the code to copy, and the code not to copy.

| Contract | Read it when you |
|---|---|
| `docs/contracts/ADDING-AN-OPERATION.md` | add or change anything that runs a tool or writes scientific output, including a new tool in the FASTQ operations dialog or a new CLI command that needs a provenance policy |
| `docs/contracts/CLI-EQUIVALENCE.md` | record or change the command an Operations panel row shows, pin a CLI parity gap, or write a replay test |
| `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` | add a new kind of result with its own viewport, Inspector sections and sidebar entry, including the RNA-seq surface |
| `docs/contracts/analysis-surface-checklist.md` | need the copyable per-surface checklist to paste into a plan |
| `docs/contracts/READ-PAIRING.md` | change how any tool receives paired, merged or single reads, or add a tool that reads FASTQ |
| `docs/contracts/CONCURRENCY-PLAYBOOK.md` | move work off the main actor, report progress, or apply a result that might be stale |
| `docs/contracts/SCREENCASTS.md` | make a new screencast, change one after review, or publish one to the website's Videos page |
| `docs/contracts/screencast-checklist.md` | need the copyable per-video checklist |

## Where the contracts come from

The rules come from the architecture review in `docs/reports/2026-10-02-architecture-review/REVIEW.md` and the phased program in `docs/plans/2026-10-02-architecture-program.md`. Finding IDs (R1 to R18) in the contracts refer to the review. When a program phase replaces a touch point or a rule with code, the contract that names it is updated in the same change.

## How the contracts are kept honest

Every `Sources/` and `Tests/` path in these files must exist. A path check added in Phase 0 runs in the pre-push hook and fails a push that cites a missing Swift file. The prose follows the project's documentation rules and passes the manual's prose lint:

```bash
LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh docs/contracts/<file>.md
```
