# Micromamba Bundling and Human Scrubber Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bundle a pinned `micromamba` binary for both GUI and CLI conda operations, and move the human-scrubber database out of the app bundle into on-demand managed storage.

**Architecture:** Keep the existing `~/.lungfish/conda` root and current per-tool environment model, but replace the runtime `micromamba` download path with a bundled-resource copy/upgrade path. Treat the human-scrubber database as managed database content resolved through `DatabaseRegistry`, downloaded into user storage only when a scrubber-backed operation first needs it.

**Tech Stack:** Swift 6, SwiftPM/Xcode app bundles, Foundation `Bundle`/`FileManager`, existing `CondaManager`, existing `DatabaseRegistry`, shell build scripts, XCTest.

---

## File Map

- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
  Responsibility: bundled `micromamba` discovery, copy, upgrade, and runtime error messaging.
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
  Responsibility: unit coverage for bundled `micromamba` bootstrap and upgrade behavior.
- Modify: `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`
  Responsibility: add pinned metadata for bundled `micromamba`.
- Modify: `scripts/bundle-native-tools.sh`
  Responsibility: bundle/fetch `micromamba` into the tools payload during release prep.
- Modify: `scripts/update-tool-versions.sh`
  Responsibility: preserve and report the bundled `micromamba` version in notices/version files.
- Modify: `README.md`
  Responsibility: document bundled `micromamba` and update bundled-tool/license summary.
- Modify: `THIRD-PARTY-NOTICES`
  Responsibility: add `micromamba` notice text and correct any redistributed-tool notice gaps.
- Modify: `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift`
  Responsibility: make `human-scrubber` resolve from user-managed storage first and support a missing/on-demand-install flow without assuming a bundled DB exists.
- Modify: `Sources/LungfishWorkflow/Resources/Databases/human-scrubber/manifest.json`
  Responsibility: move or duplicate manifest metadata into a shippable catalog form if needed after removing the bundled DB file.
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
  Responsibility: trigger the human-scrubber install-required path before invoking `scrub.sh`.
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
  Responsibility: handle missing human-scrubber DB consistently in batch/import execution paths.
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
  Responsibility: if reused, hook download/progress/error plumbing for the on-demand human-scrubber install.
- Modify: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
  Responsibility: user-facing prompt path when a scrubber-backed operation is requested and the DB is missing.
- Create or modify: `Tests/LungfishWorkflowTests/DatabaseRegistryTests.swift` or nearest existing database test file
  Responsibility: coverage for missing-vs-installed human-scrubber DB resolution.
- Modify: `Tests/LungfishWorkflowTests/FASTQBatchImporterTests.swift`
  Responsibility: importer behavior when the scrubber DB is missing or becomes available.
- Modify: `Tests/LungfishAppTests/...` nearest FASTQ/UI/service tests for scrubber operations
  Responsibility: prompt/install-required path coverage at the app layer.

## Task 1: Create The Working Branch

**Files:**
- None

- [ ] **Step 1: Create and switch to a feature branch**

Run:

```bash
git checkout -b codex/bundle-micromamba-human-scrubber-db
```

Expected: branch switches successfully with no uncommitted changes besides the spec/plan docs.

- [ ] **Step 2: Verify branch state**

Run:

```bash
git status --short --branch
```

Expected: output begins with `## codex/bundle-micromamba-human-scrubber-db`.

## Task 2: Add Bundled Micromamba Metadata And Resource Packaging

**Files:**
- Modify: `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`
- Modify: `scripts/bundle-native-tools.sh`
- Modify: `scripts/update-tool-versions.sh`
- Test: manual inspection of generated `Resources/Tools/micromamba`

- [ ] **Step 1: Write the failing metadata test expectation in `CondaManagerTests`**

Add a test like:

```swift
func testToolVersionsManifestIncludesMicromamba() throws {
    let manifestURL = URL(fileURLWithPath: "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json")
    let data = try Data(contentsOf: manifestURL)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let tools = json?["tools"] as? [[String: Any]]
    XCTAssertTrue(tools?.contains(where: { $0["name"] as? String == "micromamba" }) == true)
}
```

- [ ] **Step 2: Run the new test to verify it fails**

