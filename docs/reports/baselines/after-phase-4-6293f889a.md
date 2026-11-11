# Build timing: after-phase-4

- Commit: `6293f889a`
- Date: 2026-11-11 09:09:45 CST
- Host: Darwin arm64, 20 logical cores
- Touched path: `Sources/LungfishWorkflowTwelveS/TwelveSAmpliconMatchingWorkflow.swift`

| Phase | Seconds |
| --- | ---: |
| Cold full build (fresh worktree) | 163.6 |
| No-op build (warm) | 8.3 |
| Incremental rebuild (1 leaf file) | 9.1 |
| Incremental rebuild (touch Sources/LungfishWorkflowTwelveS/TwelveSAmpliconMatchingWorkflow.swift) | 9.1 |
| Full test suite | n/a |
