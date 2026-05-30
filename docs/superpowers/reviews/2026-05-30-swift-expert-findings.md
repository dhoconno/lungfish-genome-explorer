# Swift Expert Findings — Amplicon Genotyping + 12S Review

**Reviewer lens:** idiomatic Swift 6.2, `@Observable`/`@MainActor`/strict-concurrency
conformance, `Sendable` correctness, API design of the new public types, and the project's
binding memory rules (`%s`/`String(format:)` SIGSEGV trap, `GlobalOptions()` direct-init crash,
background→MainActor dispatch discipline).

**Scope:** read-only. No code edited.

---

## Executive summary

### Concurrency-safety health: clean across both workflows.

This is a notably well-disciplined concurrency surface. I found **zero P0 concurrency or crash
bugs.** Specifically verified clean:

- **No `%s` in `String(format:)`.** Every `String(format:)` call in the reviewed files is either
  `"%02x"` (single `UInt8`) or `"%.6f"` (`Double`). The SIGSEGV trap is not present.
- **No `GlobalOptions()` direct-init.** All CLI subcommands (e.g.
  `FastqTwelveSMatchSubcommand.swift:46`) use `@OptionGroup var globalOptions: GlobalOptions`,
  which is the safe path; no direct initializer call anywhere in `Sources/LungfishCLI`.
- **Background→MainActor dispatch is textbook.** `ViewerViewController+TwelveS.swift` runs the
  long BLAST job in `Task.detached` (line 64), keeps the heavy helpers as `nonisolated static`
  free functions (lines 172, 196) to avoid `self`-isolation, and returns to the main actor
  exclusively via `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` (lines 89-90,
  104-105, 116-117). This is exactly the prescribed idiom. No
  `Task { @MainActor in }`-from-GCD, no bare `DispatchQueue.main.async` touching `@MainActor`
  state, no `await`-of-`@MainActor`-from-`Task.detached`.
- **Structured concurrency in the 12S matcher is correct.**
  `TwelveSAmpliconMatchingWorkflow.classifyUniqueSequences` (line 298) uses `withTaskGroup`,
  partitions the unique-sequence set into disjoint chunks, and each child task writes only a
  local dictionary that is merged after. The shared `TwelveSAmpliconReadClassifier` is a fully
  immutable `Sendable` struct (all stored properties built once in `init`, `classify` is pure),
  so sharing it across child tasks is safe. No data races.
- **`TwelveSFastqReader.records()`** (line 26) wraps a `Task` in an `AsyncThrowingStream` with
  correct `continuation.onTermination { task.cancel() }` and back-pressure handling via the
  `.terminated` yield check (line 41). Cancellation is honored.
- **All long-running workflow types are `Sendable` value types** (`TwelveSAmpliconMatchingWorkflow`,
  `MHCAmpliconReferenceBundleBuilder`, `TwelveSReferenceBundleBuilder`,
  `HaplotypeDefinitionCommandService`, `ONTBarcodeDemuxGenotypingPipeline`), and none of them
  reach for `@unchecked Sendable` or `nonisolated(unsafe)` — unlike the older process-driven
  pipelines that legitimately need it. The new code stays in the safe lane.
- **GUI bridge is CLI-backed and isolation-correct.**
  `WorkflowOperationExecutionService` is `@MainActor`, shells out to `lungfish-cli` for both 12S
  matching (line 233) and the 12S reference bundle build (line 153), captures `[operationCenter]`
  (a `Sendable` reference) in the streaming `outputHandler`, and routes streamed output through a
  `static` recorder. Provenance dual-call rule (`log()` + `update*()`) is observed.

### MHC genotyping batch path: clean.

