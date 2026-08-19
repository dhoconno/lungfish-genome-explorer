# Update Tools sheet and Plugin Manager database update verification

Status: VERIFIED in the running GUI on 2026-08-19 (updated from the earlier blocked state of 2026-08-18). The build under test was `build/Debug/Lungfish.app` version 0.5.0-beta29 at commit 38d9f1cb, launched against an isolated storage root. The real `~/.lungfish` was never opened by the build under test and was confirmed unmodified afterwards.

## How to reproduce

The raw SwiftPM executable at `.build/debug/Lungfish` has no bundle identity, so macOS screen capture and automation cannot see its windows. Build a debug app bundle around the already compiled binary instead, which needs no SwiftPM lock:

```bash
bash scripts/build-app.sh --debug --skip-build
```

Then launch the bundle with an isolated root:

```bash
LUNGFISH_STORAGE_ROOT=/tmp/lge-gui-walkthrough LUNGFISH_CONDA_ROOT=/tmp/lge-gui-walkthrough/conda build/Debug/Lungfish.app/Contents/MacOS/Lungfish
```

The debug bundle registers as a separate application named "Lungfish Debug" with bundle id `com.lungfish.browser.debug`, so screen automation must be granted access to that id, not to the installed `org.lungfish.genome-browser`. If an installed Lungfish is already running, both processes answer to the name "Lungfish"; select the right one by pid.

The walkthrough root was seeded with two Kraken2 rows: a `Viral` row registered from disk with **no** `catalogID` at version 20240904, and a `Greengenes 16S` row carrying `catalogID: kraken2-special-greengenes` at version kraken2-special-v0 with a `kraken2Special` recipe. Both pointed at small placeholder directories inside the isolated root.

## What was verified

### Update Tools sheet at launch

The sheet appears on launch titled "Update tools to 2026.2" with the subtitle "Lungfish needs these tools before it can run analyses. Optional items can wait." The Required tools section lists the 2026.2 pins, spot checked against the manifest: bbtools 40.02, bcftools 1.24, cutadapt 5.2, deacon 0.16.0, fastp 1.3.6, htslib 1.24, nextflow 26.04.6, openpyxl 3.1.5, pigz 2.8, pysam 0.24.0, samtools 1.24, seqkit 2.13.0, snakemake 9.25.2, sra-tools 3.4.1, trim_galore 2.3.0, ucsc-bedgraphtobigwig 482, vsearch 2.31.0. The footer reads "Estimated download: about 2.67 GB".

Because required work is pending, the dismissal button reads "Quit" rather than "Later", and pressing Escape does not dismiss the sheet. Clicking "Quit" ends the application, which is the specified behavior.

A "Databases" section follows the tool list with the caption "Required databases are always updated; others are yours to choose." It listed both seeded rows:

- Greengenes: `kraken2-special-v0 to kraken2-special-v1, 8.59 GB`
- Viral: `20240904 to 20260626`

The Viral line is the direct visual confirmation of the final review finding: a database registered from disk with no catalog identity is now planned for update rather than silently skipped.

### Plugin Manager Databases tab

The footer reads "Custom shared storage /tmp/lge-gui-walkthrough", confirming the storage override reached the view model.

The Greengenes 16S row shows an "Update available" badge, the version transition "Installed Mar 24, 2026 - Version kraken2-special-v0 - Update available: kraken2-special-v1", and an action area with an "Update" button in Lungfish Orange next to a neutral "Remove". Clicking Update on this locally built database renders the guidance inline on the row, with a Dismiss control:

> 'Greengenes 16S' cannot be updated automatically: locally built databases are rebuilt by reinstalling, not updated in place

The row keeps its installed state and the operation completes with a warning rather than failing.

The Viral row shows the same badge and button, described as "Kraken2 viral index registered from disk (no catalog identity)" with "Version 20240904 - Update available: 20260626". Clicking Update started a real download with a progress bar and a "Downloading..." caption.

### Operations panel

During the Viral update the Operations panel listed:

- `Update Database: Viral`, type Download, in progress with elapsed time
- `Update Database: Greengenes...`, type Download, "Completed with Warnings"

This confirms both the success path and the `updateNotSupported` path run as OperationCenter operations with the expected lifecycle.

## What was not verified

- A full Update run to completion from the sheet, and the resulting `dependency-receipt.json`. The Viral download was cancelled by quitting the application once the wiring was proven, to avoid pulling a full index.
- Plugin Manager "Check for Tool Updates..." and its up to date alert.
- The Welcome window re-evaluating its required setup gate after a completed sheet run.
- The upgrade scenario from a seeded 2026.1 root in the GUI. The plan contents for that root were verified earlier through the CLI: one install (freyja), six reinstalls (`specChanged` for clair3, `buildChanged` for flye, lofreq, medaka, and phasing, `metadataMismatch` for bracken), an empty removals list even with 55 environments present including user created ones, and an estimated download of 1.1 GB.

## Safety notes

Never point `LUNGFISH_STORAGE_ROOT` at the real `~/.lungfish`, because the reconciler reinstalls and removes environments. The walkthrough root was deleted afterwards, and `~/.lungfish/databases` was confirmed unchanged.
