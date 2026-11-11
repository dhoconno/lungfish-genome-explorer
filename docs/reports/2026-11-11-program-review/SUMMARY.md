# Program review of 2026-11-11

The owner asked for an independent review of the finished work of Phases 1 to 3, of the contracts that run a phase session, and of the plans for Phases 4 and 5 of Lungfish Genome Explorer (LGE). The question was where the program does too much, too little, the wrong thing or the right thing the wrong way. Six reviewers on Fable at xhigh effort worked in two teams on 2026-11-11, blind to each other and to the expert panel, read-only on the tree at `a324c6178` (branch `phase-4`) and on the records in `~/lungfish-phase-records/`. Their reports, with every citation, are in `~/lungfish-phase-records/review-2026-11-11/seats/`. This file holds what they agree on, where they differ, and what changed in the plans and contracts as a result.

| Seat | Field | Report |
|---|---|---|
| A1 | Architecture and code | `seats/A1.md` |
| A2 | Science and users | `seats/A2.md` |
| A3 | Verification and release | `seats/A3.md` |
| B1 | Spend and orchestration | `seats/B1.md` |
| B2 | The contract set as instructions | `seats/B2.md` |
| B3 | The forward plans | `seats/B3.md`, `seats/B3-plans.md` |

## Verdict

1. The structural work of Phases 1 to 3 did its job. One process primitive, one operation start, the GUI running the CLI, the tool, kind and surface registries and the provenance writers are in the tree and held by ratchets that read 0. That program is finished and should be declared closed.
2. What is left of Phase 4 splits cold code for no user and for nothing Phase 5 uses. Phase 4 should end with the Preview of the session that is paused now.
3. The Phase 5 table of 2026-10-02 is stale. It names three things that do not exist and that Phases 3 and 4 chose not to build, it has no user outcome, and it plans a native STAR chain that does not fit the Macs users have. It is replaced.
4. Wrong numbers and hangs are found by the packaged walk, by BIO measuring against the tool itself, and by the owner. The unit tier, the full tier, the XCUI smoke and the evidence read found none in Phase 3. Nothing in any plan looked for the next wrong number on purpose, and nothing tested real-size data or a project made by an older release.
5. A session's fixed cost is too high for its size. The manager is 30% of Phase 3's spend, a ten-seat meeting ran in seven sessions where the contract says once a phase, and most hours fall after the last landing. The contract set holds 14 live contradictions and grew after the audit that capped it.

## What the seats agree on

