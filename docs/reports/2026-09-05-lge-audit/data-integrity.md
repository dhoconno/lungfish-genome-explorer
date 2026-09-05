# Data integrity, provenance, and scientific computation audit

Assessment date: 2026-09-05. Baseline: `13e114087b1c0a994ad1d957ce7d71b963e5575d`. This is a software correctness review; it does not validate biological interpretation or individual analytical pipelines. All execution probes used tiny invented records or synthetic provenance fixtures. Production code, tests and configuration were not edited.

## Assessment

LGE has a serious provenance implementation, including full-file SHA-256 hashing, runtime identities, explicit/default/resolved options, signed sidecars, publication snapshots, consumed-input snapshots, relocated-output validation, and GUI rehydration with integrity checks. These are valuable foundations. The central problem is inconsistent adoption at the final caller boundary: having a correct writer does not guarantee that a workflow publishes its payload and provenance together or records the bytes it actually consumed.

The supplied provenance requirement makes missing provenance a blocking defect. Prioritize DATA-01 through DATA-04 before adding scientific export features. DATA-05 and DATA-06 affect the promise that provenance is reproducible. DATA-07 and DATA-08 show why small independent computational oracles matter even in a heavily tested codebase.

Evidence categories: **reproduced** means a current incrementally built CLI was exercised; **source-confirmed** means the complete relevant caller/helper chain was inspected; **risk** means the behavior still needs a runtime or fault-injection experiment. P1 is high-impact correctness/data-loss or an explicit provenance-contract blocker; P2 is a bounded defect or material assurance gap. No P0 emergency was established.

## Findings

### DATA-01 — P1 — GFF3 GUI export omits provenance entirely

