# Luna benchmark checkpoint

Date: 2026-09-16 America/Chicago

- Cold job: `mhc-union-subsets-02`, frozen source `7ca64e68690f6e4db5b91f54bfe8a4847c402a62`, native worktree `allele-aware-primal-benchmark-01`.
- Process identity: PID `24757`, parent `24746`; `/.../.venv/bin/python .venv/bin/primalscheme3 panel-create` with the 11 original FASTA inputs and the frozen 200 / 150–250, 2-pool, 4-core, strict-120s + bounded-salvage-60s argv. PID remains present and is now observed in state `R`; elapsed about `13:22:21` at latest check. Parent shell remains present. Session `26388` is not a live process entry.
- Output state: bundle exists and is still being written; approximately `48G`. The bounded read-only SQLite probe (`PRAGMA busy_timeout=250; SELECT stage_id,ordinal,position FROM records WHERE stream='snapshots' ORDER BY ordinal DESC LIMIT 1`) failed immediately with `database is locked (5)`; no rows were read and no payload scan occurred. Latest stage listing shows `stages/strict/stage.json` (6,406 bytes) and `validation.json` (1,341,528 bytes) newest, both updated after the strict output files; the history journal remains present. No completion/exit receipt was observed. Do not audit, export cache, or inspect live SQLite while writer is active.
- Strict stage metadata: `validation.json` is `valid: true`, coverage `status: ok`, mean coverage `0.1189410429` versus goal `0.95`, worst target fraction `0.0`, and `strictly_above_goal: 0`; per-target fractions range from `0.0` to `0.5331696816`. `stage.json` contains configuration/artifact references but no completion or exit-status field. The only stage directory is `stages/strict`; no salvage directory is present by name. This is a finalized strict-stage validation result only, not evidence that the whole cold run has closed successfully.
- Disk: filesystem has approximately `518Gi` available (`72%` used).
- Next gate: wait for a later actionable process transition. After successful writer exit and closed history, run the exact frozen `gate-audit-cold`; then `gate-export-cache`; then the single narrow-hour cached run, sequentially. Preserve identities and provenance.

No process, frozen source, live database, or history was changed.