| Finding | Seats | Evidence in short |
|---|---|---|
| Stop the remaining Phase 4 moves | A1, A2, B3, and B1 on cost | Of 1,627 commits since 2026-10-26, `GenotypeComparisonMatrixView.swift` had 0, `GenotypeResultViewController.swift` 3 and `AnnotationTableDrawerView.swift` 2, while `ViewerViewController.swift`, which no lane splits, had 38. A touched Workflow file rebuilds in 21.5 s against 8.9 s for a leaf file, so a domain target saves at most 12.6 s. The panel's own tally says the pilot buys no build time and the matrix split is invisible to a person |
| Phase 4 is not a prerequisite of Phase 5 | A1, A2, B3 | The exemplar 12S leaf is named in 21 LungfishApp files on the launch and Inspector side, which no Phase 4 lane touches. RNA-seq does not open the genotype window or the annotation drawer |
| Replace the Phase 5 table | A1, A2, B2, B3 | `OperationLauncher`, a `TrackRenderer` protocol and an empty LungfishRNASeq target have 0 hits in Sources. The 3600 s limit that row 5d removes is already `.infinity`. `ADDING-AN-ANALYSIS-SURFACE.md:97` forbids RNA-seq code until those land. The Phase 5 backlog section is empty and the exit is a structural count |
| Look for wrong numbers on purpose | A2, A3 | Of 92 S1 rows in the Phase 3 records, 72 name BIO, 16 a walk, 2 a user and 0 a test. Variant calling, Viral Recon, primer design and MHC genotyping show 0 or 1, since no lane went there. The walk compares the screen with `lungfish-cli`, which shares the faulty code |
| Test real size, hangs and memory | A2, A3 | The only failures users met on real data are an EsViritu run killed for memory, a 20,000-record FASTA that grew the app to 404 GB and forced the Mac off, and MEGAHIT crashes. The severity table names neither a hang nor a memory kill, and the smoke covers 7 of 19 viewer kinds |
| The meeting runs once a phase | B1, B2, B3 | Seven ten-seat meetings in 14 days cost $229, up to 38% of a short session. Of 30 Phase 4 decisions, 19 had no dissent, and the two contested scope votes were undone by the quota two days later. The value was the inventory, which corrected 25 premises |
| The orchestrator decides and spawns | B1, B2 | The manager cost $1,146 of $3,765 in Phase 3. It fills to 460K to 564K tokens in its first hour, and every token it reads is paid again on about 1,000 turns. A START prompt orders about 200 KB of reading |
| Reviews earn their place, routed by yield | A3, B1 | 58 of 268 reviews found a blocker, 25 of them S1 or S2, at about $10 a blocker. BIO found one in 14 of 50, ARCH in 1 of 25. A third to fifth reviewer adds little, and a review of a commit that printed `PURE-MOVE OK` found a commit-message fix |
| Walk first, chain after | A3, B1 | `package` needs only unit evidence, yet about 55 minutes of replay, golden, executor replay and smoke run before the walk that ends most candidates. The full tier ran at least 17 times in Phase 3, 9 red, none on a product S1 or S2 |
| The backlog and contracts must shrink by a check, not by a rule | B2, B3, A2 | The backlog holds 811 rows in 498 KB against a 512 KB limit, 661 of them S3 or S4 under Later and about 70 marked done in a file that says open rows only. Ten contracts were over 20 KB at the audit, ten are today, and six grew |
| The stable release lags again | A2, B3 | Stable 2026.10.29 lacks 14 fixes rated S1, and 859 commits and five Previews follow its tag |

## Where the seats differ, and the ruling taken

| Question | Positions | Ruling |
|---|---|---|
| Land the reviewed TwelveS pilot | B3 lands it as the recipe for a new domain target. A1 does not, since it adds a target, a walk row and a packaged-resource risk to a rider Preview for no gain, and new targets are already a known operation | Not landed. Its branch stays in the phase bundle as the recipe. The owner can reverse this at the cost of one landing and one unit tier |
| The RNA-seq route | A2 runs salmon natively to a count table on a 16 GB Mac and imports nf-core/rnaseq output. B3 runs nf-core/rnaseq through the Nextflow contract. A1 wants one measured run before any pick | Sub-phase 5.0 measures both. Sub-phase 5.1, a count table that opens salmon and nf-core/rnaseq output, is the same on either route and goes first. The default for 5.2 is native salmon, since nf-core/rnaseq needs Docker and defaults to STAR at 32 GB or more, and the owner picks after 5.0 |
| Session size | B1 wants at least 15 lanes a session. B3 plans four Phase 5 sessions of 5 to 10 lanes | A session under 12 lanes runs as a short job with no meeting and no monitor. A session may run two sub-phases back to back with a Preview at each |
| The full tier | A3 runs only the integration and conformance tiers after a Preview. Their run time alone is not measured | Adopted, with the first run timed. The whole serial tier runs for a stable release and once a phase |
| Opus at max for the orchestrator | The owner's direction. B1 found no measurement and estimates $20 to $45 more a session | Adopted as directed. The first session's monitor reports its cost a turn beside 3.3's |

## What changed

