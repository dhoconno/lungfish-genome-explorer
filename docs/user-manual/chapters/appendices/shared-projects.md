---
title: Shared Projects and Bundle Migration
chapter_id: appendices/shared-projects
audience: power-user
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 22
task: Put a project on a shared drive, coordinate it between two people or two machines with project locks, read the read-only state the window shows, reopen a project whose folder moved, and check older bundles from the command line.
tags: [appendix, reference, power-user, project, multi-user, locking, migration, provenance, cli]
tools: []
entry_points:
  - Sidebar > Locate…
  - "CLI: lungfish-cli project lock"
  - "CLI: lungfish-cli project unlock"
  - "CLI: lungfish-cli project migrate"
shots:
  - id: shared-projects-read-only-banner
    caption: "A project window opened with Open Read-Only after the lock alert, with (Read Only) after the project name and window number in the title and no banner."
illustrations: []
glossary_refs: [advisory-lock, bundle, bundle-migration, checksum, exit-status, host-name, json, manifest, operations-panel, process, process-id, project, project-lock, project-store, provenance, schema-version, stale-lock, terminal, transformer, viewport, sidebar]
features_refs: [project.manage, project.copy-item]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish Genome Explorer (LGE) [project](../../GLOSSARY.md#project) is a `.lungfish` folder holding one piece of work. Nothing about that folder stops two people opening it at once. Put it on a shared drive, or open it from a laptop and a lab workstation in turn, and two copies of LGE could write into the same files, with the second write quietly overwriting the first.

LGE prevents that with a [project lock](../../GLOSSARY.md#project-lock), a small record inside the project saying who holds it. A project named `My Project.lungfish` keeps it at `My Project.lungfish/.lungfish/project.lock`. An LGE window checks the record before it opens a project and writes it when it opens the project for writing, which every ordinary open does even if you only look. The window gives the lock back when you close it or quit LGE, and a crash leaves it behind. A project opened read only takes no lock. On the command line only `project lock` and `project unlock` touch the record, and other `lungfish-cli` commands neither read nor write it.

The lock is [advisory](../../GLOSSARY.md#advisory-lock), which means it works only because every LGE [process](../../GLOSSARY.md#process), one running copy of the program, agrees to check it. macOS is never asked to refuse anyone, so a Finder copy, an rsync job (a copy program run in [Terminal](../../GLOSSARY.md#terminal), the macOS app where you type commands), or a Dropbox or Google Drive sync client ignores the lock. It keeps one LGE window from colliding with another, and nothing more. When LGE finds a lock it cannot claim, it offers to open the project read only.

The second half covers [bundle migration](../../GLOSSARY.md#bundle-migration), the rewriting of an older bundle into the current layout. LGE does not rewrite bundles. A [bundle](../../GLOSSARY.md#bundle) is a folder LGE treats as one item, as [What bundle means](../01-foundations/06-the-lungfish-project.md#what-bundle-means) explains, and many bundles, such as a reference bundle, carry a [manifest](../../GLOSSARY.md#manifest), a small file named `manifest.json` that names what the bundle holds. Each manifest carries a [schema version](../../GLOSSARY.md#schema-version), a number saying which layout it was written to, and `lungfish-cli project migrate` reports which bundles are at the current one.

## If a project just opened read only

Your project window says `(Read Only)` after its name, usually because you chose **Open Read-Only** when LGE found another session's lock. [What read only looks like](#what-read-only-looks-like) lists the other causes.

The fix needs no Terminal, including for a lock left by a session on another Mac. Ask whoever has the project open to close its window or quit LGE, which gives the lock back, then close your own window and open the project again. The opening alert names the person and the machine, so it tells you whom to ask. If the other session ended on this Mac, LGE clears its lock by itself and opens the project normally. When LGE cannot check the owner, for example because the lock came from another Mac, or when the lock file is damaged, the alert offers **Recover and Open**, which [Reading the window's read-only state](#reading-the-windows-read-only-state) describes.

## Why you would do this

Four situations bring a reader here. Two people work on one project on lab storage in the same week. One person keeps a project on an external drive and opens it from two Macs. A project's folder is renamed or moved in Finder while LGE has it open, which [When an open project's folder moves](#when-an-open-projects-folder-moves) covers. Or a project made a year ago is opened by a current LGE and its bundles need checking.

The first two are the same problem. Without the lock, whichever write lands second can find a result folder half written or the project's own index of its contents out of step, and nothing says so at the time. The lock turns silent damage into a visible refusal.

The last is a different worry. Older bundles still open. A manifest can lack its stored browser summary, a cached list of chromosomes and track counts, and LGE then builds the list in memory from the manifest's own chromosome entries. `project migrate` tells you which bundles are at the current schema version and changes none of them.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The examples use the Human Mapping and Variants (with results) demo project, which **Help > Demo Projects…** downloads, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains.

The window takes and gives back its own lock by itself and lets you clear another session's lock only through **Recover and Open**. It has no control for taking or releasing a lock on demand or for reporting on bundles, so the second half is typed in Terminal.

The lock commands act on a real project at once, so practice on a copy. Select the `.lungfish` folder in Finder and press Cmd-D to duplicate it, point the commands at the duplicate, and delete it when you are done.

## Putting a project on a shared drive

A copy made while LGE is still writing can hold a half-written result, and Finder ignores the lock, so close the project first.

1. Let every row of the [Operations Panel](../../GLOSSARY.md#operations-panel) finish, since a running operation is still writing into the project.
2. Close the project's window with **File > Close** (Cmd-W), or quit LGE.
3. In Finder, copy the whole project folder to the drive. Open the copy, press Cmd-Shift-period to show hidden names (those that begin with a dot), and check that `.project.db`, the project store, is there.
4. Open the copy from the drive with **File > Open Project Folder…** (Cmd-O). The title should show no `(Read Only)`.

LGE's code is written to run a project from a drive formatted APFS or Mac OS Extended (the Mac formats), ExFAT or FAT32 (formats that Macs and Windows PCs both read), or from an SMB share (a drive on another computer, reached over the network). It names no synced folder, and a sync client ignores the lock, so keep a project out of Dropbox and Google Drive. If it already sits in one, close it in LGE, let the sync client finish, and drag the folder out.

## Reading the window's read-only state

Open a project another session holds and LGE stops before showing it, with an alert titled with the project name and the words "may already be open". LGE sorts every lock into one of four states, and the state sets the text under the title.

| State | Meaning | What you see |
|---|---|---|
| active | The recorded process is running on this Mac. | "Another session is using this project." |
| [stale](../../GLOSSARY.md#stale-lock) | The recorded process has exited, or macOS has since given its [process id](../../GLOSSARY.md#process-id), the number it gave that running copy of the app, to a different program. A lock that Finder copied with a project is also stale on the same Mac when it names a different folder that exists. | No alert. LGE replaces the lock and opens the project normally. |
| unknown | LGE cannot tell. Every lock written on another Mac is unknown, so on shared lab storage most locks you meet read this way. | The alert says LGE "could not confirm whether a previous session is still using this project". |
| corrupted | The lock file exists but is not a readable lock record, for example because it is not valid [JSON](../../GLOSSARY.md#json), the plain-text format the record uses. | The alert says the project's lock information is damaged, so LGE cannot tell whether another session is using it. |

When LGE cannot read the lock file at all, the alert says LGE "could not read the project's lock information" and offers no recovery.

The alert offers up to three buttons.

| Button | What it does | When it appears |
|---|---|---|
| **Open Read-Only** | Opens the project for inspection. This is the default. | Always |
| **Cancel** | Opens nothing. | Always |
| **Recover and Open** | Clears the lock and opens the project for writing, after a second confirmation. | When the lock is unknown and LGE could read its record, or when the record is damaged |

Above the buttons a details block says who holds the lock. **Session** names the program that took it and its version, such as `Lungfish ProjectStore` for an LGE window or `lungfish project lock` for a command-line lock. **Owner** gives the macOS account name, the [host](../../GLOSSARY.md#host-name), which is the computer's name, and the process id. An account name is a login, not always a person, so ask who was working at that computer.

### Deciding whether to recover

**Recover and Open** raises a second confirmation, because it is the one choice here that can lose data. It asks you to make sure the project is closed in other LGE versions (any other LGE app on this Mac), in the command line (a Terminal window running a `lungfish-cli` command on it), and on other computers (any Mac with the drive mounted), and warns "Recovering a lock while another session is writing can damage the project."

Recovery is safe when the other session has ended and dangerous when it has not, and LGE cannot tell for you. If the host is not your Mac, ask the person who uses that machine, and if nobody can say, do not recover, because a laptop asleep with the project open still holds its lock. If the host matches the name `hostname` prints in Terminal, the lock is from your own Mac, and LGE offers recovery only when macOS will not let it check the owner, for example when another macOS account holds the lock. Then open Activity Monitor from **Applications > Utilities**, type the process id into its search field, and see whether a running process has that number. An LGE app with that number means the session is live. Nothing found, or another program, means it is gone.

Recovery keeps the record it replaces in a subfolder of `.lungfish/lock-recovery`, beside a `recovery.json` that holds the reason, the time, the original path, a [checksum](../../GLOSSARY.md#checksum) of the archived file, and the session that recovered it.

### What read only looks like

<!-- SHOT: shared-projects-read-only-banner -->

Once a project is open read only, the window title shows `(Read Only)` after the project name. The window shows no banner (a strip of warning text), so the title is the only sign inside it, and the opening alert is where the lock's owner is named. The window also gives no signal when the other session lets go and stays read only until you close it and open the project again.

Try to run something that writes and a sheet titled **Project Is Open Read Only** appears, naming the workflow and telling you to close the other writer or reopen the project once the lock is released. Imports, mapping, classification, and every other operation that adds files are refused, and so are renaming, moving, copying, and deleting items and editing sample metadata. Opening a bundle, moving around its [viewport](../../GLOSSARY.md#viewport), and reading the Inspector stay available. No export is refused, and an item dragged from a read-only project into another project's window is probably copied, since only the receiving window is checked.

A project copied in Finder while LGE has the original open carries that session's lock record. On the same Mac, LGE sees that the record names the original's folder and not the copy's, treats it as stale and replaces it, so the copy opens normally even while the original is open. On another Mac the record reads unknown, so the alert names the session from the original, and **Recover and Open** is safe there because that session writes into the original folder and not into the copy.

If `(Read Only)` appears without a lock alert first, there are three other causes. A project with no [project store](../../GLOSSARY.md#project-store), its hidden `.project.db` file, opens with an alert titled **Opened Read Only**. A folder built only with `lungfish-cli` has none until it is created in the app, and a folder copied without its hidden files has lost it, so copy the whole folder again. A project database from an older release brings an alert titled **Project Migration Required**, which [Migrating older bundles](#migrating-older-bundles) covers. The third cause shows no alert. LGE could not write to the project folder, its store, or its `metadata.json`, or could not open them, as on a shared drive that gives your account read-only access. In Finder, select the project folder, press Cmd-I, and read **Sharing & Permissions** to see whether your account has **Read & Write**. Whoever owns the folder or manages the drive can change it.

## When an open project's folder moves

LGE watches the folder of each open project. Rename or move that folder in Finder while LGE has it open, or disconnect the drive it lives on, and LGE stops reading the project rather than guess where it went. The [sidebar](../../GLOSSARY.md#sidebar) then reads "Project unavailable." followed by the reason, such as "Project folder moved or its volume disconnected.", above **Retry** and **Locate…** buttons, and the Inspector clears.

Click **Retry** once the drive is connected again or the folder is back where it was. Click **Locate…** when the folder has a new name or place, choose it in the panel that opens, and click **Locate**. LGE checks that the folder you chose is the one it had open by comparing the drive it sits on, the number that drive gave the folder, and its creation date. A folder renamed or moved within its drive keeps all three facts, but a copy, or a folder deleted and made again under the same name, has a new number and date and is refused with "Folder is missing, inaccessible, or is a replacement. Locate the original folder, or close all old project windows before opening a replacement." LGE then reopens the project there with the same item selected and the same folders open.

## Before you type anything

The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it. The commands below follow [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block). Set `PROJECT` once to your practice copy of the project, with double quotes because the folder name holds spaces, and every command after it names the project as `"$PROJECT"`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results) copy.lungfish"
```

That is the name Finder gives the duplicate that Cmd-D makes beside the demo project. On a shared drive the path starts with `/Volumes/` and the drive's name, as in `/Volumes/<drive name>/<project name>.lungfish`.

## Locking a project from the command line

`project lock` fits one job, maintenance you run from this Mac on a project that people open from other Macs. Their windows show the lock alert, while a window on this Mac treats the lock as stale and opens the project normally. The four lock states are the ones in [Reading the window's read-only state](#reading-the-windows-read-only-state).

Take a lock with `project lock` and the project's path. It works from any folder, because the path names the project.

```bash
lungfish-cli project lock "$PROJECT" --mode exclusive
```

On success it prints the project path, the lock file path, and the mode, and returns [exit status](../../GLOSSARY.md#exit-status) 0, the number that means success, which `echo $?` prints right after a command. Adding `--format json` prints the record itself, whose fields are these.

| Field | Holds |
|---|---|
| `user`, `host`, `pid` | Who holds the lock, on which computer, and in which process. These three tell you whom to ask. |
| `machineIdentifier` | A fixed code for the Mac, unrelated to any personal information. |
| `processStartTime` | When the process started, used to spot a reused process id. |
| `mode` | The label set by `--mode`. |
| `toolName`, `appVersion` | The program and version that took the lock. |
| `createdAt`, `cwd`, `projectPath`, `schemaVersion` | When, from which folder, on which project, and in which record layout. |

LGE compares `machineIdentifier` first and falls back to the hostname only for records too old to have it, because a Mac's hostname can change with the network. So an alert can name a host you do not recognize as your own Mac. If it differs from the name `hostname` prints, treat it as another computer and ask the person named.

`--mode` records any label you type, such as `maintenance`. The default is `exclusive`. The mode is only a label, and both block writes the same way.

A lock whose owner is still running, any lock from another Mac, and a corrupted lock all block a second lock, and the command exits 1. For a live or unknown lock the message begins "Project is already locked at" and names the owner. For a corrupted lock it begins "Project lock file is corrupted at" and advises passing `--force` only after confirming that no active writer is using the project.

### A command-line lock marks intent

`project lock` writes the record and exits at once, so the process id in the record belongs to a command that has already ended. A script cannot hold a lock for its whole run. Only an LGE window with the project open holds one while it stays open, so leave the project open in LGE on that Mac, or make sure by other means that nobody else opens it.

`--force` replaces a lock without the stale-owner checks, and unlike **Recover and Open** it keeps no archive. Use it only after checking in Activity Monitor that the owning process is not running, or after the named owner confirms they have finished. A lock from another Mac always reads as unknown, because this Mac cannot see that process, and clearing one takes `--force` for that reason.

## Unlocking a project

Release a lock with `project unlock`, which also works from any folder.

```bash
lungfish-cli project unlock "$PROJECT"
```

Without `--force`, the command removes only a lock held by its own process, or a stale lock held by the current user on this Mac. Anything else is refused with exit status 1 and a message beginning "Refusing to remove lock at". A corrupted lock is refused too, with advice to pass `--force` only after confirming no active writer is using the project.

`--force` removes the lock in every case, including a corrupted one, and exits 0. It deletes the file but does not stop the process that wrote it, which carries on writing as if it still held the lock, so run the Activity Monitor check first.

Unlocking a project that has no lock prints `No project lock found:` with the path and exits 0.

## Migrating older bundles

Despite its name, `project migrate` rewrites nothing. It walks a project, reads the manifest of every bundle it finds, and reports whether each is at the current schema version. It never changes a manifest, makes a backup, or writes a provenance record, so it is safe to run on any project. `--dry-run` changes only the `Dry run` line and the action word of an unsupported bundle, because no converter exists that could rewrite a bundle.

```bash
lungfish-cli project migrate "$PROJECT"
```

The report opens with a title line, the project's path, and the `Dry run` line, then four counts of bundles and one line per bundle. On the demo project the scan finds two reference bundles, both current.

```text
Bundles inspected: 2
Current: 2
Unsupported: 0
Migrated: 0
- Analyses/minimap2-2026-09-25T00-00-00/GRCh38.chr20.10.0-10.5Mb.lungfishref: current (none)
- Reference Sequences/GRCh38.chr20.10.0-10.5Mb.lungfishref: current (none)
```

The scan treats as a bundle any folder whose extension begins with `lungfish` and which holds a `manifest.json`, so it reaches multiple sequence alignments, trees, and primer schemes too. Each line ends with a status and, in parentheses, the action planned.

| Status | Meaning |
|---|---|
| `current` | The manifest's schema version is "1.0", the version LGE writes. The action reads `none`. |
| `unsupported` | The manifest names another schema version. No [transformer](../../GLOSSARY.md#transformer), the code that rewrites one layout into another, exists for it, so the bundle is left alone. The action reads `dry-run-report` with `--dry-run` and `report-only` without it. |
| `unreadable` | The manifest could not be decoded, which is expected and harmless for multiple sequence alignment, tree, and primer-scheme bundles, since they use their own manifest layout. The action reads `report-only`. |

The `Unsupported` count also includes `unreadable` bundles, so it can read above 0 for a project whose bundles are all fine, and `Migrated` always reads 0. Read the per-bundle lines for the cause. `--format json` gives the same report for a script.

A `current` bundle needs nothing. LGE does not check the schema version when it opens a bundle, so an `unsupported` bundle still opens whenever its manifest holds every field the current reader requires. Nothing in LGE can repair a manifest that lacks one, so ask whoever made the bundle for a current copy, or make it again from its source files.

An older project database is different, because LGE does migrate it. Opening a project whose database comes from an older release shows an alert titled **Project Migration Required**, and the window reads `(Read Only)` until you choose. **Migrate and Open** keeps the original database files and a provenance record in `.lungfish/migrations` inside the project, then updates the database, and it takes the project's lock, so close other sessions first. **Keep Browsing Files** leaves the project read only. A project file or database that names a version this LGE does not read, as a newer LGE might write, opens as a read-only folder of files with no alert, so run one LGE version on every Mac that shares a project.

## Provenance expectations

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Records hold paths relative to the project, so moving or copying the whole project folder in Finder rewrites no record.

A record travels with its item. Drag an item from one project window into another and LGE copies it with its provenance record inside, and the copy's own record names the item by its path in the source project and the SHA-256 checksum of every file the copy read. For a result folder that holds its own record at its top level, such as a TaxTriage, Kraken 2, EsViritu, NVD, or NAO-MGS result, LGE first checks each file against that record. If a file is missing or differs from what the record describes, the item is not copied, and the original stays as it was, because a result that no longer matches its record cannot vouch for itself.

Renaming, moving, or duplicating a result folder in the sidebar rewrites the paths inside the records it holds, which breaks any signature on them. With a signing key set, LGE signs each such record again, and with none it removes the signature, so the record reads as unsigned rather than as changed. A bundle, a single file, or an item copied into another project is not signed again, even with a key set. [Signing a record](../01-foundations/08-provenance-and-reproducibility.md#signing-a-record) explains how a key is set.

Taking and releasing a lock writes no provenance record, because a lock is bookkeeping rather than a result, and `project migrate` writes none either, because it changes no file.

## What good looks like

Four checks tell you the state of a shared project.

1. The window title has no `(Read Only)` after the project name when you expect to be able to write.
2. When the title does show `(Read Only)`, an opening alert named the lock's owner, the **Opened Read Only** alert said the project store is missing, the **Project Migration Required** alert said the database is from an older release, or no alert appeared because LGE could not write to or open the project's files.
3. On your practice copy, `project lock` on a free project exits 0. It exits 1 when the lock belongs to a running LGE on this Mac, to another Mac, or is corrupted. To read a lock without taking one, print it with `cat "$PROJECT/.lungfish/project.lock"`.
4. `project migrate` reports each bundle as `current`, `unsupported`, or `unreadable`, and never changes one.

When one of these disagrees, close the project window and open it again to read the opening alert. If it names a lock, ask the person it names, or recover the lock once you have confirmed that session has ended. If no alert appears, check the folder's permissions in Finder, as [What read only looks like](#what-read-only-looks-like) describes.

## Next

See [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md) for the project folder these commands act on, [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) for the records that travel with a project, and [CLI Reference](cli-reference.md) for the `project lock`, `project unlock`, and `project migrate` flags.
