# Primer Analysis Opaque Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish and reopen a durable, integrity-checked bundle of opaque externally produced files with truthful canonical wrapper provenance.

**Architecture:** LungfishIO owns a versioned manifest, relative-path inventory and read-only integrity loader. LungfishWorkflow owns the import/wrap transaction using existing canonical provenance APIs; no biological engine or interpretation is involved. UUID identities survive copying and relocation, while original execution paths remain historical provenance and current payload URLs resolve from the relocated root.

**Tech Stack:** Swift, Foundation, CryptoKit, Darwin filesystem publication primitives, XCTest, existing ProvenanceRunBuilder/ProvenanceWriter.

**Spec:** docs/proposals/2026-09-10-pcr-primer-pack.md (approved storage subset and parent task instructions).

## Global Constraints

- Work only in `.worktrees/pcr-primer-design`, branch `codex/pcr-primer-design`; no commit or push before root review.
- `.lungfishprimeranalysis` is the extension. This is opaque durable storage only; no design commands, parameters, engines, biological algorithms, UI integration, pack installation, coordinate logic or broad annotation refactor.
- Every imported/wrapped data artifact must have canonical provenance: executed wrapper workflow/tool name and version, exact caller argv, reproducible command, visible options plus resolved defaults, runtime identity, input/output paths and SHA-256/size, exit status, wall time and useful stderr. Upstream provenance is preserved as an opaque artifact, never fabricated as an executed step.
- Output provenance describes final stored payload paths; relocation resolves current URLs from relative inventory without rewriting historical argv.
- Preserve every supplied regular file byte-for-byte, including unfamiliar native outputs and supplied upstream provenance. Each input references at least one `input`-role snapshot; other referenced artifacts are allowed. Require at least one `nativeOutput` artifact. Zero results are valid and wrapper success describes storage success only. Caller-supplied `provenance` and `provenance-support` roles are reserved.
- Publication is atomic, exclusive, fails without deleting existing destinations (including dangling links), rolls back its own staging on failure, and rejects traversal/symlink escapes.
- Use UUID for analysis, run, input and result identities; results explicitly reference existing input IDs. Preserve independent-versus-combined grouping as descriptive metadata only.
- IO must not import LungfishWorkflow. Reuse canonical Workflow provenance writing; keep the IO provenance integrity contract small and explicit.
- Tests use opaque harmless text, no biological fixtures. Coordinate Swift tests with root; redirect build output to `.build/primer-analysis-tests.log`, report tail.

### Task 1: Opaque analysis bundle publication and reopening

**Files:**
- Create `Sources/LungfishIO/Bundles/PrimerAnalysisManifest.swift`: Codable/Sendable value schema, UUID identities, descriptive grouping, relative artifact inventory and provenance descriptor.
- Create `Sources/LungfishIO/Bundles/PrimerAnalysisBundle.swift`: read-only loader, manifest validation, regular-file containment, streaming checksum verification and current URL resolution.
- Create `Sources/LungfishWorkflow/Bundles/PrimerAnalysisBundleWriter.swift`: snapshot supplied files, generate canonical wrapper provenance, hash its bytes, write manifest, validate staged bundle then atomically publish without overwrite.
- Create `Tests/LungfishIOTests/Bundles/PrimerAnalysisBundleTests.swift`: malformed manifests, integrity, paths, identities and relocation read tests.
- Create `Tests/LungfishWorkflowTests/PrimerAnalysisBundleWriterTests.swift`: provenance completeness, opaque file preservation, collision and failure rollback tests.

**Interfaces:**
- Produces `PrimerAnalysisManifest` with `schemaVersion: Int`, `analysisID: UUID`, `runID: UUID`, `inputs: [PrimerAnalysisInput]`, `results: [PrimerAnalysisResult]`, `artifacts: [PrimerAnalysisArtifact]`, `provenance: PrimerAnalysisArtifact`, `grouping: PrimerAnalysisGrouping`, `publishedRootPath: String` (historical final location).
- `PrimerAnalysisInput` has `id: UUID`, `artifactPaths: [String]`; `PrimerAnalysisResult` has `id: UUID`, `inputIDs: [UUID]`, `artifactPaths: [String]`. Optional human labels must not be identities.
- `PrimerAnalysisArtifact` has `relativePath: String`, `role: String`, `format: String`, `sha256: String`, `byteSize: UInt64`.
- `PrimerAnalysisGrouping: String, Codable, Sendable` uses `independent` or `combined`; descriptive only, no inference of validated pools.
- `PrimerAnalysisBundle.load(from: URL) throws -> PrimerAnalysisBundle` validates supported schema, unique IDs and paths, referential integrity, mandatory provenance, inventory checksums/sizes and safe regular file paths. Bundle exposes `manifest`, `url`, `artifactURL(forRelativePath:) throws -> URL`.
- Writer request `PrimerAnalysisBundleWriteRequest` supplies identity/grouping/input/result metadata, `[PrimerAnalysisSourceArtifact]` mapping source URL to relative path/role/format, destination URL and required `PrimerAnalysisWrapperInvocation` (exact argv, caller version, explicit options and runtime identity). Writer determines timestamps/status and records resolved storage choices itself.
- `PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter = ProvenanceWriter()).write(_ request: PrimerAnalysisBundleWriteRequest) throws -> PrimerAnalysisBundle` publishes canonical provenance; input and output descriptors match actual copied bytes and retain origin paths. Initializer permits existing writer fault injection for rollback tests.

