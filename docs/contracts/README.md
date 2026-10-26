# Contracts

These documents are the written rules for extending Lungfish Genome Explorer (LGE). Read the one that matches the change before opening any Swift file. Each names the files to edit, the code to copy, and the code not to copy.

| Contract | Read it when you |
|---|---|
| `docs/contracts/ADDING-AN-OPERATION.md` | add or change anything that runs a tool or writes scientific output, including a new tool in the FASTQ operations dialog or a new CLI command that needs a provenance policy |
| `docs/contracts/RUNNING-A-TOOL.md` | launch any external program, pick between `NativeToolRunner`, `CondaManager.runTool`, `ProcessManager`, `CLIProcessLauncher` and `ToolProcess`, cancel a tool tree, or add a tool golden |
| `docs/contracts/ADDING-A-NEXTFLOW-WORKFLOW.md` | add a Nextflow workflow, change how one is described, pinned, launched, recorded or replayed in tests, or move Viral Recon onto the descriptor |
| `docs/contracts/RECORDING-PROVENANCE.md` | write or change a provenance record or its writer, read a record, change what the encoder writes, touch a path helper that feeds a checksum, lower a provenance ratchet baseline, or build the ToolProcess observer hook |
| `docs/contracts/CLI-EQUIVALENCE.md` | decide whether an operation needs a recorded command, record or change the command an Operations panel row shows, pin a CLI parity gap, or write a replay test |
| `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` | add a new kind of result with its own viewport, Inspector sections and sidebar entry, including the RNA-seq surface |
| `docs/contracts/analysis-surface-checklist.md` | need the copyable per-surface checklist to paste into a plan |
| `docs/contracts/READ-PAIRING.md` | change how any tool receives paired, merged or single reads, or add a tool that reads FASTQ |
| `docs/contracts/EXTERNAL-VOLUMES.md` | touch the file system in any way, because the project may live on an ExFAT external drive |
| `docs/contracts/CONCURRENCY-PLAYBOOK.md` | move work off the main actor, report progress, or apply a result that might be stale |
| `docs/contracts/VERIFICATION-ORDER.md` | run tests, gates, golden comparisons or a GUI walk in a session, or package and publish a release, so that nothing runs twice on the same code |
| `docs/contracts/MACHINES.md` | work on a Mac other than the golden runner, run or change the golden environment, or set up the self-hosted runner |
| `docs/contracts/SCOPE-AND-DELIVERY.md` | plan or brief a phase, sub-phase or lane, decide whether a row earns a lane, give a finding its severity, or decide when a Preview or a fix reaches Stable |
| `docs/contracts/RUNNING-A-PHASE-SESSION.md` | run a phase session with subagents, write a lane, review, fix or landing brief, or measure a session's model spend with `scripts/llm/session_ledger.py` |
| `docs/contracts/EXPERT-PANEL.md` | plan a phase or review its exit with the panel, brief or spawn an expert, review a lane in a field, settle a question of scope or fact, or record or revisit a panel decision |
| `docs/contracts/CLAUDE-CODE-PRACTICES.md` | run or read the weekly check of the Claude Code best practices page, or decide whether a practice from it enters a contract |
| `docs/contracts/SCREENCASTS.md` | make a new screencast, change one after review, or publish one to the website's Videos page |
| `docs/contracts/screencast-checklist.md` | need the copyable per-video checklist |

## Format specs for project folders

These specs in `docs/formats` say what a project holds on disk. Each fact in them cites the Swift file it comes from.

| Spec | Read it when you |
|---|---|
| `docs/formats/bundle-kinds.md` | add or change a bundle kind, decide a kind from a folder extension, or choose the record names a new write uses |
| `docs/formats/reference-bundle.md` | read or write a `.lungfishref` bundle, its manifest, its tracks, its view state or its records |
| `docs/formats/fastq-bundle.md` | read or write a `.lungfishfastq` bundle, a virtual bundle or the reads metadata sidecar |
| `docs/formats/analyses-layout.md` | create, name, find or delete a result folder under `Analyses/` |

## Where the contracts come from

The rules come from the architecture review in `docs/reports/2026-10-02-architecture-review/REVIEW.md` and the phased program in `docs/plans/2026-10-02-architecture-program.md`. Finding IDs (R1 to R18) in the contracts refer to the review. When a program phase replaces a touch point or a rule with code, the contract that names it is updated in the same change.

## How the contracts are kept honest

Every `Sources/` and `Tests/` path in these files must exist. A path check added in Phase 0 runs in the pre-push hook and fails a push that cites a missing Swift file. The prose follows the project's documentation rules and passes the manual's prose lint:

```bash
LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh docs/contracts/<file>.md
```
