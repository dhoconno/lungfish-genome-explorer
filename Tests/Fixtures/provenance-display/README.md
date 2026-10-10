# Provenance display fixtures

These files pin what the Inspector's Provenance tab shows a scientist for each legacy record shape. `ProvenanceLegacyDisplayTests` in `LungfishAppTests` loads them. The expected values were captured before the Phase 2.4 write-side changes, so any later difference is deliberate and reviewed.

## Records

The suite holds six record shapes. Two come from files and four are literal bytes in the test target.

| Shape | Source |
|---|---|
| Bare legacy run (`lungfish-cli` 0.4.0-alpha.11) | `Tests/Fixtures/sarscov2-srr36291587/MN908947.3.gff3.lungfish-provenance.json`, copied beside a copy of its GFF3 |
| Released envelope with an embedded `legacyWorkflowRun` (Lungfish 2026.9.58) | `Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json` in this folder |
| Primitive MSA, tree and assembly records | Literal bytes in `Tests/LungfishAppTests/ProvenanceLegacyDisplayRecords.swift`, the same records `ProvenanceEnvelopeTests` decodes |
| Schema 3 `mapping-provenance.json` | Literal bytes in the same file, hand-modelled on the schema 3 golden (`Tests/Fixtures/golden/mapping/mapping-provenance.json`), values invented |

The MHC record is the released demo's file, unchanged. It was extracted with this command, where `GOLDEN` is the golden environment folder that `docs/contracts/MACHINES.md` describes.

```sh
unzip -p "$GOLDEN/cache/lge-demo-mhc-genotyping-2026.9.58.zip" \
  "MHC Genotyping.lungfish/Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json"
```

It is 33,767 bytes and names no home folder, no temporary folder and no account. It sits at its project-relative path so the test can copy it into a temporary `.lungfish` project, where its `@/` paths resolve.

Each test copies its record into a temporary project before anything reads it. The project holds only the record, so a file the record lists inside the project is absent and reads `intermediate file, not kept`.

## Expected files

`expected/<case>.json` holds the audit status, the Run Summary, the Warnings, the Lineage, the Files and Outputs rows and the Invocation and Options rows for one case, as the Inspector's view model builds them. The Raw JSON pane is not compared here, because Phase 2.4 lane W2C changes it on purpose and pins it in its own test.

- `createdAtMilliseconds` is the instant the Run Summary dates the record. The Created text follows the Mac's time zone and locale, so the test compares the instant.
- The tree record has no `createdAt`, so the reader dates it by the sidecar's modification date. The test sets that date itself, 1777777776 seconds since 1970, after it writes the file, so the value does not come from the Mac that runs the test.
- Runtime rows appear only for fields the record's bytes carry. For a record that omits Executable, Process ID, Architecture or Dependency Set, the reader fills them in from the Mac it runs on, so the file leaves them out. The same holds for the workflow version of a record that carries none.
- The temporary project reads as `<project>`, any home folder as `<home>`, and a managed tool path as the tool's name. The bare run names its author's checkout in its recorded paths, which is why `<home>` appears in `bare-legacy-run.json`.
- The size labels come from `ByteCountFormatter` in an English locale.

## Reviewing a difference

When a display changes, the failure names the expected file and writes the actual one under the temporary directory. Run `diff` between the two. Replace the expected file only in a commit that says why the display changed. A test never writes into this folder.
