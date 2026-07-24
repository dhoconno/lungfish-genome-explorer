# Current Workbook Single-Flight Synchronization Design

Date: 2026-07-24

## Purpose

Make `current.xlsx` a dependable, provenance-tracked snapshot of the current
Lungfish Genome Explorer (LGE) genotype review state without allowing workbook
generation to interfere with annotation entry.

The current implementation schedules a workbook publication 350 milliseconds
after each matrix edit. Workbook generation holds the bundle publication lock
for the duration of the CLI workflow. A later comment, review, or style edit
attempts to acquire the same nonblocking lock and can fail with “Workbook
publication lock is already held.” A lingering lock file is not the cause; the
failure occurs only while another process owns the lock.

`annotations.json` and its audit provenance remain the authoritative immediate
record of analyst edits. `current.xlsx` is a derived snapshot that may briefly
lag behind LGE while edits are being made.

## User-Visible Behavior

The Current Workbook section has one primary action:

**Update and View Current Excel Version**

The action behaves as follows:

- When the workbook is current, it opens the existing `current.xlsx`
  immediately and does not invoke `lungfish-cli`.
- When the workbook is dirty, it requests one synchronized update and opens the
  new workbook only after publication succeeds.
- When an update is already running, it joins that update and opens the
  resulting workbook when it succeeds. It never starts a competing CLI process.
- When publication fails, the workbook remains dirty and is not opened as
  though synchronization succeeded. The existing operation failure report
  remains available.

Excel is opened through `NSWorkspace` using the system application associated
with `.xlsx` files. This preserves the active LGE matrix viewport. LGE does not
automatically open Excel after background synchronization.

The Current Workbook section reports one of these states:

- **Current** — the recorded input fingerprint matches the live review inputs.
- **Pending edits** — LGE contains inputs not represented by `current.xlsx`.
- **Updating** — one publication is running for this bundle.
- **Pending edits while updating** — the running publication represents an
  older input generation and one follow-up update is required.
- **Failed** — the last attempt failed; the workbook remains dirty.

## Automatic Synchronization

Automatic synchronization uses the same coordinator and update path as the
primary button.

- An edit marks the workbook dirty immediately.
- After 90 seconds without another relevant edit, the coordinator requests an
  update. Every relevant edit restarts this inactivity window, so typing and
  revising a lengthy comment does not trigger workbook generation mid-entry.
- Leaving the genotype bundle requests an immediate update if it is dirty.
- Hourly timers and application-quit workbook generation are intentionally out
  of scope.
- Automatic triggers never open Excel.

All triggers are idempotent. Idle, bundle-switch, and explicit button requests
for the same dirty generation join one per-bundle update.

## Per-Bundle Single-Flight Coordinator

A main-actor `GenotypeCurrentWorkbookSyncCoordinator` owns synchronization
state keyed by standardized bundle URL. Each entry contains:

- the live input fingerprint;
- the fingerprint represented by the latest successful workbook revision;
- a monotonic dirty generation;
- the generation currently being published;
- the active update task, if any;
- whether a follow-up update is required;
- whether Excel should open after the active or follow-up update;
- the most recent failure.

Only the coordinator may launch
`GenotypeCurrentWorkbookUpdateExecutionService`. Callers submit an update
intent:

- `.automaticIdle`
- `.bundleSwitch`
- `.updateAndView`

If no update is active, the coordinator snapshots the current request and
starts one operation. If an update is active, the request joins it. A newer
dirty generation sets a follow-up flag; multiple newer changes still produce
at most one follow-up operation for the newest generation.

The coordinator retains the bundle update state until the running operation and
any required follow-up complete, even if the genotype viewport is no longer
selected. UI controllers observe state but do not own the task lifetime.

## Annotation Edits During Publication

Analyst commands must not surface the workbook publication lock as an editing
error.

The genotype controller reports workbook-update activity to its annotation
command path. A comment, review, or matrix-style command submitted during the
publication lock window is deferred in submission order. The controller:

1. keeps the command associated with the bundle and author;
2. displays a nonmodal “Saving after workbook update” state;
3. replays the command as soon as the update releases the lock, whether the
   workbook update succeeded or failed;
4. refreshes matrix state and audit state from the published sidecar;
5. marks the workbook dirty at the new generation and requests one idle
   follow-up update.

The host retains the genotype controller until deferred commands have been
flushed, so switching bundles does not discard a submitted edit. Commands are
not partially applied, and normal annotation-sidecar stale-revision validation
still runs during replay.

Only the known “publication lock currently held” condition is deferred. Unsafe
locks, malformed sidecars, stale revisions, read-only bundles, and other real
errors continue to fail visibly.

## Currentness Fingerprint

Avoiding unnecessary CLI calls requires a reproducible comparison rather than
an in-memory dirty Boolean alone.

`GenotypeCurrentWorkbookInputFingerprint` is a versioned SHA-256 digest of
canonical JSON containing:

