---
title: Shared Projects and Bundle Migration
chapter_id: appendices/shared-projects
audience: power-user
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 20
task: Coordinate one project between two people or two machines with project locks, read the read-only state the window shows, and inspect or migrate older bundles from the command line.
tags: [appendix, reference, power-user, project, multi-user, locking, migration, provenance, cli]
tools: []
entry_points:
  - "CLI: lungfish-cli project lock"
  - "CLI: lungfish-cli project unlock"
  - "CLI: lungfish-cli project migrate"
shots:
  - id: shared-projects-read-only-banner
    caption: "The copied demo project opened with Open Read-Only after the lock alert, with (Read Only) after the project name in the window title. This Preview shows no yellow banner."
illustrations: []
glossary_refs: [advisory-lock, bundle, bundle-migration, checksum, exit-status, host-name, json, manifest, process, process-id, project, project-lock, project-store, provenance, schema-version, stale-lock, transformer, viewport]
features_refs: []
fixtures_refs: [demo-project]
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) is a `.lungfish` folder holding one piece of work. The project's folders are described in [A tour of the sidebar](../01-foundations/06-the-lungfish-project.md#a-tour-of-the-sidebar). Nothing about that folder stops two people opening it at once. Put it on a shared drive, or open it from a laptop and a lab workstation in turn, and two copies of LGE could write into the same files, with the second write quietly overwriting the first.

