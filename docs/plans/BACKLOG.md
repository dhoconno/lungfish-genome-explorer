# Backlog

Status: active. The one list of open rows for Lungfish Genome Explorer (LGE) phases, as
`docs/contracts/SCOPE-AND-DELIVERY.md` sets. Each row states its effect on results or users. The owner ranks the list
once a phase, and a row left unscheduled for two phases closes unless it changes results, loses data or crashes. A row
becomes a lane only when it earns one under that contract. Phase plans hold no Moved out tables. Review findings that
are not blockers, S3 and S4 walk findings and cut lanes all land here.

Phase 3.0 moves the older open rows into this file (row BACKLOG-MOVE). Until then they are part of the backlog where
they stand. The rows below came from the audit of 2026-10-26 (`docs/reports/2026-10-26-phase-1-2-audit/SUMMARY.md`,
with the team reports `TEAM-A.md` and `TEAM-B.md` beside it), in the order the audit proposes. The owner has not
ranked them.

## Rows the audit placed in Phase 3

| Id | Effect on results or users | Source | Planned |
|---|---|---|---|
| UI-PROFILE | No GUI test runs in any gate, because the `ui` profile names `scripts/release/app-smoke-gate.sh`, which never existed, and line 6 of the catalog still calls every XCUI test a diagnostic. Point the profile at `scripts/release/app_smoke_gate.py`, change line 6, and add an XCUI smoke of about ten tasks | `config/test-catalog.json:6`, `config/test-catalog.json:255`, both team reports | 3.0 |
| MAP-POOLED-PAIRS | A pooled mapping of paired bundles does not keep each bundle's pairs, so the read layout differs from mapping each bundle alone. BIO ruled a per-bundle plan with the platform rule of `docs/contracts/READ-PAIRING.md` | `docs/plans/2026-10-23-phase-2-14.md:452`, `~/lungfish-phase-records/phase-2-14/rulings/BIO-C2.md` | 3.0 |
| MAP-PAIRED-UNBOUND | An explicit `--paired` that cannot bind its files is pooled without a message, and the help of `MapCommand.swift` omits `--paired`, so the read layout changes silently | `docs/plans/2026-10-23-phase-2-14.md:455` | 3.0 |
| ESV-READCOUNT-FLAGS | EsViritu's Reads and Unique Reads may count primary records only. BIO rules what the counts mean before any classifier count is pinned | `docs/plans/2026-10-20-phase-2-13.md:703` | 3.0 |
| TOOL-TIME-LIMIT | A conda tool run stops at 3,600 s by default, which stopped EsViritu on a large sample. An analysis tool gets no wall-clock limit by default | `Sources/LungfishWorkflow/Conda/CondaManager.swift:1059`, `TEAM-A.md` | 3.0 |
| WAIT-QUARANTINE | Add `KNOWN_LOAD_FLAKES` to `scripts/full-suite-gate.sh` and start the list of tests that fail only under load, as `docs/contracts/VERIFICATION-ORDER.md` sets. `KNOWN_PREEXISTING_FAILURES` stays empty unless an owner decision is open | `scripts/full-suite-gate.sh:200`, both team reports | 3.0 |
| GEN-MAP | The module map holds line counts, so nearly every lane regenerated it. 397 commits touched only the map or ratchet baselines. Drop the counts and let a falling ratchet write its own baseline | `scripts/index/generate-module-map.py`, `scripts/ratchets/`, `TEAM-A.md` spot check 5 | 3.0 |
| BACKLOG-MOVE | Move the carry-in sections of `docs/plans/2026-10-02-architecture-program.md` and the open rows of `## Moved out of 2.13` (`docs/plans/2026-10-20-phase-2-13.md:603`) and `## Moved out of 2.14` (`docs/plans/2026-10-23-phase-2-14.md:426`) into this file, each with one effect sentence and a severity that BIO or UX sets. Fold the CHTC README rows P3-R1 to P3-R9 into one row | The program plan and the two phase plans | 3.0 |
| DB-IDENTITY | EsViritu, TaxTriage and NAO-MGS records name no database, so a methods section cannot cite the database release that made the calls | `docs/contracts/RECORDING-PROVENANCE.md`, `TEAM-B.md` | 3.1 |
| ALERT-PRESENTER | 158 `NSAlert(` sites in 69 files, 74 of them showing raw error text. One presenter names the step that failed and the next thing to try | `TEAM-B.md` | 3.1 |
| SYMLINK-REAL-ARCHIVES | Archive import refuses a link that leaves its folder, which was never tried on the official Kraken2 and EsViritu archives it guards, and Stable blocker OBS-W9 came from it. Try the refusal on those archives | `TEAM-B.md` | 3.1 |

## Rows for the owner to rank

| Id | Effect on results or users | Source |
|---|---|---|
| Science rows | TT-FUZZY-NAME, VARIANT-IMPACT-KEYS, CDS-CUT-NUMBERING, GFF3-MULTIVALUE, C6-RIBO, C6-CLUMP-ORDER and COLLECTION-PERF, which Team B ranked first for scientists. The rows hold their effects | The carry-in sections of the program plan |
| Known limits | Lines 139, 141, 155, 167, 183, 213 and 251 of `docs/reports/2026.10.22-technical.md`, which Team B ranked first among the 40 Known limits | `docs/reports/2026.10.22-technical.md` |
| C6-V11 | Plain FASTQ output for Linux users through a `collect` subcommand, which Team A placed beside 3.0 | The CHTC carry-in of the program plan |
| MAIN-THREAD-BLOCK | No check fails app code that blocks the main thread for more than two seconds, and the NAO-MGS loads still run on the main actor | `TEAM-B.md` amendment 8, `TEAM-A.md` Phase 3 scope |
| HELP-GOLDENS | 321 byte captures of CLI help are recaptured for every wording change. A parse test of each command's help replaces them, which saves lane time and changes nothing a user sees | Both team reports |
| EVENT-GOLDENS | The CLI event transcript goldens become a schema test of the event stream | `TEAM-B.md` |
| PARITY-RATCHET-SCOPE | The parity ratchet makes a new export site that records no command need a parse test that names it. An export carrying `cli-parity-exempt: not-scientific-data` should not | `scripts/ratchets/cli-parity-gaps.sh` rule 5 |
| FILE-SIZE-RATCHET | The size ratchet keeps a per-file list, so a lane split `EsVirituDiagnostics.swift` out only to stay under a baseline. Fail only a file that grows past the limit, and let a file already over it grow with one line of reason in the commit | `scripts/ratchets/file-size.sh`, `TEAM-B.md` amendment 15 |
| NOTES-CAP | Nothing refuses release notes over 15,000 characters, and a draft of 132,811 characters failed at GitHub. `release.py package` should refuse a longer file | `TEAM-A.md` amendment 19 |
| CONTRACT-TRIM | Ten contracts are over 20 KB, `ADDING-AN-OPERATION.md` and `ADDING-A-NEXTFLOW-WORKFLOW.md` at about 55 KB. Move dated history to the records, largest first | `docs/contracts/SCOPE-AND-DELIVERY.md` |