`ONTBarcodeDemuxGenotypingPipeline` is a `Sendable` struct. The Illumina multi-bundle path
(`resolveMode` line 665, `prepareIlluminaInputs` line 784, `resolveIlluminaSampleInputs` line
832) iterates samples in a sequential `async` loop, staging each sample into a distinctly-named
`*.sample-prefixed.fastq` (line 850) with a per-sample read prefix (line 881). There is **no
shared mutable state crossing an isolation boundary** and no `Task.detached`/`DispatchQueue` use
in the pipeline. Per-sample isolation is structurally guaranteed by giving each sample its own
file path. I have no concurrency concern with the batch path.

### API-design quality: high, with a few sibling-type inconsistencies.

The new value types are well-shaped: `Codable, Equatable, Sendable` where appropriate, memberwise
inits with sensible defaults, URL-normalizing initializers (`.standardizedFileURL`), `LocalizedError`
with good messages, and `with…`/`replacing…` copy helpers instead of mutation. The findings below
are P1/P2 API-consistency items, not safety bugs. The single most material one (SE-1) is a real
behavioral divergence in bundle detection.

---

## Findings

| ID | Severity | Surface | Location (file:line) | Problem | Evidence | Suggested fix | Effort |
|----|----------|---------|----------------------|---------|----------|---------------|--------|
| SE-1 | P1 | cross-cutting | `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift:63-65`; `Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift:695-697`; vs `Sources/LungfishIO/Bundles/TwelveSReferenceBundle.swift:83-88` | The three sibling bundle types disagree on what `isBundleURL` *means*. `TwelveSReferenceBundle.isBundleURL` requires the extension **and** that the manifest file exists. `MHCAmpliconReferenceBundle.isBundleURL` and `TwelveSAmpliconResultBundle.isBundleURL` check only the path extension. A `.lungfishmhcref` directory with no `mhc-reference.json` is reported as a valid bundle; an equivalent `.lungfish12sref` is not. | Side-by-side bodies above. This is consumed for real discovery in `HaplotypeDefinitionLibrary.projectMHCReferenceBundleRecords` (`HaplotypeDefinitionLibrary.swift:214-233`), which walks a project tree calling `MHCAmpliconReferenceBundle.isBundleURL`; a partially-written/corrupt `.lungfishmhcref` dir would be treated as a bundle and then silently yield no records. | Pick one contract for all three (the manifest-existence check is the stronger, less surprising one) and apply it uniformly. The format registry (`FormatIdentifier`/`FileTypeUtility`) should key off the same predicate. | S |
| SE-2 | P1 | cross-cutting | `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift:25-26` vs `TwelveSReferenceBundle.swift:43-44` and `TwelveSAmpliconResultBundle.swift:7-8` | Manifest schema-evolution fields are named inconsistently across the three new bundle manifests. MHC uses `formatVersion: Int` and has **no** `kind`/`schema-id` discriminator; both 12S manifests use `schemaVersion: Int` **plus** a `kind` string (`"12s-reference"`, `"12s-amplicon-match"`). A reader cannot identify an MHC manifest by content, only by filename. | `MHCAmpliconReferenceBundleManifest` has `public let formatVersion: Int`; `TwelveSReferenceBundleManifest`/`TwelveSAmpliconResultBundleManifest` have `public let schemaVersion: Int` and `public let kind: String`. | Converge on one name (`schemaVersion`) and add a `kind` discriminator (e.g. `"mhc-reference"`) to the MHC manifest so all three follow the same self-describing pattern as the existing `.lungfishref` family. Both are still v1, so this is a pre-release alignment, not a migration. | S |
| SE-3 | P2 | MHC | `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift:121` | `definition.speciesCode.caseInsensitiveCompare(speciesCode ?? "")` defends against a `nil` that the surrounding `&&` already excludes (`speciesCode == nil || …`). The `?? ""` is dead and slightly obscures intent; force-unwrap-free, but the guard is doubled. | `(speciesCode == nil || definition.speciesCode.caseInsensitiveCompare(speciesCode ?? "") == .orderedSame)` | Bind once: `if let speciesCode { … caseInsensitiveCompare(speciesCode) … }` or hoist the optional into a `let` guard so the comparison sees a non-optional. | S |
| SE-4 | P2 | MHC | `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift:485` | The one genuine force-unwrap in the new sources: `id: targetID?.isEmpty == false ? targetID! : source.definitionSet.id`. It is *safe* (the ternary guard guarantees non-nil), but `targetID!` after an `== false` comparison is a fragile idiom that a future edit could desync. | Line 484-485. | Use optional binding: `let resolvedID = (targetID?.isEmpty == false) ? targetID! : source.definitionSet.id` is still a `!`; prefer `let resolvedID = targetID.flatMap { $0.isEmpty ? nil : $0 } ?? source.definitionSet.id`. | S |
| SE-5 | P2 | MHC | `Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift:199-204` vs `:5-22` | `MHCAmpliconReferenceBundleBuilder.ResolvedDefinitionInput` (private struct) is a field-for-field duplicate of the public `MHCAmpliconReferenceBundleDefinitionInput`. The builder immediately re-wraps the public type into the private one (`validate`, line 235-242) with no transformation. | Two structs with identical stored properties (`definition`, `sourceURL`, `sourceDescription`, `sourceScope`). | Drop `ResolvedDefinitionInput` and thread the public `MHCAmpliconReferenceBundleDefinitionInput` through `validate`/`build` directly. Removes ~20 lines and a mapping step. | S |
| SE-6 | P2 | 12S | `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift:1012-1015` | A file-private `zip<T,U>(_:_:)` shadows the stdlib `Swift.zip`. It's only used once (line 818, to pair `startedAt`/`completedAt` `Date?`). Shadowing a stdlib name at file scope is a maintenance hazard — a reader seeing `zip(...)` elsewhere in the file would assume sequence-zip semantics. | `private func zip<T, U>(_ first: T?, _ second: U?) -> (T, U)?` at EOF. | Rename to something intention-revealing, e.g. `zipOptionals` / `both`, or inline it at the single call site as `if let s = …startedAt, let e = …completedAt { e.timeIntervalSince(s) }`. | S |
| SE-7 | P2 | cross-cutting | `TwelveSAmpliconMatchingWorkflow.swift:957-977`, `MHCAmpliconReferenceBundleBuilder.swift:427-447`, `HaplotypeDefinitionCommandService.swift:749-769` | Three byte-identical copies of `directoryChecksum(from:)` + `directorySize(from:)` (canonical SHA-256 over a `ProvenanceDirectoryManifest`). This is provenance-critical logic; three copies risk drift where one bundle's directory checksum diverges from another's. | Identical bodies in all three files. | Hoist into a single static helper on `ProvenanceFileHasher` / `ProvenanceDirectoryManifest` (e.g. `manifest.canonicalChecksum()` / `.totalSize`) and call it from all three. Architectural; flagging here because the duplication is in `Sendable` value-type provenance code I reviewed. | M |
| SE-8 | P2 | 12S | `Sources/LungfishCore/Models/SampleMetadataResolver.swift:256-291` and `:344-419`; `TwelveSAmpliconResultBundle.swift:932-962`; `TwelveSReferenceMetadata.swift:391-421` | Multiple independent TSV/CSV split-and-parse implementations exist across the new code: `SampleMetadataTable.split(line:delimiter:)` (a real quote-aware CSV splitter), the bundle's `splitTSVLine`, and the metadata builder's private `TSVTable`. They have subtly different quoting/empty-field semantics. | Three `split*`/`TSVTable` helpers with different rules (only `SampleMetadataResolver` handles quoted commas). | Not a correctness bug for the current tab-delimited internal files, but as an API it invites divergence. Consider a single shared delimited-table reader in `LungfishCore`/`LungfishIO`. | M |

