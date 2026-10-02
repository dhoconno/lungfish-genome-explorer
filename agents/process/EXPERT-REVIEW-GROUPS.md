# Expert Review Groups

## Overview

The Project Lead Agent assembles Expert Review Groups to evaluate finished work from perspectives that cut across the Development and GUI teams for Lungfish Genome Explorer (LGE). Each group is activated when it is relevant to the feature under review. Reviewers take code facts from `AGENTS.md`, the module guides and the contracts in `docs/contracts`, and cite them in their findings.

## 1. Performance & Scalability Group

This group is activated for any feature that handles files, processes data or renders large datasets.

| Criterion | Question |
|---|---|
| Memory | Does memory grow linearly with input, and are buffers bounded? |
| Streaming | Are large files streamed with pull-based readers rather than loaded whole? |
| Indexes | Do database queries use indexes rather than full scans? |
| Rendering | Does the viewer stay responsive while scrolling at every zoom level? |
| Startup | Does the feature add to launch time? |
| Laziness and caches | Is expensive work deferred until needed, and are caches bounded with correct eviction? |
| Async I/O | Are file and network operations off the main thread? |
| Real inputs | Was it measured on real large inputs, such as multi-gigabyte VCFs, whole genomes and millions of annotations? |
| Contention | Are there lock or actor bottlenecks under load? |

The deliverable is a performance report with measurements, profiles where useful and specific recommendations.

## 2. Data Integrity & Provenance Group

This group is activated for any feature that transforms, imports, exports or stores scientific data. It protects the domain invariants in `docs/architecture/ARCHITECTURE.md`.

| Criterion | Question |
|---|---|
| Round trip | Does import then export give identical data, without precision loss? |
| Coordinates | Are 0-based and 1-based coordinates handled consistently? |
| Names | Do chromosome aliases (chr1, 1 and NC_000001.11) match correctly, and is a requested accession ever swapped for an equivalent one without telling the user? |
| Strand | Are strand-specific operations such as complement and translation correct? |
| Provenance | Does the envelope record every parameter, resolved default, tool version and input checksum, and does it match what actually ran? |
| Bundle provenance | Do CLI and GUI paths write provenance into the final bundle or output directory, pointing at stored payloads rather than staging files? |
| Data loss | Can the user tell when data was dropped or truncated, and does a silent zero ever stand in for a failure? |
| Format compliance | Do exported files pass the format's validator? |
| Idempotency and atomicity | Does a rerun give the same result, and does a failed run clean up its partial output? |

The deliverable is a data integrity report with input and output comparisons and a provenance audit.

## 3. Security & Input Validation Group

This group is activated for any feature that accepts user input, reads files or makes network requests.

| Criterion | Question |
|---|---|
| Parsing safety | Can malformed files cause overruns, overflows or unchecked allocations? |
| Paths | Can a path escape its intended directory, or a symlink be followed unsafely? |
| Injection | Can a parameter carry shell metacharacters that get executed? Arguments reach a process as an argv array, never through a shell string |
| Network | Are certificates validated, and are responses validated before use? |
| Resources | Can deliberately malformed input cause runaway memory use, an endless loop or a full disk? |
| Entitlements | Does the app request only the entitlements it needs? |
| Credentials | Are API keys in the Keychain, never in user defaults or logs? |
| Temporary files | Are temporary files created safely and removed on failure? |
| Main thread | Can a user action block the main thread indefinitely? |

The deliverable is a security findings document with severity, reproduction steps and remediation priority.

## 4. Error Handling & Recovery Group

This group is activated for any feature that can fail in file I/O, network, tool execution or user input.

| Criterion | Question |
|---|---|
| Specificity | Does each message say what went wrong and what to do about it? |
| Typing | Are errors typed enums with associated values rather than strings? |
| Recovery | Can the user retry without restarting the app? |
| Partial failure | If item 5 of 10 in a batch fails, what happens to the others, and does the batch report it? |
| Cascades | Does one failure poison later operations? |
| Audience | Are raw paths and stack traces kept out of user-facing messages and kept in the failure report? |
| Offline, permissions and disk | What happens when the network is down, a file is unreadable or the disk fills during a write? |
| Cancellation | Does cancelling leave files and state clean? |

