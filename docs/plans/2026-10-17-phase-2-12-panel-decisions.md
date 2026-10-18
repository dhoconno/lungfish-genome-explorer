# Panel decisions for 2.12, 2.13 and Phase 3 (2026-10-17)

The briefs, the five inventories `inv/<FIELD>.md` and the five memos `memos/<FIELD>.md` that this table cites are kept in
`~/lungfish-phase-records/phase-2-11/p3plan/`. The plan they decide is `2026-10-17-phase-2-12.md` beside this file.

Model and effort. `lge-expert` on opus at effort xhigh, as tally clerk and plan drafter. I hold no field and cast no vote.
CODE is `.claude/worktrees/phase-2-11` at `65539ddcd2fbe756390d0890cda0b5181e77ffc0`, which equals `origin/main`.
Inputs, in the brief's order, are `briefs/inventory.md`, `briefs/memo.md`, the five inventories `inv/<FIELD>.md` and the
five memos `memos/<FIELD>.md`. "ARCH memo 2" means section 2 of `memos/ARCH.md`, "QA inv 1.3" means section 1.3 of
`inv/QA.md`. The vote rule is `docs/contracts/EXPERT-PANEL.md:75-77`. A vote passes by a majority of the experts who
vote, an abstention does not count, and a tie goes to the option that loses no recorded scientific information and can
be verified in the session, then to the smaller change.

Notation. `y` yes, `n` no, `abs` abstain, `OWN` left to the owner (with the field's recommendation in the Result
column when it matters), and `none` where a memo did not address the question.

## 1. Questions the owner answered on 2026-10-17

