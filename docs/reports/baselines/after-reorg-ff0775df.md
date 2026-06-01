# Build timing: after-reorg

- Commit: `ff0775df`
- Date: 2026-05-31 23:52:53 CDT
- Host: Darwin arm64, 14 logical cores

| Phase | Seconds |
| --- | ---: |
| No-op build (warm) | 8.8 |
| Incremental rebuild (1 leaf file) | 11.0 |
| Cold full build (clean .build) | 127.1 |
| Full test suite | 607.6 |
