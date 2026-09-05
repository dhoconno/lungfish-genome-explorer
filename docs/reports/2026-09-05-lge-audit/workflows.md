# Feature and user-workflow audit — 2026-09-05

## Method and boundaries

Read-only source audit of the current checkout. No application build, test suite, network requests, credential reads, scientific runs, or production changes were performed. Findings marked **proven in source** have a traced executable path; actual macOS rendering and timing have not been exercised. Recommendations and conditional risks are explicitly separated. Line references are repository-relative, one-based, and refer to the checkout examined. Provenance is covered by the parent audit; this report addresses user journeys and generic data lifecycle, not scientific procedure design.

## Overall assessment

Lungfish has an unusually broad and substantive feature surface. This is not a collection of empty menu placeholders: import services, native result bundles, classifier viewers, operation diagnostics, specialized workflows, project state restoration, and dependency management all have concrete implementations. The principal product risk is inconsistent handling of the same object across separate entry points. Users can successfully open a native bundle through one route and accidentally import its internal files through another. Several failure paths do not finish the visible operation. Recovery and trustworthy state reporting should take precedence over expanding the tool catalog.

## Coverage map

| Family | Entry points and implemented continuation | Audit depth / remaining verification |
|---|---|---|
| Projects and windows | File > New Project, Open Project Folder, Open Recent; `ProjectSession`, `DocumentManager`, window snapshots | Traced menu and restore; actual multiwindow persistence and dirty editor closure require UI checks |
| Native bundle viewing | Reference, FASTQ, MSA, tree, MHC reference, genotype, 12S and classifier sidebar types | Traced external-open versus drop routing; confirmed atomicity gap below |
| Raw reads and run folders | Import Center files/folders, paired sample CSV, ONT folder; pairing/config sheet, ingestion services | Traced drop dispatch and sheet lifecycle; no real data ingestion |
| References and annotations | Reference import helper, explicit annotation attachment, genome viewer and GFF3 export | Traced helper failure and operation status; provenance reviewed separately |
| BAM/CRAM and variants | Import Center, bundle attachment, mapped-read view, variant/sample table and metadata | Catalog and route inspection; no coordinate, filtering, or CRAM-reference runtime validation |
| MSA and trees | Native import cards, external open, MAFFT and tree service families, dedicated viewers | Open/import routes traced; native bundle drag/drop is broken as detailed below |
| Read transformations | 42 `FASTQOperationToolID` cases: QC, demultiplexing, filtering/trimming, pairing, orientation, extraction, subsampling, clustering | Catalog and common execution/cancellation inspected; each algorithm not independently executed |
| Mapping and assembly | Mapping/assembly tools appear in common tool catalog and have workflow services/result viewers | Surface inventory and shared lifecycle review; output fidelity remains outside this source-only pass |
| Classification and batch review | Kraken2, EsViritu, TaxTriage, NAO-MGS, NVD, CZ-ID; batch tables and DB rebuild placeholders | Traced Import Center and retry/error placeholder; wizard drop defect confirmed |
| Specialized genotyping / 12S | Workflow Library enablement, reference libraries, result tables, workbook/revision services | Catalog and gating reviewed; scientific interpretation not evaluated |
| Application migrations | Geneious plus CLC, DNASTAR, Benchling, sequence library, alignment/tree, sequencing run, phylogenetics, QIIME2, IGV import cards | Catalog/dispatch verified; archive conversion fidelity requires fixture-based matrix |
| Workflow Library / builder | Core/specialized/user sections; Nextflow/Snakemake packages, dependencies and enablement; builder views | Package persistence, identity and invalid-package recovery traced; execution semantics separate audit |
| Exports | FASTA/GenBank, GFF3, FASTQ, project metadata CSV, PNG/JPEG/TIFF/PDF, provenance variants | Menu-to-action checks; annotation scope inconsistency confirmed; graphics quality not rendered |
| Operations / recovery | Running/cancelling/terminal states, bundle locks, CLI/logs/output reveal, failure reports | Source state transitions and failure path examined; general retry is absent, classifier rebuild has retry |
| AI assistance | Opt-in provider configuration, local queries, viewer navigation and external literature search | Provider/context/tool boundaries and key persistence examined; no live provider call |
| Setup and offline use | Welcome required setup, tool reconciliation, Plugin Manager reinstall/offline guidance, storage selection | Read launch gating and error recovery; actual first launch/offline install not performed |

Reference inventory: `App/MainMenu.swift:163`, `App/DocumentManager.swift:97`, `Views/Sidebar/SidebarItem.swift:40`, `Views/ImportCenter/ImportCenterViewModel.swift:90`, `Views/FASTQ/FASTQOperationDialogState.swift:1909` (all under `Sources/LungfishApp`).

