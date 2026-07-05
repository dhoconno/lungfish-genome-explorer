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

## What it is

This appendix is about coordinating a project that more than one person or process touches, through the `lungfish project lock`, `unlock`, and `migrate` commands. For the project-folder layout these commands operate on, see [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md). For the provenance records migration preserves, see [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md).

A shared Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) is still just a project folder. What changes is operational: more than one person or process can now see that folder, usually across shared storage, on a lab workstation, or through a scripted batch workflow. Coordination suddenly matters. If one analyst is mid-migration or deep in a long manual repair while a second analyst opens the same project, the second needs a reliable signal before touching a single file.

LGE supplies that signal through project-local lock records. The advanced CLI commands write a machine-readable file at `.lungfish/project.lock` inside the project, and the GUI reads the same metadata whenever it opens a project. So a team sees one consistent warning whether they came in through the CLI or the app.

[Bundle](../../GLOSSARY.md#bundle) migration lives in the same `project` command group, and the current implementation is deliberately cautious. It scans the bundles, reports the schema versions it finds, leaves any bundle whose manifest is already current untouched, and refuses to rewrite an unsupported legacy schema until a real transformer exists for it.

The working rhythm is simple. Lock a project before any scripted maintenance, unlock it when you are done, and when you inherit an older project, run `migrate` in dry-run mode first so you can read the report before anything gets rewritten.

One note on the executable name before the examples. The commands below invoke the CLI as `lungfish`, matching the name the help text uses, and installed releases put the binary on `PATH` under exactly that name. If you build from source, the SwiftPM product is `lungfish-cli`, so you would run `.build/debug/lungfish-cli project ...` (or the release variant) instead. The application bundle ships the same binary at `Lungfish.app/Contents/MacOS/lungfish-cli`. Both names point at one program.

## Locking a project

Run `lungfish project lock` before any advanced workflow that expects exclusive write access to a project:

```sh
lungfish project lock ~/Projects/SARS-CoV-2.lungfish --mode exclusive
```

The command creates `.lungfish/project.lock` through an atomic write. Inside, the record holds the tool name, the LGE CLI version, the project path, the user, the host, the process id, the process start time when it is available, the current working directory, the creation time, and the lock mode. A typical record looks like this:

```json
{
  "appVersion": "lungfish-cli 0.5.0-alpha11",
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

The `mode` value is a label by design, not a permission system. Use `exclusive` for work that should block other writers. Reach for a more specific label such as `maintenance` when you want other tools to show a clearer warning.

The lock file is a coordination record, not an OS-level lease. The CLI process that wrote it exits the instant `lungfish project lock` returns, so the recorded `pid` belongs to that short-lived CLI process, not to your shell or your maintenance script. Any other tool inspecting the lock will treat a local lock whose recorded process has died as stale, and may replace it. The practical rules:

1. If a lock already exists and the recorded process is still live on this host, `lungfish project lock` refuses to replace it.
2. If the lock points at a local process that has exited, the command treats it as stale and replaces it.
3. Locks from another host (where this machine cannot tell whether the process is still alive) are treated as active unless you pass `--force`.

So the lock advertises intent to other tools. It does not hand you exclusive control over the project. If you need to hold that ground across a long manual workflow, your maintenance script or its wrapper is the thing responsible for re-asserting the lock, or for otherwise making sure no concurrent edits slip in while it runs.

## Unlocking a project

Remove your own lock once the advanced workflow finishes:

```sh
lungfish project unlock ~/Projects/SARS-CoV-2.lungfish
```

`unlock` removes a lock owned by the current process, or a stale local lock owned by the current user. If the lock belongs to another user, to a different process that is still alive, or to an unknown or remote host, the command refuses unless you supply `--force`:

```sh
lungfish project unlock ~/Projects/SARS-CoV-2.lungfish --force
```

Use `--force` only after you have confirmed the owner is no longer working in the project. A forced unlock deletes the file. It does not stop the other process.

## Migration reports

Run `migrate` when you inherit an older project, or before you share a project with a newer LGE installation:

```sh
lungfish project migrate ~/Projects/SARS-CoV-2.lungfish
```

For automation, request JSON:

```sh
lungfish project migrate ~/Projects/SARS-CoV-2.lungfish --format json
```

The current migration report lists manifest-backed Lungfish bundle directories, meaning those that contain a `manifest.json`. In practice that covers `.lungfishref` reference bundles today. FASTQ-derived bundle directories, which use `analyses-manifest.json` or `derived.manifest.json`, fall outside this migration scan.

A `1.0` reference bundle that already carries a `browser_summary` field in its manifest is reported as `current` with action `none`, and neither its `manifest.json` nor any `.lungfish-provenance.json` sidecar is rewritten. A `1.0` reference manifest that is missing `browser_summary` gets a schema-maintenance migration instead. With `--dry-run`, the report flags it as `migration-available` with action `dry-run-synthesize-browser-summary`. Without `--dry-run`, LGE synthesizes the `browser_summary` field, backs up the original manifest under `.lungfish/migrations/`, and writes migration provenance describing the change.

Unsupported legacy bundles are reported as `unsupported` with action `report-only` or `dry-run-report`, and they are neither renamed nor changed. That restraint is deliberate. A migration that rewrites scientific bundle data has to know the old schema, copy or rewrite the payload, preserve the provenance sidecars, and keep the original data by moving it to a `.v<old>` suffix before the new bundle takes its place. Until a schema-specific transformer exists, LGE reports the gap rather than pretend to migrate.

Use `--dry-run` when you only want the scan result:

```sh
lungfish project migrate ~/Projects/SARS-CoV-2.lungfish --dry-run --format json
```

## Provenance expectations

Project locks are coordination metadata, not scientific outputs. Migration is a different matter. When a migration actually rewrites or wraps scientific data, it must preserve the existing [provenance sidecars](../../GLOSSARY.md#provenance-sidecar) and write fresh migration provenance of its own: the workflow or tool name and version, the options, the inputs, the outputs, the checksums, the file sizes, the runtime identity, the exit status, stderr when it is useful, and the wall time.

The current no-op and report-only migration creates no new scientific outputs. It preserves the existing sidecars the easy way, by leaving bundles untouched, and it reports whether a sidecar was present for each bundle it inspected.

## Practical policy for shared labs

Treat `.lungfish/project.lock` as the source of truth for advanced command-line maintenance. Before you run a script that edits a project, create a lock. Before you open a project someone else is maintaining, inspect the lock record or ask the owner. When a script finishes, whether it succeeded or failed, unlock the project as part of cleanup.

For routine GUI work, just use the project as you always would. When the GUI opens a project that carries active or unknown lock metadata, it marks the window `Read Only`, shows a persistent project-lock banner, and blocks project-writing workflows, so a shared team leans on the same lock signal in both CLI and app sessions.

## See also

- [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) for the project-folder layout these commands operate on.
- [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for the run records that migrations preserve and that workflows attach to outputs.
- [Power User Notes](power-user-notes.md) for the tool-internals and reproducibility caveats that pair with the workflows referenced here.
- [CLI Reference](cli-reference.md) for the full set of `lungfish project ...` commands and their flags.
