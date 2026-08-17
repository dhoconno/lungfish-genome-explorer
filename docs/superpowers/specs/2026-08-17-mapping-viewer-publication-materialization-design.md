# Mapping Viewer Publication Materialization Design

## Problem and evidence

Both beta28 minimap2 runs completed mapping and BAM import, but failed before viewer publication. The nonduplicated-reference run at `minimap2-2026-08-17T13-55-52` has a valid BAM/index and mapping exit status 0, while its operation log ends at 99% with `invalidViewerPayloadPath("genome/sequence.fa.gz")`; no `.lungfishbam` bundle exists and `mapping-result.json` has no `viewerBundlePath`.

`MappingViewerBundlePreparer` currently creates a top-level `genome` symlink. `MappingViewerBundlePublicationService` intentionally opens every manifest-declared payload through descriptor-relative `O_NOFOLLOW` traversal, so it rejects the candidate. Candidate cleanup then removes the failed bundle.

The first materialization fix exposed a second, filesystem-specific failure in the normal mapping workflow. On writable ExFAT volume `/Volumes/AJL-T7`, mapping, BAM normalization, and summary generation complete, then `MappingViewerBundlePreparer` fails at `Preparing lightweight reference bundle...` with `NSPOSIXErrorDomain Code=17 File exists`. The destination item is absent before the copy. A direct synthetic reproduction on the same volume shows that recursive `COPYFILE_CLONE` returns `EEXIST`, leaves a partial destination directory, and omits a payload. The source tree contains ExFAT AppleDouble `._*` sidecars: clone semantics copy extended attributes, ExFAT synthesizes destination AppleDouble files for those attributes, and recursive enumeration later collides with the explicit source sidecars. A fresh retry using `COPYFILE_RECURSIVE | COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC` completes the tree.

The failed user analysis at `minimap2-2026-08-17T16-27-53` contains valid output sidecars and BAM data but no viewer bundle. This pins the failure boundary to lightweight reference materialization. Verification may read workflow metadata and structural filesystem state, but must not inspect raw scientific payload contents or alter the failed run.

After the preparer fallback was green, a fresh app-owned minimap2 run created `minimap2-2026-08-17T17-25-36` with valid BAM/result/provenance sidecars but still no viewer. An isolated full-service ExFAT regression then localized this third boundary: the real preparer and real `BAMImportService` both succeed, but the publisher's first-time root `renameatx_np(..., RENAME_EXCL)` fails with `ENOTSUP` (`Operation not supported`). A direct synthetic syscall check confirms that ExFAT rejects `RENAME_EXCL` while ordinary same-volume rename succeeds.

## Chosen design

Keep the publisher's no-follow, identity, transaction, and rollback boundaries unchanged. The preparer will materialize each manifest-referenced top-level item as a real directory/file hierarchy. It will first use macOS `copyfile` clone semantics, which attempt copy-on-write cloning and ordinarily fall back to copying when cloning is unavailable. This avoids mandatory duplicate data on APFS; the explicit recovery below covers ExFAT trees where AppleDouble collisions defeat that ordinary fallback.

For each destination item, retain `COPYFILE_RECURSIVE | COPYFILE_CLONE` as the first attempt so APFS references keep copy-on-write behavior. If and only if that attempt returns `EEXIST` after the preparer pre-cleared the exact destination item, the preparer will remove only that partially created destination and retry once with `COPYFILE_RECURSIVE | COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW_SRC`. Omitting extended-attribute copy prevents ExFAT from synthesizing AppleDouble files that collide with explicit `._*` source entries; `COPYFILE_NOFOLLOW_SRC` preserves the no-follow posture during the fallback. Any non-`EEXIST` first failure, cleanup failure, or fallback failure is surfaced without another retry.

The copy call will be injected only at an internal materialization seam so deterministic tests can return an explicit errno and inspect flags without changing the public preparer API or global process state. The production operation still calls Darwin `copyfile` and captures `errno` immediately. Tests must simulate the real partial-destination behavior, verify removal before retry, and verify the resulting payload tree rather than asserting source text.

Candidate construction remains transactional at its existing temporary candidate path. A materialization error aborts candidate preparation and is surfaced to the operation; publication never observes a partially accepted bundle. The source bundle remains the provenance origin, but every declared viewer payload and its checksummed descriptor resolves inside the final viewer bundle after atomic publication.

For the final root rename, retain the native `RENAME_SWAP` path exactly as-is for replacement publication. For first-time publication only, route `RENAME_EXCL` through the existing `PortableExclusiveRename` helper. APFS therefore retains the single native exclusive rename. If a filesystem reports only `ENOTSUP`/`EOPNOTSUPP`, the helper uses its hardened directory-reservation fallback: create the destination directory exclusively, inspect the reservation, and replace that reservation with an ordinary same-volume `renameat`. Existing-destination errors and all other failures remain failures. This is intentionally not an ExFAT emulation of `RENAME_SWAP`; replacing an existing viewer on a filesystem without swap support remains explicit and unsupported in this change.

