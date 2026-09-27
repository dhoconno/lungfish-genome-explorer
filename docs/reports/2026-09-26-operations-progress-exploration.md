# Operations Panel: progress and live output exploration

Issue: https://github.com/dhoconno/lungfish-genome-explorer/issues/33

Branch: `codex/issue-33-operations-progress`

Base inspected: `a4e1c35830af81e1dd736a294e92632a6236a87c`

Status: exploration and recommended direction; product code has not changed. Findings come from source inspection by a UI/UX specialist and two software architects, with a second UX review of the information hierarchy. No runtime reproduction, tool-version validation, or test execution was performed.

## User requirements

- Correct the misleading runtime progress and ETA experience across operations, using assembly issue #33 as a concrete case.
- Give accurate percentages wherever available log data supports reliable measurement or estimation.
- When percentages or ETA are uninformative, present useful activity instead.
- Keep the **Progress** column as the visible lifecycle/outcome indicator, including completed, failed, and completed with warnings.
- Make the newest captured log line visible without opening a disclosure. Opening a log should show the latest output and make following a running workflow easy.

## Findings

Paths and line numbers below refer to the inspected base revision.

| Finding | Source evidence |
|---|---|
| Continuous updates can starve visible row refresh. The shared 150 ms task is cancelled and restarted on every active update. The elapsed timer refreshes only elapsed/ETA. | `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:232`, `:349` |
| ETA extrapolates from every fraction, including startup placeholders and arbitrary stage weights. At 1%, remaining time becomes 99 times elapsed time. | `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:824` |
| Running rows always use a determinate bar and hide the state label. Terminal labels already exist and should be preserved. | `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:724`, `:748` |
| Collapsed rows display detail, not the latest log. Expanded cells recreate the log view, show the newest 200 entries starting at the top, and lack tail following or scroll restoration. | `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift:907`, `:1055`, `:1259`, `:1290` |
| FASTQ-mediated assembly starts at 1% and expects JSON progress on stderr. The assemble command discards the fraction and prints human status to stdout using carriage returns. | `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift:18`, `:375`, `:753`; `Sources/LungfishCLI/Commands/AssembleCommand.swift:274` |
| Direct assembly has a separate reporting route. Every managed-pipeline stderr callback receives a synthetic 50%, then the GUI rescales it. Repairing delivery alone cannot make these numbers meaningful. | `Sources/LungfishWorkflow/Assembly/ManagedAssemblyPipeline.swift:115`; `Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift:342` |
| The tool runner buffers stdout until exit. Stderr forwarding decodes arbitrary chunks without carrying partial UTF-8 or lines. Its existing EOF drain guarantee must survive changes. | `Sources/LungfishWorkflow/Conda/CondaManager.swift:1161`, `:1181`, `:1200` |
| SPAdes stage recognition exists, but its percentage constants and assumed k-mer interpolation are heuristics. No validated MEGAHIT progress adapter/realistic log fixture was found. | `Sources/LungfishWorkflow/Assembly/SPAdesOutputParser.swift:189`, `:203`, `:234` |
| Warning outcome is inferred from the bounded retained log. A warning in an elided middle section can cease to influence the result. Retain warning counts independently of display retention. | `Sources/LungfishKit/OperationCenter.swift:234`, `:279` |

## Interface options

1. **Improve existing rows:** add latest output, truthful progress semantics, and persistent inline log state. Lowest layout disruption, but narrow nested scrolling remains.
2. **Compact list with persistent lower log inspector — recommended:** keep every operation's status and latest output visible; selection opens a readable full-width log without rebuilding expanded rows.
3. **Operation cards:** clear for one or two workflows, but consumes too much vertical space for concurrent operations.

Recommended list structure (percentages below illustrate semantics, not validated assembler capabilities):