**Source-confirmed.** File > Export > Annotations reaches `exportGFF3`, then `beginGFF3Export` in [AppDelegate+ImportCenter.swift](../../../Sources/LungfishApp/App/AppDelegate+ImportCenter.swift#L3044). Both the open-document and sidebar-reference paths eventually call `GFF3Writer.write` directly at line 3107 and immediately show success. The helper receives annotations and a suggested filename, but no source identity or snapshot. [GFF3Reader.swift](../../../Sources/LungfishIO/Formats/GFF/GFF3Reader.swift#L611) shows the static writer only writes GFF3 bytes and closes the handle. It cannot add workflow provenance through another layer: LungfishIO does not depend on LungfishWorkflow.

**Impact:** an apparently successful scientific export has no command, options, checksummed inputs or output sidecar. This violates the explicit project requirement; it is not merely an optional metadata improvement. CLI conversion has provenance, so GUI and CLI differ.

**Remediation:** route the GUI action through a provenance-aware export service accepting a source/snapshot identity, selected annotation identities, format and final destination. Stage payload and provenance together; preserve existing destination files on failure. Include unsaved annotation state in a durable input snapshot rather than attributing edited rows to unchanged disk bytes.

**Acceptance:** export from both supported GUI entry paths; verify final payload path, digest, size, app/tool version, exact replay input and resolved options. Force sidecar publication failure and confirm no success message and no lost previous export. Export edited annotations and replay against the recorded snapshot.

### DATA-02 — P1 — `convert --force` destroys the previous output before publication is guaranteed

**Reproduced.** [ConvertCommand.swift](../../../Sources/LungfishCLI/Commands/ConvertCommand.swift#L148) removes the old output at lines 152–153, writes new bytes, and only at lines 204–250 computes inputs and publishes provenance. There is no enclosing payload backup/restore. [CLIProvenanceSupport.swift](../../../Sources/LungfishCLI/Support/CLIProvenanceSupport.swift#L214) writes directory provenance and focused sidecars sequentially; it does not roll back the caller's payload.

**Probe:** create `input.fa`, an existing `out.fa` containing `OLD OUTPUT`, and a nonempty directory named `.lungfish-provenance.json` next to them. Invoke `convert input.fa --to out.fa --to-format fasta --force --quiet`. Exit status is 1 with “existing destination is not a regular file”; `out.fa` nevertheless contains the new FASTA and the original bytes are gone. Full argv/output is preserved in [cli-probes.json](evidence/cli-probes.json).

**Impact:** failed operations mutate scientific data and leave new data without the required sidecar. Validation-before-deletion already protects invalid format errors, but does not protect errors after payload writing.

**Remediation:** one transaction must own input snapshot, staged payload, all sidecars and replacement. Keep old payload/sidecars until the new set is installed; retain recovery artifacts if restoration itself fails. Reuse audited publication primitives, avoiding another independent transaction framework.

**Acceptance:** inject writer failure, root-sidecar obstruction, focused-sidecar obstruction, cancellation, and replacement failure. Existing bytes and provenance must remain consistent; a new destination must not appear complete after failure. Test successful replacement once as a normal control.

### DATA-03 — P1 — In-place conversion attributes the new bytes to the original input

**Reproduced.** The same caller computes `provenanceInputFiles` after output writing at [ConvertCommand.swift:204](../../../Sources/LungfishCLI/Commands/ConvertCommand.swift#L204). Input/output path equality is permitted with `--force`. `CLIProvenanceSupport.appendInputRecord` also reopens local URLs when adding them to the builder rather than treating all caller file records as consumed snapshots.

**Probe:** convert a lowercase FASTA to itself. The original checksum was `48b26bb1b081d74658d4d112cdf572ebdfdf6f6ec62bb7b38e5373ff2de198b9`; output normalization changed it to `0ced0c610892c2528c5ec78ab57e7a19982c155d1400ee76b8ce84c5cbe12bd5`. Both input and output descriptors record the latter. Exit status is 0.

**Impact:** provenance makes a false statement about the consumed input. Other mutable-input callers deserve inspection, but this report does not claim that they all fail.

**Remediation:** either explicitly disallow aliasing input/output, including symlinks and hard links, or support it with a pre-mutation consumed-input snapshot and transactional replacement. For reproducible in-place work, a checksum alone is insufficient after the old bytes disappear: retain a durable input revision or give the user a clear replay limitation.

**Acceptance:** exact-path, symlink and hard-link aliases; normalization-changing input; source changed between read and publication. The recorded checksum must represent consumed bytes and replay inputs must resolve to a retained version.

### DATA-04 — P1 — Several GUI exports still use destructive post-write provenance

**Source-confirmed; failure scenario not executed in AppKit.** [ScientificFileExportProvenance.swift:48](../../../Sources/LungfishWorkflow/Provenance/ScientificFileExportProvenance.swift#L48) builds a sidecar after the caller has written its payload; on sidecar writer failure it removes the output at line 64. It has no previous-output backup. Descriptor/envelope construction before the `do` can also fail without this cleanup. The stronger `writeAtomically` API exists at line 70 and has behavioral tests, but multiple production callers still use `write`.

A particularly clear caller is [AnnotationTableDrawerView+Bookmarks.swift:170](../../../Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Bookmarks.swift#L170): it atomically replaces a TSV, then writes provenance, and its catch removes the destination and only logs the error at lines 191–193. File-level atomic writing does not preserve the original version across a later sidecar failure. Compressed reference sequence export also writes/compresses the destination before calling this helper ([AppDelegate+ImportCenter.swift:2819](../../../Sources/LungfishApp/App/AppDelegate+ImportCenter.swift#L2819)).

**Remediation:** move user-facing replacements to a transaction-owning export API. Audit the seven `ScientificFileExportProvenance.write` production call sites; distinguish safe newly staged files from replaceable user destinations before changing them. Add a visible actionable error to bookmark export. Do not remove an existing destination in catch unless the transaction positively owns that version.

**Acceptance:** replacing a known TSV while provenance publication fails preserves old TSV/sidecar bytes and surfaces an error. New-file failure leaves no successful-looking artifact. Avoid testing only the shared helper: invoke the caller's export service too.

### DATA-05 — P2 — Reproducibility export ignores durable replay argv

**Reproduced with an isolated canonical provenance fixture.** The fixture records historical argv `printf historical-execution` and durable replay argv `printf durable-replay`. `provenance export --format shell` emits the historical form. [ProvenanceExporter.swift:225](../../../Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift#L225) sends envelopes with steps through `legacyWorkflowRun`; [ProvenanceRecord.swift:506](../../../Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift#L506) preserves historical command separately from durable argv; [ProvenanceExporter.swift:905](../../../Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift#L905) chooses `step.command`. The no-step branch chooses `envelope.argv` as well. The exporter contains no reference to `durableReplayArgv`.

**Impact:** a retained replay path can be correct in the JSON while an exported script still depends on historical staging paths. GUI rehydration deliberately maintains both identities, so discarding the distinction defeats work already done elsewhere.

**Remediation:** introduce one explicit replay-command selection rule used by shell, Python and workflow-language exporters: prefer supported durable replay argv; fall back only when history is itself replayable. Preserve historical argv in the audit record. Do not merely overwrite historical commands to make tests pass. Qualify generated scripts when inputs, environments or commands cannot be reconstructed.

**Acceptance:** use different original/durable paths, remove staging, export and execute a harmless file-copy replay in a new directory, and compare output hashes. Verify all advertised export formats against the same command-selection contract. Include commands with spaces, quote characters and dollar signs; generated code must treat metadata and paths as data.

**Additional source risk:** shell `INPUT_n` assignments interpolate filenames inside double quotes without shell escaping ([ProvenanceExporter.swift:865](../../../Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift#L865)). A filename containing shell expansions may be interpreted when a recipient runs the generated script. No adversarial script was executed in this audit. Fold generated-code escaping checks into this repair, not a separate exporter rewrite.

### DATA-06 — P2 — Bookmark export records a descriptive action as an executable command

**Source-confirmed.** [AnnotationTableDrawerView+Bookmarks.swift:207](../../../Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Bookmarks.swift#L207) generates `['Lungfish Genome Explorer', 'export-bookmarked-variants', ...]`. No corresponding CLI command exists in the inspected command registrations. The scientific export helper stores this as both historical and durable argv. That records user intent but does not provide the reproducible shell command required by the project.

The collected bookmark rows precede the save-panel callback, while input database hashes are computed later; changed bookmarks or database contents during the panel's lifetime can also make the selected rows and recorded source version diverge. This timing risk was not executed.

**Remediation:** provide a supported headless export over a durable selection/input snapshot, or record a clearly non-executable GUI action plus explicit replay capability and retained selection data. Meet the scientific provenance requirement through a real reproducible path, not an invented executable name. Reuse the export service from DATA-04.

**Acceptance:** move the source bundle, change later bookmarks, and replay the earlier export from its snapshot. The same rows and bytes must result. The UI must distinguish an audit trail from an executable replay when historical data cannot be restored.

### DATA-07 — P2 — Nx thresholds round down and can overstate N50/N90

**CLI reproduced; other sites source-confirmed.** [AnalyzeCommand.swift:175](../../../Sources/LungfishCLI/Commands/AnalyzeCommand.swift#L175) stops at `totalLength / 2`. Three records of lengths 3, 2, 2 produce N50=3 even though the length-3 record covers only 3/7 of all bases. The expected N50 is 2. The same floor exists in [FASTQStatisticsCollector.swift:291](../../../Sources/LungfishIO/Formats/FASTQ/FASTQStatisticsCollector.swift#L291), [ExactBarcodeDemux.swift:413](../../../Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift#L413), and [AssemblyStatistics.swift:180](../../../Sources/LungfishIO/Assembly/AssemblyStatistics.swift#L180), which truncates a floating-point percentage for general Nx. The materializer-specific statistics should be checked when consolidating, not assumed correct by similarity.

This follows the ordinary definition: at least the requested percentage of bases must be included. See the original definition in [Lander et al., 2001](https://www.ncbi.nlm.nih.gov/IEB/Research/Acembly/Articles/2001Lander.pdf).

**Remediation:** use a small shared, overflow-safe integer threshold implementation with explicitly defined zero-input behavior. Aggregate read histograms without expanding all reads. Do not duplicate separate fixes in every view/CLI pipeline.

**Acceptance:** lengths `[3,2,2]` give N50=2; a non-integral 90% boundary, exact boundary, singleton and empty set have independently calculated expected results; large Int64 totals do not overflow or lose precision. GUI bundle statistics and CLI output agree.

### DATA-08 — P2 — Composition invents adjacency between independent records; stats flags do nothing

**Composition reproduced; flags source-confirmed.** [CompositionCommand.swift:131](../../../Sources/LungfishCLI/Commands/CompositionCommand.swift#L131) concatenates every sequence before positional composition. Lines 278–314 then compute triplets and adjacent pairs over that concatenation. Separate records `AA` and `CC` produce the pair `AC` and triplet `AAC`, neither of which occurs inside either record. Base counts remain valid; positional frequencies do not.

[AnalyzeCommand.swift:58](../../../Sources/LungfishCLI/Commands/AnalyzeCommand.swift#L58) declares `calculateGCContent`, and line 64 declares `lengthDistribution`; neither is read elsewhere in the file. Help also advertises N90 although the result type has no N90. These are concrete examples of a feature surface outgrowing its implementation.

**Remediation:** compute positional statistics per record and aggregate counts with per-record frame reset. Define how partial terminal triplets and ambiguous symbols affect denominators. Wire documented flags to behavior or remove them from the advertised surface; decide whether N90 belongs in the stats result. Stream records for base counts and histograms instead of constructing sequences plus an extra concatenated copy.

**Acceptance:** independent `AA`/`CC` yields only `AA` and `CC` adjacent pairs and no full triplets; splitting/merging records changes only statistics whose meaning depends on boundaries. Help and JSON/text output match actual flag behavior. The plan intentionally uses nonbiological toy strings and does not prescribe domain-specific analytical settings.

## Provenance coverage and assurance

| Surface | Inspected evidence | Conclusion |
|---|---|---|
| Canonical builder | Validates successful outputs, file descriptor completeness, runtime and argv; consumed/relocated snapshot APIs | Strong reusable foundation; direct envelope construction can bypass builder guarantees |
| Hasher | Full streaming SHA-256 and directory manifest | Full-file hashes are a strength; verify I/O costs on real-scale files before adding repeat passes |
| CLI helper | Recomputes local records; serial root/focused sidecar publication | Caller must own source snapshots and whole-operation transaction |
| Generic GUI attachment import | Rehydrator checks source/final integrity, rejects scientific attachment without provenance | Positive guardrail; migration/recovery behavior still merits fault injection |
| GUI import rehydration | Historical paths and durable replay paths retained separately | Valuable distinction; exporter currently ignores it |
| GFF3 GUI export | Complete direct write/success chain | Blocking omission |
| Generic GUI export | Strong atomic API plus older post-write API | Adoption is inconsistent |
| CLI conversion | Success coverage plus fresh probes | Failed overwrite and aliased input remain unsafe |
| Statistical summaries | CLI, FASTQ histogram, assembly Nx, composition | Small boundary oracles missing despite broad tests |
| External tool-specific pipelines | Shared provenance infrastructure inspected, no exhaustive tool execution | No certification of every pipeline's numerical output or provenance coverage |
| Signature verification | CLI explicitly says “Verify a signed ... sidecar” and prints “Signature valid” | Do not confuse sidecar authenticity with payload integrity or scientific validity; current wording correctly limits the claim |

## Validation performed

`swift build --product lungfish-cli` passed incrementally in 5.54 seconds. `swift test --filter 'ProvenanceFileHasherTests|ProvenanceBuilderTests|ScientificFileExportProvenanceTests|ScientificCLIProvenanceCoverageTests'` built incrementally in 7.97 seconds and passed 32 XCTest cases plus 41 Swift Testing cases. Logs: [CLI build](evidence/cli-build.log), [selected tests](evidence/provenance-tests.log). An earlier `--skip-build` smoke was used only as orientation; the reported results above come from the fresh build-aware command.

Five current-CLI probes and their exact output are retained in [cli-probes.json](evidence/cli-probes.json). The replay probe is explicitly a constructed schema fixture; it demonstrates exporter selection, not an executed biological workflow. Temporary paths in evidence are machine-specific and may later be cleaned. No release packaging/publication, network analysis, GUI mutation, or real user-data conversion was performed.

## Review priorities

Repair publication and snapshot correctness first; then make replay semantics honest and unify small statistical kernels. Do not replace the full provenance system. Its existing behavioral tests and integrity primitives are assets. Add tests at the places where user-facing actions choose those primitives, and retain transaction/fault-injection coverage even if it is lengthy: those tests protect recovery contracts rather than implementation style.
