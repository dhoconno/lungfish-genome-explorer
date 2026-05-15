---
title: Shared Projects and Bundle Migration
chapter_id: appendices/shared-projects
audience: power-user
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 6
task: Coordinate advanced multi-user project work and inspect bundle migration readiness from the command line.
tags: [appendix, reference, power-user, project, multi-user, locking, migration, provenance, cli]
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

LGE now provides that signal through project-local lock records. The advanced CLI commands write a machine-readable file at `.lungfish/project.lock` inside the project. The GUI reads the same metadata on project open so teams get a consistent warning surface across CLI and app workflows.

[Bundle](../../GLOSSARY.md#bundle) migration is also exposed through the same `project` command group. The current implementation is conservative: it scans bundles, reports the schema versions it can see, leaves bundles whose manifests are already current untouched, and refuses to rewrite unsupported legacy schemas until a real transformer exists.

A note on the executable name before the examples: the commands below invoke the CLI as `lungfish`, matching the command name the help text uses. Installed releases expose the binary on `PATH` as `lungfish`. If you are building from source, the SwiftPM product is `lungfish-cli`, so invoke `.build/debug/lungfish-cli project ...` (or the release variant) instead. The application bundle ships the same binary at `Lungfish.app/Contents/MacOS/lungfish-cli`. The two names refer to the same program.

## Locking a project

Use `lungfish project lock` before an advanced workflow that expects exclusive write access to a project:

```sh
lungfish project lock ~/Projects/SARS-CoV-2.lungfish --mode exclusive
```

The command creates `.lungfish/project.lock` using an atomic write. The record contains the tool name, LGE CLI version, project path, user, host, process id, process start time when available, current working directory, creation time, and lock mode. A typical record looks like this:

```json
{
  "appVersion": "lungfish-cli 0.4.0-alpha.16",
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

The lock file is a coordination record, not an OS-level lease. The CLI process that created the record exits as soon as `lungfish project lock` returns, so the recorded `pid` is the short-lived CLI process, not your shell or your maintenance script. Other tooling that inspects the lock will treat a local lock whose recorded process is no longer running as stale and may replace it. Practical rules:

1. If a lock already exists and the recorded process is still live on this host, `lungfish project lock` refuses to replace it.
2. If the lock points at a local process that has exited, the command treats it as stale and replaces it.
3. Locks from another host (where this machine cannot tell whether the process is still alive) are treated as active unless you pass `--force`.

So the lock signals intent to other tools, not exclusive control over the project. If you need to keep an active hold across a long manual workflow, your maintenance script (or wrapper) is responsible for re-asserting the lock or otherwise ensuring no concurrent edits happen while it runs.

## Unlocking a project

Remove your own lock when the advanced workflow is complete:

```sh
lungfish project unlock ~/Projects/SARS-CoV-2.lungfish
```

`unlock` removes a lock owned by the current process, or a stale local lock owned by the current user. If the lock belongs to another user, an active different process, or an unknown or remote host, the command refuses unless `--force` is supplied:

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

The current migration report lists manifest-backed Lungfish bundle directories that contain a `manifest.json`; in practice this currently covers `.lungfishref` reference bundles. FASTQ-derived bundle directories that use `analyses-manifest.json` or `derived.manifest.json` are not part of this migration scan.

`1.0` reference bundles that already carry a `browser_summary` field in their manifest are reported as `current` with action `none`, and neither their `manifest.json` nor any `.lungfish-provenance.json` sidecar is rewritten. `1.0` reference manifests that are missing `browser_summary` get a schema-maintenance migration: with `--dry-run`, the report flags them as `migration-available` with action `dry-run-synthesize-browser-summary`; without `--dry-run`, LGE synthesizes the `browser_summary` field, backs up the original manifest under `.lungfish/migrations/`, and writes migration provenance describing the change.

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

For routine GUI work, continue using the project normally. When the GUI opens a project with active or unknown lock metadata, it marks the window `Read Only`, shows a persistent project-lock banner, and blocks project-writing workflows so shared teams can rely on the same lock signal in both CLI and app sessions.

## See also

- [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) for the project-folder layout these commands operate on.
- [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for the run records that migrations preserve and that workflows attach to outputs.
- [Power User Notes](power-user-notes.md) for the tool-internals and reproducibility caveats that pair with the workflows referenced here.
- [CLI Reference](cli-reference.md) for the full set of `lungfish project ...` commands and their flags.