| Operation / activity | Progress | Time | Action |
|---|---|---|---|
| Assembly · Graph construction; newest captured line | Running | Elapsed 12m | Cancel |
| Tool with validated stage counters · 680 / 1,000 units; newest captured line | Running · 68% of stage | Elapsed 4m | Cancel |
| Download · 6.2 GB / 10 GB; newest captured line | Running · 62% | Elapsed 2m; ≈1m remaining, if stable | Cancel |
| Assembly · output summary; latest captured line | Completed | Took 24m | Reveal |
| Operation · warning summary; latest captured line | Completed with warnings | Took 8m | Details |
| Assembly · concise failure reason; latest captured line | Failed | Ran 3m | Details |
| Assembly · stopping worker; latest captured line | Cancelling… | Elapsed 6m | Disabled |
| Assembly · cancelled by user; latest captured line | Cancelled | Ran 6m | Details |

- Progress always includes state text. A bar/icon supplements that text. Preserve retry presentation where relevant.
- Time always supplies elapsed or final duration. Add estimated remaining time only with a justified, fresh estimate; avoid allocating a mostly empty ETA column.
- Keep current stage and newest captured log line distinct. Debug chatter must not erase a meaningful stage, but the actual newest line remains available and visibly timestamped.
- Show last-output age. Silence means “No new output for 2m,” not proof of a stalled process. An activity indicator means active lifecycle, not measured advancement.
- Show failures and warning outcomes in the list without requiring selection. Selected failure details appear above the log.
- Use readable system typography, keyboard-accessible controls and explicit text in addition to color. Announce lifecycle transitions, not every arriving line.

## Log interaction

The lower inspector identifies the selected operation and contains its latest-line header, scrollable selectable log, Follow latest / Jump to latest controls, and secondary command/output/diagnostic actions.

- First opening starts at the newest output.
- Follow new output while at the bottom. Scrolling up or selecting earlier text pauses following.
- Preserve scroll anchor and selection while paused. Show a new-line count and Jump to latest action.
- Preserve follow/scroll state per operation. Never change selection or steal focus because another job becomes noisy or fails.
- Keep the latest-line header updating while the user reads history.
- Distinguish a bounded preview from complete on-disk diagnostics. Explain retention with an omission marker.

## Progress and event architecture

Keep lifecycle, activity, progress evidence, and ETA separate. Progress observations should carry phase identity, stage/overall scope, optional completed/total/unit, optional fraction, basis (measured, tool-reported, validated estimate, or unspecified), and timestamp. ETA needs its own scope, basis, freshness, and eligibility.

Use exact completed/total counters when available. Label stage-local percentages as stage-local. A validated estimate may display an approximate percentage with its basis available in the inspector. Merely counting k-mer iterations does not establish the fraction of overall computational work or remaining time; show “iteration n of N” when supported. Unknown logs still appear live without changing progress. Existing byte-total percentages remain useful.

SPAdes stage markers can be reused now. Reliable within-stage SPAdes and MEGAHIT percentages require captured logs for supported versions and tests that verify denominators, phase transitions, skipped stages and resets. Do not relabel current arbitrary stage constants as accurate estimates. Do not fabricate cross-stage percentages by forcing monotonicity across unrelated denominators.

Compute rate-based ETA from observations within the same phase, with sufficient samples and stability. Invalidate stale estimates when progress stops, totals change, or phases change. A valid stage percentage is not enough to predict the end of the workflow.

Stream stdout and stderr through incremental framing with per-stream carry for UTF-8, LF, CRLF, CR replacements and final unterminated output. Assign operation identity, stream, observation timestamp and sequence. Cross-stream chronology means observed order. Verify wrapper buffering against the installed micromamba version before selecting any runtime flag.

Tee complete diagnostics to disk independently of the sampled UI. Feed normalized events to tool-specific progress parsers. Extend/reconcile the existing shared CLI event contract rather than adding another assembly-only JSON dialect; cover both direct GUI and CLI-mediated assembly routes.

