# Slice C IO Fixture Cleanup Implementation Note

Worker: C
Branch: `codex/wave2-io-fixtures`
Scope: `GFF3RealFileTest`, `VCFRealFileTests`, and package resources under `Tests/LungfishIOTests/Resources`.

Plan:
- Run the focused GFF3/VCF real-file tests first to confirm the current hard-coded Desktop fixtures are silently skipped.
- Replace `/Users/dho/Desktop/test2/...` dependencies with committed package resources loaded through `Bundle.module`.
- Keep behavior-level parser coverage for feature/variant counts, headers, sequence distribution, coordinate conversion, parent relationships, strands, phases, filters, INFO fields, streaming, classification, and genotype parsing.
- Verify no Desktop-only paths or skip helpers remain in `Tests/LungfishIOTests`, then run the focused tests and the full `LungfishIOTests` filter.