Run:

```bash
swift test --filter CondaManagerTests/testToolVersionsManifestIncludesMicromamba
```

Expected: FAIL because `micromamba` is not yet present in `tool-versions.json`.

- [ ] **Step 3: Add `micromamba` to `tool-versions.json`**

Add a tool entry shaped like:

```json
{
  "name": "micromamba",
  "displayName": "micromamba",
  "version": "2.0.5",
  "license": "BSD-3-Clause",
  "licenseId": "BSD-3-Clause",
  "sourceUrl": "https://github.com/mamba-org/mamba",
  "releaseUrl": "https://github.com/mamba-org/micromamba-releases/releases",
  "licenseUrl": "https://github.com/mamba-org/mamba/blob/main/LICENSE",
  "copyright": "Copyright (c) QuantStack and mamba contributors",
  "executables": ["micromamba"],
  "dependencies": [],
  "provisioningMethod": "downloadBinary",
  "notes": "Static conda-compatible package manager for plugin environments"
}
```

- [ ] **Step 4: Extend `scripts/bundle-native-tools.sh` to fetch the pinned `micromamba` binary**

Add a helper patterned after the existing binary-download sections:

```bash
MICROMAMBA_VERSION=$(get_tool_version "micromamba")

download_micromamba() {
    local arch=$1
    if [ "$arch" != "arm64" ] && [ "$arch" != "universal" ]; then
        return
    fi

    local url="https://github.com/mamba-org/micromamba-releases/releases/download/${MICROMAMBA_VERSION}/micromamba-osx-arm64"
    curl -L -o "$OUTPUT_DIR/micromamba" "$url"
    chmod +x "$OUTPUT_DIR/micromamba"
}
```

Call it from the main build flow after other downloads complete.

- [ ] **Step 5: Extend `scripts/update-tool-versions.sh` to preserve/report `micromamba`**

Ensure the generated version summary includes the new manifest entry, and skip unsupported auto-update logic if you are not adding GitHub version discovery immediately.

The minimal code path should continue to work because the script already iterates manifest entries for version summaries:

```bash
jq -r '.tools[] | "- \(.displayName): \(.version) (\(.license) license)"' "$MANIFEST"
```

If no explicit update logic is added for `micromamba`, add a comment in the case statement explaining it is release-pinned intentionally.

- [ ] **Step 6: Run the metadata test again**

Run:

```bash
swift test --filter CondaManagerTests/testToolVersionsManifestIncludesMicromamba
```

Expected: PASS.

- [ ] **Step 7: Verify the bundling script produces the binary**

Run:

```bash
./scripts/bundle-native-tools.sh --arch arm64
ls -lh Sources/LungfishWorkflow/Resources/Tools/micromamba
```

Expected: `micromamba` exists and is executable in `Resources/Tools/`.

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishWorkflow/Resources/Tools/tool-versions.json scripts/bundle-native-tools.sh scripts/update-tool-versions.sh Tests/LungfishWorkflowTests/CondaManagerTests.swift
git commit -m "build: bundle pinned micromamba resource"
```

## Task 3: Switch CondaManager To Bundled Micromamba Bootstrap

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`

- [ ] **Step 1: Write the failing bootstrap tests**

Add tests covering copy and upgrade behavior with temp directories, for example:

```swift
func testEnsureMicromambaCopiesBundledBinaryWhenMissing() async throws
func testEnsureMicromambaReplacesOlderInstalledBinary() async throws
```

Use a test-only initializer or helper that injects:

```swift
let manager = CondaManager(
    rootPrefix: tempRoot,
    bundledMicromambaURL: bundledURL,
    bundledMicromambaVersion: "2.0.5"
)
```

Assert:

```swift
XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installedURL.path))
XCTAssertEqual(try String(contentsOf: installedURL), "fake-micromamba-2.0.5")
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
swift test --filter CondaManagerTests/testEnsureMicromambaCopiesBundledBinaryWhenMissing
swift test --filter CondaManagerTests/testEnsureMicromambaReplacesOlderInstalledBinary
```

Expected: FAIL because `CondaManager` has no injectable bundled-binary path and still downloads from the network.

