# Build timing: baseline-before

- Commit: `5d58cd69`
- Date: 2026-05-31 19:55:47 CDT
- Host: Darwin arm64, 14 logical cores

| Phase | Seconds |
| --- | ---: |
| No-op build (warm) | 13.2 |
| Incremental rebuild (1 leaf file) | 10.9 |
| Cold full build (clean .build) | 163.3 |
| Full test suite | 458.5 |
