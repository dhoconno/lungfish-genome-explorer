# Demo project fixtures

This folder holds released demo project archives, committed byte for byte. Tests install them with the real `DemoProjectInstaller`, so they run on exactly what an earlier Lungfish Genome Explorer (LGE) wrote. The provenance sidecars inside were written by LGE 2026.9.58, before Phase 2.4 changed how LGE writes them. Loading such a project and reading its provenance must keep working, and it must change no byte of the project.

## Archives

| Field | Value |
|---|---|
| File | `lge-demo-mhc-genotyping-2026.9.58.zip` |
| Origin | `https://github.com/dhoconno/lungfish-genome-explorer/releases/download/demo-projects/lge-demo-mhc-genotyping-2026.9.58.zip` |
| Size | 110,747 bytes |
| SHA-256 | `f11b808067437ae3182efe31d50fc0a047857ae0a14cd20f564abd15b673fba0` |
| Catalogue entry | `mhc-genotyping` in `Sources/LungfishWorkflow/Resources/DemoProjects/demo-projects.json`, which pins the same URL, size and SHA-256 |
| Project folder | `MHC Genotyping.lungfish` |
| Entries | 84, made of 35 folders and 49 files |
| Provenance files | 27 JSON sidecars. All carry the canonical envelope keys and the eight compatibility keys. One, at the root of the annotated reference bundle, also carries an embedded `legacyWorkflowRun` |

The file is a copy of the archive that the golden genotype capture downloads and checks, which `docs/contracts/MACHINES.md` describes. It was copied after its size and SHA-256 matched the catalogue entry above. Nothing was downloaded for this commit.

## The archive is never edited

Do not unzip and rezip it, recompress it, add, remove or rename an entry, reorder entries, touch a date, or replace it with a newer release under the same name. A single changed byte breaks the SHA-256 that the catalogue, the installer and the tests all check, and it stops the file being evidence of what 2026.9.58 wrote.

A newer demo release is added as a new file beside this one, with a new row in the table above. The old file stays.

## What the archive holds that a reader should know

- Paths in the sidecars are project-relative (`@/`), or the `<workspace>` and `<tool-root>` placeholders that LGE resolves when it reads a file.
- One exception remains. The file `mhc-reference.json` of the `.lungfishmhcref` bundle and 7 sidecars inside that bundle hold literal absolute paths of the demo build's scratch folder, a folder named `lge-demo-build` in the system temporary directory of the Mac that built the demo. They name no user and no home folder. They stay as released, because the archive cannot change. Anything derived from them for a committed file spells that folder `<tmp>`.
- The only other absolute paths are the executable of the app under `/Applications` and web addresses.
- The archive holds no home folder, no account name and no per-user temporary folder. A scan of all 49 files for `/Users`, `/private`, `/var/folders` and `/home` finds nothing.