- [ ] **Step 3: Add bundled-binary discovery and injection seams to `CondaManager`**

Refactor the actor initialization minimally:

```swift
public actor CondaManager {
    public static let shared = CondaManager()

    private let bundledMicromambaURLProvider: @Sendable () -> URL?
    private let bundledMicromambaVersion: String?

    init(
        rootPrefix: URL? = nil,
        bundledMicromambaURLProvider: @escaping @Sendable () -> URL? = {
            let candidates = [
                Bundle.module.resourceURL?.appendingPathComponent("Tools/micromamba"),
                Bundle.main.resourceURL?.appendingPathComponent("Tools/micromamba"),
                Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("../Resources/Tools/micromamba").standardized
            ]
            return candidates.compactMap { $0 }.first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }
        },
        bundledMicromambaVersion: String? = NativeToolRunner.bundledVersions["micromamba"]
    ) { ... }
}
```

- [ ] **Step 4: Replace network bootstrap in `ensureMicromamba()` with copy/upgrade logic**

Implement the core logic:

```swift
if let bundledURL = bundledMicromambaURLProvider() {
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

    let shouldInstall = !FileManager.default.fileExists(atPath: micromambaPath.path)
        || installedMicromambaVersion() != bundledMicromambaVersion

    if shouldInstall {
        let tempTarget = binDir.appendingPathComponent("micromamba.tmp")
        if FileManager.default.fileExists(atPath: tempTarget.path) {
            try FileManager.default.removeItem(at: tempTarget)
        }
        try FileManager.default.copyItem(at: bundledURL, to: tempTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempTarget.path)
        if FileManager.default.fileExists(atPath: micromambaPath.path) {
            try FileManager.default.removeItem(at: micromambaPath)
        }
        try FileManager.default.moveItem(at: tempTarget, to: micromambaPath)
    }

    _ = try await runMicromamba(["--version"])
    return micromambaPath
}
throw CondaError.micromambaNotFound
```

Also update `CondaError.micromambaNotFound` to mention reinstall/corrupt bundle rather than auto-download.

- [ ] **Step 5: Remove or quarantine the runtime download URL path**

Delete the `latest/download` bootstrap path unless you explicitly keep it behind a development-only fallback. The production path should no longer fetch from GitHub.

- [ ] **Step 6: Run the focused tests**

Run:

```bash
swift test --filter CondaManagerTests/testEnsureMicromambaCopiesBundledBinaryWhenMissing
swift test --filter CondaManagerTests/testEnsureMicromambaReplacesOlderInstalledBinary
swift test --filter CondaManagerTests/testCondaManagerMicromambaPath
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/CondaManager.swift Tests/LungfishWorkflowTests/CondaManagerTests.swift
git commit -m "feat: bootstrap micromamba from bundled resource"
```

## Task 4: Convert Human Scrubber Database To Managed User Storage

**Files:**
- Modify: `Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift`
- Modify: `Sources/LungfishWorkflow/Resources/Databases/human-scrubber/manifest.json`
- Modify: build/release packaging as needed to stop shipping the 983 MB DB file
- Test: `Tests/LungfishWorkflowTests/...DatabaseRegistry...`

- [ ] **Step 1: Write the failing database-resolution tests**

Add tests like:

```swift
func testEffectiveDatabasePathForHumanScrubberPrefersUserInstalledCopy() async throws
func testEffectiveDatabasePathForHumanScrubberReturnsNilWhenNotInstalled() async throws
```

The missing-path test should assert:

```swift
let path = await registry.effectiveDatabasePath(for: "human-scrubber")
XCTAssertNil(path)
```

- [ ] **Step 2: Run the tests to verify current behavior fails the new expectation**

Run:

```bash
swift test --filter DatabaseRegistryTests/testEffectiveDatabasePathForHumanScrubberReturnsNilWhenNotInstalled
```

Expected: FAIL today because the bundled DB in `Resources/Databases/human-scrubber/` still satisfies lookup.

- [ ] **Step 3: Refactor `DatabaseRegistry` to separate metadata from bundled-payload assumptions**

Add a metadata path helper so the manifest can still ship without the DB file:

