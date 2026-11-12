# The expert panel

Five experts set a phase's scope when its plan is written and review the phase's exit. A severity settles a finding, never a vote (`docs/contracts/SCOPE-AND-DELIVERY.md`, SAD). A tag (E-EP-n) points to the reason for a rule in entry n of `~/lungfish-phase-records/llm/evidence/EP.md`.

## The panel

| Id | Seat and remit |
|---|---|
| `SWIFT`, S | Swift and macOS. Concurrency, processes, durable writes, memory cost, security-sensitive code |
| `ARCH`, A | Architecture. Layering, write ownership, one GUI and CLI path, layouts, rollback |
| `BIO`, B | Bioinformatics. Scientific output, read layouts, parameters, sample identity, provenance facts |
| `UX`, U | UI and UX. Every word a user reads, progress, failure and cancel, the Inspector |
| `QA`, Q | QA and QC. Test tiers, goldens, determinism, the gates, release engineering and signing |

These five vote (E-EP-2). The `manual-fidelity-reviewer` agent checks every factual claim of user-facing text, and each wrong fact is a fix that lands with the lane (E-EP-3). The `llm-efficiency-monitor` agent reports each session's spend. A phase that reaches a field none of the five owns co-opts a sixth expert for that phase by a vote of at least 4 to 1, recorded in its plan with the field's remit and checklist.

## The meeting

The panel meets once, when a phase plan is written (E-EP-4). A later session of the same plan, a fix session, a release job and a short job hold no meeting. The manager writes a sub-phase plan and the ARCH expert reads it.

1. Owner direction. The manager records the owner's words with their date in the plan's first section. It asks with the AskUserQuestion tool before the first spawn and in a plain message that ends its turn after it (E-EP-5).
2. Round 1, inventory. One `lge-expert` for each field (E-EP-1), opus at effort xhigh, writes `SCR/inv/<FIELD>.md` from the last plan's decisions and the backlog's ranked rows, with facts at a named commit, candidate lanes, risks and open questions `Q-<letter><n>`.
3. Round 2, challenge. One `lge-planner` drafts the plan and the lane briefs. Each field with a row in the draft reads only its rows, opus at effort xhigh, and writes `SCR/challenge/<FIELD>.md` with CORRECT lines (a wrong fact with its `path:line`) and OBJECT lines (scope or severity). The same seats cast every vote at that effort (E-EP-6), only on an OBJECT that a second field opposes.
4. Review. One fresh `lge-review` agent from the field a lane changes most reviews it, with BIO as well for scientific output and the fact-check for user-facing text. A lane of only documentation or only tests gets no field review. The QA expert reviews every release step before it runs and reads each candidate's evidence (`docs/contracts/VERIFICATION-ORDER.md`, row Evidence read).

Experts never edit code or build, lanes never decide scope, and lanes are cut only in the plan's cut order.

## Rulings and disputes

When two readings of a fact disagree, a fresh agent of the field reads the code at a named commit and that reading is the ruling (E-EP-7). A question within one field goes to that field's expert as a ruling (`lge-ruling`), and into the plan when it binds more than one lane. A question across fields or a change to a recorded decision goes to a vote only when two fields disagree on scope or on an S1 or S2 finding, or when the owner asks. A majority of the experts who vote carries it, an expert abstains on a question its field cannot judge, and a tie goes to the option that loses no recorded scientific information and can be verified in the session, then to the smaller change (E-EP-8).

The plan records each decision as a row under Panel decisions with an id (a topic letter and a number that a later plan cites with its phase, as 2.7 E3). A recorded decision binds every later session until the panel revisits it by a recorded vote or a contract change replaces it (SAD). A revisit is a row under the old id with the new decision, the vote and the evidence. Before a plan is deleted, its decisions in force move into the next plan or the contract they belong to.

## Review checklists

A review applies the checklist of the lane's field and of each other field the lane touches, plus the checks the plan adds, and cites each check by its id (E-EP-10).

