---
title: Troubleshooting
chapter_id: appendices/troubleshooting
audience: bench-scientist
prereqs: []
estimated_reading_min: 30
task: Look up a Lungfish Genome Explorer symptom by what appears on screen, find out what it means and what to do, and check whether it is a known defect.
tags: [reference, troubleshooting, errors, support, operations-panel, known-defects]
tools: []
entry_points: []
shots:
  - id: operations-panel-failed-row
    caption: "A failed row in the Operations Panel and its Issue button, with its details pane open on the command and log, and the right-click menu open on Copy Failure Report."
illustrations: []
glossary_refs: [accession, advisory-lock, bundle, cohort, conda, container, dependency-set, docker, environment-variable, exit-status, failure-report, fastq, kraken2, nextflow, operations-panel, plugin-pack, project, project-lock, project-store, provenance, provenance-sidecar, read-classification, symlink, working-directory, workflow-library]
features_refs: [containers.run]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) is a window over a set of established programs that were built to be typed at rather than clicked. LGE runs those programs for you and shows you the results. When something goes wrong, the message you see often came from one of those programs rather than from LGE itself, so it may use words LGE never uses. This appendix collects the symptoms people actually meet, says what each one means in plain words, and gives the action to take.

The appendix is organised by what you see on screen rather than by which part of LGE is at fault. Look up the pale grey menu item, the message, the run that stopped, or the missing result, and read across. Each entry names the chapter that covers the operation in full. The last main section, [Known defects in this release](#known-defects-in-this-release), is the one list of faults in LGE itself that this manual keeps, each with a workaround and the build it was checked against, and [Defects by chapter](#defects-by-chapter) finds the rows for one chapter.

To check which release you have, open **Lungfish Genome Explorer > About Lungfish Genome Explorer**, the first item under the app's own menu.

Some sections are read in the window and some need commands typed into Terminal, and each says which at its start. Two words are worth fixing first. An [exit status](../../GLOSSARY.md#exit-status) is the number a command hands back when it finishes, where zero means it succeeded and anything else means it stopped. A [working directory](../../GLOSSARY.md#working-directory) is the folder a Terminal window is sitting in when you type a command, and typing `pwd` and pressing Return prints it.

## Before you type anything

The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it and [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains Terminal, commands, and paths.

## Start here, at the failed row

This section is done entirely in the LGE window.

A run that fails turns its row red in the [Operations Panel](../../GLOSSARY.md#operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Before you read any table below, right-click that row and choose **Copy Failure Report**. On a trackpad with no second button, hold Control and click, or click with two fingers. Do not retype the command by hand from what you remember choosing in a dialog, because a fresh typing mistake hides the real one.

Click the row's **Log** button, or select the row, to open its details pane. The pane shows the error message, the command LGE built on your behalf under Command, and the log the tool wrote. Read the error message first and the command second.

<!-- SHOT: operations-panel-failed-row -->

The right-click menu on a failed row offers every item [The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes, and three more that only a failed row has.

| Item | What it gives you |
|---|---|
| **Copy Failure Report** | The operation title, the command, the error message, the tool's one-line summary, the longer detail, and the log, as one block ready to paste |
| **Open GitHub Issue** | A pre-filled issue in your browser carrying the report, which you review and submit yourself |
| **Reveal Failure Report in Finder** | The report file on disk, offered once the file exists |

**Copy CLI Command** and **Copy Log**, on the same menu, copy the command alone and the log alone.

That [failure report](../../GLOSSARY.md#failure-report) file is written as the failure happens, so it survives quitting the app. It lives at `~/Library/Logs/<app name>/Operations/Failures`, where the tilde stands for your Home folder and the app name keeps a Debug or Preview build's reports apart from a stable build's. Library is hidden in Finder, so **Reveal Failure Report in Finder** is the easy way there. LGE keeps the 50 most recent reports and deletes the oldest each time it writes a new one, so copy a report you care about rather than assuming it will still be there next month. If LGE cannot write a report, for example because the disk is full, it skips the report without a second error, so a missing report says nothing about the operation itself.

## Nothing happens when I choose a menu item

This section is done entirely in the LGE window.

A few items stay hidden, pale grey, or quiet until something is turned on or chosen, and none of them says so loudly.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| An item in **Tools > Genotyping** or **Tools > Classification** reads Enable before its name, and choosing it asks whether to open the Workflow Library | The item is a specialized workflow, such as an MHC genotyping workflow or 12S Amplicon Matching. Genotyping works out which versions of a gene a sample carries. A workflow that reads Enable is off until you enable it, because each needs a large install of outside programs. Nothing is broken. | Click **Open Workflow Library** and turn the workflow on once, as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows. | [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md) |
| The Inspector has no Assistant tab | The tab stays hidden until AI search is switched on in the **AI Services** tab of Settings. Even then it appears only while the viewport shows a reference sequence or a multiple sequence alignment. Reads, read alignments (mapping results), assemblies, classifier results, genotype results, and primer analyses give an Inspector without it. | Switch AI search on, as [The AI Assistant](ai-assistant.md) shows, then select a reference sequence in the sidebar. | [The AI Assistant](ai-assistant.md) |
| A primer scheme bundle you copied into the project is missing from the Primer Scheme menus | A bundle missing `manifest.json`, `primers.bed`, or `PROVENANCE.md` is left out of the menus without a message. This is a known defect, listed in [Known defects in this release](#defect-primer-scheme-silent-skip). | Check the bundle folder for the three files, or import the scheme again from its BED file. | [Primer Scheme Bundles](primer-schemes.md#bundle-layout) |
| **Tools > Variant Calling > Call Variants...** is pale grey | Calling variants needs an alignment to read. The item comes on when the viewport shows, or the sidebar has one selected, reference bundle or mapping result that holds at least one alignment track. Several selected at once turn it off again. | Select the mapping result, or the reference bundle carrying the alignment, and choose the item again. | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) |
| **Tools > Alignment & Phylogenetics > Build Tree with IQ-TREE...** is pale grey | The item acts on the alignment shown in the viewport, or on exactly one alignment selected in the sidebar. When no alignment is shown and the sidebar selection is not exactly one alignment, it stays off, and its tooltip reads "Open or select an alignment to build a tree." | Click one `.lungfishmsa` bundle in the sidebar and choose the item again. | [Building Trees](../02-sequences/05-building-trees.md) |
| **View > Zoom In**, **Zoom Out**, **Zoom to Fit**, or **Zoom Reset (10kb)** is pale grey | Nothing zoomable is on screen, such as while a read bundle or a classifier result is selected. The four items come on with a sequence display or a multiple sequence alignment. | Open a sequence or an alignment first. | [Keyboard Shortcuts](keyboard-shortcuts.md) |
| **Tools > Genotyping > MHC Haplotype Definitions...** is pale grey | The window manages the haplotype definitions of the MHC genotyping workflows, so the item stays off until one of them is switched on, and its tooltip says so. | Turn on MiSeq Amplicon MHC Genotyping or Full-Length ONT MHC Genotyping in the Workflow Library, as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows. | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md#where-haplotype-definitions-come-from) |
| The four items of **Selection > Genotype Sample** are pale grey | They act on one sample of a genotype result and need a sample selected in its Review lens, or a call selected in a MiSeq result. | Open the genotype result and select a sample first. | [Keyboard Shortcuts](keyboard-shortcuts.md#inside-the-genotype-result-window) |

A pale grey menu item's keyboard shortcut does nothing either, so pressing the shortcut for a disabled item is silence rather than a second symptom.

## I cannot write to my project

This section is done entirely in the LGE window.

A [project](../../GLOSSARY.md#project) is the folder LGE keeps one piece of work in. A project another copy of LGE holds opens read only, as [Shared Projects and Bundle Migration](shared-projects.md#reading-the-windows-read-only-state) explains. That appendix also gives the window route for clearing a lock left behind by a session that has really ended.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| The window title shows ` (Read Only)` after the project name, and an alert about the lock came first | Another session holds the [project lock](../../GLOSSARY.md#project-lock), or LGE could not read the lock file to find out. | Close the other copy of the app, or the command-line run, and reopen the project. | [Shared Projects and Bundle Migration](shared-projects.md) |
| The window title shows ` (Read Only)` and no lock alert appeared first | The project has no [project store](../../GLOSSARY.md#project-store), because it was built only with `lungfish-cli` or copied without its hidden files, and an alert titled Opened Read Only says so. Otherwise LGE cannot write to the project folder or its store. | Check that you can write to the folder, for example that it is not on a read-only volume or owned by another user. A folder built only on the command line gains its store once it is created in the app. A copied project needs the whole folder copied again, hidden files included. | [Shared Projects and Bundle Migration](shared-projects.md#what-read-only-looks-like) |
| An alert titled with the project name and "may already be open" names a user, a host, and a process id | A live lock from a named session. The host is the computer holding it and the process id is the number macOS gave that running program, so together they say which machine and which window to close. | Confirm that session has ended before you clear the lock, since clearing a live one is how two writers end up in one folder. | [Shared Projects and Bundle Migration](shared-projects.md) |
| An alert headed "Project Is Open Read Only" appears when you click Run | You started a workflow that writes into the project while writing is blocked. The alert names the workflow. | Close the other writer, then close and reopen the project. The alert keeps appearing until you reopen it, because reopening is what gives the lock to your window. | [Shared Projects and Bundle Migration](shared-projects.md) |
| The lock alert says the project's lock information is damaged, or that LGE could not read it | The lock file exists but LGE cannot make sense of it. Writing stays blocked until the lock is inspected or removed. | Make sure no other session is running, then clear the lock with **Recover and Open**, as [Shared Projects and Bundle Migration](shared-projects.md#deciding-whether-to-recover) describes. | [Shared Projects and Bundle Migration](shared-projects.md) |

On network storage, meaning a drive that lives on another computer and is reached over the network, a reported locking failure is often not a real lock problem. Lock failures name `.lungfish/project.lock` for a project, or a `.install.lock` file inside the tool folder for a plugin install. Those names begin with a dot, so Finder hides them until you press Cmd-Shift-period in a Finder window. Before you change how a share is mounted, look for stray files whose names begin with `._`, which macOS leaves on volumes that cannot hold its file metadata and which confuse the check. They are safe to delete, and macOS writes fresh ones when it needs them.

## A run stopped and I do not know why

These entries name the exact text a run prints, so you can match what you saw. The fixes are done in the window except where a command is shown.

The exit status appears in the failure report and in Terminal. [Exit status](cli-reference.md#exit-status) in the CLI Reference lists every value. These are the ones this appendix meets.

| Exit status | What it means here |
|---|---|
| 1 | The command refused or failed, for example a lock it may not replace. |
| 2 | A usage error the command itself catches, such as `tools update --apply` without `--yes`. Nothing ran. |
| 3 | An input error, such as a missing file or a pack name that was not recognised. Nothing was installed. |
| 4 | An output error, such as an output file that already exists or an expected workflow output that was not created. |
| 5 | A format error, such as a file `analyze validate` finds malformed or, with `--strict`, irregular. |
| 10 | `tools update --plan` found pending work, which is a report rather than a fault. |
| 64 | A workflow error. The command refused the work, the work failed inside a workflow step, or the command line could not be parsed. |
| 65 | The Docker daemon could not be reached, so a pipeline that runs in containers cannot start. |
| 126 | A tool the command needs is not installed. |

Exit 64 covers both a run started without a required setting and a run whose tool failed, so read the message rather than assuming a typing mistake.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| A medium or long run on an external drive slows down, or moves its scratch files | [Nextflow](../../GLOSSARY.md#nextflow), the pipeline runner behind some LGE workflows, keeps temporary files beside a run. LGE tests the project's drive first and moves those files to the internal drive when the test fails. A drive that cannot store macOS file metadata writes extra files named `._` beside every file, and Nextflow trips over them. Results still land where you asked. | Nothing, if the run finishes. If it does not, move the project to the internal drive and rerun. A drive formatted exFAT, the usual format for drives shared with Windows PCs, is the most common cause, and Finder's **File > Get Info** on the drive names its format. | [Running External Workflows](../08-workflows/03-running-external-workflows.md) |
| An SRA download row fails with HTTP 429, or says too many requests | ENA and NCBI limit how many requests they accept from one network in a short time, and 429 is a web server's code for too many requests. Nothing is wrong with the run or with LGE. | Wait a few minutes, then start the download again from the SRA Runs pane. For heavy searching from the command line, a free NCBI API key raises the limit, passed as `lungfish-cli fetch sra search <query> --api-key <key>`. | [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) |
| An SRA download row fails after the connection dropped | A dropped connection while ENA is sending the files sends the run to the SRA Toolkit, which fetches it from NCBI instead. The row fails only when the toolkit cannot fetch the run either, most often because the network itself is down. With Download source set to Prefer NCBI the order is reversed, and the error names both archives' reasons. | Check the connection, then start the download again from the SRA Runs pane. |
| SRA downloads are slow while ENA is sending the files | ENA's servers are busy. NCBI holds the same reads, but the SRA Toolkit has to convert them on your Mac. | Set **Download source** in the SRA Runs pane's Advanced Search Filters to Prefer NCBI, or add `--prefer-source ncbi` to `lungfish-cli fetch sra download`. | [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md#which-path-served-your-download) | [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) |
| A TaxTriage row in the Operations Panel reads Completed with Warnings, or every TASS Score in the result reads 0.000 | A pipeline step failed and TaxTriage carried on without it. The row's detail names the step, and a step killed for lack of memory usually means the host genome entered the top hits and was downloaded as a reference. | Put the host's taxonomy ID in **Exclude host taxa**, 9606 for human, or raise **Max memory**, then run again, as [Keep the human genome out of the top hits](../06-classification/04-running-taxtriage.md#keep-the-human-genome-out-of-the-top-hits) shows. | [Running TaxTriage](../06-classification/04-running-taxtriage.md) |
| A Viral Recon or TaxTriage run stops at once with "Docker daemon unreachable" | The pipeline runs its steps in containers through Docker Desktop, and Docker Desktop is not running. | Start Docker Desktop, wait until it reports that its engine is running, and run again. [Containers and pipelines will not start](#containers-and-pipelines-will-not-start) has the check. | [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) |
| A message begins "Required tool is missing", exit status 126 | The tool the operation runs is not installed. | Install the pack that holds it, as [Tools and databases are missing](#tools-and-databases-are-missing) explains. | [Plugin Packs](../01-foundations/07-plugin-packs.md) |
| `Empty Kraken2 report`, exit status 64 | This is a known defect, listed with its workaround in [Known defects in this release](#defect-kraken-empty). | See the defect row. | [Running Kraken 2](../06-classification/02-running-kraken2.md) |

Any other failure that names a tool, such as MEGAHIT, is worth checking against the defect list before you change your settings.

## A command refused me

Every entry here is a command typed into Terminal. A refusal means nothing ran and nothing on disk was changed.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| `genotype-cohort` stops with a message that at least two input FASTQ bundles are required | A [cohort](../../GLOSSARY.md#cohort) is the group of samples compared together, so one bundle is not a cohort. [FASTQ](../../GLOSSARY.md#fastq) is the text format holding sequencing reads and their quality scores. | Pass two or more bundles, or run `fastq genotype` on the single sample instead. | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) |
| `convert` says "File already exists. Use --force to overwrite.", or, with `--force`, that input and output must be different files, exit status 4 | The output names an existing file, or names the input file itself, and the command declines to convert a file onto itself. | Give the output a different name. | [CLI Reference](cli-reference.md) |
| A VCF import stops saying VCFv3 is not supported | The file is in version 3 of the Variant Call Format, which LGE refuses. Any 4.x version is accepted. | Convert it to VCF 4.x with `bcftools convert` or with vcftools' `vcf-convert`. Neither ships with LGE, so install one yourself, or ask whoever gave you the file for a 4.x copy. | [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) |
| `fastq ont-barcode-genotype` prints a deprecation notice | Deprecated means the command still works but is scheduled for removal. | Build per-sample `.lungfishfastq` bundles with a FASTQ import recipe, a saved set of import steps LGE replays for you, then run `fastq genotype` or `fastq genotype-cohort` on those. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) |
| An unknown-pack error with exit status 3 | The pack id is misspelled, or the pack is experimental and the command-line installer does not offer it. | Read the list of ids the error prints. For an experimental pack, see [its defect row](#defect-conda-experimental-pack). | [Plugin Packs](../01-foundations/07-plugin-packs.md) |

## The run finished but the result is not what I expected

The hardest failures are the quiet ones, where a command finishes with exit status zero and the answer is still not what you wanted.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| Raising **Min Reads** on a genotyping run removes no rows from the report | This is how the setting works. Min Reads, `--min-support` on the command line, sets the read support a call needs to count as haplotype evidence. It never removes rows, so the raw evidence stays visible. | Use the result window's filters to hide thin rows, as [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md) explains. | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) |
| The **Mean Q** card reads lower than another program's mean quality for the same reads | LGE's Mean Q converts each quality score to the chance the base is wrong, averages those chances, and converts the average back to a score, which is what seqkit reports as AvgQual. A plain average of the scores, which some programs report, comes out higher on the same reads. | Compare Mean Q only with other Mean Q values, or with seqkit's AvgQual. | [Quality Control for Reads](../03-reads/03-quality-control.md) |
| After **Mark Duplicates in Bundle Tracks**, every alignment track appears twice, one name ending `[unmarked]` and one ending `[dup-marked]` | This is how duplicate marking works in a bundle. The original track is kept and renamed, and the marked copy is added under `alignments/marked/`. Running it again says every track already has a duplicate-marked version and changes nothing. | Choose the `[dup-marked]` track for later steps, and keep the `[unmarked]` one as the record of the input. | [Alignment Quality](../04-alignments/04-alignment-quality.md) |
| An extracted sequence's name line carries a bracket such as `[chr20:1000-2000, 1-based]` | The bracket gives the region in the same 1-based, inclusive counting the ruler and **Go to Location** use, so you can paste it straight back. A name line without the `1-based` tag came from an older extraction whose start was counted from zero, so add one to its start. | Nothing, for a tagged header. | [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) |
| A CZ ID import does not appear under `Analyses/` | CZ ID results are written as `Classifications/<sample>.lungfishtax`, which the import sheet names as the destination. | Look for the result under `Classifications/` in the sidebar. | [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md) |
| After an Oxford Nanopore run-folder import, the barcode bundles are not at the top of the project | They are written under `Imports/<run name>/`, one bundle per barcode. | Open the run's folder under `Imports/` in the sidebar. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) |
| You import a BigWig or BigBed file and nothing appears in the window | Both formats hold values along a genome, BigWig for a continuous signal such as coverage and BigBed for named intervals. LGE recognises both by their extension, or by their contents when the extension is missing, but has no reader for a loose file of either kind, so detection succeeds and display cannot follow. The file is not broken. | Convert the file to a format LGE reads, such as bedGraph or BED, or view it in a genome browser that supports it. | [File Formats](file-formats.md) |
| A number differs between the window and a command, or a count looks wrong | Check the defect list first. Several known defects are wrong or empty numbers rather than failed runs. | See [Numbers and files that are wrong or incomplete](#numbers-and-files-that-are-wrong-or-incomplete). | The chapter named in the defect row |

## Tools and databases are missing

Every check in this section is a command typed into Terminal. The Plugin Manager, **Tools > Plugin Manager...** (Cmd-Shift-B), is the window route for installing what these commands report as missing.

Most LGE operations run their tools from private folders of software, one per tool, called environments. A missing-tool error means an environment is absent, not that the operation is unsupported. On the command line the message begins with the words Required tool is missing and then names the tool, and the command exits 126. Install the pack that holds the tool, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of tools LGE installs on request.

The first check for any missing-tool error is `lungfish-cli debug env --check-tools`, which reports each tool as available with its version or as not found. Add `--tool <name>`, replacing `<name>` with the tool you mean, to check one.

A [dependency set](../../GLOSSARY.md#dependency-set) is the exact list of tool versions one LGE release was built and tested against. `lungfish-cli version --tools` prints the app version, the dependency set, and a table of the tools that ship with LGE. The number of rows depends on your install, so a count that differs from a colleague's is not a fault.

`lungfish-cli tools update --plan` lists every install, reinstall, removal, and database update this machine is missing against the pinned set. It exits 10 when work is pending and 0 when there is none. A line starting `preserve` names a tool you installed yourself that LGE leaves alone, and tells you how to switch to the pinned build if you want it.

Databases are managed apart from tool packs. Use `lungfish-cli conda db list` to see what is available and installed, `lungfish-cli conda db recommend` to see which Kraken 2 database suits this Mac's memory, and `lungfish-cli conda db download <name>` to fetch one. EsViritu has its own pair, `lungfish-cli esviritu download-db` and `lungfish-cli esviritu db-status`. The window route is [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab).

Two messages come from the lock LGE takes while it changes its tool folder. Running two installs at once prints `waiting for conda lock held by pid <n>`, where the number names the other install's process, and then continues by itself once that install finishes. A tool folder you cannot write to prints `conda root is read-only; reinstall as the admin user`, which is about the folder's permissions rather than the pack. An admin user is an account allowed to install software, and whoever set up the computer can tell you whether yours is one.

If a pack install sits at solving the environment for many minutes, a proxy is the usual cause, meaning a machine your network sends downloads through. Ask whoever runs your network whether one is in use and what its address is. Then quit LGE, open Terminal from **Applications > Utilities**, set the [environment variable](../../GLOSSARY.md#environment-variable) `HTTPS_PROXY` with `export HTTPS_PROXY=http://proxy.example.org:8080`, using the address they give you, and start LGE from that same window with its full path, as [Finding the program](cli-reference.md#finding-the-program) gives it, ending in `Contents/MacOS/Lungfish` instead of `lungfish-cli`. An app opened from the Dock does not see the variable. The download tool reads that variable, not LGE itself.

## Containers and pipelines will not start

Every check in this section is a command typed into Terminal, apart from starting Docker Desktop.

A [container](../../GLOSSARY.md#container) packages a program with everything it needs so it behaves the same on every machine. Viral Recon and TaxTriage run their steps inside containers through [Docker](../../GLOSSARY.md#docker) Desktop, a separate app you install yourself, and when Docker Desktop is not running they fail with "Docker daemon unreachable" or with messages that do not name it at all. [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) says which tools need it and how to install it.

Start Docker Desktop first and wait until it reports that its engine is running. Then run `lungfish-cli debug container`, which checks the Docker Desktop connection the pipelines use. A working machine prints `Docker daemon reachable` under the heading "Docker (used by pipelines)", with the Docker version, and the command exits 0. When Docker Desktop is not running it prints `Docker daemon unreachable`, tells you to start Docker Desktop, and exits 65. A second section, "Apple Containerization (not used by pipelines)", reports Apple's own container system, which no pipeline uses, so its state does not matter here. Add `--pull-test` to check that the machine can also download an image, the packaged copy of a tool, through Docker. For a TaxTriage run, `lungfish-cli taxtriage check-prerequisites` checks Nextflow and the container runtime together before you commit to a run.

No setting lets these pipelines run without Docker. `lungfish-cli workflow run` lists `docker`, `conda`, and `local` for its `--executor` option, which [`workflow run`](cli-reference.md#workflow-run) describes, but it refuses any value other than `docker` for an nf-core pipeline before anything runs, and the window offers no other choice.

`lungfish-cli debug env` on its own is a quicker check that probes no tools. It prints the macOS version, the core count, the memory, the processor architecture, and whether Apple Containerization is available, and it reminds you that pipelines run through Docker Desktop. None of those figures is a target to match.

## Is this file or bundle intact

Every check in this section is a command typed into Terminal. There is no window route for these three.

`lungfish-cli analyze validate <files>...` checks whether a sequence or variant file is well formed. Add `--strict` to reject files that are readable but irregular. In a FASTA file it reports duplicate record names, empty records, and characters outside the nucleotide and protein alphabets. In a FASTQ file it reports duplicate read names and empty reads. In a VCF it reports data lines whose number of columns disagrees with the `#CHROM` header line, and records that repeat an earlier position with the same bases. A file that fails exits with status 5. `lungfish-cli bundle validate <bundle>` checks the structure of a reference bundle.

`lungfish-cli provenance verify` checks a signed [provenance](../../GLOSSARY.md#provenance) record, and signing is off by default. On an ordinary unsigned [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) it exits 64 and reports that the signature artifact is missing, which means "not signed" rather than "not valid". To check an unsigned record, open the sidecar in any text editor, read its `exitStatus` field, and check that the output files it lists exist.

Missing index files regenerate by themselves. An index file is a small companion that lets LGE jump straight to one part of a large file rather than reading all of it. LGE rebuilds a `.fai`, a `.bai`, or a `.tbi` the first time an operation needs one. If that rebuild fails, the underlying tools are `samtools faidx`, `samtools index`, and `tabix`.

## Known defects in this release

This is the single list of faults in LGE itself that this manual keeps. Every row was checked against the build in its last column, by running the app or its bundled `lungfish-cli`, or by reading the source that build was made from. A chapter whose steps a defect blocks carries one sentence and a link back here. A defect that a later release fixes leaves this list, so a row here means the fault was present in the build named.

Each row has its own anchor, so a chapter can link the row it means. [Defects by chapter](#defects-by-chapter), after the tables, lists the rows for each chapter.

### Window

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| **Reassemble missing.**{#defect-reassemble} **Reassemble...** never appears on the right-click menu of an assembly result in `Analyses/`, because it is offered only on bundles and those results are folders. | [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md) | Start a new assembly from **Tools** with the same settings, read from the result's provenance record. | 2026.9.52 |
| **Primer scheme bundle left out silently.**{#defect-primer-scheme-silent-skip} A `.lungfishprimers` bundle in the project's `Primer Schemes/` folder that lacks `manifest.json`, `primers.bed`, or `PROVENANCE.md` is left out of every Primer Scheme menu, with no message saying why. | [Primer Scheme Bundles](primer-schemes.md#bundle-layout) | Check that the bundle folder holds all three files, or import the scheme again from its BED file. | 2026.9.52 |
| **GATK Core card size.**{#defect-gatk-card} The Plugin Manager's GATK Core card, shown once experimental features are on, describes the pack as command construction and dry-run support, although its commands run, and estimates 600 MB, while the installed pack takes about 900 MB. | [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md), [Plugin Packs](../01-foundations/07-plugin-packs.md) | Allow about 1 GB of disk for it. | 2026.9.52 |
| **Region without a sequence name.**{#defect-query-region} In the Variants tab's Query Builder, a Region value with no sequence name, such as `1000-2000`, is ignored without a warning, so the table is not restricted at all. | [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md) | Write the region with its sequence name, as `chr20:1000-2000`. | 2026.9.52 |
| **CZ ID taxon count.**{#defect-czid-root-row} When a CZ ID report carries its own root row, the imported result's action bar counts that row as a taxon, so two real taxa read as 3 taxa. | [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md) | Subtract one. | 2026.9.52 |
| **EsViritu Coverage filter.**{#defect-esviritu-coverage-filter} Typing a number into the EsViritu **Coverage** column filter matches on breadth, the percent of the genome covered, although the column shows mean depth. | [Running EsViritu](../06-classification/03-running-esviritu.md) | Sort the Coverage column instead of filtering it. | 2026.9.52 |
| **EsViritu Identity column.**{#defect-esviritu-identity} The EsViritu **Identity** column shows the identity fraction with a percent sign, so 0.997 appears as 1.0%. | [Running EsViritu](../06-classification/03-running-esviritu.md) | Read the value as a fraction, so 1.0% means an identity near 1, that is near 100 percent. Copying a row rounds it to two decimals. | 2026.9.52 |
| **Kraken 2 provenance buttons.**{#defect-kraken-provenance} On a Kraken 2 result reopened from the sidebar, the action bar's information button and **Export > Show Provenance...** do nothing. | [Running Kraken 2](../06-classification/02-running-kraken2.md) | Read the run's settings in the Inspector instead. | 2026.9.52 |
| **NAO-MGS panel order.**{#defect-naomgs-order} The NAO-MGS read panels are labelled as ordered by unique read count, but they are ordered by total hits. | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | Read the order as total hits. | 2026.9.52 |
| **TaxTriage Add Sample.**{#defect-taxtriage-add-sample} In the TaxTriage dialog, **Add Sample** adds a row with no reads file, and the row has no control for choosing one, so the run leaves that row out without a warning. | [Running TaxTriage](../06-classification/04-running-taxtriage.md) | Select every sample's bundle, controls included, in the sidebar before you open the dialog. | 2026.9.52 |

### Runs that fail or stop

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| **MEGAHIT fails.**{#defect-megahit} MEGAHIT 1.2.9 fails most runs on Apple Silicon Macs, with a nonzero exit and no contigs, even with the two workarounds LGE applies. Three of four test runs on the human mitochondrial reads failed. | [When to Assemble](../07-assembly/01-when-to-assemble.md), [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md) | Run it again, or use SPAdes. A MEGAHIT run that does finish is correct. | 2026.9.40 |
| **Empty Kraken2 report.**{#defect-kraken-empty} A Kraken 2 run whose database matches none of the reads stops with `Empty Kraken2 report` and exit status 64, instead of showing a result that is 100 percent unclassified. | [Running Kraken 2](../06-classification/02-running-kraken2.md) | Read the failure as "nothing matched". Try a larger database, or check that the reads are the sample you meant. | 2026.9.52 |
| **Select Reads by Sequence edit distance.**{#defect-select-reads-edit-distance} **Select Reads by Sequence** stops with `edit distance must be between 0 and 2` and writes nothing when Min Overlap times Error Rate rounds to 3 or more. | [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) | Keep Min Overlap times Error Rate below 2.5, as with the defaults of 16 and 0.15. | 2026.9.52 |
| **NAO-MGS extract by database.**{#defect-naomgs-by-db} `lungfish-cli extract reads --by-db` on an imported NAO-MGS result exits 1 saying the extraction produced zero reads. | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | Use `lungfish-cli extract reads --by-classifier --tool naomgs` with the result, the sample, and an accession, as that chapter shows. | 2026.9.40 |
| **ONT Fluidigm Sample Split reports failure.**{#defect-fluidigm-provenance} **ONT Fluidigm Sample Split** and `lungfish-cli fastq ont-fluidigm-samples` finish the split, then stop with "Local provenance file descriptor must be added from a URL" and exit status 1, so the run is reported as failed. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) | On the command line the output folder is written before the error, so read it there. In the window there is no workaround. | 2026.9.52 |
| **fastq scout and demultiplex on a bundle.**{#defect-scout-bundle-provenance} `lungfish-cli fastq scout` and `lungfish-cli fastq demultiplex` given a `.lungfishfastq` bundle stop with the same "Local provenance file descriptor must be added from a URL" message and exit status 1. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) | Run the command from inside the `.lungfish` project folder and pass the FASTQ file inside the bundle instead. | 2026.9.52 |

### Numbers and files that are wrong or incomplete

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| **Orient against one long sequence.**{#defect-orient-long-reference} Orienting reads against a reference that is one long sequence, such as a chromosome slice, orients nothing and writes an empty result. No warning appears, and only the Unmatched count in the run summary shows that every read failed to match. | [Read Processing](../03-reads/08-read-processing.md) | Orient against a reference split into short records, such as single genes, and compare the output read count with the input count. | 2026.9.52 |
| **VarSkip Long amplicon count.**{#defect-varskip-count} The shipped NEB VarSkip Long scheme reports 29 amplicons, although its primer file defines 25. | [Primer Scheme Bundles](primer-schemes.md) | Read 25 for VarSkip Long. | 2026.9.52 |
| **fastq orient --compress.**{#defect-orient-compress} `lungfish-cli fastq orient --compress` writes plain text, not gzip. | [Read Processing](../03-reads/08-read-processing.md) | Name the output without `.gz` and compress it yourself with `gzip`. | 2026.9.52 |
| **fastq interleave lowest qualities.**{#defect-interleave-q2} `lungfish-cli fastq interleave` rewrites the quality of every `N` base as 0 and raises a quality of 0 or 1 on any other base to 2. The bases themselves are untouched. | [Read Processing](../03-reads/08-read-processing.md) | Treat quality scores of 0 to 2 in the output as approximate. | 2026.9.52 |
| **Search Reverse Complement switch.**{#defect-search-reverse-complement} The **Search Reverse Complement** switch in **Select Reads by Sequence** changes nothing, because the search always covers both strands. | [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) | None needed. Expect both strands to be searched. | 2026.9.52 |
| **Nanopore base count estimate.**{#defect-ont-base-estimate} After a Nanopore run-folder import, the base count in `demux-manifest.json` is an estimate, one and a half times the compressed file size, and can be far too high. The FASTQ viewport may show the same estimate until the summary is refreshed. The read counts are exact. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) | Run **Tools > QC & Reporting > Refresh QC Summary** on the bundle, then read the Bases card. | 2026.9.52 |
| **extract-annotations CDS keeps introns.**{#defect-extract-annotations-cds} `lungfish-cli bundle extract-annotations --feature-type CDS` writes the whole span of a coding feature, introns included. | [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) | Extract the feature in the window, by right-clicking it, which joins the exons in the gene's own orientation. | 2026.9.52 |
| **A second VCF import replaces the first.**{#defect-vcf-import-same-id} `lungfish-cli import vcf` takes a track's id from the file name, so `calls.vcf.gz` becomes `calls`. Importing a second file of the same name into one bundle, or the same file again under a different `--name`, gives the new track that same id, and it replaces the earlier track without a message. | [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) | Give each file a distinct name before you import it. | 2026.9.52 |
| **bundle info variant count.**{#defect-bundle-info-variants} `lungfish-cli bundle info` reports 0 in the Variants column for a track that `bundle create --variant` built from a compressed VCF. | [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) | Open the bundle in LGE once, or trust the Variants tab's row count. | 2026.9.52 |
| **Min Contig not applied.**{#defect-assembly-min-contig} The SPAdes **Min Contig** setting is recorded in the result but not applied, so short contigs stay in. On the command line `--min-contig-length` and `--memory-gb` are accepted and ignored for Flye and hifiasm. | [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md), [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md) | Sort the contig table by length and ignore the short contigs, or filter them yourself after the run. | 2026.9.52 |
| **12S reference name lines.**{#defect-twelve-s-names} Building a 12S reference from a FASTA whose name lines are not in the form `Common name (Scientific name)`, such as `>Homo_sapiens`, fills a sequence's names only when a metadata table row matches that sequence exactly. Any other record matches no metadata row. The reference is written with the raw label as its scientific name and empty common name, taxid, and group columns, and the command reports success. | [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | Write name lines as `>Human (Homo sapiens)`, and check that the built reference shows species names before you match reads against it. | 2026.9.52 |
| **12S help lists five columns.**{#defect-twelve-s-help} The help text of `fastq 12s-reference-metadata` and `fastq 12s-reference-bundle` names five of the seven required metadata columns, leaving out `common_name` and `name_source`. | [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | Build the table from the column list in that chapter. | 2026.9.52 |
| **nao-mgs summary names one sample.**{#defect-naomgs-summary} `lungfish-cli nao-mgs summary` on a file holding several samples pools the hits of every sample into its totals, but its Sample line names only the first sample. | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | Read the totals as covering every sample in the file, or import the file into a project to see each sample. | 2026.9.52 |
| **joint-genotype without --gvcf.**{#defect-joint-genotype-no-gvcf} `lungfish-cli gatk joint-genotype` with no `--gvcf` is accepted, exits 0, and plans a combine step with no input. | [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md) | Always pass one `--gvcf` per sample. | 2026.9.52 |
| **GATK, Viral Recon, and BAM headers name local folders.**{#defect-vcf-header-paths} LGE rewrites the folder paths in the VCF headers of its own variant callers, bcftools, LoFreq, iVar, Medaka, and Clair3. The VCFs the `lungfish-cli gatk` commands and a Viral Recon run write keep the tools' header lines unchanged, so they can name the tool folder and a temporary work folder on the Mac that made them. Every BAM LGE writes also names local folders in its `@PG` header lines, which record the programs that produced it. | [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md), [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md), [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) | Before you share one of these files outside your group, read its header with `bcftools view -h` for a VCF or `samtools view -H` for a BAM, and remove any line that names a private folder. | 2026.9.52 |

### Records that are wrong or missing

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| **bbduk version unknown.**{#defect-bbduk-version} Some provenance steps, such as bbduk's, record the tool version as `unknown`. | [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) | Take tool versions from `lungfish-cli version --tools` or [Tool Versions](tool-versions.md). | 2026.9.40 |
| **LoFreq version.**{#defect-lofreq-version} The LoFreq version in a provenance record is LoFreq's error message, because LoFreq rejects the `--version` flag LGE asks it with. | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) | Take LoFreq's version from [Tool Versions](tool-versions.md). | 2026.9.52 |
| **EsViritu version.**{#defect-esviritu-version} The EsViritu version in a provenance record reads `3.14`, the Python version, rather than EsViritu's own. | [Running EsViritu](../06-classification/03-running-esviritu.md) | Take EsViritu's version from [Tool Versions](tool-versions.md). | 2026.9.52 |
| **Freyja output has no checksum.**{#defect-freyja-checksum} A Freyja provenance record lists `freyja-demix.tsv` with no checksum or size, because the record is written from the plan before Freyja runs. | [Running Freyja](../06-classification/07-running-freyja.md) | Keep the whole output folder together, so the plan and the record stay beside the result, or record a checksum yourself with `shasum -a 256 freyja-demix.tsv`. | 2026.9.52 |
| **Freyja messages not kept.**{#defect-freyja-messages} A successful `lungfish-cli freyja demix --execute` run keeps none of Freyja's own messages in its provenance record, and a failed run writes no provenance record at all, only the plan file. | [Running Freyja](../06-classification/07-running-freyja.md) | Save the text Freyja prints in Terminal yourself. | 2026.9.52 |
| **GATK runs share one record.**{#defect-gatk-provenance-overwrite} Each `lungfish-cli gatk ... --execute` into the same output folder replaces the previous run's provenance record. | [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md) | Give every GATK run its own output folder. | 2026.9.52 |
| **GATK options accept misspellings.**{#defect-gatk-misspelled} Some `lungfish-cli gatk` options accept a misspelled value without a warning. An unknown `filter --preset` becomes `best-practices-both`, `--preset custom` builds no filter expressions, an unknown `select --type` is dropped so every variant is selected, an unknown `--combine-strategy` becomes `auto`, an unknown `--emit-ref-confidence` becomes GVCF, and an unknown `validate-sam --mode` becomes summary. | [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md), [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md) | Check the recorded command in the provenance record. | 2026.9.52 |
| **Bibliography cites the wrong tool.**{#defect-bibliography-wrong-tool} `lungfish-cli provenance bibliography` matches a step to the wrong tool when the two names share a single word. Trim Galore, `gatk-variants-to-table`, `gatk-select-variants`, and LGE's own consensus and alignment-trimming steps print the iVar citation. `gatk-variant-filtration` and LGE's variant database import print the Medaka citation. LGE's QC summary steps print MultiQC, its tree reroot, relabel, and subtree steps print IQ-TREE, and a step named `gzip` prints HTSlib. Many tools, including every assembler, print no citation at all. | [Tool Bibliography](bibliography.md) | Delete a citation for a tool that never ran, and take the right one from the tables in [Tool Bibliography](bibliography.md). | 2026.9.52 |
| **reproduce.py repeats an input.**{#defect-export-duplicate-parameter} When two recorded steps name the same file, the `reproduce.py` export writes its `INPUTS` entry twice, and the second copy replaces the first without a warning. The Nextflow and Snakemake exports list each file once. | [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) | Delete the duplicate line. | 2026.9.52 |

### Command-line options that are ignored or refused

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| **Experimental packs refused.**{#defect-conda-experimental-pack} `lungfish-cli conda install --pack` with an experimental pack, `gatk-core`, `phasing`, or `wastewater-surveillance`, stops with "Unknown tool pack" and exit status 3. The list of ids the error prints leaves out every experimental pack. | [Plugin Packs](../01-foundations/07-plugin-packs.md), [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md), [Running Freyja](../06-classification/07-running-freyja.md) | Turn experimental features on and install the pack from the Plugin Manager, **Tools > Plugin Manager...** (Cmd-Shift-B), as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. | 2026.9.52 |
| **--format json ignored.**{#defect-format-ignored} `--format json` is accepted and ignored by `conda packs`, `ops stats`, `workflow list`, `conda offline-export`, and `version`, which print ordinary text. `blast verify --format tsv` prints text, and `project migrate --format tsv` prints text. | [Running in CI](06-running-in-ci.md), [BLAST Verification](../06-classification/06-blast-verification.md) | Read the text output, or read the field you need from the provenance sidecar, which is JSON. | 2026.9.52 |
| **MEGAHIT --profile default.**{#defect-megahit-profile} `lungfish-cli assemble --assembler megahit --profile default` passes `--presets default` to MEGAHIT, which is not one of its presets. | [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md) | Leave `--profile` off for MEGAHIT. | 2026.9.52 |
| **Upper-case .NF not run.**{#defect-nf-extension-case} `lungfish-cli workflow run` recognises a Nextflow file only by a lower-case `.nf` extension, so `pipeline.NF` is not run as Nextflow, while `workflow validate` accepts it. | [Running External Workflows](../08-workflows/03-running-external-workflows.md) | Name pipeline files in lower case. | 2026.9.52 |
| **check-tools Nextflow version.**{#defect-check-tools-nextflow} `lungfish-cli debug env --check-tools` prints Nextflow's complaint about a flag as Nextflow's version. | [Running in CI](06-running-in-ci.md) | Treat the row as proof that Nextflow is present, and run `nextflow -version` for the number. | 2026.9.52 |
| **project migrate counts.**{#defect-migrate-counts} `lungfish-cli project migrate` prints summary counts that do not add up, because unreadable bundles are counted as unsupported and bundles with a migration available are counted nowhere. | [Shared Projects and Bundle Migration](shared-projects.md) | Trust the per-bundle lines, not the counts. | 2026.9.52 |
| **Help examples.**{#defect-help-examples} The example lines in many `--help` screens spell the program `lungfish` rather than `lungfish-cli`, and `translate --help` shows examples with `--all-frames` and `--stop-as-asterisk`, which that command does not accept. | [CLI Reference](cli-reference.md) | Type `lungfish-cli`, and use the flags in the OPTIONS list of the help screen. | 2026.9.52 |

### Defects by chapter

Find your chapter and follow the link to its row.

| Chapter | Rows in the tables above |
|---|---|
| [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | [12S reference name lines](#defect-twelve-s-names), [12S help lists five columns](#defect-twelve-s-help) |
| [BLAST Verification](../06-classification/06-blast-verification.md) | [--format json ignored](#defect-format-ignored) |
| [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) | [LoFreq version](#defect-lofreq-version) |
| [CLI Reference](cli-reference.md) | [Help examples](#defect-help-examples) |
| [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) | [reproduce.py repeats an input](#defect-export-duplicate-parameter) |
| [Extracting Sequences](../02-sequences/03-extracting-and-comparing.md) | [extract-annotations CDS keeps introns](#defect-extract-annotations-cds) |
| [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md) | [GATK runs share one record](#defect-gatk-provenance-overwrite), [GATK options accept misspellings](#defect-gatk-misspelled) |
| [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md) | [GATK, Viral Recon, and BAM headers name local folders](#defect-vcf-header-paths) |
| [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md) | [CZ ID taxon count](#defect-czid-root-row) |
| [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) | [A second VCF import replaces the first](#defect-vcf-import-same-id), [bundle info variant count](#defect-bundle-info-variants) |
| [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | [NAO-MGS panel order](#defect-naomgs-order), [NAO-MGS extract by database](#defect-naomgs-by-db), [nao-mgs summary names one sample](#defect-naomgs-summary) |
| [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md) | [joint-genotype without --gvcf](#defect-joint-genotype-no-gvcf), [GATK options accept misspellings](#defect-gatk-misspelled) |
| [Long-Read Assembly (Flye, hifiasm)](../07-assembly/03-running-flye-or-hifiasm.md) | [Min Contig not applied](#defect-assembly-min-contig) |
| [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) | [GATK, Viral Recon, and BAM headers name local folders](#defect-vcf-header-paths) |
| [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) | [ONT Fluidigm Sample Split reports failure](#defect-fluidigm-provenance), [fastq scout and demultiplex on a bundle](#defect-scout-bundle-provenance), [Nanopore base count estimate](#defect-ont-base-estimate) |
| [Plugin Packs](../01-foundations/07-plugin-packs.md) | [GATK Core card size](#defect-gatk-card), [Experimental packs refused](#defect-conda-experimental-pack) |
| [Primer Scheme Bundles](primer-schemes.md) | [Primer scheme bundle left out silently](#defect-primer-scheme-silent-skip), [VarSkip Long amplicon count](#defect-varskip-count) |
| [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) | [bbduk version unknown](#defect-bbduk-version) |
| [Read Processing](../03-reads/08-read-processing.md) | [Orient against one long sequence](#defect-orient-long-reference), [fastq orient --compress](#defect-orient-compress), [fastq interleave lowest qualities](#defect-interleave-q2) |
| [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md) | [Region without a sequence name](#defect-query-region) |
| [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md) | [GATK Core card size](#defect-gatk-card), [Experimental packs refused](#defect-conda-experimental-pack) |
| [Running EsViritu](../06-classification/03-running-esviritu.md) | [EsViritu Coverage filter](#defect-esviritu-coverage-filter), [EsViritu Identity column](#defect-esviritu-identity), [EsViritu version](#defect-esviritu-version) |
| [Running External Workflows](../08-workflows/03-running-external-workflows.md) | [Upper-case .NF not run](#defect-nf-extension-case) |
| [Running Freyja](../06-classification/07-running-freyja.md) | [Freyja output has no checksum](#defect-freyja-checksum), [Freyja messages not kept](#defect-freyja-messages), [Experimental packs refused](#defect-conda-experimental-pack) |
| [Running in CI](06-running-in-ci.md) | [--format json ignored](#defect-format-ignored), [check-tools Nextflow version](#defect-check-tools-nextflow) |
| [Running Kraken 2](../06-classification/02-running-kraken2.md) | [Kraken 2 provenance buttons](#defect-kraken-provenance), [Empty Kraken2 report](#defect-kraken-empty) |
| [Running TaxTriage](../06-classification/04-running-taxtriage.md) | [TaxTriage Add Sample](#defect-taxtriage-add-sample) |
| [Shared Projects and Bundle Migration](shared-projects.md) | [project migrate counts](#defect-migrate-counts) |
| [Short-Read Assembly (SPAdes, MEGAHIT, SKESA)](../07-assembly/02-running-spades.md) | [Reassemble missing](#defect-reassemble), [MEGAHIT fails](#defect-megahit), [Min Contig not applied](#defect-assembly-min-contig), [MEGAHIT --profile default](#defect-megahit-profile) |
| [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) | [Select Reads by Sequence edit distance](#defect-select-reads-edit-distance), [Search Reverse Complement switch](#defect-search-reverse-complement) |
| [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) | [GATK, Viral Recon, and BAM headers name local folders](#defect-vcf-header-paths) |
| [Tool Bibliography](bibliography.md) | [Bibliography cites the wrong tool](#defect-bibliography-wrong-tool) |
| [When to Assemble](../07-assembly/01-when-to-assemble.md) | [MEGAHIT fails](#defect-megahit) |

## Reporting something this appendix does not cover

Gather the failure report first, with **Copy Failure Report** on the failed row's right-click menu, since it already holds the command, the message, and the log. Then add the app version, which **Lungfish Genome Explorer > About Lungfish Genome Explorer** shows and `lungfish-cli version` prints, and the macOS version from the Apple menu's **About This Mac**. The installed tool versions from `lungfish-cli version --tools` help but are optional.

The fastest route is **Open GitHub Issue** on the failed row's right-click menu, which opens a pre-filled issue in your browser. You review it and submit it yourself, so nothing is filed without your action. Submitting needs a free GitHub account. **Help > Report an Issue...** opens a new GitHub issue too, carrying the version string and the project's path and lock state, so it also needs an account. Without one, paste the failure report into an email to whoever supports LGE where you work.

Leave your project's data files out of the report. The failure report holds LGE's own log and the command it ran rather than your sequences. The command does name your files and folders, and often your sample names, so read it before you send it and replace any name you may not share. Sequence data is rarely yours alone to share.

## Next

See [Tool Bibliography](bibliography.md), the next appendix, to cite the tools a run used. [CLI Reference](cli-reference.md) gives the syntax of any command named here, [Running in CI](06-running-in-ci.md) covers exit statuses and checks in an unattended script, and [File Formats](file-formats.md) describes what each LGE bundle contains.
