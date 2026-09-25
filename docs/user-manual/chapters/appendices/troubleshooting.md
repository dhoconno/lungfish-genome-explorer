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
    caption: "A failed row in the Operations Panel expanded to show its command and log, with the right-click menu open on Copy Failure Report."
illustrations: []
glossary_refs: [accession, advisory-lock, bundle, cohort, conda, container, dependency-set, environment-variable, exit-status, failure-report, fastq, kraken2, nextflow, operations-panel, plugin-pack, project, project-lock, provenance, provenance-sidecar, read-classification, symlink, working-directory, workflow-library]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) is a window over a set of established programs that were built to be typed at rather than clicked. LGE runs those programs for you and shows you the results. When something goes wrong, the message you see often came from one of those programs rather than from LGE itself, so it may use words LGE never uses. This appendix collects the symptoms people actually meet, says what each one means in plain words, and gives the action to take.

The appendix is organised by what you see on screen rather than by which part of LGE is at fault. Look up the pale grey menu item, the message, the run that stopped, or the missing result, and read across. Each entry names the chapter that covers the operation in full. The last main section, [Known defects in this release](#known-defects-in-this-release), is the one list of faults in LGE itself that this manual keeps, each with a workaround and the build it was checked against.

To check which release you have, open **Lungfish Genome Explorer > About Lungfish Genome Explorer**, the first item under the app's own menu.

Some sections are read in the window and some need commands typed into Terminal, and each says which at its start. Two words are worth fixing first. An [exit status](../../GLOSSARY.md#exit-status) is the number a command hands back when it finishes, where zero means it succeeded and anything else means it stopped. A [working directory](../../GLOSSARY.md#working-directory) is the folder a Terminal window is sitting in when you type a command, and typing `pwd` and pressing Return prints it.

## Before you type anything

This section is optional, and nothing in the window-only sections needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

## Start here, at the failed row

This section is done entirely in the LGE window.

A run that fails turns its row red in the [Operations Panel](../../GLOSSARY.md#operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). Before you read any table below, right-click that row and choose **Copy Failure Report**. On a trackpad with no second button, hold Control and click, or click with two fingers. Do not retype the command by hand from what you remember choosing in a dialog, because a fresh typing mistake hides the real one.

Click the small arrow at the row's left edge to expand it. The expanded row shows the command LGE built on your behalf, the files it wrote, the running log, and on a failed row an Error section with the message. Read the Error section first and the command second.

<!-- SHOT: operations-panel-failed-row -->

The right-click menu on a failed row offers the items in this table.

| Item | What it gives you |
|---|---|
| **Copy Failure Report** | The operation title, the command, the error message, the tool's one-line summary, the longer detail, and the log, as one block ready to paste |
| **Copy CLI Command** | The command alone |
| **Copy Log** | The log alone |
| **Run Again...** | The same operation repeated exactly as recorded, when it can be replayed |
| **Open GitHub Issue** | A pre-filled issue in your browser carrying the report, which you review and submit yourself |
| **Reveal Failure Report in Finder** | The report file on disk |

That [failure report](../../GLOSSARY.md#failure-report) file is written as the failure happens, so it survives quitting the app. It lives at `~/Library/Logs/<app name>/Operations/Failures`, where the tilde stands for your Home folder and the app name keeps a Debug or Preview build's reports apart from a stable build's. Library is hidden in Finder, so **Reveal Failure Report in Finder** is the easy way there. LGE keeps the 50 most recent reports and deletes the oldest each time it writes a new one, so copy a report you care about rather than assuming it will still be there next month. If LGE cannot write a report, for example because the disk is full, it skips the report without a second error, so a missing report says nothing about the operation itself.

[The Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) describes the panel in full.

## Nothing happens when I choose a menu item

This section is done entirely in the LGE window.

Three things stay hidden or pale grey until something is turned on, and none of them says so loudly.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| Every item in **Tools > Genotyping** is pale grey with `(not enabled)` after its name | Genotyping works out which versions of a gene a sample carries. Its workflows are off until you enable them, because each needs a large install of outside programs. Nothing is broken. | Turn the workflow on once in the [Workflow Library](../../GLOSSARY.md#workflow-library), as [Running External Workflows](../08-workflows/03-running-external-workflows.md#procedure) shows. | [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md) |
| The Workflow Builder item is not in the Tools menu at all | The Workflow Builder is experimental and hidden by default, so the item is absent rather than pale grey. | Turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. | [The Workflow Builder](../08-workflows/01-the-workflow-builder.md) |
| The Inspector has no Assistant tab | The tab stays hidden until AI search is switched on in the **AI Services** tab of Settings. Even then it appears only while the viewport shows a reference sequence or an alignment of sequences, so reads, alignments, assemblies, classifier results, and genotype results give an Inspector without it. | Switch AI search on, as [The AI Assistant](ai-assistant.md) shows, then select a reference sequence in the sidebar. | [The AI Assistant](ai-assistant.md) |

A pale grey menu item's keyboard shortcut does nothing either, so pressing the shortcut for a workflow you have not enabled is silence rather than a second symptom.

## I cannot write to my project

This section is done entirely in the LGE window.

A [project](../../GLOSSARY.md#project) is the folder LGE keeps one piece of work in. A project another copy of LGE holds opens read only, as [Shared Projects and Bundle Migration](shared-projects.md#reading-the-windows-read-only-state) explains. That appendix also gives the window route for clearing a lock left behind by a session that has really ended.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| The window title ends in ` (Read Only)` | Another session holds the [project lock](../../GLOSSARY.md#project-lock), or LGE could not read the lock file to find out. | Close the other copy of the app, or the command-line run, and reopen the project. | [Shared Projects](shared-projects.md) |
| An alert titled with the project name and "may already be open" names a user, a host, and a process id | A live lock from a named session. The host is the computer holding it and the process id is the number macOS gave that running program, so together they say which machine and which window to close. | Confirm that session has ended before you clear the lock, since clearing a live one is how two writers end up in one folder. | [Shared Projects](shared-projects.md) |
| An alert headed "Project Is Open Read Only" appears when you click Run | You started a workflow that writes into the project while writing is blocked. The alert names the workflow. | Close the other writer, then close and reopen the project. The alert keeps appearing until you reopen it, because reopening is what gives the lock to your window. | [Shared Projects](shared-projects.md) |
| A message says lock metadata is corrupted, or could not be read | The lock file exists but LGE cannot make sense of it. Writing stays blocked until the lock is inspected or removed. | Make sure no other session is running, then clear the lock as [Shared Projects](shared-projects.md) describes. | [Shared Projects](shared-projects.md) |

On network storage, meaning a drive that lives on another computer and is reached over the network, a reported locking failure is often not a real lock problem. Lock failures name `.lungfish/project.lock` for a project, or a `.install.lock` file inside the tool folder for a plugin install. Those names begin with a dot, so Finder hides them until you press Cmd-Shift-period in a Finder window. Before you change how a share is mounted, look for stray files whose names begin with `._`, which macOS leaves on volumes that cannot hold its file metadata and which confuse the check. They are safe to delete, and macOS writes fresh ones when it needs them.

## A run stopped and I do not know why

These entries name the exact text a run prints, so you can match what you saw. The fixes are done in the window except where a command is shown.

The exit-status numbers below appear in the failure report and in Terminal.

| Exit status | What it means |
|---|---|
| 0 | The command succeeded. |
| 1 | The command refused or failed, for example a lock it may not replace or an output that already exists. |
| 2 | A usage error, such as `tools update --apply` without `--yes`. Nothing ran. |
| 4 | An expected workflow output was not created. |
| 3 | A pack name was not recognised and nothing was installed. |
| 10 | `tools update --plan` found pending work, which is a report rather than a fault. |
| 64 | A workflow error. The command refused the work, or the work failed inside a workflow step. |

Exit 64 covers both a run started without a required setting and a run whose tool failed, so read the message rather than assuming a typing mistake.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| A medium or long run on an external drive slows down, or moves its scratch files | [Nextflow](../../GLOSSARY.md#nextflow), the pipeline runner behind some LGE workflows, keeps temporary files beside a run. LGE tests the project's drive first and moves those files to the internal drive when the test fails. A drive that cannot store macOS file metadata writes extra files named `._` beside every file, and Nextflow trips over them. Results still land where you asked. | Nothing, if the run finishes. If it does not, move the project to the internal drive and rerun. A drive formatted exFAT, the usual format for drives shared with Windows PCs, is the most common cause, and Finder's **File > Get Info** on the drive names its format. | [Running External Workflows](../08-workflows/03-running-external-workflows.md) |
| An SRA download row fails with HTTP 429, or says too many requests | ENA and NCBI limit how many requests they accept from one network in a short time, and 429 is a web server's code for too many requests. Nothing is wrong with the run or with LGE. | Wait a few minutes, then start the download again from the SRA Runs pane. For heavy searching from the command line, a free NCBI API key raises the limit, passed as `lungfish-cli fetch sra search <query> --api-key <key>`. | [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) |
| An SRA download row fails partway through after the connection dropped | In the window, a dropped connection while ENA is sending the files ends the run. The window switches to the SRA Toolkit only when ENA lists no files or sends a file that fails LGE's checks. | Start the download again. If it keeps failing, run `lungfish-cli fetch sra download <accession> --output-dir <folder>`, which falls back to the SRA Toolkit after any ENA failure, then import the files through the Import Center. | [Downloading Reads from the SRA](../03-reads/02-downloading-from-sra.md) |
| `Empty Kraken2 report`, exit status 64 | This is a known defect, listed with its workaround in [Known defects in this release](#known-defects-in-this-release). | See the defect list. | [Running Kraken 2](../06-classification/02-running-kraken2.md) |
| A message about a provenance publication artifact that no longer matches, with nothing written | This is a known defect, listed with its workaround in [Known defects in this release](#known-defects-in-this-release). | See the defect list. | [CLI Reference](cli-reference.md) |

Any other failure that names a tool, such as MEGAHIT, Medaka, or Clair3, is worth checking against the defect list before you change your settings.

## A command refused me

Every entry here is a command typed into Terminal. A refusal means nothing ran and nothing on disk was changed.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| `genotype-cohort` stops with a message that at least two input FASTQ bundles are required | A [cohort](../../GLOSSARY.md#cohort) is the group of samples compared together, so one bundle is not a cohort. [FASTQ](../../GLOSSARY.md#fastq) is the text format holding sequencing reads and their quality scores. | Pass two or more bundles, or run `fastq genotype` on the single sample instead. | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) |
| `convert` says the output file already exists, or, with `--force`, that input and output must be different files | The output names the input file, and the command declines to convert a file onto itself. | Give the output a different name. | [CLI Reference](cli-reference.md) |
| A VCF import stops saying VCFv3 is not supported | The file is in version 3 of the Variant Call Format, which LGE refuses. Any 4.x version is accepted. | Convert it to VCF 4.x with `bcftools convert` or with vcftools' `vcf-convert`. Neither ships with LGE, so install one yourself, or ask whoever gave you the file for a 4.x copy. | [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) |
| `fastq ont-barcode-genotype` prints a deprecation notice | Deprecated means the command still works but is scheduled for removal. | Build per-sample `.lungfishfastq` bundles with a FASTQ import recipe, a saved set of import steps LGE replays for you, then run `fastq genotype` or `fastq genotype-cohort` on those. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) |
| An unknown-pack error with exit status 3 | The pack id is misspelled, or the pack is experimental and the command-line installer does not offer it. | Read the list of ids the error prints. For an experimental pack, see the defect list. | [Plugin Packs](../01-foundations/07-plugin-packs.md) |

## The run finished but the result is not what I expected

The hardest failures are the quiet ones, where a command finishes with exit status zero and the answer is still not what you wanted.

| Symptom | What it means | What to do | Chapter |
|---|---|---|---|
| Raising **Min Reads** on a genotyping run removes no rows from the report | This is how the setting works. Min Reads, `--min-support` on the command line, sets the read support a call needs to count as haplotype evidence. It never removes rows, so the raw evidence stays visible. | Use the result window's filters to hide thin rows, as [Reading the Genotype Comparison](../09-genotyping/03-reading-the-genotype-comparison.md) explains. | [Running Amplicon MHC Genotyping](../09-genotyping/02-running-genotyping.md) |
| You import a BigWig or BigBed file and nothing appears in the window | Both formats hold values along a genome, BigWig for a continuous signal such as coverage and BigBed for named intervals. LGE recognises both by their contents but has no reader for a loose file of either kind, so detection succeeds and display cannot follow. The file is not broken. | Convert the file to a format LGE reads, such as bedGraph or BED, or view it in a genome browser that supports it. | [File Formats](file-formats.md) |
| A number differs between the window and a command, or a count looks wrong | Check the defect list first. Several known defects are wrong or empty numbers rather than failed runs. | See [Known defects in this release](#known-defects-in-this-release). | The chapter named in the defect row |

## Tools and databases are missing

Every check in this section is a command typed into Terminal. The Plugin Manager, **Tools > Plugin Manager...** (Cmd-Shift-B), is the window route for installing what these commands report as missing.

Most LGE operations run their tools from private folders of software, one per tool, called environments. A missing-tool error means an environment is absent, not that the operation is unsupported. Install the pack that holds the tool, as [Plugin Packs](../01-foundations/07-plugin-packs.md#procedure) shows. A [plugin pack](../../GLOSSARY.md#plugin-pack) is a themed group of tools LGE installs on request.

The first check for any missing-tool error is `lungfish-cli debug env --check-tools`, which reports each tool as available with its version or as not found. Add `--tool <name>`, replacing `<name>` with the tool you mean, to check one.

A [dependency set](../../GLOSSARY.md#dependency-set) is the exact list of tool versions one LGE release was built and tested against. `lungfish-cli version --tools` prints the app version, the dependency set, and a table of the tools that ship with LGE. The number of rows depends on your install, so a count that differs from a colleague's is not a fault.

`lungfish-cli tools update --plan` lists every install, reinstall, removal, and database update this machine is missing against the pinned set. It exits 10 when work is pending and 0 when there is none. A line starting `preserve` names a tool you installed yourself that LGE leaves alone, and tells you how to switch to the pinned build if you want it.

Databases are managed apart from tool packs. Use `lungfish-cli conda db list` to see what is available and installed, `lungfish-cli conda db recommend` to see which Kraken 2 database suits this Mac's memory, and `lungfish-cli conda db download <name>` to fetch one. EsViritu has its own pair, `lungfish-cli esviritu download-db` and `lungfish-cli esviritu db-status`. The window route is [The Databases tab](../01-foundations/07-plugin-packs.md#the-databases-tab).

Two messages come from the lock LGE takes while it changes its tool folder. Running two installs at once prints `waiting for conda lock held by pid <n>`, where the number names the other install's process, and then continues by itself once that install finishes. A tool folder you cannot write to prints `conda root is read-only; reinstall as the admin user`, which is about the folder's permissions rather than the pack. An admin user is an account allowed to install software, and whoever set up the computer can tell you whether yours is one.

If a pack install sits at solving the environment for many minutes, a proxy is the usual cause, meaning a machine your network sends downloads through. Ask whoever runs your network whether one is in use and what its address is. Then quit LGE, open Terminal from **Applications > Utilities**, set the [environment variable](../../GLOSSARY.md#environment-variable) `HTTPS_PROXY` with `export HTTPS_PROXY=http://proxy.example.org:8080`, using the address they give you, and start LGE from that same window with `"/Applications/Lungfish Preview.app/Contents/MacOS/Lungfish"`. An app opened from the Dock does not see the variable. The download tool reads that variable, not LGE itself.

## Containers and pipelines will not start

Every check in this section is a command typed into Terminal.

A [container](../../GLOSSARY.md#container) packages a program with everything it needs so it behaves the same on every machine. Some pipelines run their steps inside containers, and when the container runtime is not ready they fail in ways that do not name the runtime. Which tools need one is in [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers).

Run `lungfish-cli debug container` first. It reports whether the Apple Containerization framework is available, and a working machine prints `Status      : Ready`. Any other status means the container route is closed on that machine. Add `--pull-test` to check that the machine can download an image, the packaged copy of a tool, because the framework can be present and still fail to fetch one. For a TaxTriage run, `lungfish-cli taxtriage check-prerequisites` checks Nextflow and the container runtime together before you commit to a run.

When the container route is closed, a Nextflow run can be pointed at conda instead of containers, and [Running External Workflows](../08-workflows/03-running-external-workflows.md) shows the dialog where that choice is made.

`lungfish-cli debug env` on its own is a quicker check that probes no tools. It prints the macOS version, the core count, the memory, the processor architecture, and whether Apple Containerization is available. None of those figures is a target to match.

## Is this file or bundle intact

Every check in this section is a command typed into Terminal. There is no window route for these three.

`lungfish-cli analyze validate <files>...` checks whether a sequence or variant file is well formed. Adding `--strict` also rejects files that are readable but irregular, such as a record whose fields disagree with the header, so use it when a file opens yet behaves oddly later. `lungfish-cli bundle validate <bundle>` checks the structure of a reference bundle.

`lungfish-cli provenance verify` checks a signed [provenance](../../GLOSSARY.md#provenance) record, and signing is off by default. On an ordinary unsigned [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) it exits 64 and reports that the signature artifact is missing, which means "not signed" rather than "not valid". To check an unsigned record, open the sidecar in any text editor, read its `exitStatus` field, and check that the output files it lists exist.

Missing index files regenerate by themselves. An index file is a small companion that lets LGE jump straight to one part of a large file rather than reading all of it. LGE rebuilds a `.fai`, a `.bai`, or a `.tbi` the first time an operation needs one. If that rebuild fails, the underlying tools are `samtools faidx`, `samtools index`, and `tabix`.

## Known defects in this release

This is the single list of faults in LGE itself that this manual keeps. Every row was checked against the build in its last column, by running the app or its bundled `lungfish-cli`, or by reading the source that build was made from. A chapter whose steps a defect blocks carries one sentence and a link back here. A defect that a later release fixes leaves this list, so a row here means the fault was present in the build named.

### Window

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| Opening a saved workflow in the Workflow Builder shows an empty canvas. | [The Workflow Builder](../08-workflows/01-the-workflow-builder.md) | The saved file is intact. Run it with `lungfish-cli workflow builder-run --workflow <file> --project <project>`, or redraw the chain. | 2026.9.40 |
| **Reassemble...** never appears on the right-click menu of an assembly result in `Analyses/`, because it is offered only on bundles and those results are folders. | [Running SPAdes](../07-assembly/02-running-spades.md) | Start a new assembly from **Tools** with the same settings, read from the result's provenance record. | 2026.9.40 |
| Every saved workflow carries version `1.0.0`, and nothing in the window raises it. | [The Workflow Builder](../08-workflows/01-the-workflow-builder.md) | Put a version in the workflow's name if you need to tell saves apart. | 2026.9.40 |
| The Plugin Manager's GATK Core card describes the pack as command construction and dry-run support, although its commands run, and estimates 600 MB, while the installed pack takes about 900 MB. | [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md), [Plugin Packs](../01-foundations/07-plugin-packs.md) | Allow about 1 GB of disk for it. | 2026.9.40 |
| Two View menu items share the shortcut Cmd-Opt-0, **Content Text Size > Default** and **All Samples** in a TaxTriage result. | [Keyboard Shortcuts](keyboard-shortcuts.md) | Choose **View > All Samples** from the menu. | 2026.9.40 |
| **Mark Duplicates** in the Inspector shows no row in the Operations Panel and does not stop another operation from changing the same bundle at the same time. | [Alignment Quality](../04-alignments/04-alignment-quality.md) | Start nothing else on that bundle until the "Duplicate Marking Complete" alert appears. | 2026.9.40 |
| In the Variants tab's Query Builder, a Region value with no sequence name, such as `1000-2000`, is ignored without a warning, so the table is not restricted at all. | [Reading the Variants Table](../05-variants/02-reading-the-variant-browser.md) | Write the region with its sequence name, as `chr20:1000-2000`. | 2026.9.40 |
| **Create Bundle** in an assembly's contig table records the assembler as `Unknown`. | [Extracting Contigs](../07-assembly/04-extracting-contigs.md) | Build the bundle with `lungfish-cli extract contigs --assembly`, which records the assembler. | 2026.9.40 |
| The CZ ID import sheet's **Project Destination** shows a folder under `Analyses`, but the result is written to the project's `Classifications` folder. | [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md) | Look for the result under `Classifications`. | 2026.9.40 |
| An imported CZ ID result's action bar counts the root row as a taxon, so two real taxa read as 3 taxa. | [Importing CZ ID Results](../06-classification/08-importing-cz-id-results.md) | Subtract one. | 2026.9.40 |
| Typing a number into the EsViritu **Coverage** column filter matches on breadth, the percent of the genome covered, although the column shows mean depth. | [Running EsViritu](../06-classification/03-running-esviritu.md) | Sort the Coverage column instead of filtering it. | 2026.9.40 |
| The EsViritu **Identity** column shows the identity fraction with a percent sign, so 0.997 appears as 1.0%. | [Running EsViritu](../06-classification/03-running-esviritu.md) | Export the table with **Export** as CSV or TSV, which writes the raw fraction, so 0.997 means 99.7 percent. | 2026.9.40 |
| On a Kraken 2 result reopened from the sidebar, the action bar's information button and **Export > Show Provenance...** do nothing. | [Running Kraken 2](../06-classification/02-running-kraken2.md) | Read the run's settings in the Inspector instead. | 2026.9.40 |
| The NAO-MGS read panels are labelled as ordered by unique read count, but they are ordered by total hits. | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | Read the order as total hits. | 2026.9.40 |
| Every TaxTriage result shows a TASS Score of 0.000, an empty Confidence bar, and a dash for Coverage, and the High Confidence card and the batch overview's Mean TASS read zero. The pinned pipeline does not write the file LGE reads the score from. | [Running TaxTriage](../06-classification/04-running-taxtriage.md) | Right-click the result folder, choose Show in Finder, and open `report/<sample>.odr.txt` in a text editor for the pipeline's own 0 to 100 score, coverage breadth, and depth. The Reads and Unique Reads columns are correct. | 2026.9.40 |
| In the TaxTriage dialog, **Add Sample** adds a row with no reads file and no way to attach one, and the run then leaves that row out without a warning. | [Running TaxTriage](../06-classification/04-running-taxtriage.md) | Select every sample's bundle, controls included, in the sidebar before you open the dialog. | 2026.9.40 |

### Runs that fail or stop

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| Some `lungfish-cli` commands stop with a message that the provenance publication artifact no longer matches, and write nothing, when their working folder or output path is under `/tmp` or `/private/tmp`. `convert`, and `import vcf --output-dir` attaching to a bundle, fail this way. Other commands run there without trouble. | [CLI Reference](cli-reference.md), [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) | Work in an ordinary folder, such as one inside Documents. Type `pwd` and press Return to see where you are. | 2026.9.40 |
| MEGAHIT 1.2.9 fails most runs on Apple Silicon Macs, with a nonzero exit and no contigs, even with the two workarounds LGE applies. Three of four test runs on the human mitochondrial reads failed. | [When to Assemble](../07-assembly/01-when-to-assemble.md), [Running SPAdes](../07-assembly/02-running-spades.md) | Run it again, or use SPAdes. A MEGAHIT run that does finish is correct. | 2026.9.40 |
| Every Medaka variant-calling run fails. A check before the run rejects any alignment whose header lacks the Nanopore platform and model, with "Medaka could not verify ONT/basecaller metadata in this BAM", and an alignment that passes then fails because LGE asks Medaka for a `variant` command the installed Medaka 2.2.2 no longer has. | [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) | None for Medaka. Use Clair3 from Terminal, as that chapter's command-line section shows. | 2026.9.40 |
| Clair3 runs started from LGE fail with messages such as `pypy3: command not found` and "Tool version not match", because LGE starts Clair3 without its own software folder on the search path, so it runs under the Mac's built-in Python. | [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md) | In Terminal, run `export PATH="$HOME/.lungfish/conda/envs/clair3/bin:$PATH"` and then `run_clair3.sh` directly, as that chapter's command-line section shows. | 2026.9.40 |
| A Kraken 2 run whose database matches none of the reads stops with `Empty Kraken2 report` and exit status 64, instead of showing a result that is 100 percent unclassified. | [Running Kraken 2](../06-classification/02-running-kraken2.md) | Read the failure as "nothing matched". Try a larger database, or check that the reads are the sample you meant. | 2026.9.40 |
| **Select Reads by Sequence** stops with `edit distance must be between 0 and 2` and writes nothing when Min Overlap times Error Rate rounds to 3 or more. | [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) | Keep Min Overlap times Error Rate below 2.5, as with the defaults of 16 and 0.15. | 2026.9.40 |
| **Primer Trimming** with Primer Source set to Literal Sequence removes a whole read when the primer sits at the start of it, instead of cutting the primer off. | [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md) | Trim primers after mapping instead, as [Primer Trimming an Alignment](../04-alignments/03-primer-trimming.md) shows. | 2026.9.40 |
| `lungfish-cli extract reads --by-db` on an imported NAO-MGS result exits 1 saying the extraction produced zero reads. | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | Use `lungfish-cli extract reads --by-classifier --tool naomgs` with the result, the sample, and an accession, as that chapter shows. | 2026.9.40 |
| **ONT Fluidigm Sample Split** and `lungfish-cli fastq ont-fluidigm-samples` finish the split, then stop with "Local provenance file descriptor must be added from a URL" and exit status 1, so the run is reported as failed. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md#reading-the-results) | On the command line the output folder is written before the error, so read it there. In the window there is no workaround. | 2026.9.40 |
| `lungfish-cli fastq scout` and `lungfish-cli fastq demultiplex` given a `.lungfishfastq` bundle stop with the same "Local provenance file descriptor must be added from a URL" message and exit status 1. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md#on-the-command-line) | Run the command from inside the `.lungfish` project folder and pass the FASTQ file inside the bundle instead. | 2026.9.40 |
| `lungfish-cli blast verify` given a gzip-compressed `--source` file reports that no matching reads were found, rather than saying compressed input is not supported. | [BLAST Verification](../06-classification/06-blast-verification.md) | Decompress the file first with `gunzip -k` and pass the plain `.fastq`. | 2026.9.40 |

### Numbers and files that are wrong or incomplete

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| Orienting reads against a reference that is one long sequence, such as a chromosome slice, orients nothing and writes an empty result with no warning. | [Read Processing](../03-reads/08-read-processing.md), [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | Orient against a reference split into short records, such as single genes, and compare the output read count with the input count. | 2026.9.40 |
| When you import a primer scheme, a spare primer whose tag follows `_LEFT` or `_RIGHT`, as in `_LEFT_alt1`, is counted as a separate amplicon. The shipped NEB VarSkip Long scheme also reports 29 amplicons where it has 25. | [Primer Scheme Bundles](primer-schemes.md#how-lge-counts-primers-and-amplicons) | Name spare primers with the tag before `_LEFT` or `_RIGHT`, as in `NAME-2_LEFT`. Read 25 for VarSkip Long. | 2026.9.40 |
| `lungfish-cli fastq orient --compress` writes plain text, not gzip. | [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | Name the output without `.gz` and compress it yourself with `gzip`. | 2026.9.40 |
| `lungfish-cli fastq interleave` rewrites every base quality of 2 as 0. The bases are untouched. | [Read Processing](../03-reads/08-read-processing.md) | Treat the lowest quality scores in the output as understated. | 2026.9.40 |
| The **Search Reverse Complement** switch in **Select Reads by Sequence** changes nothing, because the search always covers both strands. | [Subsetting and Extraction](../03-reads/06-subsetting-and-extraction.md) | None needed. Expect both strands to be searched. | 2026.9.40 |
| After a Nanopore run-folder import, the base count in `demux-manifest.json` is an estimate, one and a half times the compressed file size, and can be far too high. The FASTQ viewport may show the same estimate until the summary is refreshed. The read counts are exact. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) | Run **Tools > QC & Reporting > Refresh QC Summary** on the bundle, then read the Bases card. | 2026.9.40 |
| `lungfish-cli fastq demultiplex` can report fewer input reads than the file holds, and the missing reads appear in no output. On the Nanopore mitochondrial reads it reported 927 of 950. | [Oxford Nanopore Runs](../03-reads/07-ont-runs.md) | Take the true read count from the import summary or the FASTQ viewport, not from the demultiplex summary. | 2026.9.40 |
| `lungfish-cli bundle extract-annotations --feature-type CDS` writes the whole span of a coding feature, introns included, on the plus strand. | [Extracting and Comparing Sequences](../02-sequences/03-extracting-and-comparing.md) | Extract the feature in the window, by right-clicking it, which joins the exons in the gene's own orientation. | 2026.9.40 |
| `lungfish-cli extract reads --region` accepts only a whole sequence name. A range such as `chr20:1000-2000` is rejected with "No BAM reference names matched the requested regions". | [Reading an Alignment](../04-alignments/02-reading-an-alignment.md) | Use **Extract Reads in Selected Region...** in the window for a range. | 2026.9.40 |
| `lungfish-cli bundle info` reports `Variants: 0` for a track that `bundle create --variant` built from a compressed VCF. | [Importing Existing VCFs](../05-variants/06-importing-existing-vcfs.md) | Open the bundle in LGE once, or trust the Variants tab's row count. | 2026.9.40 |
| The SPAdes **Min Contig** setting is recorded in the result but not applied, so short contigs stay in. On the command line `--min-contig-length` and `--memory-gb` are accepted and ignored for Flye and hifiasm. | [Running SPAdes](../07-assembly/02-running-spades.md), [Running Flye or hifiasm](../07-assembly/03-running-flye-or-hifiasm.md) | Sort the contig table by length and ignore the short contigs, or filter them yourself after the run. | 2026.9.40 |
| Building a 12S reference from a FASTA whose name lines are not in the form `Common name (Scientific name)`, such as `>Homo_sapiens`, matches no metadata row. The reference is written with empty species, common name, taxid, and group columns, and the command reports success. | [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | Write name lines as `>Human (Homo sapiens)`, and check that the built reference shows species names before you match reads against it. | 2026.9.40 |
| The help text of `fastq 12s-reference-metadata` and `fastq 12s-reference-bundle` names five of the seven required metadata columns, leaving out `common_name` and `name_source`. | [12S Amplicon Metabarcoding](../06-classification/10-twelve-s-metabarcoding.md) | Build the table from the column list in that chapter. | 2026.9.40 |
| `lungfish-cli nao-mgs summary` on a file holding several samples reports only the first sample, and leaves the Organism column blank. | [Importing NAO-MGS Results](../06-classification/05-running-nao-mgs.md) | Import the file into a project and read the viewport, which counts every sample. | 2026.9.40 |
| `lungfish-cli gatk joint-genotype` with no `--gvcf` is accepted, exits 0, and plans a combine step with no input. | [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md) | Always pass one `--gvcf` per sample. | 2026.9.40 |

### Records that are wrong or missing

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| Provenance records written by many `lungfish-cli` commands, including the `gatk` commands, `import vcf`, and `fastq entropy-filter`, give the app version as `Lungfish dev (0)` instead of the release version, and some steps, such as bbduk's, record the tool version as `unknown`. `variants call` records the release correctly. | [File Formats](file-formats.md#provenance-sidecars), [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) | Take the release from `lungfish-cli --version` and tool versions from `lungfish-cli version --tools` or [Tool Versions](tool-versions.md). | 2026.9.40 |
| The LoFreq version in a provenance record is LoFreq's error message, because LoFreq rejects the `--version` flag LGE asks it with. | [Calling Variants](../05-variants/01-calling-variants-from-amplicons.md) | Take LoFreq's version from [Tool Versions](tool-versions.md). | 2026.9.40 |
| The EsViritu version in a provenance record reads `3.14`, the Python version, rather than EsViritu's own. | [Running EsViritu](../06-classification/03-running-esviritu.md) | Take EsViritu's version from [Tool Versions](tool-versions.md). | 2026.9.40 |
| A Freyja provenance record lists `freyja-demix.tsv` with no checksum or size, because the record is written from the plan before Freyja runs. | [Running Freyja](../06-classification/07-running-freyja.md) | Keep the whole output folder together, so the plan and the record stay beside the result, or record a checksum yourself with `shasum -a 256 freyja-demix.tsv`. | 2026.9.40 |
| A successful `lungfish-cli freyja demix --execute` run keeps none of Freyja's own messages in its provenance record, and a failed run writes no provenance record at all, only the plan file. | [Running Freyja](../06-classification/07-running-freyja.md) | Save the text Freyja prints in Terminal yourself. | 2026.9.40 |
| Each `lungfish-cli gatk ... --execute` into the same output folder replaces the previous run's provenance record. | [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md) | Give every GATK run its own output folder. | 2026.9.40 |
| Some `lungfish-cli gatk` options accept a misspelled value without a warning. An unknown `filter --preset` becomes `best-practices-both`, `--preset custom` builds no filter expressions, an unknown `select --type` is dropped so every variant is selected, and an unknown `--combine-strategy` becomes `auto`. | [Filtering, Selecting, and Metrics](../06-human-germline-variants/03-filtering-selecting-and-metrics.md), [Joint Genotyping](../06-human-germline-variants/02-joint-genotyping.md) | Check the recorded command in the provenance record. | 2026.9.40 |
| `lungfish-cli provenance bibliography` matches some steps to the wrong tool on a shared word. Trim Galore and `gatk-variants-to-table` print the iVar citation, and `gatk-variant-filtration` prints the Medaka citation. Many tools, including every assembler, print no citation at all. | [Tool Bibliography](bibliography.md) | Delete a citation for a tool that never ran, and take the right one from the tables in [Tool Bibliography](bibliography.md). | 2026.9.40 |
| A Nextflow export fails `nextflow lint` with "Incorrect number of call arguments, expected 3 but received 1", because the first step is handed one input where it declares three. | [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) | Have someone who knows Nextflow correct the wiring, or send the Shell Script export instead. | 2026.9.40 |
| A Snakemake export fails `snakemake --dry-run` with a CyclicGraphException, because the `samtools flagstat` step lists the same BAM as its input and its output. | [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) | Delete that output from the rule by hand, or send the Shell Script export instead. | 2026.9.40 |
| When two recorded steps name the same file, the exports write its parameter twice, and in `reproduce.py` the second copy replaces the first without a warning. | [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) | Delete the duplicate line. | 2026.9.40 |

### Command-line options that are ignored or refused

| Symptom | Affects | Workaround | Verified build |
|---|---|---|---|
| `lungfish-cli conda install --pack` with an experimental pack, `gatk-core`, `phasing`, or `wastewater-surveillance`, stops with "Unknown tool pack" and exit status 3. The list of ids the error prints leaves out every experimental pack. | [Plugin Packs](../01-foundations/07-plugin-packs.md#experimental-packs-and-features), [Reference Files for GATK](../06-human-germline-variants/04-reference-packs.md), [Running Freyja](../06-classification/07-running-freyja.md) | Turn experimental features on and install the pack from the Plugin Manager, **Tools > Plugin Manager...** (Cmd-Shift-B). | 2026.9.40 |
| `lungfish-cli bundle export --format container` is rejected, because the program-wide `--format` option takes the value first, and without it the command reports the format missing. | [File Formats](file-formats.md) | Copy or zip the bundle folder by hand to move it. | 2026.9.40 |
| `--format json` is accepted and ignored by `conda packs`, `ops stats`, `workflow list`, `conda offline-export`, and `version`, which print ordinary text. `workflow diff` and `blast verify` print text for `--format json` and `--format tsv` alike, and `project migrate --format tsv` prints text. | [Running in CI](06-running-in-ci.md), [BLAST Verification](../06-classification/06-blast-verification.md) | Read the text output, or read the field you need from the provenance sidecar, which is JSON. | 2026.9.40 |
| `lungfish-cli assemble --assembler megahit --profile default` passes `--presets default` to MEGAHIT, which is not one of its presets. | [Running SPAdes](../07-assembly/02-running-spades.md) | Leave `--profile` off for MEGAHIT. | 2026.9.40 |
| A command with its own `--threads` option ignores the value you give, because the program-wide `--threads` option takes it first, so the command runs with its default thread count. `variants phase --threads 4` plans GATK with one thread, and `fastq entropy-filter --threads 2` runs with four. `fastq demultiplex`, `fastq pbaa-cluster`, `fastq savont-cluster`, `fastq ont-fluidigm-samples`, `fastq ont-pacbio-barcode-demux`, and `workflow builder-run` declare the option the same way. | [HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md), [CLI Reference](cli-reference.md) | None from the command line. The result is otherwise correct. | 2026.9.40 |
| `lungfish-cli workflow run` recognises a Nextflow file only by a lower-case `.nf` extension, so `pipeline.NF` is not run as Nextflow, while `workflow validate` accepts it. | [Running External Workflows](../08-workflows/03-running-external-workflows.md) | Name pipeline files in lower case. | 2026.9.40 |
| `lungfish-cli debug env --check-tools` prints Nextflow's complaint about a flag as Nextflow's version. | [Running in CI](06-running-in-ci.md) | Treat the row as proof that Nextflow is present, and run `nextflow -version` for the number. | 2026.9.40 |
| `lungfish-cli project migrate` prints summary counts that do not add up, because unreadable bundles are counted as unsupported and bundles with a migration available are counted nowhere. | [Shared Projects and Bundle Migration](shared-projects.md) | Trust the per-bundle lines, not the counts. | 2026.9.40 |
| The example lines in many `--help` screens spell the program `lungfish` rather than `lungfish-cli`, and `translate --help` shows examples with `--all-frames` and `--stop-as-asterisk`, which that command does not accept. | [CLI Reference](cli-reference.md) | Type `lungfish-cli`, and use the flags in the OPTIONS list of the help screen. | 2026.9.40 |

## Reporting something this appendix does not cover

Gather the failure report first, with **Copy Failure Report** on the failed row's right-click menu, since it already holds the command, the message, and the log. Then add the app version, which **Lungfish Genome Explorer > About Lungfish Genome Explorer** shows and `lungfish-cli version` prints, and the macOS version from the Apple menu's **About This Mac**. The installed tool versions from `lungfish-cli version --tools` help but are optional.

The fastest route is **Open GitHub Issue** on the failed row's right-click menu, which opens a pre-filled issue in your browser. You review it and submit it yourself, so nothing is filed without your action. Submitting needs a free GitHub account. Without one, use **Help > Report an Issue...**, which opens the same template carrying the version string, and send it to whoever supports LGE where you work.

Leave your project's data files out of the report. The failure report holds LGE's own log and the command it ran rather than your sequences, so it is safe to send as it stands, and sequence data is rarely yours alone to share.

## Next

See [CLI Reference](cli-reference.md) for the syntax of any command named here, [Running in CI](06-running-in-ci.md) for exit statuses and checks in an unattended script, or [File Formats](file-formats.md) for what each LGE bundle contains.