- the decoded annotation sidecar in deterministic encoded form;
- effective workbook haplotype calls in deterministic sample/locus order;
- sorted included workbook loci;
- candidate display settings that affect workbook output;
- manifest-attested MHC candidate artifact paths, sizes, and checksums;
- the fingerprint schema version.

The workbook revision provenance records:

- `currentWorkbookInputFingerprint`;
- `currentWorkbookInputFingerprintSchemaVersion`;
- the resolved update intent;
- all existing command, runtime, input, output, checksum, size, exit-status, and
  wall-time provenance.

On bundle load and after every relevant edit, LGE computes the live fingerprint
off the main thread. It compares that value with the latest current-workbook
revision’s recorded provenance fingerprint. A missing or unsupported
fingerprint is treated as dirty once, allowing the next successful update to
establish the new baseline.

The update service computes and records the fingerprint from the immutable
inputs actually used for publication. The UI does not declare the workbook
current until the published fingerprint equals the newest live fingerprint.

## Data Flow

### Matrix edit

1. Validate the command against current raw read evidence and selection.
2. Publish `annotations.json`, annotation provenance, and audit immediately
   when the publication lock is available.
3. If a workbook publication owns the lock, defer only that annotation command
   and replay it after the lock is released.
4. Recompute the live input fingerprint and increment the dirty generation.
5. Restart the 90-second inactivity trigger.

### Automatic update

1. Idle or bundle-switch trigger submits an automatic intent.
2. The coordinator returns immediately if the recorded workbook fingerprint
   already equals the live fingerprint.
3. Otherwise it starts or joins the one per-bundle update.
4. Completion reloads the manifest and workbook revision, recomputes
   currentness, and schedules one follow-up only if a newer generation exists.

### Update and view

1. Resolve and validate the manifest-backed `current.xlsx` URL.
2. If current, open it immediately.
3. If dirty, start or join synchronization and set `openAfterSuccess`.
4. After the final required generation succeeds, open the manifest-resolved
   workbook URL.

## Failure Handling

- Annotation persistence is never reported as failed solely because a workbook
  update temporarily owns the publication lock.
- A failed workbook update does not roll back already published annotations.
- A failed update leaves the fingerprint dirty and preserves
  `openAfterSuccess` only for an explicit retry initiated by the analyst.
- Missing or non-regular `current.xlsx` disables immediate viewing and requires
  a successful update before opening.
- Read-only bundles may view an existing current workbook but cannot update it.
- Switching bundles never blocks navigation; synchronization continues through
  the coordinator and Operations Panel.
- Repeated automatic failure does not form a retry loop. Another relevant edit,
  bundle switch, or explicit action is required.

## Performance

- Fingerprints use already loaded semantic inputs plus manifest checksums; they
  do not hash candidate payload files repeatedly.
- File hashing for the small annotation sidecar and provenance reads runs off
  the main thread.
- The idle timer is per bundle and is reset rather than multiplied.
- The coordinator stores one task and at most one follow-up marker per bundle.
- Context menus and annotation controls consume cached synchronization state.
- Existing matrix rendering and selection hot paths remain unchanged.

## Testing

### Unit tests

- Equal live and recorded fingerprints are current.
- Any relevant annotation, call, locus, tint, or candidate checksum change is
  dirty.
- Fingerprints are deterministic across dictionary and input ordering.
- Missing/unsupported provenance fingerprint is dirty.
- A clean update-and-view request opens without a CLI call.
- A dirty request updates once and then opens.
- Concurrent idle, bundle-switch, and explicit requests are single-flight.
- An explicit view request joins an active automatic update.
- Edits during an active update are deferred, replayed in order, audited, and
  produce one follow-up generation.
- Update success cannot clear a newer dirty generation.
- Update failure leaves the workbook dirty and does not open it.
- Read-only and missing-current-workbook states behave as specified.

### Integration tests

- Rapid comment/review cadence does not produce a publication-lock alert.
- Bundle switching starts one background update and preserves deferred edits.
- The generated workbook and manifest revision contain the exact published
  fingerprint and full reproducibility provenance.
- The copied real-world legacy `_0nt_nov` bundle continues using the
  annotation-only compatibility path without weakening full-update validation.

### Performance tests

- Fingerprint computation remains bounded for representative large cohorts.
- Repeated dirty notifications allocate only one timer and one follow-up marker.
- Update request handling and context-menu state reads remain below the existing
  interactive latency thresholds.

## Acceptance Criteria

- `Add comment`, false-positive, false-negative, and style actions never show
  the expected transient workbook-lock error.
- At most one `update-current-workbook` CLI process runs per genotype bundle.
- The primary action is named “Update and View Current Excel Version.”
- Clean workbooks open without an unnecessary CLI invocation.
- Dirty workbooks update once and open only after successful publication.
- Idle and bundle-switch synchronization never open Excel.
- New edits made during publication are preserved, audited, and represented by
  one later workbook update.
- Workbook currentness survives bundle reload through the recorded fingerprint.
- Scientific call validation, crash-safe workbook rotation, and provenance
  requirements remain intact.
