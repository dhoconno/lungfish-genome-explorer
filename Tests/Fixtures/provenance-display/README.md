# Provenance display fixtures

These files pin what the Inspector's Provenance tab shows a scientist for each legacy record shape. `ProvenanceLegacyDisplayTests` in `LungfishAppTests` loads them. The expected values were captured before the Phase 2.4 write-side changes, so any later difference is deliberate and reviewed.

## Records

The suite holds eight record shapes. Four come from files and four are literal bytes in the test target.

| Shape | Source |
|---|---|
| Bare legacy run (`lungfish-cli` 0.4.0-alpha.11) | `Tests/Fixtures/sarscov2-srr36291587/MN908947.3.gff3.lungfish-provenance.json`, copied beside a copy of its GFF3 |
| Released envelope with an embedded `legacyWorkflowRun` (Lungfish 2026.9.58) | `Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json` in this folder |
| Version 2 envelope of a cancelled `fastq trim` run | `Analyses/fastq-trim-cancelled/.lungfish-provenance.json` in this folder |
| Version 2 envelope of a failed `fastq trim` run | `Analyses/fastq-trim-failed/.lungfish-provenance.json` in this folder |
| Primitive MSA, tree and assembly records | Literal bytes in `Tests/LungfishAppTests/ProvenanceLegacyDisplayRecords.swift`, the same records `ProvenanceEnvelopeTests` decodes |
| Schema 3 `mapping-provenance.json` | Literal bytes in the same file, hand-modelled on the schema 3 golden (`Tests/Fixtures/golden/mapping/mapping-provenance.json`), values invented |

The MHC record is the released demo's file, unchanged. It was extracted with this command, where `GOLDEN` is the golden environment folder that `docs/contracts/MACHINES.md` describes.

```sh
unzip -p "$GOLDEN/cache/lge-demo-mhc-genotyping-2026.9.58.zip" \
  "MHC Genotyping.lungfish/Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json"
```

It is 33,767 bytes and names no home folder, no temporary folder and no account. It sits at its project-relative path so the test can copy it into a temporary `.lungfish` project, where its `@/` paths resolve.

The cancelled and failed records are written by hand in the layout of the version 2 encoder, and their values are invented. They follow the real cancelled record of the provenance compat corpus (`s1-cancelled-single-step`) and the schema 2 goldens. Each holds every fact, so the coverage audit finds nothing missing. The cancelled record states `status` cancelled while its last step exited 0, the case where nothing else in the record shows a problem. The failed record states `status` failed with an exit status of 1 and the tool's stderr. Both sit at their project-relative path, like the MHC record, so the test can copy each into a temporary project.

Each test copies its record into a temporary project before anything reads it. The project holds only the record, so a file the record lists inside the project is absent and reads `intermediate file, not kept`.

## Expected files

`expected/<case>.json` holds the audit status, the Run Summary, the Warnings, the Lineage, the Files and Outputs rows and the Invocation and Options rows for one case, as the Inspector's view model builds them. The Raw JSON pane is not compared here, because Phase 2.4 lane W2C changes it on purpose and pins it in its own test.

- `createdAtMilliseconds` is the instant the Run Summary dates the record. The Created text follows the Mac's time zone and locale, so the test compares the instant.
- The tree record has no `createdAt`. The reader dates it by the sidecar's modification date and reports that it invented the date, so the Run Summary reads Created Not recorded and the expected file holds no instant. The test sets that date itself, 1777777776 seconds since 1970, after it writes the file, to show that the tab does not use it.
- Every Runtime row is pinned, the Dependency Set row last. A fact the record never held reads Not recorded, because since 2.6 no reader fills one from the Mac it runs on. The workflow version of a record that carries none reads Not recorded the same way.
- The temporary project reads as `<project>`, any home folder as `<home>`, and a managed tool path as the tool's name. The bare run names its author's checkout in its recorded paths, which is why `<home>` appears in `bare-legacy-run.json`.
- The size labels come from `ByteCountFormatter` in an English locale.

`notRecorded` lists the Run Summary rows that read Not recorded instead of being left out. They are a date the reader invented and an exit status or wall time the record lacks.

A bare run or primitive record is the Older record format. Its status is `legacy` when nothing it could hold is missing, and `incomplete` when something is, with an Older record format warning after the gaps. An envelope of any version and a typed record never are.

## Reviewing a difference

When a display changes, the failure names the expected file and writes the actual one under the temporary directory. Run `diff` between the two. Replace the expected file only in a commit that says why the display changed. A test never writes into this folder.