---

## Per-type API-design notes (where it is clean — stated explicitly)

The brief asks for explicit confirmation where a surface is clean. Per the named public types:

- **`TwelveSAmpliconResultBundle` family** (`TwelveSAmpliconResultBundleManifest`,
  `…Artifacts`, `…Target`, `…SampleResult`, `…ReadFate`, `…UnresolvedSequence`,
  `TwelveSAmpliconResultBundleData`): idiomatic. `Codable, Equatable, Sendable` value types,
  memberwise inits with defaults, `replacing…`/`with…` copy helpers (e.g.
  `replacingSampleMetadata`, `withAlternateMatches`), and the URL-bearing `…Artifacts` normalizes
  every URL in its init (lines 118-129). The derived-projection types (`TwelveSTargetCountRow`,
  `TwelveSScientificNameCountRow`) are correctly `Equatable, Sendable` but **not** `Codable` —
  appropriate, since they're computed views, not persisted. `TwelveSAmpliconResultBundleError`
  is a clean `Error, Equatable, CustomStringConvertible`. **Clean.**

- **`TwelveSReferenceBundle` / `TwelveSReferenceBundleManifest` / `TwelveSReferenceBundleMetrics`
  / `TwelveSReferenceBundleSourceFile`:** idiomatic `Codable, Equatable, Sendable`; enum-as-
  namespace with `static` accessors. Only nit is SE-1/SE-2 (cross-sibling divergence), not an
  intrinsic defect. **Clean apart from the sibling inconsistencies.**

