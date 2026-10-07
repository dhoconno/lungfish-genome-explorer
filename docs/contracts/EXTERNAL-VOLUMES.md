# External volumes

This contract says how Lungfish Genome Explorer (LGE) code must behave when a project lives on an external drive. Most external SSDs ship formatted as ExFAT, and many users keep sequencing data on them. Code that only works on the internal APFS disk is a defect, even when every test passes on the developer's Mac.

The owner set this rule on 2026-10-07 after Preview 2026.10.9 finished a Viral Recon run on an ExFAT drive and then failed to show it. `AnalysesFolder.createAnalysisDirectory` renamed its staging folder with `RENAME_EXCL`, ExFAT answered `ENOTSUP`, and the user saw the message that the batch folder "couldn't be saved in the folder Analyses".

## Rules

| Rule | What it means |
|---|---|
| Assume the project is on ExFAT | Every feature, fix and refactor that touches the file system must work on ExFAT, FAT32 and SMB shares as well as APFS. Review a change with that question before merging it. |
| Fall back, never fail | When a call can answer `ENOTSUP` or `EOPNOTSUPP` on a foreign volume, the code takes a portable path that keeps the same guarantee. It never turns that answer into a failed run. |
| Use the shared helpers | Exclusive renames go through `PortableExclusiveRename` in `Sources/LungfishIO/Storage/PortableExclusiveRename.swift`. Code in LungfishCore, which cannot import LungfishIO, reserves the name with an exclusive `mkdir` and renames over the empty reservation, as `AnalysisRunRecord.beginRun` does. |
| Ignore AppleDouble files | A listing on ExFAT holds a `._name` sidecar beside most files. Scans, counts, hashes and copies skip names that start with `._`. |
| Test the unsupported path | A change that adds or edits one of the calls in the table below adds a test that makes the call fail with `ENOTSUP` and checks that the result is the same. |
| The ratchet guards it | `scripts/ratchets/volume-portability.sh` counts the raw calls in the table below. The count may only fall. |

## What differs on ExFAT

The owner's Mac measured these on a fresh ExFAT disk image on 2026-10-07. APFS supports every row.

| Behaviour | ExFAT result | What to do |
|---|---|---|
| `renamex_np` or `renameatx_np` with `RENAME_EXCL` | `ENOTSUP` | Call `PortableExclusiveRename.renameatxNP`, which reserves the name and then renames |
| `RENAME_SWAP` | `ENOTSUP` | Move the old entry aside under a unique name, rename the new one in, then remove the old one |
| `clonefile` and `copyfile` with `COPYFILE_CLONE` | `ENOTSUP` | Use `FileManager.copyItem` or `COPYFILE_CLONE` without `COPYFILE_CLONE_FORCE`, both of which fall back to a copy |
| Hard links (`link`, `linkat`, `FileManager.linkItem`) | `ENOTSUP` | Copy the file |
| `mkfifo` | `ENOTSUP` | Put a named pipe in the system temporary directory, never in the project |
| Extended attributes | Stored in a `._name` sidecar file | Skip `._` names in every listing |
| POSIX permissions | Not stored, every entry reads as `0700` | Never rely on `chmod` for privacy or to mark a file read-only |
| Directory link count | Always 1 | Never infer a child count from `st_nlink` |
| Modification time | Rounded to 10 milliseconds | Compare times with a tolerance, or compare sizes and hashes |
| Names that differ only in case | The same file | Never create two entries whose names differ only in case |

Symbolic links, `O_EXCL` creation, `flock` and `fcntl` locks all work on a local ExFAT volume. File watching uses the foreign-volume policy in `FileSystemWatcher.StreamPolicy`.

## How to test

Unit tests run on APFS, so they inject the failure. `PortableExclusiveRename.Operations` takes a `nativeRename` closure, and `AnalysesFolderRunRecordTests.testCreateFallsBackWhenTheVolumeRejectsExclusiveRename` in `Tests/LungfishIOTests/AnalysesFolderRunRecordTests.swift` shows the pattern.

A test that needs real ExFAT behaviour, such as AppleDouble sidecars, reads the `LUNGFISH_EXFAT_TEST_ROOT` environment variable and skips when it is unset. Its name contains `ExFAT`. This script makes a scratch ExFAT disk image, mounts it, runs every such test against it and removes it afterwards.

```bash
bash scripts/testing/exfat-tests.sh
```

Run it before merging any change that adds or edits a call in the table above.