- [x] **Step 1: Write failing tests and run them.** Use fresh temporary roots per test, harmless `Data("opaque output\\n".utf8)`, and explicit invocation `argv: ["storage-test-host", "--case", "opaque-wrap"]` representing the invoked test harness rather than an invented biological command. Tests initially fail because types are absent. Core assertions:

```swift
XCTAssertEqual(reopened.manifest.analysisID, analysisID)
XCTAssertEqual(try Data(contentsOf: reopened.artifactURL(forRelativePath: "native/unfamiliar.bin")), original)
XCTAssertThrowsError(try PrimerAnalysisBundle.load(from: corruptedRoot))
XCTAssertFalse(FileManager.default.fileExists(atPath: failedDestination.path))
XCTAssertEqual(try Data(contentsOf: existingSentinel), sentinel)
```

Run `swift test --filter 'PrimerAnalysis(Bundle|BundleWriter)Tests' > .build/primer-analysis-tests.log 2>&1` and inspect the final log lines. Record the expected failure in report.

- [x] **Step 2: Implement manifest and strict loader.** Reject unsupported schema, empty/malformed digests, absolute/backslash/NUL/empty/dot/dot-dot path components, duplicate relative paths (including provenance), missing/duplicate input/result IDs, result references to absent input IDs and entity references to absent artifacts. Use lstat and check parent components to reject symbolic links; hash regular files with bounded-memory streaming. Require nonempty provenance JSON with canonical wrapper identity/argv/runtime/options/output descriptor fields, checksum and size. Avoid any workflow dependency; a narrow structural JSON check is acceptable and must be documented. Reopening does not require original sources or tool installations. Keep historical provenance immutable.

```swift
let expected = manifest.artifacts + [manifest.provenance]
for artifact in expected {
    let file = try validatedRegularFileURL(root: root, relativePath: artifact.relativePath)
    guard try digestAndSize(file) == (artifact.sha256, artifact.byteSize) else {
        throw PrimerAnalysisBundleError.integrityMismatch(artifact.relativePath)
    }
}
```

- [x] **Step 3: Implement writer transaction.** Validate request before publication; create a unique sibling staging directory. Copy only verified regular files with no source link traversal. Derive input identities from exactly consumed bytes, not a later reread of mutable source files. Build final destination output descriptors with staged origin URLs via `ProvenanceRunBuilder.relocatedOutput`; use `consumedInputSnapshot` for original source paths. Record fixed workflow identity for wrapping, exact provided caller argv, runtime and resolved storage options. Write via `ProvenanceWriter` to staging, inventory all generated provenance files or use a single canonical sidecar with generated signing artifacts inventoried. Manifest excludes itself to avoid checksum recursion. Validate staged bundle; atomically rename using exclusive no-overwrite semantics. On failure remove only owned staging, never destination.

```swift
let startedAt = Date()
let staging = try makeUniqueSibling(of: request.destinationURL)
defer { removeOwnedStagingIfPresent(staging) }
// Copy files, build descriptors, write required canonical provenance and manifest.
_ = try PrimerAnalysisBundle.load(from: staging)
try exclusiveRename(staging, request.destinationURL)
return try PrimerAnalysisBundle.load(from: request.destinationURL)
```

- [x] **Step 4: Complete meaningful tests.** Verify all copied files (including unfamiliar nested native file and upstream provenance) stay byte-for-byte; canonical envelope output paths equal final destination files and hashes/sizes, argv exact, runtime/options/timing/status complete; no upstream execution is fabricated. Copy/move bundle, delete old source/staging roots, reopen and resolve current URLs. Tamper content, truncate file, remove provenance, give malformed provenance with updated inventory hash, unsupported schema, broken references, duplicate IDs/paths, traversal, symlink file and parent, destination collision and dangling symlink: all reject. Inject ProvenanceWriter failure and assert no destination, no owned staging leftovers, source untouched. Test descriptive independent and combined metadata persistence without interpreting biology.

- [x] **Step 5: Review gate and record evidence.** Run focused suite once after fixes. Controller reviews entire new source/tests against global constraints, then independent reviewer reviews task diff plus report. Resume implementer for concrete findings and scoped covering tests. Root performs final integration review before any commit. Report exact API, evidence and remaining feature scope.

## Execution evidence

- Initial RED confirmed missing storage types.
- Final focused command: `swift test --filter 'PrimerAnalysis(Bundle|BundleWriter)Tests' > .build/primer-analysis-tests.log 2>&1`. Result: 14 tests passed, zero failures at 2026-09-10 19:09:30 local time.
- Controller Astra and root reviewed all production files. Fresh Astra task review identified publication ownership, required native inventory, vacuous validation tests and extension handling; one consolidated fix batch addressed them. Scoped re-review: spec compliant within parent-refined ownership scope; quality Approved; no remaining important findings.
- Additional fixes: canonical typed-string option parsing, manifest/provenance identity and grouping binding, signature-reference-bound support inventory, explicit local signing coverage, safe JSON descriptor reads and streamed payload hashes, source root rejection and exclusive staged file creation.
- The parent descriptor and staging identity remain held/checked for exclusive publication and cleanup. Detected foreign replacements are preserved. Existing path-based provenance writing does not provide isolation against arbitrary concurrent same-user directory mutation; this boundary is documented in the format guide.
- Parent integration verification: 187 XCTest plus 9 Swift Testing tests passed, zero failures at 2026-09-10 19:11:05; evidence `.build/primer-analysis-integrated.log`. CLI help returned exit 0 and missing-bundle inspection returned exit 1 without success output. Root review clean. No commit or push has been made by this subsystem worker/controller.