LGE prevents that with a [project lock](../../GLOSSARY.md#project-lock), a small record inside the project saying who holds it. The record lives at `.lungfish/project.lock` in the project folder. Finder hides names that begin with a dot, and Cmd-Shift-period in a Finder window shows or hides them. The LGE window checks this record before it opens a project and writes it when it takes one. On the command line only `project lock` and `project unlock` touch the record, and other `lungfish-cli` commands neither read nor write it.

The lock is [advisory](../../GLOSSARY.md#advisory-lock), which means it works only because every LGE [process](../../GLOSSARY.md#process), one running copy of the program, agrees to check it. macOS is never asked to refuse anyone, so a Finder copy, an rsync job, or a Dropbox or Google Drive sync client ignores the lock. It keeps one LGE window from colliding with another, and nothing more. A `lungfish-cli` command run against an open project is not stopped by it.

When LGE finds a lock it cannot claim, it offers to open the project read only. You can look at everything and change nothing. Every [viewport](../../GLOSSARY.md#viewport) opens and every bundle can be inspected, but no operation that writes into the project will start.

The second half of this appendix covers [bundle migration](../../GLOSSARY.md#bundle-migration). A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains. Each bundle carries a [manifest](../../GLOSSARY.md#manifest), a small file naming what the bundle holds, and each manifest carries a [schema version](../../GLOSSARY.md#schema-version), a number saying which layout it was written to. A project made by an older LGE can hold manifests in an older layout, and `lungfish-cli project migrate` reports on them.

## If a project just opened read only

Your project window says `(Read Only)` after its name because you chose **Open Read-Only** when LGE found another session's lock. LGE is keeping two writers apart.

The fix needs no Terminal, including for a lock left by a session on another Mac. Ask whoever has the project open to close it, then close your own window and open the project again. The opening alert names the person and the machine, so it tells you whom to ask. If the other session ended on this Mac, LGE clears its lock by itself and opens the project normally. When LGE cannot check the owner, for example because the lock came from another Mac, or when the lock file is damaged, the alert offers **Recover and Open**, which [Reading the window's read-only state](#reading-the-windows-read-only-state) describes. A reader who works only in the window can stop once the project reopens.

## Why you would do this

Three situations bring a reader here. Two people work on one project on lab storage in the same week. One person keeps a project on an external drive and opens it from two Macs. Or a project made a year ago is opened by a current LGE and its bundles need checking.

The first two are the same problem. Without the lock, whichever write lands second can find a result folder half written or the project's own index of its contents out of step, and nothing says so at the time. The lock turns silent damage into a visible refusal.

The third is a different worry. Older bundles still open, because LGE reads old manifests as well as new ones. What an old reference manifest can lack is a stored list of its chromosomes, so the window works the list out from the sequence data each time and takes longer to show it. `project migrate` finds those bundles and fills the list in without touching the sequence data.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The examples use the demo project, which is built in LGE rather than downloaded, as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. They assume it sits at `~/Desktop/lge-docs/LGE Manual Demo.lungfish`.

The first half of this appendix is done in the window. The second half is typed in Terminal, because the window has no controls for taking a lock, releasing one, or migrating bundles on demand.

Every command here acts on a real project at once, so practise on a copy. Select the `.lungfish` folder in Finder and press Cmd-D to duplicate it, point the commands at the duplicate, and delete it when you are done. A duplicate made while LGE has the original open carries that session's lock with it, which the section below explains.

## Reading the window's read-only state

Open a project another session holds and LGE stops before showing it, with an alert titled with the project name and the words "may already be open". When the other session is running, the text reads "Another session is using this project. You can open it read-only to inspect it. Close the other session and try again to make changes." When the lock file is damaged, the text says LGE cannot tell whether another session is using the project.

The alert offers up to three buttons.

| Button | What it does | When it appears |
|---|---|---|
| **Open Read-Only** | Opens the project for inspection. This is the default. | Always |
| **Cancel** | Opens nothing. | Always |
| **Recover and Open** | Clears the lock and opens the project for writing, after a second confirmation. | When LGE cannot tell whether the lock's owner is still running, as with a lock from another Mac, and could read the record, or when the record is damaged |

Above the buttons a details block names the session, the owner, the [host](../../GLOSSARY.md#host-name), which is the name of the computer that took the lock, the [process id](../../GLOSSARY.md#process-id), which is the number macOS gave that running copy of the app, when the lock was created, and the project path. The owner and host tell you whom to ask.

### Deciding whether to recover

**Recover and Open** raises a second confirmation, because it is the one choice here that can lose data. It asks you to make sure the project is closed in other LGE versions, in the command line, and on other computers, and warns "Recovering a lock while another session is writing can damage the project."

Recovery is safe when the other session has ended and dangerous when it has not, and LGE cannot tell for you. If the host is not your Mac, ask the person who uses that machine. If the host is your own Mac, open Activity Monitor from **Applications > Utilities**, type the process id into its search field, and see whether any running process has that number. Nothing found means the session is gone.

Recovery keeps the record it replaces. It moves the old lock into a `lock-recovery` folder inside the project's hidden `.lungfish` folder and writes a `recovery.json` beside it, holding the reason, the time, the original path, a [checksum](../../GLOSSARY.md#checksum) of the archived file, and the session that recovered it. That pair of files is the evidence if you later need to know who was locked out and when.

### What read only looks like

<!-- SHOT: shared-projects-read-only-banner -->

Once a project is open read only, the window title shows `(Read Only)` after the project name. That title is the reliable sign, so do not wait for a banner, which the window may not show. The opening alert is where the lock's owner is named.

Try to run something that writes and a sheet titled **Project Is Open Read Only** appears, naming the workflow and telling you to close the other writer or reopen the project once the lock is released. Classifying reads, calling variants, and importing are all refused. Opening a bundle and moving around its viewport stay available.

A project copied while another copy of LGE had the original open carries that session's lock inside it. Open the copy and its alert names the session from the original. Once that session has ended, the copy opens normally on the same Mac. On another Mac, use **Recover and Open**.

A folder built only with `lungfish-cli` and never opened in the app has no [project store](../../GLOSSARY.md#project-store), the app's own hidden index of the project's contents, and the app opens it read only for that reason. The title reads `(Read Only)` either way. If `(Read Only)` appears without a lock alert first, the missing project store is the cause.

## Before you type anything

This section is optional, and nothing in the window-only sections needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

A backslash before a space in a path, as in `LGE\ Manual\ Demo.lungfish`, keeps the space inside one folder name. Dragging a folder from Finder onto a Terminal window types its path with the backslashes in place.

## Locking a project from the command line

LGE sorts every lock into one of four states.

| State | Meaning |
|---|---|
| active | The recorded process is running on this Mac. |
| stale | The recorded process has exited, or macOS has since given its process id to a different program, which LGE detects by comparing start times. |
| unknown | LGE cannot tell. Every lock written on another Mac is unknown, so on shared lab storage most locks you meet read this way. |
| corrupted | The lock file exists but is not a readable lock record, for example because it is not valid [JSON](../../GLOSSARY.md#json), the plain-text format the record uses. |

Take a lock with `project lock` and the project's path. It works from any folder, because the path names the project.

```bash
lungfish-cli project lock ~/Desktop/lge-docs/LGE\ Manual\ Demo.lungfish --mode exclusive
```

On success it prints the project path, the lock file path, and the mode, and returns [exit status](../../GLOSSARY.md#exit-status) 0, the number that means success. Adding `--format json` prints the record itself, whose fields are these.

| Field | Holds |
|---|---|
| `user`, `host`, `pid` | Who holds the lock, on which computer, and in which process. These three tell you whom to ask. |
| `machineIdentifier` | A fixed code for the Mac, unrelated to any personal information. |
| `processStartTime` | When the process started, used to spot a reused process id. |
| `mode` | The label set by `--mode`. |
| `toolName`, `appVersion` | The program and version that took the lock. |
| `createdAt`, `cwd`, `projectPath`, `schemaVersion` | When, from which folder, on which project, and in which record layout. |

LGE compares `machineIdentifier` first and falls back to the hostname only for records too old to have it, because a Mac's hostname can change with the network. So an alert can name a host you do not recognise as your own Mac.

`--mode` records any label you type. The default is `exclusive`, and `maintenance` is the usual alternative. The mode is a label for other readers, not a permission level, and both block writes the same way.

A lock whose owner is still running, any lock from another Mac, and a corrupted lock all block a second lock. The command exits 1 with a message beginning "Project is already locked at", followed by the lock path and the owner as user, host, and process id.

### A command-line lock marks intent

A lock taken from the command line is a note that maintenance is under way, not a live hold on the project. An LGE window on the same Mac treats it as stale and opens the project normally, while a window on another Mac cannot check it and shows the lock alert. `project lock` writes the record and exits at once, so the process id in the record belongs to a command that has already ended. The lock is stale the moment the command finishes, and a second `project lock` on the same project succeeds because it replaces a stale lock without complaint. A script that needs an unbroken hold has to keep an LGE process running for the whole job, or make sure by other means that nobody else opens the project.

`--force` replaces a lock without the stale-owner checks, and unlike **Recover and Open** it keeps no archive. Use it only after checking in Activity Monitor that the owning process is not running, or after the named owner confirms they have finished. A lock from another Mac always reads as unknown, because this Mac cannot see that process, and clearing one takes `--force` for that reason.

## Unlocking a project

Release a lock with `project unlock`, which also works from any folder.

```bash
lungfish-cli project unlock ~/Desktop/lge-docs/LGE\ Manual\ Demo.lungfish
```

Without `--force`, the command removes only a lock held by its own process, or a stale lock held by the current user on this Mac. Anything else is refused with exit status 1 and a message beginning "Refusing to remove lock at", naming the owner and ending "pass --force to override". Same user on the same Mac is not enough while the owning process is still running.

A corrupted lock is refused too, with a message that the project lock file is corrupted and advice to pass `--force` only after confirming no active writer is using the project.

`--force` removes the lock in every case, including a corrupted one, and exits 0. It deletes the file but does not stop the process that wrote it, which carries on writing as if it still held the lock, so run the Activity Monitor check first.

Unlocking a project that has no lock prints `No project lock found:` with the path and exits 0, so the command is safe in a cleanup step that runs whether or not a lock was ever taken.

## Migrating older bundles

`project migrate` walks a project, reads the manifest of every bundle it finds, and reports the schema version of each. Run it with `--dry-run` first, which reports without changing anything.

```bash
lungfish-cli project migrate ~/Desktop/lge-docs/LGE\ Manual\ Demo.lungfish --dry-run
```

The report ends with one line per bundle. Lines like these appear on the demo project, which also lists its other bundles.

```text
- Analyses/Multiple Sequence Alignments/Primate-mitochondria.lungfishmsa: unreadable (report-only)
- Phylogenetic Trees/Primate mitochondria.lungfishtree: unreadable (report-only)
- Reference Sequences/HBB.lungfishref: current (none)
- Reference Sequences/chr20_10.0-10.5Mb.lungfishref: migration-available (dry-run-synthesize-browser-summary)
```

The scan treats as a bundle any folder whose extension begins with `lungfish` and which contains a `manifest.json`, so it reaches alignments, trees, and primer schemes as well as reference bundles. Each line ends with a status and, in parentheses, the action taken or planned.

| Status | Meaning |
|---|---|
| `current` | The manifest is at the current schema version and nothing was touched. |
| `migration-available` | A dry run found a reference manifest missing its stored chromosome list, and wrote nothing. |
| `migrated` | A real run filled that list in. |
| `unsupported` | No [transformer](../../GLOSSARY.md#transformer), the code that rewrites one layout into another, exists for that schema version, so the bundle was left alone. |
| `unreadable` | The manifest could not be decoded. This is expected and harmless for alignment, tree, and primer-scheme bundles, which use their own manifest layout. |

Read these per-bundle lines rather than the counts printed above them, which do not add up. This is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

Drop `--dry-run` to perform the migration.

```bash
lungfish-cli project migrate ~/Desktop/lge-docs/LGE\ Manual\ Demo.lungfish
```

The eligible bundle's line then reads `migrated (synthesized-browser-summary)`. Inside that bundle, in a hidden `.lungfish/migrations/` folder, the run leaves two timestamped files, a `.manifest.json.backup` holding the manifest as it was and a `.project-migrate-provenance.json` recording the change. The original manifest is copied to the backup before anything else and the new manifest is put in place last, so an interrupted run leaves the old manifest untouched. A second dry run reports the bundle as `current`, so the command is safe to run twice.

Unsupported bundles are reported and never rewritten, and their action reads `dry-run-report` or `report-only`. Rewriting scientific data would mean knowing the old layout exactly and keeping the original recoverable, so until a transformer exists for a schema version, LGE reports the gap rather than guessing.

For a script, add `--format json`, which gives one entry per bundle with its relative path, manifest path, schema version, status, action, message, and whether a provenance record was found.

## Provenance expectations

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it.

Taking and releasing a lock writes no provenance record, because a lock is bookkeeping rather than a result. A migration does write one, because it changes a file inside a bundle. The record is written before the new manifest is put in place, so it describes the final file. Beside the usual fields it names the transformer and the schema versions it read and wrote, and lists the backup among the outputs. The bundle's original record stays where it was, so how the bundle was made and how it was migrated sit side by side.

## What good looks like

Four checks tell you a shared project is in the state you think it is.

1. The window title has no `(Read Only)` after the project name when you expect to be able to write.
2. When the title does show `(Read Only)`, an opening alert named the lock's owner, or no alert appeared because the project store is missing.
3. `project lock` on a free project exits 0. It exits 1 when the lock belongs to a running LGE on this Mac, to another Mac, or is corrupted.
4. `project migrate --dry-run` reports each bundle as `current`, `unreadable` for alignments, trees, and primer schemes, or names exactly the bundles it would change.

When one of these disagrees, close the project window and open it again to read the opening alert. If it names a lock, ask the person it names, or recover the lock once you have confirmed that session has ended.

## Next

See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) for the project folder these commands act on, [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for the records migration preserves, and [CLI Reference](cli-reference.md) for every `lungfish-cli project` flag.