## Actionable defects

### WF-01 — P1 — Native bundle drops flatten packages into unrelated files

**Proven in source.** Trigger: drop an ordinary `.lungfishmsa` or `.lungfishtree` bundle onto the project sidebar. Other directory bundles outside the whitelist also face incorrect dispatch; bundles whose contents trigger the earlier ONT-directory heuristic can take a different route. The same path also receives supported ZIP-wrapped native objects.

Call chain: `MainSplitViewController+MultiDocument.swift:508` → `MainSplitViewController+FASTQImport.swift:36` → `Services/SidebarImportPlanner.swift:86`. The atomic-directory whitelist contains only reference, FASTQ, and MHC-reference bundles. Other directories recurse through `:96–113`; regular files with extensions are admitted by `:131–140`. The resulting files are individually imported at `MainSplitViewController+MultiDocument.swift:560–568`, with ordinary copy fallback at `MainSplitViewController+FASTQImport.swift:219–232`. For example an MSA bundle's sequence file can be routed into reference import, while its JSON/database payload is copied separately. In contrast, external open explicitly recognizes native MSA/tree bundles at `AppDelegate.swift:1691–1703`.

**Impact:** lost bundle identity and inter-file relationships in the destination, misleading imported objects, and unexpected extra work. Source bundle deletion is not asserted.

**Remediation:** use one native bundle registry/capability service for ZIP recognition, sidebar scanning, external open and atomic import; validate/copy each recognized bundle as one object. Define and explain the policy for recognized bundles nested in a dropped ordinary directory (currently the three recognized types are silently skipped unless top-level).

**Acceptance:** every advertised native bundle type, plain and ZIP-wrapped, yields exactly one correctly typed destination with its complete structure and provenance. Dropping a parent directory neither descends into packages nor silently discards them without feedback. Parameterize the existing `SidebarImportPlannerTests.swift` coverage across the complete registry; existing tests at 80–120 cover only reference/MHC atomicity.

### WF-02 — P1 — Failed sidebar reference imports leave a permanent Running operation

**Proven in source.** Trigger: standalone reference import helper throws after the operation starts, e.g. malformed input or helper failure. In `Views/MainWindow/MainSplitViewController+FASTQImport.swift:66–119`, the operation ID is declared inside `do` at 72. Success calls `complete` at 95, but `catch` at 109 only logs and posts a failed drop notification; it cannot access the ID and never calls `fail`. No cancellation callback was supplied.

**Impact:** a failed import remains Running, cannot be cancelled (`LungfishKit/OperationCenter.swift:206–207,711–714`), and cannot be cleared (`:750–752`). Repeating failure accumulates stale activity; no standard operation failure report is produced for this row. This is a visible lifecycle bug, not merely a missing log.

**Remediation:** put operation ownership outside the throwing scope and guarantee exactly one terminal transition. Reuse the adjacent annotation-import pattern at `FASTQImport.swift:143–171`, which correctly reports failure. Record the generated output bundle on success for consistent result navigation.

**Acceptance:** injected helper startup, parse and publication failures all produce one Failed row with useful error information; no running row remains. Success produces one Completed row; cancellation, if offered, reaches a terminal state after worker exit.

### WF-03 — P2 — Wizard import cards accept drops, then silently do nothing

**Proven in source.** Trigger: drop files onto NAO-MGS, NVD, CZ-ID or Primer Scheme cards. Every card installs a file-URL drop target and returns true in `Views/ImportCenter/ImportCenterView.swift:247–250`. `performDropImport` forwards directly to `dispatchFileImport` (`ImportCenterViewModel.swift:611`); dispatch closes the window at 676, hits `break` for these four actions at 740–747, and records `succeeded: true` at 750. Clicking Import takes the separate working wizard route at 596–602 / 765–773.

**Impact:** the accepted drop closes the Import Center with no wizard, result, or explanation. Stored history incorrectly claims successful dispatch, although current `ImportCenterView` does not render that history; this audit does not claim a visible green success badge.

**Remediation:** route drops through each card's import kind, prepopulate the appropriate wizard where supported, or decline drops and explain the required action. Do not record success for a no-op.

**Acceptance:** mouse import and compatible drop converge on the same configuration and output workflow for every card. Unsupported drops are rejected without closing the window. Wizard cancellation remains distinguishable from completion.

### WF-04 — P2 — Multiple sample-sheet drops silently ignore all but one CSV

