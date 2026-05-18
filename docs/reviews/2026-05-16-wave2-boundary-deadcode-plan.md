# Wave 2 Boundary/Dead-Code Cleanup Plan

**Worker:** D

**Goal:** Remove first-pass dead resource/module boundaries without touching unrelated lanes, and leave reproducibility/packaging resources intact.

**Scope owned in this pass:**
- Duplicate root `Resources/` files only when canonical SwiftPM-bundled copies remain.
- `Sources/LungfishWorkflow/Plugins/ContainerToolPlugin.swift` and `Tests/LungfishWorkflowTests/ContainerPluginTests.swift`.
- `Package.swift` only for proven-dead products, targets, test targets, and dependencies.
- `Sources/LungfishPlugin/**`, `Tests/LungfishPluginTests/**`.
- `Sources/LungfishUI/**`, `Tests/LungfishUITests/**`, and integration tests importing that dead module.

## Proof Commands

Run from `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/wave2-boundary-deadcode`.

### Root Resources

Command:

```sh
find Resources -maxdepth 4 -type f -print | sort
```

Result:

```text
Resources/AppIcon.icns
Resources/Containerization/init.rootfs.tar.gz
Resources/Containerization/vmlinux
```

Command:

```sh
find Sources -path '*Resources/Containerization*' -type f -print | sort
```

Result:

```text
Sources/LungfishWorkflow/Resources/Containerization/init.rootfs.tar.gz
Sources/LungfishWorkflow/Resources/Containerization/vmlinux
```

Command:

```sh
shasum -a 256 Resources/Containerization/init.rootfs.tar.gz Sources/LungfishWorkflow/Resources/Containerization/init.rootfs.tar.gz Resources/Containerization/vmlinux Sources/LungfishWorkflow/Resources/Containerization/vmlinux Resources/AppIcon.icns Sources/Lungfish/AppIcon.icns
```

Result summary:
- `Resources/Containerization/init.rootfs.tar.gz` matches the SwiftPM-bundled `Sources/LungfishWorkflow/Resources/Containerization/init.rootfs.tar.gz`.
- `Resources/Containerization/vmlinux` matches the SwiftPM-bundled `Sources/LungfishWorkflow/Resources/Containerization/vmlinux`.
- `Resources/AppIcon.icns` matches `Sources/Lungfish/AppIcon.icns`, but it is still required by packaging scripts and is not deleted.

Command:

```sh
rg -n "Resources/Containerization|Containerization/(init\.rootfs|vmlinux)|init\.rootfs|vmlinux|AppIcon\.icns|Resources/AppIcon" -S .
```

Result summary:
- Container runtime code and `scripts/test-container-runtime.sh` use the canonical SwiftPM path under `Sources/LungfishWorkflow/Resources/Containerization`.
- `Package.swift` copies `Resources/Containerization` relative to the `Sources/LungfishWorkflow` target path, not root `Resources/Containerization`.
- `Resources/AppIcon.icns` is referenced by `scripts/build-app.sh`, `scripts/release/build-notarized-dmg.sh`, app-icon generation, release smoke scripts, and tests, so it remains.

### ContainerToolPlugin

Command:

```sh
rg -n "ContainerToolPlugin|ContainerTool|ToolPlugin" Sources Tests Package.swift -S
```

Result summary:
- Production hits are limited to `Sources/LungfishWorkflow/Plugins/ContainerToolPlugin.swift`.
- Test hits are limited to `Tests/LungfishWorkflowTests/ContainerPluginTests.swift`.
- No Nextflow schema/parser or `NextflowRunner` code references this model.

### LungfishPlugin

Command:

```sh
rg -n "^import LungfishPlugin|^@testable import LungfishPlugin|\bLungfishPlugin\b" Sources Tests Package.swift -S
```

Result summary:
- `LungfishPlugin` appears as its package product/target/test target and in `Tests/LungfishPluginTests`.
- No production source imports `LungfishPlugin`.
- App "Plugin Manager" references are conda/plugin-pack management code, not this dead SDK module.
- `loadBuiltInPlugins()` has only test consumers, so deletion is preferred over wiring it into production.

### LungfishUI

Command:

```sh
rg -n "^import LungfishUI|^@testable import LungfishUI|\bLungfishUI\b" Sources Tests Package.swift -S
```

Result summary:
- `LungfishUI` appears as its package product/target/test target, as a structural dependency of `LungfishApp` and `LungfishIntegrationTests`, in its own tests, and in two integration test files.
- No production app source imports `LungfishUI`.
- `Tests/LungfishIntegrationTests/EndToEndTests.swift` and `Tests/LungfishIntegrationTests/CrossModuleTests.swift` use it only for test-only track/cache/frame coverage.

## Implementation

1. Keep `Resources/AppIcon.icns` because release packaging still depends on it.
2. Delete root `Resources/Containerization/` after confirming canonical target resources remain under `Sources/LungfishWorkflow/Resources/Containerization/`.
3. Delete `ContainerToolPlugin.swift` and `ContainerPluginTests.swift`; do not touch Nextflow schema/parser or runner code.
4. Remove `LungfishPlugin` product, target, and test target from `Package.swift`, then delete `Sources/LungfishPlugin/` and `Tests/LungfishPluginTests/`.
5. Remove `LungfishUI` product, target, test target, `LungfishApp` dependency, and `LungfishIntegrationTests` dependency from `Package.swift`.
6. Remove the `LungfishUI` imports and UI-only checks from integration tests, then delete `Sources/LungfishUI/` and `Tests/LungfishUITests/`.

## Verification

Required commands after implementation and actual results:

```sh
swift package describe --type json
```

Result: passed. The described package graph no longer contains `LungfishPlugin` or `LungfishUI`; `LungfishApp` depends on `LungfishCore`, `LungfishIO`, and `LungfishWorkflow`.

```sh
swift build --product lungfish-cli
```

Result: passed. Existing warnings were emitted in unrelated Core/IO/Workflow/App/CLI files.

```sh
swift build --target LungfishApp
```

Result: passed, proving the removed `LungfishUI` dependency is not required by `LungfishApp`.

```sh
swift test --filter LungfishWorkflowTests
```

Result: passed. The filter runs the broad `LungfishWorkflowTests` target; runtime-dependent container tests skipped where the local runtime/kernel was unavailable.

```sh
swift test --filter LungfishIntegrationTests.EndToEndTests
```

Equivalent command run:

```sh
swift test --filter EndToEndTests
```

Result: passed. XCTest executed 11 `EndToEndTests` cases with 0 failures; Swift Testing also matched 1 end-to-end test and passed.

```sh
swift test --filter LungfishIntegrationTests.CrossModuleTests
```

Equivalent command run:

```sh
swift test --filter CrossModuleTests
```

Result: passed. XCTest executed 12 `CrossModuleTests` cases with 0 failures; Swift Testing matched 0 additional tests.

```sh
git diff --check
```

Result: passed.

## Residual Risks

- Some historical docs and comments may still refer to `LungfishPlugin` or `LungfishUI`; this pass only removes compile-time surfaces in the owned lane.
- `Resources/AppIcon.icns` remains a duplicate by checksum, but deleting it would break packaging scripts in the current repository shape.
- Removing integration tests for UI-only track/cache/frame types intentionally drops test-only coverage for a module with no production consumers.