- **`TwelveSReferenceIndex` / `TwelveSReferenceRecord`:** `Equatable, Sendable`, immutable, with a
  pure `enriched(with:)` transform and a derived `target` computed property. SHA-256 via
  `CryptoKit` (`"%02x"`, safe). **Clean.**

- **`TwelveSReferenceMetadata*` (`…Entry`, `…Index`, `…Builder`, `…BuildConfiguration`,
  `…BuildResult`, `…BuildError`):** the `Index` builds an internal `[String: …]` lookup in `init`
  and exposes it via `entry(sequenceSHA256:)` — good encapsulation, `Sendable`. The `Builder` is a
  stateless `Sendable` struct with an `async` `build` that cleans up partial output on failure
  (`catch` at lines 134-140). **Clean.**

- **`MHCAmpliconReferenceBundle` / manifest / metrics / source-file:** idiomatic value types; the
  `haplotypeDefinition(id:assayID:speciesCode:in:)` query API is reasonable. SE-1, SE-2, SE-3
  apply. Otherwise **clean.**

- **`MHCAmpliconReferenceBundleBuilder` (+ `…DefinitionInput`, `…BuildConfiguration`,
  `…BuildResult`, `…BuildError`):** `Sendable` struct, `@Sendable` progress-handler typealias,
  partial-output cleanup on failure (line 193-196). SE-4, SE-5, SE-7 apply (polish). **Clean
  on safety.**

- **`SampleMetadataResolver` + `SampleMetadataTable` + `ResolvedSampleMetadata` +
  `SampleMetadataSourceSummary` + `SampleMetadataSourceKind` + `SampleMetadataResolverError`:**
  all `Codable, Equatable, Sendable`; `SampleMetadataResolver` is a pure namespace enum with a
  single static `resolve`. `ResolvedSampleMetadata` normalizes its `columns` in `init` (always
  leads with `sample_id`, dedups case-insensitively) — good defensive design. The error enum is
  `LocalizedError, Equatable` with row-numbered diagnostics. SE-8 (shared parser) is the only
  note. **Clean and idiomatic.**

- **`HaplotypeDefinitionCommandService` / `HaplotypeDefinitionLibrary` /
  `HaplotypeDefinitionRecord` / `HaplotypeDefinitionScope` / `HaplotypeDefinitionCommandResult`:**
  `Sendable` value types, `Identifiable` record with a composite `id`, scope precedence modeled
  cleanly, `@discardableResult` on the mutating command methods. SE-4, SE-7 apply. **Clean on
  safety.**

