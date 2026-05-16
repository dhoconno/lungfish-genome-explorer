# Wave 2 Remediation Orchestration

Date: 2026-05-16
Base: `acd514b4` (`codex/wave1-integrated-fixes`)

Wave 2 is the second Codex remediation wave, not Claude's original Wave 2.
It starts from the staged Wave 1 checkpoint and targets the remaining verified
findings from the Claude review plus residual gaps found by independent triage.

## Guardrails

- Missing provenance is blocking for any scientific workflow that creates,
  imports, transforms, exports, or wraps data.
- Write failing regression tests before production changes when behavior changes.
- Keep worktrees scoped; do not revert unrelated changes.
- Each lane must add a short spec/plan under `docs/reviews/`, list changed
  files, run focused verification, and leave any residual risks explicit.
- Scientific provenance, IO parsing, AppKit/modal behavior, and deletions require
  independent review before integration.

## Worktrees

| Branch | Worktree | Scope |
|---|---|---|
| `codex/wave2-integrated-fixes` | `.worktrees/wave2-integrated-fixes` | Integration branch and orchestration docs |
| `codex/wave2-cli-provenance` | `.worktrees/wave2-cli-provenance` | CLI classify/map materialization, ONT provenance, minimap2 GUI coverage, exit-code expansion |
| `codex/wave2-io-correctness` | `.worktrees/wave2-io-correctness` | VCF, LIKE escaping, streaming FAI, BigWig deletion |
| `codex/wave2-concurrency-modal` | `.worktrees/wave2-concurrency-modal` | MainActor dispatch, runModal migrations, OperationCenter logs, download cancellation/progress |
| `codex/wave2-boundary-deadcode` | `.worktrees/wave2-boundary-deadcode` | Safe resource/dead-code deletion, module pruning prep |
| `codex/wave2-dialog-runtime-tests` | `.worktrees/wave2-dialog-runtime-tests` | Dialog shell/status polish and test hygiene |

## Sequencing

1. Integrate CLI/provenance and IO first because they affect scientific output.
2. Integrate concurrency/modal after targeted AppKit tests pass.
3. Integrate safe dead-code/resource cleanup after build verification.
4. Integrate dialog/runtime/test hygiene after visual or source-level regressions.
5. Run a second boundary pass for `LungfishCLI -> LungfishApp` and
   `LungfishCore` AppKit removal after provenance and UI lanes settle.

## Final Verification Target

- `swift build --product lungfish-cli`
- `swift build --target LungfishApp`
- Focused test suites from each lane
- Broader selected regression suite covering Wave 1 and Wave 2 touched areas
- `git diff --check`
- Debug app build artifact path recorded for user review
