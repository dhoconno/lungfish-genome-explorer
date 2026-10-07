# External volumes

This contract says how Lungfish Genome Explorer (LGE) code must behave when a project lives on an external drive. Most external SSDs ship formatted as ExFAT, and many users keep sequencing data on them. Code that only works on the internal APFS disk is a defect, even when every test passes on the developer's Mac.

The owner set this rule on 2026-10-07 after Preview 2026.10.9 finished a Viral Recon run on an ExFAT drive and then failed to show it. `AnalysesFolder.createAnalysisDirectory` renamed its staging folder with `RENAME_EXCL`, ExFAT answered `ENOTSUP`, and the user saw the message that the batch folder "couldn't be saved in the folder Analyses". An audit the same day found the same fault in primer design and primer export, and in replacing an existing mapping viewer, MHC genotyping bundle or set of cohort alignments.

## Rules

| Rule | What it means |
|---|---|
| Assume the project is on ExFAT | Every feature, fix and refactor that touches the file system must work on ExFAT, FAT32 and SMB shares as well as APFS. Review a change with that question before merging it. |
| Fall back, never fail | When a call can answer `ENOTSUP` or `EOPNOTSUPP` on a foreign volume, the code takes a portable path that keeps the same guarantee. It never turns that answer into a failed run. |
| Rename only through `PortableRename` | Every rename with `RENAME_EXCL` or `RENAME_SWAP` goes through `PortableRename` in `Sources/LungfishCore/Storage/PortableRename.swift`. LungfishCore is the kernel, so every module can call it. No code outside it calls `renamex_np` or `renameatx_np`. |
| Ignore AppleDouble files | A listing on ExFAT holds a `._name` sidecar beside most files. Scans, counts, hashes and copies skip names that start with `._`. |
| Test the unsupported path | A change that adds or edits one of the calls in the table below adds a test that runs it as on ExFAT and checks that the result is the same. |
| The ratchet guards it | `scripts/ratchets/volume-portability.sh` runs in the pre-push hook. Raw rename calls are banned, and the other calls in the table below may only fall in number. |

## Which `PortableRename` call to use

| Need | Call | On ExFAT |
|---|---|---|
| Move a file, folder or link, never replacing an existing entry | `PortableRename.exclusive(_:to:)`, or `renameatxNP` with `RENAME_EXCL` for descriptor-relative code | Reserves the destination name, then renames over the reservation |
| Exchange two existing entries, such as a new bundle and the one it replaces | `PortableRename.swap(_:_:)`, or `renameatxNP` with `RENAME_SWAP` | Rotates the two entries through a hidden tombstone |
| Record the fallback (in provenance, say) before taking it | `nativeRenameatx`, then on `isUnsupportedExclusiveRename` call `fallbackExclusiveRename` or `fallbackSwap` | The caller decides when the fallback runs |

The URL calls throw `POSIXError` and return a `PortableRename.Mechanism`, which a caller records when its provenance names how it published.

A swap on ExFAT is not atomic. Three renames take its place, and a failed step undoes the earlier ones. A crash between the first two leaves the replaced entry under `.<name>.lungfish-swap-<UUID>`. The next swap of the same entry puts it back first, and so does opening the project, through `PortableRename.recoverInterruptedSwaps`. A tombstone beside an entry that exists holds a retired generation and is never deleted automatically.

## What differs on ExFAT

The owner's Mac measured these on a fresh ExFAT disk image on 2026-10-07. APFS supports every row.

| Behaviour | ExFAT result | What to do |
|---|---|---|
| `renamex_np` or `renameatx_np` with `RENAME_EXCL` | `ENOTSUP` | Call `PortableRename`, never the system call |
| `RENAME_SWAP` | `ENOTSUP` | Call `PortableRename`, never the system call |
| `clonefile` and `copyfile` with `COPYFILE_CLONE` | `ENOTSUP` | Use `FileManager.copyItem` or `COPYFILE_CLONE` without `COPYFILE_CLONE_FORCE`, both of which fall back to a copy |
| Hard links (`link`, `linkat`, `FileManager.linkItem`) | `ENOTSUP` | Copy the file |
| `mkfifo` | `ENOTSUP` | Put a named pipe in the system temporary directory, never in the project |
| Extended attributes | Stored in a `._name` sidecar file | Skip `._` names in every listing |
| POSIX permissions | Not stored, every entry reads as `0700` | Never rely on `chmod` for privacy or to mark a file read-only |
| Directory link count | Always 1 | Never infer a child count from `st_nlink` |
| Modification time | Rounded to 10 milliseconds | Compare times with a tolerance, or compare sizes and hashes |
| Names that differ only in case | The same file | Never create two entries whose names differ only in case |

Symbolic links, `O_EXCL` creation, `flock` and `fcntl` locks all work on a local ExFAT volume. A rename keeps an entry's inode number, within a folder, across folders and across a remount, so identity checks after a rename hold. File watching uses the foreign-volume policy in `FileSystemWatcher.StreamPolicy`.

## How to test

Unit tests run on APFS, so they run the code as if on ExFAT. Wrap the call in `PortableRename.simulatingUnsupportedFlags`, and every `PortableRename` call inside it takes its fallback. `AnalysesFolderRunRecordTests.testCreateFallsBackWhenTheVolumeRejectsExclusiveRename` in `Tests/LungfishIOTests/AnalysesFolderRunRecordTests.swift` shows the pattern. The simulation follows the current task and the calls it makes. Code on another thread or in a detached task needs an injected `PortableRename.Operations` instead.

A test that needs real ExFAT behaviour reads the `LUNGFISH_EXFAT_TEST_ROOT` environment variable and skips when it is unset. Its name contains `ExFAT`. The test script has two modes.

```bash
bash scripts/testing/exfat-tests.sh
```

This mode makes a scratch ExFAT disk image, mounts it, runs every `ExFAT` test against it and removes it afterwards.

```bash
bash scripts/testing/exfat-tests.sh --simulate
```

This mode runs every suite that renames, on the normal disk, with `LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS=1`. A Debug build then sends every `PortableRename` call down its fallback, in every thread.

Run both before merging any change that adds or edits a call in the tables above.