| Answer | Owner's words | Question ids it settles | What the memos had said |
|---|---|---|---|
| 1 | "No, Preview only." | Q-A2, Q-S2, Q-B1, Q-U1, Q-Q1. Q-U4 becomes moot for Phase 2 | UX and BIO had advised a Stable walk (UX inv 1.4, BIO inv 1.4) |
| 2 | "Literal, 2.12 + 2.13." | Q-A1, Q-S1, Q-Q2, Q-Q3 (routes move behind a key as before, the key goes one release later) | QA had offered an exempt list that fit 2.12 (QA inv 1.3). Q-A4 and PROC-LIST fall with it |
| 3 | "After I finish the other phases, at least that is my plan for now." | Q-A3, Q-S3, Q-B6, Q-U2, Q-Q4 | ARCH, BIO and UX had asked that agent-facing contract lines close earlier, which the contract-lines vote below settles |
| 4 | "Let the panel propose." | Q-B2, Q-U3 (decision [9], translate headers) | Section 4 below |
| 5 | "Yes, close them in Phase 2." | Q-A6, Q-B8 (viewer exports that begin no Operations row) | All five marked it OWNER. ARCH, SWIFT and QA recommended a census in 2.13 and conversion in Phase 3. BIO and UX recommended the same with byte pins. The answer overrides them |
| 6 | "Refuse and name the holder" | Q-S6. Phase 3's OperationLauncher refuses with the holder, and the queue question stays with Phase 5d | ARCH, SWIFT, BIO and QA recommended refuse. UX voted refuse through Phase 3 with the queue at 5d |
| 7 | "XCUI gate and your walk" | Q-U10, Q-Q6 (UX's O-U1). XCUI is runnable in a gate from 3.1, which fixes the stale `scripts/release/app-smoke-gate.sh` entry at `config/test-catalog.json:237`, and each Phase 3 Preview gets a short owner walk of the migrated views | QA and UX recommended both. ARCH and SWIFT recommended walks until XCUI runs unattended. BIO voted XCUI from 3.1 |
| 8 | "Yes, if the data shows it" | Q-S9, Q-B4. 2.12 measures one thread against two at 40 runs each (SWIFT memo 1, Q-S9). arm64 defaults to one thread only if it crashes less and BIO's contig compare passes, and the record names the effective thread count | ARCH, SWIFT and BIO recommended measuring first. UX and QA voted yes on the same conditions |
| 9 | Not asked | Q-B5, Q-U12 (K9). Recorded as kept for Phase 4a. A drop stays the owner's call at Phase 4's plan | ARCH, BIO, UX and QA keep it for 4a (BIO phrased it as OWNER with "keep, in 4a"). SWIFT marked it OWNER with the same recommendation |

## 2. Decision table for the questions the panel decides

| Id | Question | ARCH | SWIFT | BIO | UX | QA | Result |
|---|---|---|---|---|---|---|---|
| Q-A4 | An exempt list for `Process()` sites | n | n | n | n | n | No, 5 to 0. Moot under answer 2. PROC-LIST drops |
| Q-A5 | The measure of "one provenance writer" | y | y | y | y | y | 5 to 0. `envelope_encodes_outside_writer 0`, `bare_workflow_run_writes 0`, the writer-function count amended to count only definitions that bypass `ProvenanceWriter` and held at 0 (2 at CODE, `FastqTrimSubcommand.swift:108`, `ReferenceBundleManualAnnotationService.swift:408`), the four plain-encoder blind spots (`scripts/ratchets/provenance-writers.sh:33-35`) gone, exports and payloads on a writer encode API. `legacy_run_embeds` (15) and `provenance_filename_literals` (177) stay at or under baseline. Non-envelope cleanup journals take their own encoder after BIO rules which cleanup encodes are records |
| Q-S4 | "through `ProvenanceWriter` or `DurableReplace`" | y, folded | y, as Q-A5 | n | y, as Q-A5 | n | Folded into Q-A5. Nobody voted for a second writer. BIO and QA voted no to the "or `DurableReplace`" words, the others folded it into the `ProvenanceWriter`-only measure |
| Q-A7 | PRIMER-RUN runs `primers design` on a runner in 2.12 | y, split | y | y | y | y | Yes, 5 to 0. Never cut (SWIFT, BIO, UX, QA). Minority, ARCH would cut M2 (the runner) to 3.6 last |
| Q-A8 | Folder of `OperationSpec` and `OperationLauncher` | ruled R-A4 | y | abs | abs | y | `Sources/LungfishKit/Launch/`, 3 to 0, BIO and UX abstained. ARCH's field ruling |
| Q-A9 | Viewport order with the seven unlisted kinds | y | y | y | y, plus Quick Look | y | Yes, 5 to 0. The eight kinds with a hide function and no place in 3a join it, Quick Look included (ARCH inv 2.1, UX memo 1) |
| Q-A10 | Viewport migrations carry no hidden key | y | y | y | y | y | Yes, 5 to 0 (same as Q-Q7) |
| Q-A11 | GATK-KEY and A64 join 2.12 | y | y | y | y, plus PRIMER-RUN and BIO's rows | y | Yes, 5 to 0 |
| Q-A12 | Rename the nine test classes that keep a deleted key's words | ruled R-A5 | y | abs | y | y | Rename in 2.13, 4 to 0, BIO abstained |
| Q-A13 | `scripts/checks/module-imports.py` timing | first lane of 3.1 | same | same | same | same | First lane of 3.1, 5 to 0 |
| Q-A14 | `ResultViewport` in LungfishKit or a new target | LungfishKit | LungfishKit | abs | abs | abs | LungfishKit, 2 to 0, three abstained. Revisit in 4d |
| Q-A15 | Kraken2's `TaxonomyViewController` moves into a leaf target in 3.3 | y (proposed) | y, in scope | y, in scope | y, in scope | y, in scope | Yes, 5 to 0 in substance. Only ARCH named it as a question. The other four put it in their 3.3 scope |
| Q-S5 | A `durable-writes` ratchet in 2.13, moves in 4f | y | y | y | y | y | Yes, 5 to 0 |
| Q-S7 | A `lungfish-cli` run takes an on-disk bundle lock | y, 3.6 ruling | y, 3.6 | y, 3.6 | y, 5d | n for Phase 3, y as 4f | A design ruling in 3.6, 3 to 2 on placement (UX for 5d, QA for 4f). All five want the lock in some phase |
| Q-S8a | Typed events deliver on the main actor in post order | y | y | y | y | y | Yes, 5 to 0 |
| Q-S8b | Each viewport PR types its own surface's events | y, rider | y | y | y | n | Yes, 4 to 1, QA voted one behaviour per PR. ARCH's rider binds, so a PR types only the events whose poster and every observer sit in its files |
| Q-S10 | L11's key travels in the child's environment only | y | y | y | y | y | Yes, 5 to 0. The test greps argv, row text, View Log and failure sheets, then records and goldens, for a throwaway key (SWIFT, UX, QA) |
| Q-B3 | A reader note for TaxTriage records of 2026.10.19 and earlier | n | y | n | y, a `Not found` marker | n | No for Phase 2, 3 to 2. The Known limit stays. UX's marker is a candidate for a later Provenance-tab lane |
| Q-B7 | Manifest-less result folders keep one read-only prefix fallback | y | y | y | y | y | Yes, 5 to 0. 3.1 pins what a renamed folder opens as today. Minority detail, BIO wants a rename to write the kind manifest or refuse, which is a behaviour change for a later ruling |
| Q-B9 | Move the TaxTriage viewer's unique-read write to the producer | y, in 3.3 | y, in 3.3 | n, keep with pin | n, keep with pin | n, keep with pin | Keep the write in the view with a byte pin through Phase 3, 3 to 2. The move is a later BIO lane (Phase 4 or 5). The 2.12 K1 lane still moves the save off the main actor (S31 note 1) |
| Q-B10 | Extend `ResultViewportController.swift` and `ScopedEventFilter`, or replace them | ruled R-A6 | extend | extend | extend | abs | Extend, no parallel protocol, 4 to 0. On the layout, ARCH's field ruling R-A6 holds (section 5) |
| Q-U5 | K12 (a) and C13 go to 3d, K12 (b) and (d) stay in 2.12 | y | y | y | y | y | Yes, 5 to 0 |
| Q-U6 | SW17 (a), a tool path under the reader's storage root shows the tool's name | y | y | y, with the version | y | y | Yes, 5 to 0. Display only, the record is unchanged |
| Q-U7 | RENAME-COMMAND maps at display time | y | y | y | y, amended | y | Yes, 5 to 0, as R-B2 (section 5) |
| Q-U8 | A65-NOPROJECT refuses with `No Project Open` | y | y | y | y, ruled | y | Refuse, 5 to 0. Words `Open or create a project before running BLAST.` through `NoProjectPresenterSeam` (UX memo 1) |
| Q-U9 | zstd stays in the export panel if A49-ZSTD waits | keep | keep | keep | keep | keep | Keep, 5 to 0. Moot when A49-ZSTD lands in 2.13 |
| Q-U11 | One BLAST and extraction label set, pinned in 3.1, ruled at 3.3's entry | y | y | y | y | y | Yes, 5 to 0. Open for that ruling, BIO asks that no label say "Verify", while UX's draft reads `Verify with BLAST…` |
| Q-U13, Q-Q5 | `GATKVariantCallingRoute` goes in 2.12 | y | y | y | y | y | Yes, 5 to 0 |
| Q-Q7 | Phase 3 adds no hidden keys | y | y | y | y | y | Yes, 5 to 0 |
| Q-Q8 | The switch matrix freezes today's leaks as declared entries | y | y | y | y | y | Yes, 5 to 0 |
| Q-Q9 | A stub surface in a test target measures Phase 3's exit | y | y | y | y, plus a falling count of App files naming a leaf viewport type | y | Yes, 5 to 0 |
| Q-Q10 | A recorded MEGAHIT retry in the conformance gate | y, gates only | y, one retry | y, on conditions | y in the gate, n in the app | n, unless no thread count runs clean | Yes, 4 to 1. One retry on exit -11 or -6 in the conformance gate only, logged with its signal in gate evidence, contigs byte-equal to the golden. The product never retries |
| Contract lines | A lane that changes behaviour keeps true the `docs/contracts/*.md` and module `AGENTS.md` lines it changes | y | y | y | y (V-DOC) | y | Yes, 5 to 0. Its review checks those lines. DP rows no lane touches wait for the documentation pass |
| P3-COUNT | Number of Phase 3 sub-phases | 6 | 6 | 6 | 6 | 7 | Six, 4 to 1. QA split 3d into its own last session |
| P3-EXEMPLARS | TwelveS and PrimerAnalysis migrate in 3.1 | y | n, 3.2 | n, 3.2 | y | y | In 3.1, 3 to 2. 3.2 is then NVD, NAO-MGS, EsViritu and TaxTriage |
| P3-BUNDLE | All nine bundle viewports in one sub-phase (3.4) | y | y | y | y | n, split 3.4 and 3.5 | Yes, 4 to 1 |
| P3-3B | 3b runs with mapping and reference in 3.5 | y | y | y | y | n, 3.6 | Yes, 4 to 1 |
| P3-3C | The typed event core lands in 3.1 with no site moved | y | y | y | y | n, after the migrations | Yes, 4 to 1 |
| P3-3D | 3d runs last, with the Phase 3 exit review | y | y | y | y | y, as 3.7 | Yes, 5 to 0 |

## 3. Ties and splits, with the proposed tie-break

| # | Topic | Votes | Proposed resolution and reason |
|---|---|---|---|
| T1 | **Tie.** Order of A67-ENGINES and the PRIMER-RUN runner flip | ENGINES first, ARCH and UX. PRIMER-RUN first with ENGINES as its proof, BIO and QA. ENGINES in 2.13, SWIFT | ENGINES first, then the runner flip (PRIMER-RUN M2). PRIMER-RUN M1 (the record's argv, A67-ANALYSES and R-B1) starts at hour 0. Reason, the first tie rule. The three bundle replays compare side A while side A still exists, so no engine's payload changes without a pin, and the proof runs inside 2.12 |
| T2 | **Open.** Decision [9] part B, unique FASTA ids for mates that share an identifier | BIO yes (its own proposal). No other memo voted on it, since they were written beside BIO's. SWIFT's condition 2 (the id stays one token with no space, `/` or `\|`) rules out the `{id}/{mate}` form BIO wrote | The manager puts part B to a one-question vote of the four other fields (`lge-expert`, opus, max) before the TRANSLATE lane's second milestone. The lane's first milestone (the six-frame pins and BIO's red test that both mates get one id) goes ahead. If B passes, BIO names a separator that meets SWIFT's condition |
| T3 | **Tie.** Decision [9], signed values on input (`--frame -1`) | UX yes. BIO no. QA optional. ARCH and SWIFT silent | Not in Phase 2. With one vote each way, the second tie rule gives the smaller change, and BIO's reason (it grows the CLI for no payload gain) stands unanswered |
| T4 | **Split on a new fact.** R-B2's disclosure line | ARCH, BIO and QA put the note in the copied text's first comment line. UX puts it beside the Command row and in Copy Command's tooltip, because zsh, the default macOS shell, leaves `INTERACTIVE_COMMENTS` off and a pasted `# ...` line prints `command not found: #`. SWIFT did not address placement | The majority stands as written, but it voted before UX's fact. CMD-DISPLAY's first milestone pastes the copied text into a default zsh. If the comment line errors there, UX's placement applies, since the record is unchanged either way and the words a person reads are UX's remit (`docs/contracts/EXPERT-PANEL.md:30`). The manager records which one ran |
| T5 | **Split, consequence clause of R-A1.** What happens when a 2.12 flip cannot land and its A against C declares a difference | ARCH, a named Phase 3 task. SWIFT, a 2.14. UX, the manager tells the owner at once. QA, the manager records it. BIO, never cut | The manager tells the owner the same day with both options, a 2.14 or a named Phase 3 task. Answer 2 reads the exit literally, so only the owner can relax it |
| T6 | Split, Q-B10 layout | SWIFT, BIO and UX grow `ResultViewportController.swift` in place. ARCH rules a new `Sources/LungfishKit/Surfaces/` folder with that file's two types moved in as a pure move | ARCH's ruling R-A6 holds. Layout on disk is ARCH's remit (`docs/contracts/EXPERT-PANEL.md:28`, `:72`), it matches the program's `LungfishKit/Surfaces/*.swift (new)` (`docs/plans/2026-10-02-architecture-program.md:190`), and it starts no parallel protocol, which was the point of the three "extend" votes |
| T7 | Split, `BlastReadActionRoute` | U-R1 (a key name is never reused) has UX, QA, SWIFT and BIO. ARCH's R-A2 keeps the key type for A65-M3's new sites | U-R1 carries 4 to 1 (section 5). 2.12's KEYS lane deletes the key whole |
| T8 | Split by placement, Q-S7, Q-B3, Q-B9, Q-S8b | See section 2 | Majority as recorded. None is a tie |

Lane-level splits (where a row lands, its model, its order) are resolved by majority in `draft-phase-2-12.md`, each
with its minority in one line. Two of them are not votes but facts. A65-M3a waits for KEYS, since both edit
`Sources/LungfishApp/Services/BlastSubmitRoute.swift` and the program lets two lanes run together only on disjoint
files (`docs/plans/2026-10-02-architecture-program.md:11`). And owner answer 8 fixes MEGAHIT's probe in 2.12 at 40 runs
each, which settles the memos' 20, 40 and "between sessions".

## 4. Decision [9], translate headers

BIO leads (owner answer 4). All five memos keep the signed headers byte for byte. At CODE `translate` writes
`>{name}_frame{label} [{code name}] [{n} aa]` (`Sources/LungfishCLI/Commands/TranslateCommand.swift:160-161`) and
`fastq translate` the same around the read id (`FastqTranslateSubcommand.swift:56-57`). The label is
`ReadingFrame.rawValue`, `+1` to `-3` (`Sources/LungfishCore/Models/SequenceAlphabet.swift:88-94`), so `--frame 4` prints
`_frame-1`. Only `_frame+1` is pinned (`Tests/LungfishCLITests/FASTATextModePinTests.swift:84`, `NewCommandTests.swift:96`).

| Part | Decision | Vote |
|---|---|---|
| A, keep the signed form | The headers stay byte for byte, in both commands, as the one header form | 5 to 0 (ARCH memo 6, SWIFT memo 5, BIO memo 5, UX memo 5, QA memo 6) |
| A, what changes | (1) Both `--frame` helps say that 4 to 6 are the reverse-complement frames, printed as `-1` to `-3`, and that frame `-1` starts at the last base. (2) A pin covers all six frames of `translate` and of `fastq translate`, written at the base before any other change (QA). (3) The two help captures `lungfish-cli.translate.txt` and `lungfish-cli.fastq.translate.txt` under `Tests/Fixtures/golden/cli-help/` move by prediction. (4) Both commands change together, and the record's `frame` parameter stays the option's number (`TranslateCommand.swift:184`, `FastqTranslateSubcommand.swift:86`) (SWIFT). (5) The FASTQ pane's words (`Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:489`) follow UX's ruling | 5 to 0 on (1) to (4). (5) is a UX field ruling |
| A, payload cost | No FASTA byte moves. Two help captures and one new pin move. Lane TRANSLATE in 2.12, `lge-worker`, sonnet, max, 0.5 lane-sessions (ARCH 0.25, BIO 0.75 with B, the others 0.5) | |
| Rejected | Numbered headers `_frame4` to `_frame6` | 5 to 0 against. They move every saved header, the three pins and the viewer's agreement, and drop the strand |
| Rejected | Signed values on input | Tie T3, not in Phase 2 |
| B, unique ids for mates | `fastq translate` writes a mate-qualified id only when the input resolves as interleaved under the read-pairing contract's `auto` rule, because `FASTQReader` cuts the id at the first space (`Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift:676`) and both Casava 1.8 mates then get one FASTA id (BIO memo 5, inferred from code, a red test confirms it first). Payload moves only for interleaved inputs whose mates share an id | BIO yes. Open (T2) |

## 5. Rulings and their votes

| Ruling | Text | ARCH | SWIFT | BIO | UX | QA | Result |
|---|---|---|---|---|---|---|---|
| R-A1 | No route flip lands in 2.13 behind a key, since that key could go no earlier than 2.14. A flip cut from 2.12 moves to 2.13 only when its A against C is empty | y (ARCH memo 1.1) | y in substance (SWIFT memo 2, "a slipped flip means a 2.14") | y in substance (BIO memo 2 cut order, "a key added in 2.13 cannot be deleted inside Phase 2") | y in substance (UX memo 0 item 1) | y in substance (QA memo 2, "no flip may be cut to 2.13 unless its A against C parity declares nothing") | Binds, 5 to 0. Its consequence clause is T5. It also binds the export conversions of owner answer 5 |
| R-B1 | A replay of a recorded `primers design` into an existing destination exits 3, names the bundle and suggests `--project`, and never replaces | y | y | y | y, with words | y | 5 to 0. UX's words, `Output already exists: <path>. Give --output a new path, or use --project to write a new bundle in the project.` QA's test asserts the exit code and that the old bundle's bytes are unchanged |
| R-B2 | The record keeps the command as it ran. Copy Command maps a folder the rename moved, at copy and display time only, and says so | y | y, resolved contained paths only | y | y, amended placement | y | 5 to 0 on the rule. The placement of the note is T4 |
| R-B3 | A region bundle from a GenBank document keeps no annotations, as the in-process route did, and its record says so. Carrying them is Phase 5b's payload change | y | y | y | y, plus a notes line | y | 5 to 0 |
| U-R1 | A hidden key name is never reused. `BlastReadActionRoute` goes whole in 2.12, and a 2.12 flip that needs a key gets a new name that the 2.12 notes list with its sites, because a person who set `legacy` in 2026.10.20 would otherwise run the new sites in process unknowingly (notes `docs/release-notes/2026.10.20.md:79`) | n (R-A2 keeps the type) | y in substance (KEYS-211, "A65-M3's sites never read this key") | y in substance (KEYS-211 deletes it with its code) | y (ruling) | y (12.03, "12.06 to 12.08 use a new key name") | Binds, 4 to 1, ARCH voted to keep the type one more release. R-A2 is overruled on the key type and stands on the three `.legacy` arms and the two `closedBy` entries |

ARCH's other rulings, recorded as field rulings with no vote needed (`docs/contracts/EXPERT-PANEL.md:72`).

| Ruling | Text | Votes cast on it |
|---|---|---|
| R-A3 | Each 2.12 flip lane ends its report with a deletion table in the form of the 2.11 K3 key table (`docs/plans/2026-10-15-phase-2-11.md:152-167`). "No key" means the lane already deleted the old path | None against. QA's ROUTE-KEYS meter (QA memo 12.01) serves the same end and had no second vote |
| R-A4 | `OperationSpec` and `OperationLauncher` go in `Sources/LungfishKit/Launch/` | Q-A8, 3 to 0 |
| R-A5 | Rename the nine test classes that keep a deleted key's words, in 2.13 | Q-A12, 4 to 0 |
| R-A6 | `ResultViewport` and `SurfaceRegistry` go in a new `Sources/LungfishKit/Surfaces/`, with `ResultExportFormat` and `BlastRequest` moved there as a pure move. The typed event layer extends `ScopedEventFilter` | Q-B10, see T6 |
| R-A7 | 3b retires routing prefixes only. `AppDelegate.swift:1958` is the temp-folder sweep list, not routing. The routing tables are `AppDelegate.swift:302-306`, `SidebarProjectScanner.swift:993`, `:1047` and `Sources/LungfishOperations/ProjectDeletionPlanner.swift:455-456` | No objection in any memo |

## 6. What the manager must break before the plan is final

1. T1, the order of A67-ENGINES and the PRIMER-RUN runner flip. The proposal is ENGINES first.
2. T2, decision [9] part B, which needs a vote of the other four fields.
3. T4, R-B2's note placement, settled by CMD-DISPLAY's paste test unless the manager prefers to ask the three majority
   fields first.
4. T5, the words the owner hears if a flip slips with a declared difference.

T3 resolves by the contract's second tie rule and needs no manager action.