**Proven in source.** The sample-sheet panel explicitly allows one file (`ImportCenterViewModel.swift`, `fastq-sample-sheet` card), but card drop collection accepts arbitrary URL counts (`ImportCenterView.swift:257–274`). Dispatch uses only `urls.first` at `ImportCenterViewModel.swift:681–683`, then writes history for every supplied URL at 750/839.

**Impact:** batch intent is lost and the selected first file can depend on asynchronous provider completion order. Other inputs are silently ignored.

**Remediation:** share format/cardinality validation between panel and drop. Either accept exactly one with a clear error or deliberately schedule each sample sheet.

**Acceptance:** two dropped sheets cannot silently process one; order is deterministic if batching is supported, and each history entry refers to an actual operation.

### WF-05 — P2 — Save and Save As have no project-level responder implementation

**Proven source wiring gap; AppKit enabled appearance untested.** `App/MainMenu.swift:199–211` installs `NSDocument.save(_:)` and `NSDocument.saveAs(_:)`. Repository-wide inspection finds no `NSDocument` subclass or project responder implementing those selectors. `FolderMetadataEditorSheet.swift:165` does have a private `save(_:)` for its own sheet; that does not implement project Save/Save As. Project state instead lives in `ProjectFile`, `ProjectSession`, and explicit window snapshots (`AppDelegate.swift:1526–1535`). The only other app `NSDocumentController` uses concern recent URLs.

**Impact:** familiar commands imply manual project save/copy semantics the app does not implement. This is not evidence that autosaved project data is lost.

**Remediation:** decide the product contract: either implement Save/Save Project Copy with clearly defined data scope, or remove inert commands and communicate automatic persistence. Any project-copy command must preserve relative references and scientific provenance.

**Acceptance:** Cmd-S and Cmd-Shift-S have documented, observable behavior or are absent from the menu. Reopening verifies edited metadata, annotations, view state and project-copy independence according to that contract.

### WF-06 — P2 — Missing/invalid workflow packages disappear instead of remaining repairable

**Proven in source.** Package import stores a filesystem path, not a managed copy (`Services/WorkflowLibrary.swift:612–620`). On refresh, failed validation is discarded with `try?` / `compactMap` (`:584–595`). `WorkflowLibraryViewModel.swift:141–150` replaces UI rows with valid results only. Even `removePackage(withManifestID:)` cannot remove a now-invalid entry because it requires successful validation (`WorkflowLibrary.swift:623–627`).

**Impact:** moving, disconnecting, or damaging a previously imported package silently removes it from the user's library while stale paths/enablement remain. Users have no row to locate or diagnose it.

**Remediation:** persist a library registration identity, last known metadata and URL independently of validation. Render missing/invalid entries with Locate, Revalidate and Remove actions; decide explicitly whether Add links to source or installs a managed copy.

**Acceptance:** missing entrypoints, missing volumes and malformed manifests remain visible and explainable after restart; removal works without parsing the source; Locate restores the existing entry.

### WF-07 — P2 — Importing a replacement workflow from a new path creates duplicate identities after refresh

**Proven in source.** `WorkflowLibraryViewModel.swift:160–164` replaces the visible row by manifest ID, but `WorkflowLibraryImportedPackageStore.addPackage` de-duplicates only the source path (`WorkflowLibrary.swift:612–615`). Both paths survive and return on refresh. UI iteration identifies each row by manifest ID (`WorkflowLibraryPanelView.swift:143`).

**Impact:** two versions with one manifest ID reappear after refreshing/reopening, yielding ambiguous enablement and duplicate SwiftUI identities. Exact rendered corruption is not runtime-tested.

**Remediation:** define replacement/version semantics in the persistent store, enforcing a unique execution identity or explicit version identity. UI replacement must update the same persisted registration.

**Acceptance:** adding the same ID from a second path either replaces the old registration atomically or presents a clearly versioned choice; reload never produces duplicate row identities.

### WF-08 — P2 — Fast navigation away from AI settings drops the latest API-key edit

**Proven in source.** `Views/Settings/AIServicesSettingsTab.swift:278–287` waits 500 ms before storing a key and returns when cancelled. `.onDisappear` at 188–189 calls `cancelPendingSaves`, cancelling all three tasks at 393–399 without flushing values.

**Impact:** pasting/updating a key and immediately changing settings tabs leaves the old/missing credential in Keychain. Closing settings is affected only if it triggers this view lifecycle event; that needs AppKit verification. Explicit Clear All uses immediate deletion and is not subject to this debounce. The user can reasonably believe configuration succeeded and encounter missing-key failures or unintended fallback behavior.

