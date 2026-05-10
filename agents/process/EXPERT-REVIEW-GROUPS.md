# Expert Review Groups — Cross-Cutting Evaluation Specifications

## Overview

Expert Review Groups are assembled by the Project Lead Agent to evaluate completed implementations from specialized perspectives that cut across both the Development and GUI teams. Each group is activated when relevant to the feature being reviewed.

---

## 1. Performance & Scalability Group

**When activated**: Any feature that handles files, processes data, or renders large datasets.

**Evaluation criteria:**
- **Memory footprint**: Does memory usage scale linearly with input size? Are there unbounded buffers?
- **Streaming vs. loading**: Are large files streamed or loaded entirely into memory?
- **Index usage**: Are database queries using indexes? Are there full table scans?
- **Render performance**: Does the sequence viewer maintain 60fps during scroll at all zoom levels?
- **Startup impact**: Does the new feature add to app launch time?
- **Lazy loading**: Are expensive computations deferred until actually needed?
- **Cache effectiveness**: Are caches bounded? Do they evict correctly?
- **Async I/O**: Are file operations off the main thread? Are network requests non-blocking?
- **Large dataset benchmarks**: Test with real-world large inputs (multi-GB VCFs, whole genomes, millions of annotations)
- **Thread contention**: Are there lock contentions or actor bottlenecks under load?

**Deliverable**: Performance report with measurements, flame graphs where applicable, and specific optimization recommendations.

---

## 2. Data Integrity & Provenance Group

**When activated**: Any feature that transforms, imports, exports, or stores scientific data.

**Evaluation criteria:**
- **Round-trip fidelity**: Does importing then exporting produce identical data? Are there precision losses?
- **Coordinate systems**: Are 0-based and 1-based coordinates handled correctly and consistently?
- **Chromosome aliasing**: Does "chr1" match "1" match "NC_000001.11" correctly?
- **Strand handling**: Are strand-specific operations (complement, translation) correct?
- **Provenance completeness**: Does the provenance record include all parameters, tool versions, and input checksums?
- **Provenance accuracy**: Does the provenance record match what was actually executed?
- **Bundle provenance**: Do CLI and GUI paths write provenance into final output bundles/directories, with records pointing at the stored payloads rather than temporary staging files?
- **Data loss detection**: Can the user tell if data was lost or truncated during import?
- **Format compliance**: Do exported files pass format validators (VCF spec, BAM spec, etc.)?
- **Idempotency**: Running the same operation twice produces the same result?
- **Atomicity**: If an operation fails mid-way, is partial output cleaned up?

**Deliverable**: Data integrity report with test cases showing input/output comparisons and provenance audit.

---

## 3. Security & Input Validation Group

**When activated**: Any feature that accepts user input, reads files, or makes network requests.

**Evaluation criteria:**
- **File parsing safety**: Are there buffer overruns, integer overflows, or unchecked allocations when parsing malformed files?
- **Path traversal**: Can file paths escape the sandbox? Are symlinks followed unsafely?
- **Injection**: Can tool parameters contain shell metacharacters that get executed?
- **Network safety**: Are HTTPS certificates validated? Are API responses validated before use?
- **Resource limits**: Can a crafted input cause OOM, infinite loops, or disk exhaustion?
- **Sandboxing**: Does the app request only necessary entitlements?
- **Credential handling**: Are API keys stored securely (Keychain, not UserDefaults)?
- **Temp file cleanup**: Are temporary files created securely and cleaned up on failure?
- **Input bounds**: Are array indices, string lengths, and numeric ranges validated at system boundaries?
- **Denial of service**: Can a user operation block the main thread indefinitely?

**Deliverable**: Security findings document with severity ratings, reproduction steps, and remediation priority.

---

## 4. Error Handling & Recovery Group

**When activated**: Any feature with failure modes (file I/O, network, tool execution, user input).

**Evaluation criteria:**
- **Error specificity**: Do error messages tell the user what went wrong AND what to do about it?
- **Error hierarchy**: Are errors typed enums with associated values, not string messages?
- **Recovery paths**: After an error, can the user retry without restarting the app?
- **Partial failure**: If a batch operation fails on item 5 of 10, what happens to items 1-4 and 6-10?
- **Cascading failures**: Does one failed operation poison the state for subsequent operations?
- **User-facing vs. developer messages**: Are raw error strings (file paths, stack traces) hidden from users?
- **Offline behavior**: What happens when NCBI/network is unreachable?
- **Permission errors**: What happens when file permissions prevent reading/writing?
- **Disk full**: What happens when the disk is full during a write operation?
- **Cancellation cleanup**: Does cancelling mid-operation leave files/state in a clean condition?