| Document | Change |
|---|---|
| `docs/plans/2026-10-02-architecture-program.md` | The structural program is closed. Phase 4 ends with the Preview of its first session. Phase 5 is rewritten with a user outcome, owner questions with defaults, a trust session, sub-phases 5.0 to 5.3, exits and a computed budget. A process job rebuilds the contract set before the trust session |
| `docs/plans/2026-11-09-phase-4.md` | The remaining order, the walk, the exit checks and the budget are cut to the close. The moves of session 2 are closed and replaced by the split-on-touch rule |
| `docs/contracts/SCOPE-AND-DELIVERY.md` | Precedence, the structural-lane rule, the truth sweep, plan shape and a computed budget, hang and memory words in the severity table, the probe rule for conditional ratings, truth probes, affected results, the backlog and owner-list rules, and the file-size rule. Audit history and the replaced-decisions table moved out |
| `docs/contracts/RUNNING-A-PHASE-SESSION.md` | The orchestrator on opus at max with what it never does, reviews capped at two and routed by yield, landing by fast-forward or in batches of three, one unit-tier rule, no Debug pass |
| `docs/contracts/EXPERT-PANEL.md` | One inventory and one challenge round when a phase is planned, votes only on opposed objections, no meeting in a later session of the same plan |
| `docs/contracts/VERIFICATION-ORDER.md` | Package first, walk the new rows, then the rest of the chain. The whole full tier for a stable release and once a phase |
| `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` | The RNA-seq section no longer waits on prerequisites that Phase 4 dropped, and points at the plan |

The rebuild of the contract set to its byte caps, the typed agents, the tracked session scripts, the backlog split and `OWNER-DIRECTIONS.md` are work with scripts and tests, so they are lanes of the process job in the program plan and not edits of this review.

## Findings kept in full in the seat reports

| Seat | Finding | Where it went |
|---|---|---|
| A1 F4 | A surface that runs something makes 15 to 20 App edits, and a missed switch arm shows as a hidden result | Lane ARMS in 5.1 removes the `default` arms so the compiler lists them |
| A1 F5 | 45 commits removed blank lines to hold a file-size count | The file-size rule in `SCOPE-AND-DELIVERY.md`, and lane FILESIZE-RULE of the process job |
| A1 F6 | R1 to R18 against the tree | The closing paragraph of the program plan |
| A2 F7 | 21 backlog rows are rated S3 until measured | The probe rule and lane PROBES of the trust session |
| A2 F8 | 31 lines of release notes tell a user to redo an old result, and nothing marks the result | The affected-results rule and lane AFFECTED |
| A2 F10 | A tool environment can differ from the lock with no word | Lane ENV-DRIFT, before 5.3 |
| A3 F4 | The owner check list is 69 KB against a cap of 20 rows, and more than 30 rows went unwalked three Previews running | The owner-list rule and lane TWINS |
| A3 F5 | The checkout under `~/Documents` cost over six hours of prompts and five lanes | An owner question |
| A3 F6 | No project made by a shipped release guards an upgrade | Lane UPGRADE-CORPUS |
| A3 F11 | The cost table managers plan from is from the laptop | Lane VO-TRIM of the process job |
| B1 F7 | The session table stops at the last landing, before half the spend | The session table takes every row at the close |
| B2 F1 | 14 contradictions between contracts, agent definitions and briefs | The precedence rule now, the rest in lane CONFLICTS |
| B2 F3 | A lane's real rules are a 23.5 KB stack in the records folder titled Phase 3.2 | Lane AGENT-TYPES |
| B2 F10 | The helpers a session depends on live in the records folder | Lane SESSION-SCRIPTS |

## What nobody could check

Who uses LGE and on which channel. Salmon's time and memory on this lab's data, and whether nf-core/rnaseq runs at a useful speed under Docker on Apple silicon, which sub-phase 5.0 measures. Whether the tool families nobody read are wrong, which the truth sweep answers. How the weekly quota weighs opus at max. The run time of the integration and conformance tiers alone.

## Cost of this review

Six seats on Fable at xhigh, 54 to 63 tool calls each, about 13 to 16 minutes each, three points of the week (81% to 84%).