**Remediation:** persist latest values on explicit commit or flush pending writes on departure; debounce validation/network work independently. Preserve visible write errors.

**Acceptance:** paste and close/change tabs within 100 ms, reopen, and verify the exact new key via a fake Keychain service. Replacing and manually clearing fields obey the same lifecycle; retain the existing immediate Clear All behavior. No actual credentials need to enter tests.

## Design and lifecycle risks requiring explicit product decisions

### WF-R1 — P1 product priority — AI context disclosure needs a clearer boundary

AI is off by default (`LungfishCore/Models/AppSettings.swift:236`) and keys use Keychain: positive controls. Settings also explicitly disclose provider fallback (`AIServicesSettingsTab.swift:96`), so this is not an undisclosed-fallback claim. However the enablement text only says queries retrieve genomic context (`:82–85`), while every system prompt can automatically include bundle names, sample name examples, visible sample names and variant/sample table examples (`Services/AI/AIAssistantService.swift:419–465`). `sendWithFallback` sends the same conversation/context to successive configured providers after eligible failure (`:280–306`). Tool results are automatically added to subsequent provider messages (`:134–169`).

The registry is constrained to query, table-read, viewer navigation and PubMed tools (`AIToolRegistry.swift:105–119,275–299`); no arbitrary shell/file-write operation is exposed here. Do not describe this assistant as an unrestricted execution agent. The principal concern is data sharing and provider scope, including structured data identifiers users may not realize are sent with a general question.

**Recommendation:** show which context classes and recipient endpoints are enabled; offer per-project identifier/table-context controls and an explicit provider allowlist/fallback toggle. Provide inspectable outgoing context and apply redaction before prompt construction. Audit `AIToolRegistry.swift:270` public tool-argument logging and `AIAssistantService.swift:88,144` public previews for unnecessary sensitive content. Acceptance uses synthetic sample identifiers and a recording provider to verify redaction, allowed recipients, and no network calls while AI is disabled. No actual disclosure of a particular user's data is asserted.

### WF-R2 — P2 — Read-only viewing is coupled to required tool setup on the Welcome path

`WelcomeWindowController.swift:300–307` gates `canLaunch` on the required pack being ready and not installing/refreshing/reconciling; welcome actions use this at 832/887 and guard at 1020. Setup failures remain visible (`:515–517`) and reinstallation can be retried; launch reconciliation deliberately yields first-install ownership to Welcome (`AppDelegate+DependencyReconciliation.swift:75–83`). Plugin Manager has offline guidance and reinstall actions (`PluginManagerView.swift:456–463,574–575,662`). These are real recovery paths.

**Product tradeoff:** a fresh offline machine may be prevented from entering ordinary browsing from Welcome even when its intended task needs no external tool. External-open paths were not proven to obey the same gate, so this is not a claim that all viewing is blocked. Offer a clearly scoped viewer-only entry and defer tool setup until a requiring action, if the application can technically support it. Validate offline fresh launch, cached tools, missing environment, failed install and retry, and tool updates while another project is open.

### WF-R3 — P2 — Cancellation completion and general retry need stronger contracts

Operations expose useful terminal states, logs and failure files, but the center calls a synchronous cancellation callback then immediately finishes cancellation/unlocks (`LungfishKit/OperationCenter.swift:721–725,776–783`). A callback that only requests asynchronous cancellation may return before worker exit. This is a conditional race, not proof that every operation is unsafe. Require an acknowledged worker-terminal event before releasing output ownership; exercise cancellation during startup, processing and publication.

General operation context menus offer CLI/log/reveal/cancel/clear (`OperationsPanelController.swift:1504–1564`) but no generic retry descriptor. Automatic HTTP retry metadata is different from user retry. Classifier database rebuild already has an explicit Retry button and request identity protection (`MainSplitViewController+ClassifierDisplay.swift:670,686–703`), a useful pattern. Add “Run Again…” with restored, inspectable inputs/options for repeatable operations; avoid unsafe blind retries of partial writers.

### WF-R4 — P2 — Export selection scope is inconsistent

GFF3 chooses any current viewer document first, failing if it has no annotations; only without a document does it inspect sidebar selection, and then exports the first eligible item (`AppDelegate+ImportCenter.swift:3044–3077`). Menu validation accepts any current document (`:3091–3096`). This can yield a no-annotations error even when the user has selected an exportable reference bundle, and multi-selection is silently narrowed. Confirm selection semantics in UI before labelling individual outcomes data loss. Use one export-scope model showing source name, count and selection, and disable only when no supported scope exists.

