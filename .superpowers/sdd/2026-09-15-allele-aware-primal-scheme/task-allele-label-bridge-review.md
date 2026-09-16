# Independent LGE allele-label bridge review

## Verdict

Approved: `6a5a2f2e9139f143732880ab264f04e67d8f35b0`, against native label schema `primalscheme3.allele-label-map/v1` from `236e74a`. No load-bearing defect found in this bounded review. No source edits or scientific runs performed. Sol's separate tiny real matrix11 smoke and root's integrated tests remain their own acceptance evidence.

## Reviewed contract

- The bridge is display-only: it writes a separate derived map and provenance, retaining the native map and all scientific target/class/row/configuration/coverage identities unchanged.
- Native source indices and target order must exactly match the LGE result's ordered inputs. Row-map input UUID, contiguous row index, normalized header, native record ID/description and optional comment are checked before joining original names. Stable source-row names/IDs must be unique; repeated human labels remain allowed and distinct.
- Native classes must partition the target's rows exactly once, preserve multiplicity and retain matching per-row FASTA aliases. Original `.lungfishmsa` metadata is joined by consumed aligned row name; raw FASTA falls back to its consumed original header.
- Acceptance requires fresh native label audit evidence, matching advertised schema/path/counts, and retained validation bytes equal to the validated bytes. The existing upstream allele contract independently binds all native files to panel and audit input inventories and binds audit output bytes/source/runtime/argv. The bridge does not substitute counts for that upstream hash validation.
- Enrichment provenance inventories optimizer, native map, native stored FASTAs, audit validation, normalized row maps, optional source metadata and derived output with hash/size and final published paths. Artifact paths in the result remain relative. Host invocation/runtime and transform scope are recorded; an exception propagates to the existing retained workflow failure envelope, including scratch artifacts.
- Saved inspection first invokes bundle-wide hash/size/provenance validation, then checks derived-map schema/result/native reference, row/input ownership and class correspondence to coverage. Both text and JSON take this path. Missing historical advertisement remains compatible; missing or detached advertised maps fail closed. This does not purport to defeat wholesale coordinated rewriting of every provenance inventory.
- Changes are confined to the five reviewed Swift source/test files; no native/discovery/scientific policy changes.

## Independent verification

Sol confirmed the current built executable/tests include the pinned source and no rebuild was in progress. Executed from the LGE worktree:

```sh
swift test --skip-build --filter 'PrimalScheme3AlleleLabelMapTests|PrimerAnalysisInspectCommandTests'
```

13 tests passed: 5 label-map and 8 inspection tests, zero failures. Retained log: `/tmp/allele-label-bridge-independent-review.log` (SHA256 `6041a7516bfe0e489fbd2889f310715192a5ddcedff1ed81385e802927e2b549`, 217563 bytes). macOS emitted duplicate private-framework Objective-C class warnings; no test failure resulted. Other unrelated test bundles reported zero selected tests; those are not counted.

Existing fixtures exercise duplicate display labels with distinct stable IDs, two source occurrences, raw FASTA fallback, transform provenance, historical absence, missing/detached audit bytes, detached normalized headers, wrong result ID and text/JSON corruption rejection. Read-only inspection also traced upstream native audit inventories and pipeline failure retention rather than repeating the native suite.