```swift
private func bundledMetadataURL(for id: String) -> URL? {
    databasesRoot()?
        .appendingPathComponent(id)
        .appendingPathComponent("manifest.json")
}
```

Update `manifest(for:)` to use metadata-only lookup, but keep `bundledDatabasePath(for:)` returning `nil` when the payload file is absent.

- [ ] **Step 4: Remove the bundled human-scrubber database file from release packaging**

Keep `manifest.json` if you want bundled metadata, but stop shipping:

```text
Sources/LungfishWorkflow/Resources/Databases/human-scrubber/human_filter.db.20250916v2
```

The release build should include metadata only, not the nearly-1-GB database payload.

- [ ] **Step 5: Add explicit install-state helpers for the human-scrubber DB**

Extend `DatabaseRegistry` with narrow helpers:

```swift
public func isDatabaseInstalled(_ id: String) -> Bool {
    effectiveDatabasePath(for: id) != nil
}

public func requiredDatabaseManifest(for id: String) -> BundledDatabase? {
    manifest(for: id)
}
```

Do not generalize beyond what this branch needs.

- [ ] **Step 6: Run the focused database tests**

Run:

```bash
swift test --filter DatabaseRegistryTests/testEffectiveDatabasePathForHumanScrubberPrefersUserInstalledCopy
swift test --filter DatabaseRegistryTests/testEffectiveDatabasePathForHumanScrubberReturnsNilWhenNotInstalled
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Databases/DatabaseRegistry.swift Sources/LungfishWorkflow/Resources/Databases/human-scrubber/manifest.json
git commit -m "refactor: treat human scrubber db as managed data"
```

## Task 5: Add On-Demand Human Scrubber Install Flow

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift` if reusing download plumbing
- Test: nearest app/service/importer tests

- [ ] **Step 1: Write the failing service/importer tests**

Add tests for the missing-database path, for example:

```swift
func testHumanReadScrubFailsWithInstallRequiredWhenDatabaseMissing() async throws
func testBatchImporterHumanReadScrubStopsBeforeRunningToolWhenDatabaseMissing() async throws
```

Assert an actionable error, for example:

```swift
XCTAssertTrue(error.localizedDescription.contains("database"))
XCTAssertTrue(error.localizedDescription.contains("install"))
```

- [ ] **Step 2: Run those tests to verify current behavior is insufficient**

Run:

```bash
swift test --filter FASTQBatchImporterTests/testBatchImporterHumanReadScrubStopsBeforeRunningToolWhenDatabaseMissing
```

Expected: FAIL or produce a late generic execution error rather than an install-required path.

- [ ] **Step 3: Introduce a narrow install-required error at the workflow/service boundary**

Add an error shape in the most local place possible, for example:

```swift
enum HumanScrubberDatabaseError: LocalizedError {
    case installRequired(databaseID: String, displayName: String)

    var errorDescription: String? {
        switch self {
        case .installRequired(_, let displayName):
            return "\(displayName) is required before running human-read scrubbing. Install it and try again."
        }
    }
}
```

Throw this before invoking `scrub.sh` when:

```swift
guard let dbPath = await DatabaseRegistry.shared.effectiveDatabasePath(for: databaseID) else {
    let name = await DatabaseRegistry.shared.requiredDatabaseManifest(for: databaseID)?.displayName ?? databaseID
    throw HumanScrubberDatabaseError.installRequired(databaseID: databaseID, displayName: name)
}
```

- [ ] **Step 4: Add the app prompt path**

In the UI/controller layer handling the operation request, intercept the install-required error and present a prompt with:

```swift
let alert = NSAlert()
alert.messageText = "Human Read Scrubber Database Required"
alert.informativeText = "This operation needs the Human Read Scrubber Database before it can run. The download is large and will be stored in your database storage location."
alert.addButton(withTitle: "Install")
alert.addButton(withTitle: "Cancel")
```

If the user chooses install, route to the existing database download machinery or a new narrow helper that downloads the DB to managed storage, then allow retry.

- [ ] **Step 5: Reuse existing download plumbing instead of inventing a new subsystem**

Prefer a small adapter over a new downloader. The implementation should look like:

```swift
try await HumanScrubberDatabaseInstaller.shared.ensureInstalled(
    progress: { fraction, message in ... }
)
```

If a dedicated installer type is needed, keep it focused on one database and back it with the existing storage/config model.

- [ ] **Step 6: Run the focused tests**

Run:

```bash
swift test --filter FASTQBatchImporterTests
swift test --filter FASTQDerivativeServiceTests
```

Expected: the new missing/install-required behavior passes without regressing existing scrubber operation tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Services/FASTQDerivativeService.swift Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift Tests
git commit -m "feat: install human scrubber database on demand"
```