### WF-R5 — Conditional ZIP staging lifetime issue

Verified chain: `LGEZipImportResolver.swift:77–83` creates extraction staging and returns a recognized native object; cleanup removes staging (`:40–45`). `MainSplitViewController+MultiDocument.swift:552` presents a FASTQ sheet with deferred import callback (`MainSplitViewController+FASTQImport.swift:353–363`), while staging cleanup occurs at 572 or after other-file import at 558. A flattened native package containing raw FASTQ/BAM payload could therefore lose those inputs before the sheet is accepted. Ordinary raw-FASTQ ZIPs are rejected by this resolver, and ordinary `.lungfishfastq` ZIPs stay atomic and do not take this sheet path; **the standard zipped FASTQ bundle is not proven broken**. Fixing WF-01 should prevent most of the exposure. Stage ownership should nevertheless remain attached to all consumer tasks until completion/cancellation; add a synthetic packaged attachment fixture to prove or dismiss the remaining route.

## Simplification recommendations

1. Establish a single capability-driven object registry spanning detection, open, atomic copy, import, export, inspector and menu validation. The same bundle should have the same identity across Finder open, Import Center, sidebar drops and ZIP imports.
2. Keep current core/specialized workflow grouping, but make frequently used compatible actions primary and show dependency/install state inline. Keep all tools searchable rather than adding more top-level menu branches.
3. Treat each operation as a durable user object: exact source/destination, configuration, current phase, terminal status, result navigation and repeatable retry. Wire all import entry points to that object; retire the separate dispatch-only history or label it honestly.
4. Make automatic persistence explicit and separate project copy/export from view preferences. Users should know what will be present after reopening before they learn bundle internals.
5. Unify import validation across drag/drop and file panels. Show intended destination and number of inputs before dispatch; rejected/no-op sources must not silently disappear.
6. Keep migration import breadth, but expose format-specific support limits and a per-item import report. A catalog entry alone does not establish lossless migration fidelity.
7. Preserve constrained AI tools and default-off behavior; improve context/recipient transparency before adding action capabilities.

## Implementation order and acceptance journey matrix

**Phase 1 — Reliability before expansion:** WF-01 and WF-02, then WF-03/WF-04; small deterministic tests around planning and failure injection. No external scientific tools needed. Add bundle-registry parity checks and guarantee operation finalization.

**Phase 2 — Recovery and persistence:** WF-05 through WF-08; missing-file/volume fixtures, duplicate package-ID fixtures, fake Keychain persistence. Restore/remove workflow registrations independently of validation. Document auto-save semantics.

**Phase 3 — Coherent interaction model:** export-scope chooser, durable operation descriptors and retry, viewer-only setup decision, AI context/provider controls. Use recorded network stubs and tiny generic files, not real sample data.

**Phase 4 — Focused manual validation:** run each major family through empty project → import/open → inspect → configure → run → cancel or fail → retry → locate result → save/close → reopen → export. Cross that sequence with: one/many files, file versus directory versus ZIP, valid/malformed/missing inputs, read-only destination, interrupted helper, changed frontmost project, missing external dependency and offline mode. Verify the destination and imported object count at each transition. Do not mistake source-level route coverage for successful full scientific workflows.

## Positives worth retaining

- Explicit per-window operation routing context and frontmost project mirroring (`AppDelegate.swift:1512–1523`, `OperationCenter.swift:107–120`).
- Classified running/cancelling/terminal operation states, warning labels, CLI command and log diagnostics, durable failure reports (`OperationCenter.swift:132–208,698–704`).
- Cancellation-aware native process handling in `FASTQOperationExecutionService.swift:763–806`, including process-tree termination and cancellation checks.
- Classifier database recovery has actionable retry plus request-generation checks, rather than an unrecoverable empty viewer.
- Specialized workflows can be enabled deliberately and unsupported command-runner packages explicitly say they are review-only (`Services/WorkflowLibrary.swift`, `WorkflowPackageRunnerKind` extension).
- Setup and dependency reconciliation deliberately avoid competing installers; missing requirements do not silently masquerade as ready.
- AI has an off-by-default setting, finite tool rounds, repeated-failure termination, a bounded tool registry, and Keychain-backed credentials.

## Scope limitations

This report does not certify runtime correctness of every renderer, tool adapter, scientific output, platform-specific menu responder, permissions prompt, accessibility traversal, keyboard shortcut, export image, or migration adapter. It does not establish comparative scientific accuracy, biological applicability or operational experimentation advice. Those require bounded fixtures, runtime QA, and domain-specific evaluation. No success of a build/test run is claimed.