- **`TwelveSAmpliconMatchingWorkflow` / config / result / error + `TwelveSAmpliconReadClassifier`
  + `TwelveSChimeraReviewing` protocol + reviewers + `TwelveSFastqReader`:** the strongest part of
  the surface. Protocol-oriented chimera-review injection (`any TwelveSChimeraReviewing` with a
  `Sendable` constraint and an injectable `@Sendable` `runVSearch` closure for testability), pure
  immutable classifier, structured `withTaskGroup`, cancellable `AsyncThrowingStream`. SE-6
  (shadowed `zip`) is the only nit. **Clean.**

- **`AmpliconGenotypingMode` / `AmpliconGenotypingReadType`:** clean `String`-raw enums with
  `cliArgument` round-tripping and tolerant `init?(cliArgument:)`. **Clean.**

- **GUI `@Observable`/`@MainActor`:** `GenotypeAnnotationStore` is correctly
  `@Observable @MainActor`. Every new AppKit view/controller
  (`TwelveSAmpliconResultViewController`, `GenotypeResultViewController`, the genotype views) is
  `@MainActor final class`. `GenotypeQuickFilterBarView`'s pure parsing helpers are correctly
  `nonisolated static` (lines 275, 304). The display-state structs
  (`TwelveSResultDisplayState`, `GenotypeResultDisplayState`) are value types
  (`Equatable`/`Equatable, Sendable`). The one `Task { @MainActor [weak self] in }`
  (`GenotypeResultViewController.swift:3346`) is launched from an `NSSavePanel` completion handler
  on a `@MainActor` class — main-actor context, not the GCD-background hazard. **Clean.**

---

## Retain-cycle / escaping-closure audit

- **`ViewerViewController+TwelveS.swift:31-130`:** the outer `onUnresolvedBlastRequested` closure
  captures `[weak controller]` (line 31). Inside `Task.detached`, the already-unwrapped strong
  `controller` local is held for the BLAST duration; this is **not** a cycle because the task is
  retained by the `OperationCenter` cancel callback (line 129), not by the controller. The
  completion paths null out `controller.onUnresolvedBlastCancelRequested` (lines 111, 124) to
  drop the back-reference. Acceptable.
- **`MainSplitViewController.swift:3219-3230`:** all four result-display callbacks capture
  `[weak self]` / `[weak controller]`. No cycle.
- **`WorkflowOperationExecutionService.swift:156, 236`:** `outputHandler` captures
  `[operationCenter]` (an explicit, `Sendable` capture), not `self`. No cycle.

No retain cycles found in the reviewed surface.

---

## Items I explicitly checked and found absent (negative confirmations)

- `%s` in `String(format:)` with Swift strings — **absent.**
- `ArgumentParser.GlobalOptions()` direct init — **absent** (all use `@OptionGroup`).
- `Task { @MainActor in }` from a GCD background context — **absent.**
- bare `DispatchQueue.main.async` touching `@MainActor` state without `assumeIsolated` — **absent**
  in the new code (the two `DispatchQueue.main.async` sites both wrap `MainActor.assumeIsolated`).
- `await`-ing a `@MainActor` member from inside `Task.detached` — **absent** (the detached task
  only calls `nonisolated static` helpers and a `Sendable` `BlastService.shared`).
- `try!` / `fatalError` / `preconditionFailure` / `assertionFailure` in the new TwelveS/MHC
  sources — **absent.**
- `@unchecked Sendable` / `nonisolated(unsafe)` in the new workflow/IO/core types — **absent**
  (correctly avoided; the new types are honestly `Sendable`).

---

## Bottom line

From the Swift-language / concurrency / API-design lens, this surface is in good shape. There are
**no P0s** in my lens. The P1s (SE-1, SE-2) are sibling-bundle consistency gaps that are cheap to
fix before release and matter because `.lungfishmhcref`, `.lungfish12sref`, and `.lungfish12s`
should present one coherent bundle contract (the cross-workflow-consistency requirement applies to
file formats too, not just GUI widgets). The P2s are duplication/polish opportunities, with SE-7
(triplicated provenance-checksum logic) being the most worth consolidating because it is
provenance-critical.