Replace resetting debounce with bounded-interval batching: once a refresh is pending, subsequent events accumulate without postponing its deadline. Keep per-operation ordering and flush records before terminal transitions. Display nonzero exit failures promptly after stream drain. A log line containing the word “error” is diagnostic evidence, not sufficient by itself to declare a terminal failure. Success follows normalization, final bundle publication and provenance completion, not merely tool-reported 100%.

## Scientific provenance

UI retention and sampled progress must not become the scientific record. Preserve complete diagnostics on success, failure, timeout and cancellation. Current managed assembly writes a combined stdout-then-stderr log after the runner returns; thrown cancellation/timeout paths need explicit coverage. Preserve final bundle log artifacts and final stored payload references.

Regression coverage must protect executed tool/workflow name/version, exact argv or reproducible command, user-visible options and resolved defaults, runtime/conda/container identity, input/output paths, checksums and sizes, exit status, wall time and useful stderr. Provenance completion remains a requirement of successful scientific output publication.

## Suggested implementation sequence and acceptance checks

1. Repair streaming/framing, CLI event delivery, and starvation-free UI refresh. Fake tools must emit visible stdout and stderr before exit through both assembly routes.
2. Introduce explicit progress evidence and independent ETA eligibility. Preserve trustworthy byte percentages; remove automatic ETA inference from legacy unspecified fractions. Add durable warning counts independent of capped logs.
3. Build the persistent inspector and revised Progress/Time presentation. Verify first-open tail, paused scrolling and selection, switching operations, concurrent noisy jobs, narrow windows and keyboard access.
4. Add versioned real-log fixtures and validated tool adapters. Start with known stage recognition; enable percentages only where fixtures establish their meaning.
5. Verify exit/EOF ordering, nonzero exit, launch failure, cancellation, timeout, high-volume logs, final unterminated text, partial UTF-8 and CR updates. Preserve complete diagnostic artifacts and final-path provenance.

This exploration recommends the second interface option and evidence-based progress model. It does not claim that the issue is fixed or that assembler-specific percentage accuracy has been demonstrated.


## Implementation outcome

Implemented on `codex/issue-33-operations-progress` in the issue-33 worktree. The list now displays lifecycle outcomes in Progress, elapsed time and eligible ETA in Time, and the latest captured line directly in each row. A persistent lower inspector follows the log tail, preserves historical reading and selection per operation, and provides a new-line count and Jump to latest. Resizing and opening Details do not pause following. Continuous output uses bounded batching rather than resetting debounce.

Progress observations now have explicit scope and basis. Existing measured byte counters retain percentages; rate-based ETA requires stable, fresh overall measurements. Legacy arbitrary fractions cannot produce percentages or ETA. SPAdes supplies recognized stage activity; assemblers without validated counters show live diagnostics and elapsed time. No assembler-specific within-stage percentage adapter is claimed: captured versioned logs establishing reliable denominators remain future work.

Both subprocess streams use incremental UTF-8 and CR/LF framing and drain before terminal callbacks. Managed assembly tees diagnostics to disk during execution, including failure and cancellation; fresh MEGAHIT output remains on its selected volume. CLI assembly has opt-in shared JSON events with separate stage and log delivery, including no-contigs warnings. Scientific bundle and provenance publication paths are preserved and covered by regression tests.

## Validation

The final unchanged-source focused repository gate passed all 323 selected tests, including progress evidence, log retention, streaming, managed assembly, CLI/provenance, execution service, appearance, and Operations UI. A minimum-window screenshot confirms that Details and Follow latest leave the newest line visible. Additional broader targeted tests passed as recorded in the implementation plan.

The full unit attempt executed 14,499 XCTest cases and 605 Swift Testing cases. It initially exposed two UI issues; both affected suites passed after fixes. The full attempt remains marked FAIL because the source changed during its execution. This report does not claim a clean full unit gate; the subsequent stable focused gate passed. Real large assembler workloads and version-specific within-stage percentage adapters remain unvalidated.