**Deliverable**: Error handling matrix listing each failure mode, the current behavior, and whether it meets the "actionable error message" standard.

---

## 5. Documentation & Onboarding Group

**When activated**: Any user-visible feature or API change.

**Evaluation criteria:**
- **In-app help**: Does the Help panel cover this feature? Is the description accurate?
- **Tooltips**: Do all buttons, controls, and status indicators have explanatory tooltips?
- **Inline guidance**: For complex operations, is there progressive disclosure or step-by-step guidance?
- **CLI help text**: Does `lungfish <command> --help` explain all parameters clearly?
- **Error messages as documentation**: Do error messages teach the user what went wrong?
- **API documentation**: Do public types and methods have doc comments?
- **Changelog**: Is the feature described in a format suitable for release notes?
- **Search discoverability**: Can the user find this feature through the universal search?
- **First-run experience**: If a new user encounters this feature first, will they understand it?
- **Migration guidance**: If this replaces an old workflow, is the transition path clear?

**Deliverable**: Documentation audit listing gaps, inaccuracies, and proposed content for each finding.

---

## 6. Bioinformatics Correctness Group (Adversarial Science Review)

**When activated**: Any feature that implements a bioinformatics algorithm, calls an external tool, or displays scientific data. This group operates like a hostile grant study section and a skeptical Reviewer #2 — they look for every scientific weakness.

**Adversarial Bioinformatician perspective** (the reviewer who has used every competing tool):
- **Algorithm correctness**: Does the implementation match published algorithms and tool documentation? Are there silent deviations in rounding, tie-breaking, or edge handling?
- **Parameter defaults**: Are defaults defensible in a methods section? Compare against samtools, bcftools, IGV, BWA, SPAdes, Kraken2, BLAST+ defaults
- **Comparison testing**: Run identical input through Lungfish AND the reference command-line tool — results MUST match or deviations MUST be justified
- **Format compliance**: Does output strictly conform to specs (VCF 4.3, GFF3, SAM spec, FASTQ Phred encoding)? Would it pass a format validator?
- **Coordinate systems**: 0-based half-open vs. 1-based inclusive — is usage consistent and documented throughout?
- **Reproducibility**: Same input + same parameters = bit-identical output? If stochastic, is the seed documented?
- **Version sensitivity**: Does output change across reference genome builds? Is this warned about?
- **Statistical validity**: Are quality scores, p-values, or confidence intervals computed correctly? Are multiple testing corrections applied where needed?

**Adversarial Biologist perspective** (the bench scientist who asks "so what?" and "could this mislead my experiment?"):
- **Biological plausibility**: Does the result make biological sense? A 50Mb "gene", a 99.9% identity BLAST hit with e-value 0.1, or a negative read count should all trigger alarms
- **Clinical/lab impact**: Could misinterpretation lead to a wrong experiment, wrong primer order, or wrong diagnostic call?
- **Naming and labeling**: Standard nomenclature used? (HUGO gene names, NCBI taxonomy, IUPAC bases)
- **Units and scales**: Quality scores in expected range? Coordinates in right units? Percentages that actually sum correctly?
- **Missing data handling**: Is "no data" distinguishable from "zero"? Are absent annotations shown differently from empty annotations?
- **Confidence communication**: Does the display convey uncertainty appropriately? (e.g., low-confidence BLAST hits should not look identical to high-confidence ones)
- **Taxonomy accuracy**: Species names current? Deprecated taxids handled? Strain vs. species confusion avoided?
- **Literature alignment**: Would results be consistent with published data for well-characterized organisms?

**Deliverable**: Scientific review document structured like a manuscript review:
- **Major Concerns** (block merge) — scientific errors that could produce wrong results
- **Minor Concerns** (fix before release) — defensible but suboptimal choices
- **Suggestions** (improvements for future) — nice-to-have enhancements

Each concern includes the biological or bioinformatics rationale and, where applicable, comparison data against reference tools.

---

## Group Assembly Quick Reference

| Feature Type | Groups to Activate |
|---|---|
| File import/export | Data Integrity, Security, Performance, Error Handling, Bioinformatics Correctness |
| New bioinformatics tool | Bioinformatics Correctness (both personas), Data Integrity, Performance, Error Handling, Documentation |
| Scientific data visualization | Bioinformatics Correctness (both personas), Documentation, Performance |
| GUI operation panel | Error Handling, Documentation, Performance |
| Database/indexing change | Performance, Data Integrity, Security |
| Network/API feature | Security, Error Handling, Performance |
| Architecture refactor | Performance, Security, Error Handling |
| New user-facing feature | Documentation, Error Handling, all relevant domain groups |