| Id | Check |
|---|---|
| SWIFT 1 | Isolation. No actor state is read across an interleavable `await`, and no `Task.detached` or GCD hop sits in a task-local scope. |
| SWIFT 2 | Main thread. No hashing, file read, SQLite query or result load runs on the main actor. |
| SWIFT 3 | Processes. Every launch uses a runner that `docs/contracts/RUNNING-A-TOOL.md` names, and a cancel stops the whole tool tree with no process left. |
| SWIFT 4 | Durability. Writes use `DurableReplace` or `PortableRename`, and `scripts/testing/exfat-tests.sh --simulate` ran for each touched write path. |
| SWIFT 5 | Cost. Each large file is opened and hashed once per command, no database folder is hashed per run, and large inputs stream. |
| SWIFT 6 | Security. Arguments reach a process as an argv, never a shell string. Paths from users, records or downloads are checked before a write, move or delete. No secret reaches a log, record or golden. |
| SWIFT 7 | Timing. Timing-sensitive suites ran with every core busy. |
| ARCH 1 | Layering. No module imports one above it in `docs/architecture/MODULES.md`. |
| ARCH 2 | One path. The GUI runs the command the CLI runs, and the recorded argv equals the argv run (`docs/contracts/CLI-EQUIVALENCE.md`). |
| ARCH 3 | Write ownership. One component creates, settles or discards each result folder and writes its root record last, and planning writes nothing. |
| ARCH 4 | Names and layouts. One sanitizer names every sample, layouts follow `docs/formats/`, and older layouts still open. |
| ARCH 5 | Records. `provenance verify` passes on every new result, and cleanup deletes nothing a record names. |
| ARCH 6 | Ratchets and size. No ratchet rises, no baselined file grows, and new files stay at or under 800 lines. |
| ARCH 7 | Rollback. A replaced route stays untouched with its pins passing until the panel removes it, a switch routes back to it, and a parity test runs both. |
| BIO 1 | Payloads. Scientific outputs equal the frozen base byte for byte, sorted where order is not defined, with only declared shape differences. |
| BIO 2 | Counts and layouts. Read counts, pairing and read-set plans equal the base (`docs/contracts/READ-PAIRING.md`), and every argv keeps its layout flags, thresholds and database. |
| BIO 3 | Parameters. Every command keeps its effective parameters, including a run with no flags, and recorded defaults equal real defaults. |
| BIO 4 | No fact lost, none false. Every frozen record fact keeps its value, a degraded result says so with its reason, nothing is recorded that was not chosen or checked, and versions come from the environment that ran. |
| BIO 5 | Sample identity. Grouping and order do not depend on the locale, one label names a sample everywhere, and ids with dots or punctuation keep their results. |
| BIO 6 | Traceability. Lineage runs from each tool input to its payload checksums, records are written before any removal, and every output a record names exists with its digest. |
| BIO 7 | Goldens. Each change is predicted key by key and checked, and no scientific payload moves unless that is the lane's purpose. |
| UX 1 | Labels. Words a person reads say what happened and what to do next for every outcome, and output a program parses keeps its frozen form unless the lane changes it on purpose. |
| UX 2 | Warnings. Completed with Warnings appears in exactly the cases it did at the base, one line per cause, and no information line becomes a warning. |
| UX 3 | Progress. Every stage message reaches the row detail, the log and the viewer overlay, batch lines name the sample, held progress never moves back, and a bar shows only for progress evidence (E-EP-9). |
| UX 4 | End of run. A result shows in the sidebar only when complete, a failure alert names the failed step and the next thing to try, and a cancel reads Cancelled with no alert. |
| UX 5 | Inspector. New rows appear in Copy text and VoiceOver order, a derived value reads Not recorded, and older records display unchanged. |
| UX 6 | No silent writes. Reading or displaying writes nothing (hash before and after), and nothing is written into a bundle or a read-only project. |
| UX 7 | Words. New strings use sentence case and plain words, release notes name each change a user can see, and `docs/user-manual/features.yaml` is updated. |
| UX 8 | No silent outcomes. A row reads Completed only when its outputs exist where the person will look, and every refusal or failed save shows words in view. |
| QA 1 | Freeze first, for scientific output only. A pin commit passes at its base with the run shown, changes no file under `Sources`, and lands before the behaviour it pins. |
| QA 2 | Behaviour, not source text. Assertions read outputs, records, events or labels, and the `source-text-assertions` ratchet does not rise. |
| QA 3 | Tiers and tools. A real-tool test sits in the tier its class name selects, gates on `ToolAvailability` and never on a bare `XCTSkip`, and ran once with `LUNGFISH_REQUIRE_TOOLS=1` with no skip. |
| QA 4 | Terminal states. Success, a degraded result, failure and cancel each end with the exit code, status and row the decisions set, through the real transport. |
| QA 5 | Goldens and contracts. Each changed key has a prediction row, the compare is clean at the base, no run-varying key is unmasked, and contract counts move by exactly the converted leaves. |
| QA 6 | Determinism. Tests use `--threads 1`, `TestTempDirectory` and explicit 30-second process waits, and write nothing to `UserDefaults.standard`. |
| QA 7 | Release and signing. Package, push, `release.py setup` and `publish` follow `docs/contracts/VERIFICATION-ORDER.md`, and a signing, notarization or Sparkle change follows `docs/development/developer-id.md` on a packaged build. |
| QA 8 | GUI. The XCUI smoke ran on the packaged candidate in a session that does not lock, with no skip, and a new bundle kind joined the view-switch test. |
