# Implementation Gate 1: Bioinformatics Review

- Reviewer: explorer `Pascal`
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

- The selected viral callers (`lofreq`, `ivar`, `medaka`) are coherent with the intended managed-environment installation path.
- Current smoke tests are appropriate install sanity checks, but they are not behavioral validation of the callers themselves.
