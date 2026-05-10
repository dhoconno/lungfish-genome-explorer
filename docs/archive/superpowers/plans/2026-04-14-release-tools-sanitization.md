# Release Tools Sanitization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sanitize executable permissions in the copied Release tools bundle so Developer ID export succeeds without breaking packaged wrapper-script execution.

**Architecture:** Add a standalone sanitizer script that runs only against the copied app-bundle tools directory during Release builds. Preserve Mach-O binaries and a narrow script allowlist, strip `+x` from everything else, then verify the resulting packaged app by executing the wrappers from bundle paths.

**Tech Stack:** Swift Testing, Xcode project shell build phases, POSIX shell, macOS `file` utility, `xcodebuild`.

---

## File Map

- Create: `scripts/sanitize-bundled-tools.sh`
  Responsibility: normalize executable permissions inside the copied tools bundle.
- Modify: `Lungfish.xcodeproj/project.pbxproj`
  Responsibility: run the sanitizer during Release app builds after resource copy.
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`
  Responsibility: lock in sanitizer script presence and Release build-phase wiring.
- Modify: `docs/superpowers/specs/2026-04-14-release-tools-sanitization-design.md`
  Responsibility: approved design record.
- Modify: `docs/superpowers/plans/2026-04-14-release-tools-sanitization.md`
  Responsibility: implementation handoff.

## Task 1: Add Failing Release Packaging Tests

**Files:**
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`

- [ ] **Step 1: Add a test that requires the sanitizer script to exist**

- [ ] **Step 2: Add a test that requires the Xcode project to call the sanitizer in Release builds**

- [ ] **Step 3: Run `swift test --filter ReleaseBuildConfigurationTests` and confirm failure before implementation**

## Task 2: Implement The Sanitizer And Wire It Into Release Builds

**Files:**
- Create: `scripts/sanitize-bundled-tools.sh`
- Modify: `Lungfish.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the sanitizer script with a strict allowlist and Mach-O preservation**

- [ ] **Step 2: Add a Release-only Xcode shell phase that invokes the sanitizer on the copied tools bundle**

- [ ] **Step 3: Re-run `swift test --filter ReleaseBuildConfigurationTests` and confirm the tests pass**

## Task 3: Verify Against The Packaged App

**Files:**
- No source edits required unless verification fails

- [ ] **Step 1: Rebuild the Release archive**

- [ ] **Step 2: Run Developer ID export again and confirm the Mach-O slice failure is gone**

- [ ] **Step 3: Inspect the archived/exported tools bundle and confirm non-code files no longer retain `+x`**

- [ ] **Step 4: Execute packaged wrapper scripts from the built app bundle**

Run the packaged BBTools wrappers directly from:

- `.../Lungfish.app/.../Tools/bbtools/clumpify.sh`
- `.../Lungfish.app/.../Tools/bbtools/bbduk.sh`
- `.../Lungfish.app/.../Tools/bbtools/bbmerge.sh`
- `.../Lungfish.app/.../Tools/bbtools/repair.sh`
- `.../Lungfish.app/.../Tools/bbtools/tadpole.sh`
- `.../Lungfish.app/.../Tools/bbtools/reformat.sh`

Run the packaged scrubber chain from:

- `.../Lungfish.app/.../Tools/scrubber/scripts/scrub.sh`

The verification commands may use help/version invocations rather than full workflow data, but they must execute from bundle paths and complete successfully.

- [ ] **Step 5: If packaged wrapper execution fails, expand or correct the allowlist before retrying export**