## Task 6: Complete License Review And Shipped Notices

**Files:**
- Modify: `README.md`
- Modify: `THIRD-PARTY-NOTICES`
- Modify: any shipped manifest/license summary files generated from `tool-versions.json`

- [ ] **Step 1: Gather license sources for shipped third-party payloads**

Check:

```bash
rg -n "micromamba|BBTools|VSEARCH|UCSC|OpenJDK|sra-human-scrubber|seqkit|fastp|cutadapt" README.md THIRD-PARTY-NOTICES Sources/LungfishWorkflow/Resources/Tools/tool-versions.json
```

Expected: locate all current summary entries before editing notices.

- [ ] **Step 2: Update `THIRD-PARTY-NOTICES` for bundled `micromamba`**

Add:

```text
micromamba
Copyright (c) QuantStack and mamba contributors
Licensed under the BSD 3-Clause License
Source: https://github.com/mamba-org/mamba
```

Use the exact upstream notice text required by the shipped license.

- [ ] **Step 3: Re-audit currently bundled entries for redistribution language**

Specifically validate that the notice text and README summary are correct for:

```text
BBTools
VSEARCH
UCSC tools
OpenJDK (Temurin)
sra-human-scrubber
```

If any summary is too loose or inaccurate, fix it directly rather than leaving a follow-up note.

- [ ] **Step 4: Update README bundled-tools summary**

Add `micromamba` to the tool table and adjust the human-scrubber database wording so the README reflects:

```markdown
- scrubber executable is bundled
- human-scrubber database is downloaded on demand into managed storage
```

- [ ] **Step 5: Commit**

```bash
git add README.md THIRD-PARTY-NOTICES Sources/LungfishWorkflow/Resources/Tools/tool-versions.json
git commit -m "docs: update bundled tool notices and license review"
```

## Task 7: Verify End To End

**Files:**
- None beyond prior task outputs

- [ ] **Step 1: Run targeted tests**

Run:

```bash
swift test --filter CondaManagerTests
swift test --filter DatabaseRegistryTests
swift test --filter FASTQBatchImporterTests
```

Expected: PASS for all touched test groups.

- [ ] **Step 2: Build the app**

Run:

```bash
swift build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Build/export the app bundle if available in your local workflow**

Run:

```bash
./scripts/build-app.sh
```

Expected: app bundle builds successfully with bundled `micromamba` present and without the embedded human-scrubber DB payload.

- [ ] **Step 4: Verify the release payload changed in the expected direction**

Run:

```bash
du -sh build/export/Lungfish.dmg
```

Expected: noticeably smaller than the previous `912M` image, primarily from removing the `human-scrubber` bundled database.

- [ ] **Step 5: Smoke-test the bundled `micromamba` path**

Run:

```bash
rm -f ~/.lungfish/conda/bin/micromamba
swift test --filter CondaManagerTests/testEnsureMicromambaCopiesBundledBinaryWhenMissing
```

Expected: the copy/bootstrap path succeeds without network access.

- [ ] **Step 6: Commit final verification fixes**

```bash
git add -A
git commit -m "test: verify bundled micromamba and managed human scrubber db"
```

## Self-Review

- Spec coverage: the plan covers bundled `micromamba`, shared GUI/CLI behavior, managed human-scrubber DB storage, on-demand install prompting, license review, and CI/test coverage.
- Placeholder scan: no `TODO`/`TBD` placeholders remain.
- Type consistency: the plan uses `CondaManager`, `DatabaseRegistry`, and the existing FASTQ service/importer layers consistently, with any new helper names intentionally narrow and local to the branch.
