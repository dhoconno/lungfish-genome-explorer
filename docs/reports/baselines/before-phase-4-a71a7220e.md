# Build timing: before-phase-4

- Commit: `a71a7220e`
- Date: 2026-11-09 01:18:50 CST
- Host: Darwin arm64, 20 logical cores
- Touched path: `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift`

| Phase | Seconds |
| --- | ---: |
| Cold full build (fresh worktree) | 156.5 |
| No-op build (warm) | 7.8 |
| Incremental rebuild (1 leaf file) | 8.9 |
| Incremental rebuild (touch Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift) | 21.5 |
| Full test suite | n/a |
