---
title: Shared Projects and Bundle Migration
chapter_id: 01-foundations/09-shared-projects
audience: power-user
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 6
task: Coordinate advanced multi-user project work and inspect bundle migration readiness from the command line.
tags: [foundations, project, multi-user, locking, migration, provenance, cli]
tools: [lungfish project lock, lungfish project unlock, lungfish project migrate]
entry_points:
  - "CLI: lungfish project lock"
  - "CLI: lungfish project unlock"
  - "CLI: lungfish project migrate"
shots: []
planned_shots: []
illustrations: []
glossary_refs: [project, bundle, provenance-sidecar]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

A shared Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) is still just a project folder. The difference is operational: more than one person or process can see the folder, usually through shared storage, a lab workstation, or a scripted batch workflow. That makes coordination visible. If one analyst is running a migration or a long manual repair while another analyst opens the same project, the second analyst needs a reliable signal before changing files.

LGE now provides that signal through project-local lock records. The advanced CLI commands write a machine-readable file at `.lungfish/project.lock` inside the project. GUI project-open warnings and read-only mode are follow-on work, but the metadata is already there for the GUI and for other automation to inspect.

[Bundle](../../GLOSSARY.md#bundle) migration is also exposed through the same `project` command group. The current implementation is conservative: it scans bundles, reports the schema versions it can see, leaves current-version bundles byte-for-byte untouched, and refuses to rewrite unsupported legacy schemas until a real transformer exists.

## Locking a project

Use `lungfish project lock` before an advanced workflow that expects exclusive write access to a project:

```sh
lungfish project lock ~/Projects/SARS-CoV-2.lungfish --mode exclusive
```

The command creates `.lungfish/project.lock` using an atomic write. The record contains the tool name, LGE CLI version, project path, user, host, process id, process start time when available, current working directory, creation time, and lock mode. A typical record looks like this:

```json
{
  "appVersion": "lungfish-cli 0.4.0-alpha.12",
  "createdAt": "2026-05-09T19:34:43Z",
  "cwd": "/Users/diana/Projects",
  "host": "lab-mac-01.local",
  "mode": "exclusive",
  "pid": 48291,
  "processStartTime": "Sat May  9 19:33:10 2026",
  "projectPath": "/Users/diana/Projects/SARS-CoV-2.lungfish",
  "schemaVersion": 1,
  "toolName": "lungfish project lock",
  "user": "diana"
}
```

The `mode` value is intentionally a label, not a permission system. Use `exclusive` for work that should block other writers. Use a more specific label such as `maintenance` when you want other tools to show a clearer warning.

If a lock file already exists and belongs to a live local process, `lungfish project lock` refuses to replace it. If the lock points at a local process that no longer exists, the command treats it as stale and replaces it. Locks from another host are treated as active unless you explicitly override them.

## Unlocking a project

Remove your own lock when the advanced workflow is complete:

```sh
lungfish project unlock ~/Projects/SARS-CoV-2.lungfish
```

`unlock` only removes a lock owned by the current user and the current process. If the lock belongs to another user, another process, or another host, the command refuses to remove it:

```sh
lungfish project unlock ~/Projects/SARS-CoV-2.lungfish --force
```

Use `--force` only after checking that the owner is no longer working in the project. A forced unlock removes the file; it does not stop the other process.

## Migration reports

Run `migrate` when you inherit an older project or before sharing a project with a newer LGE installation:

```sh
lungfish project migrate ~/Projects/SARS-CoV-2.lungfish
```

For automation, request JSON:

```sh
lungfish project migrate ~/Projects/SARS-CoV-2.lungfish --format json
```

The report lists every LGE bundle directory found under the project. Current `.lungfishref` bundles with manifest format `1.0` are reported as `current` with action `none`. Their `manifest.json` and any `.lungfish-provenance.json` sidecar are not rewritten.

Unsupported legacy bundles are reported as `unsupported` with action `report-only` or `dry-run-report`. They are not renamed or changed. This is deliberate. A migration that rewrites scientific bundle data must know the old schema, copy or rewrite the payload, preserve provenance sidecars, and keep the original bundle data by moving the original to a `.v<old>` suffix before the new bundle replaces it. Until a schema-specific transformer exists, LGE reports the gap instead of pretending to migrate.

Use `--dry-run` when you only want the scan result:

```sh
lungfish project migrate ~/Projects/SARS-CoV-2.lungfish --dry-run --format json
```

## Provenance expectations

Project locks are coordination metadata, not scientific outputs. Migration is different: when a migration actually rewrites or wraps scientific data, it must preserve existing [provenance sidecars](../../GLOSSARY.md#provenance-sidecar) and write new migration provenance describing the workflow or tool name and version, options, inputs, outputs, checksums, file sizes, runtime identity, exit status, stderr when useful, and wall time.

The current no-op/report-only migration does not create new scientific outputs. It does preserve existing sidecars by leaving bundles untouched and by reporting whether a sidecar was present for each inspected bundle.

## Practical policy for shared labs

Treat `.lungfish/project.lock` as the source of truth for advanced command-line maintenance. Before running a script that edits a project, create a lock. Before opening a project that someone else is maintaining, inspect the lock record or ask the owner. After a script succeeds or fails, unlock the project as part of cleanup.

For routine GUI work, continue using the project normally. The current GUI does not yet warn on project-open when the lock exists, so shared teams should agree on CLI lock use before relying on shared storage for concurrent edits.