The deliverable is an error handling matrix of failure modes, current behavior, and whether each meets the actionable-message standard.

## 5. Documentation & Onboarding Group

This group is activated for any user-visible feature or API change.

| Criterion | Question |
|---|---|
| Manual | Does the user manual cover the feature accurately, and does `docs/user-manual/features.yaml` list it with its menu path and sources? |
| In-app help | Do controls and status indicators have tooltips, and do complex operations explain themselves? |
| CLI help | Does `lungfish-cli <command> --help` explain every option? |
| Errors as guidance | Do error messages teach the user what went wrong? |
| API docs | Do public types and methods have doc comments? |
| Release notes | Is the change described in a form ready for the release notes? |
| Discovery | Can the user find the feature through search and menus, and will a first-time user understand it? |

The deliverable is a documentation audit listing gaps, inaccuracies and proposed text. Documentation follows the prose rules in `docs/user-manual/STYLE.md`.

## 6. Bioinformatics Correctness Group (Adversarial Science Review)

This group is activated for any feature that implements a bioinformatics algorithm, calls an external tool or displays scientific data. It works like a hostile study section and a skeptical second reviewer, looking for every scientific weakness. The Bioinformatics Architect (`agents/specialists/05-bioinformatics-architect.md`) chairs it.

### Adversarial bioinformatician

This reviewer has used every competing tool.

| Criterion | Question |
|---|---|
| Algorithm fidelity | Does the implementation match the published method, including rounding, tie-breaking and edge handling? |
| Defaults | Would each default stand up in a methods section, compared with samtools, bcftools, IGV, BWA, SPAdes, Kraken2 and BLAST+? |
| Comparison | Does the same input through LGE and through the reference tool give the same result, or is the difference justified? |
| Format compliance | Does output meet VCF 4.3, GFF3, the SAM specification and FASTQ Phred encoding? |
| Coordinates | Is 0-based half-open or 1-based inclusive used consistently and documented? |
| Reproducibility | Does the same input give bit-identical output, and is any random seed recorded? |
| Build sensitivity | Does output change across reference builds, and is the user warned? |
| Statistics | Are scores, p-values and intervals computed correctly, with multiple-testing correction where needed? |

### Adversarial biologist

This reviewer is the bench scientist who asks what a result means for the next experiment.

| Criterion | Question |
|---|---|
| Plausibility | Does the result make biological sense? A 50 Mb gene, a 99.9 percent identity hit with an e-value of 0.1 or a negative read count must raise an alarm |
| Lab impact | Could a misreading lead to a wrong experiment, primer order or diagnostic call? |
| Nomenclature | Are HGNC gene names, NCBI taxonomy and IUPAC bases used, and are deprecated taxids handled? |
| Units | Are quality scores, coordinates and percentages in the expected range and units? |
| Missing data | Is no data distinguishable from zero, and an absent annotation from an empty one? |
| Confidence | Does the display show uncertainty, so a weak hit never looks like a strong one? |
| Literature | Would the result agree with published data for well-characterized organisms? |

The deliverable reads like a manuscript review. Major concerns block the merge, minor concerns are fixed before release, and suggestions wait for later work. Each concern gives its biological or bioinformatics reasoning and, where possible, comparison data from the reference tool.

## Group assembly

| Feature type | Groups to activate |
|---|---|
| File import or export | Data Integrity & Provenance, Security & Input Validation, Performance & Scalability, Error Handling & Recovery and Bioinformatics Correctness |
| New bioinformatics tool | Bioinformatics Correctness with both personas, Data Integrity & Provenance, Performance & Scalability, Error Handling & Recovery and Documentation & Onboarding |
| Scientific data visualization | Bioinformatics Correctness with both personas, Documentation & Onboarding and Performance & Scalability |
| GUI operation panel | Error Handling & Recovery, Documentation & Onboarding and Performance & Scalability |
| Database or indexing change | Performance & Scalability, Data Integrity & Provenance and Security & Input Validation |
| Network or API feature | Security & Input Validation, Error Handling & Recovery and Performance & Scalability |
| Architecture refactor | Performance & Scalability, Security & Input Validation and Error Handling & Recovery, plus a golden-output comparison from the Testing & QA Lead |
| New user-facing feature | Documentation & Onboarding, Error Handling & Recovery and every relevant domain group |
