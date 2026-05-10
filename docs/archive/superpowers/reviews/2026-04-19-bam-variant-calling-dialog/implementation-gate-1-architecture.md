# Implementation Gate 1: Architecture Review

- Reviewer: explorer `Noether`
- Scope: Task 1 pack activation and managed native-tool wiring
- Files reviewed:
  - `Sources/LungfishWorkflow/Conda/PluginPack.swift`
  - `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
  - `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
  - `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
  - `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
  - `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
  - `Tests/LungfishAppTests/WelcomeSetupTests.swift`

## Outcome

- Blocker: no

## Notes

- Pack ordering, CLI visibility, and managed-tool enum additions were internally consistent.
- Follow-up note from review: pin optional-pack package specs instead of relying on default package IDs.
- Resolution: addressed in Task 1 by pinning `lofreq`, `ivar`, and `medaka` install package specs plus version/license metadata in `PluginPack.swift`, with registry tests updated accordingly.
