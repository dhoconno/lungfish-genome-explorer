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

A swap on ExFAT is not atomic. Three renames take its place, and a failed step undoes the earlier ones. A crash between the first two leaves the replaced entry under `.<name>.lungfish-swap-<UUID>`. The next swap of the same entry puts it back first when the entry is missing. Opening the project runs `PortableRename.recoverInterruptedSwaps`, and there an entry that is missing, or holds only the empty file an interrupted rename reserved it with, takes its newest tombstone that holds bytes. A read runs no recovery. Any other tombstone beside an entry that exists holds a retired generation and is never deleted automatically.

## Replacing a file durably

A record that a later run rewrites, such as a provenance record, goes through `DurableReplace` in `Sources/LungfishCore/Storage/DurableReplace.swift`. The name holds a complete old or new file at every step, and the new bytes are durable before the old ones go.

| Step | What happens | On ExFAT |
|---|---|---|
| Stage | The bytes go to `.<name>.lungfish-stage-<UUID>`, created with `O_EXCL` and `O_NOFOLLOW` on the folder's descriptor, and `fsync` syncs them | The same |
| Swap | The stage and the old file change places through `PortableRename`, so the name never empties and the old file keeps its inode under the stage name | Three renames through a tombstone, each one reserving its destination with an empty file first |
| Sync | `fsync` syncs the folder and the observer sees the swap. A refusal swaps the old file back | The same, through the rotation |
| Retire | The old copy under the stage name is unlinked | The same |
| Flush | One `F_FULLFSYNC` per volume ends the transaction, or `fsync` when a volume refuses it | Accepted |

`DurableReplace.transaction` groups many publications under one flush, so a bundle that writes 101 records flushes the drive once. `ProvenanceWriter` writes rewrites, signed writes and observed writes this way. A first write that replaces nothing keeps `DurableAtomicFileStore.create`, which never replaces a file, and joins the same flush.

Five other record writers publish through `DurableReplace` too. Each file goes out in one call that names the file and its folder, so its name holds a complete old or new file at every step and a failed call removes its stage file.

- `BundleManifest.save(to:)` in `Sources/LungfishCore/Bundles/BundleManifest.swift` publishes `manifest.json`.
- `AnalysesFolder.writeAnalysisMetadata(_:to:)` in `Sources/LungfishIO/Bundles/AnalysesFolder.swift` publishes `analysis-metadata.json`.
- `DependencyReceiptStore.save(_:)` in `Sources/LungfishWorkflow/Dependencies/DependencyReceiptStore.swift` publishes `dependency-receipt.json`.
- `MappingProvenance.save(toFile:)` in `Sources/LungfishWorkflow/Mapping/MappingProvenance+TrackRecord.swift` publishes a mapping record, `MappingProvenance.save(to:)` in `Sources/LungfishWorkflow/Mapping/MappingProvenance.swift` publishes `mapping-provenance.json` through it, and `bam adopt-mapping` publishes an adopted track's `<bam stem>.mapping-provenance.json` the same way.
- `GenotypeAnnotationPublicationCoordinator` in `Sources/LungfishIO/Bundles/GenotypeAnnotationPublicationCoordinator.swift` publishes `annotations.json` and its provenance record inside one transaction and rolls both back when either fails.

The genotype coordinator also restores a name that an interrupted ExFAT swap emptied before it reads its snapshot, so an edit is never built from nothing. `DurableReplace` never replaces a link, so the coordinator first turns a link that the earlier generation-based annotation store left under either name into a file that holds the same bytes.

Before it stages, a publication restores a name that holds nothing from its newest leftover that holds bytes. A leftover is a `.lungfish-swap-` tombstone or an aside the caller names, such as the `.<name>.provenance-displaced-<UUID>` copy that earlier releases left when a rewrite stopped halfway. An empty file under the name beside such a leftover is the reservation of a rename that never ran, and it gives way to the leftover. A caller whose observer saw the name empty passes `Recovery.none`, so the observer's receipt still holds. `DurableReplace.recover` runs the same restore on its own. Inside a project, opening the project restores an entry an empty reservation holds before anything reads it. Outside a project the next write of the record restores it, because a read runs no recovery. A writer that reads its file before it rewrites it, such as the dependency receipt and the genotype pair, restores the name first.

## Opening a folder without following links

A durable writer opens its folder with `NoFollowFileSystem.openDirectoryHierarchy` in LungfishCore. Inside a project or bundle the walk starts at the outermost `.lungfish*` folder. It follows links above that folder and refuses a link below it. Outside every project and bundle the folder itself is the anchor, so a conda root under a storage folder that moved to an external drive and was linked back still opens. A folder that is itself a link is refused in both cases, except `/tmp` and `/var`, the links macOS installs, which open through `/private`.

`DurableReplace` publishes provenance records into the folder a command writes to, so it opens that folder with `NoFollowFileSystem.openDestinationFolder` instead. The five record writers above open their folders the same way, so a link below a `.lungfish*` anchor is refused for them too, and a storage folder outside every project may be a link. Inside a project or bundle the two opens agree. Outside every project and bundle the destination may itself be a link, such as an output folder the user reaches through one, and it opens as the real folder it names. The first write that keeps `DurableAtomicFileStore.create` still opens with `openDirectoryHierarchy`, so it refuses such a destination. A folder outside every project opens by its full path, so a link above it, or a record destination that is a link, may lead into a project and through that project's links. The threat model accepts both, and no LGE writer reaches a project that way.

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
| Inode number of a file | A written file takes the number of its first cluster, which every rename keeps. An empty file gets a number near the top of the range, which changes on every rename | Read a new file's identity after its bytes land, and match empty files by size |
| `F_FULLFSYNC` | Accepted on files and folders | Flush once per transaction |

The last two rows were measured on the ExFAT driver of macOS 26 on 2026-10-10. Symbolic links, `O_EXCL` creation, `flock` and `fcntl` locks all work on a local ExFAT volume. A rename keeps a written file's inode number, within a folder, across folders and across a remount, so identity checks after a rename hold. `F_GETPATH` on a folder descriptor opened with `O_EVTONLY` names the folder's new path after the folder is renamed inside its parent folder, so `ProjectStoreWriterLease` finds its lock in a renamed project folder. That was measured on macOS 26 on 2026-10-16 by `ProjectStoreWriterLeaseTests.testReleasedLeaseRemovesItsLockAfterAMoveOnExFAT`, and a move to a different parent folder was not measured. File watching uses the foreign-volume policy in `FileSystemWatcher.StreamPolicy`.

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

This mode runs every suite that renames, on the normal disk, with `LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS=1`. A Debug build then sends every `PortableRename` call down its fallback, in every thread. A suite whose name holds `Durability` runs in this mode too, so name the tests of a writer that replaces files through `DurableReplace` that way.

`ProvenanceWriterDurabilityTests` holds the fault matrix. It fails one step of a write, or ends a child test process right after it, at every step `DurableReplace` and `PortableRename` take. After each fault the record's name must hold the old or the new record, before any recovery on APFS and after recovery on ExFAT, and the sidecar finder must return that record. The same matrix runs on the disk image in the first mode.

The five record writers above each have a class that counts one publication through the same seam, fails each step and each rename of a rewrite in turn, and checks the name afterwards. They are `BundleManifestDurabilityTests`, `AnalysesFolderDurabilityTests`, `DependencyReceiptStoreDurabilityTests`, `MappingProvenanceDurabilityTests` and `GenotypeAnnotationPublicationDurabilityTests`. Each one runs the matrix on the disk image too, in a test with `ExFAT` in its name.

Run both before merging any change that adds or edits a call in the tables above.