The publication plan continues to hold the candidate root descriptor/device/inode and payload descriptors across the rename, rechecks root ownership before and after sidecar finalization, and validates payload identities while hashing. Mapping result, mapping provenance, and canonical provenance keep their existing witness-gated snapshot/rollback transaction. Those sidecar paths already use `PortableExclusiveRename`, so the narrow root delegation aligns first-time bundle publication with the repository's existing ExFAT-safe exclusive-publication primitive without creating a second fallback implementation.

## Alternatives considered

1. Relax the publisher to follow origin-scoped symlinks. Rejected: it weakens a deliberate no-follow boundary and reintroduces path-swap/escape risk during hashing and rehydration.
2. Copy only manifest-declared leaf files. Viable but more complex and risks omitting companion files or changing existing bundle semantics. Recursive top-level materialization preserves the current selection behavior.
3. Always perform byte-for-byte copies. Correct but needlessly doubles large reference storage on clone-capable filesystems.
4. Manually enumerate and copy the hierarchy. Rejected because it duplicates `copyfile` traversal and metadata behavior, expanding the security and correctness surface.
5. Always use data/stat/no-follow flags. Rejected because it would discard clone performance and ordinary metadata/xattr behavior for large APFS references when only the ExFAT collision requires that fallback.
6. Use ordinary `rename` directly after `RENAME_EXCL` returns `ENOTSUP`. Rejected because it would silently drop create-only reservation semantics and duplicate an existing hardened primitive.
7. Emulate `RENAME_SWAP` on ExFAT with a multi-rename displacement/rollback transaction. Deferred: it requires additional old/new root identity witnesses and substantially more race/rollback coverage. The observed failure is first-time publication, so broadening replacement semantics is unnecessary here.
8. Publish retries under a new unique final viewer name. Rejected for this change because it changes durable paths and leaves superseded viewers requiring a new cleanup policy.

## Verification contract

The regression must use the real `MappingViewerBundlePreparer`, real `BAMImportService`, and real `MappingViewerBundlePublicationService`. Before the production change it must fail at publication because the preparer emits a symlink. Afterward it must prove:

- every manifest-declared payload component is a real file/directory, not a symlink;
- the final manifest, reference, BAM, index, import provenance, mapping result, mapping provenance, and canonical provenance resolve at final paths;
- checksums and sizes in provenance match the final payloads;
- candidate paths are rehydrated out of BAM metadata/import provenance;
- `MappingResult.viewerBundleURL` and stored `viewerBundlePath` point to the final bundle;
- the existing publisher symlink-rejection regression continues to pass.

Focused Swift tests, relevant broader tests, a debug app build, and the strongest available deterministic/XCUI mapping path will be run. No claim of a live GUI fix will be made unless the final viewer is actually attached and readable.

The follow-up regression contract additionally requires:

- a deterministic injected-copy test where the first clone call creates a partial destination and reports `EEXIST`, the preparer removes that exact destination, and a second call succeeds with exactly the data/stat/no-follow flags;
- assertions for exactly two calls, complete payload materialization, and no retained partial marker;
- a non-`EEXIST` failure test proving the original error is rethrown without cleanup/retry;
- an isolated synthetic ExFAT run under a test-created directory on `/Volumes/AJL-T7`, with cleanup limited to that exact directory, or an equivalent documented manual command if a permanent external-volume test is unsuitable;
- focused preparer coverage, the prior real preparer/importer/publisher regression, broader relevant tests, debug and release app builds, and direct ExFAT materialization;
- a normal workflow run in the freshly built LGE app (or the strongest app-owned automation invoking the same `AppDelegate` path) on the AJL-T7 project, followed by structural validation that the final viewer bundle exists, `mapping-result.json` records its final `viewerBundlePath`, manifest/BAM/index/reference/provenance resolve and validate at final paths, and the app records its display-success event.

The root-publication follow-up additionally requires:

- a deterministic injected `ENOTSUP` regression proving first-time `RENAME_EXCL` delegates to `PortableExclusiveRename` and completes through its reservation path;
- an assertion that replacement `RENAME_SWAP` remains on the native path and receives no fallback;
- the opt-in full-service ExFAT regression using an existing read-only reference bundle and BAM beneath an isolated UUID-named test directory: real preparer, real BAM import, candidate rehydration, first-time publication, final result/provenance binding, checksums, sizes, and exact cleanup;
- another fresh app-owned AJL-T7 mapping/display run after the publisher change, because service-level success alone does not prove sidebar attachment and viewer display.

The existing failed analysis runs are immutable verification evidence. Diagnostic directories created solely for the original direct reproduction may be removed only after their evidence is no longer needed.
