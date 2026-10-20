# Provenance record freeze

Phase 2.13 lane 13.12 took these bytes at the base `ca0fc49c5` before any encode moved onto `ProvenanceWriter`. Each
file is the record of one row of `BIO-13.12.md` F2, built from the fixed ids, paths and dates of
`Tests/LungfishWorkflowTests/ProvenanceRecordFreezeFixtures.swift`.

| File | Row | Test |
|---|---|---|
| `cleanup-preparation-provenance.json` | 9 | `ProvenanceWriterPackageTests` |
| `cleanup-execution-provenance.json` | 7 | `ProvenanceWriterPackageTests` |
| `automatic-cleanup-failure-provenance.json` | 5 | `ProvenanceWriterPackageTests` |
| `cleanup-journal.json` | 8 | `ProjectStorageRecordJSONTests` |
| `cleanup-execution-summary.json` | 6 | `ProjectStorageRecordJSONTests` |
| `automatic-cleanup-failure.json` | 4 | `ProjectStorageRecordJSONTests` |
| `viewer.import.lungfish-provenance.json` | 1 to 3 | `ProvenanceWriterRewriteTests` |

The bytes must not move. The cleanup executor checks the digest and size of the journal that the preparation record
names, and a reader of a published record compares exact paths. Never capture these files again. A change that moves
them is a change to records on disk and needs its own ruling.
