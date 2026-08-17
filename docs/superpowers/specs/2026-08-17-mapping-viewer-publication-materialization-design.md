# Mapping Viewer Publication Materialization Design

## Problem and evidence

Both beta28 minimap2 runs completed mapping and BAM import, but failed before viewer publication. The nonduplicated-reference run at `minimap2-2026-08-17T13-55-52` has a valid BAM/index and mapping exit status 0, while its operation log ends at 99% with `invalidViewerPayloadPath("genome/sequence.fa.gz")`; no `.lungfishbam` bundle exists and `mapping-result.json` has no `viewerBundlePath`.

`MappingViewerBundlePreparer` currently creates a top-level `genome` symlink. `MappingViewerBundlePublicationService` intentionally opens every manifest-declared payload through descriptor-relative `O_NOFOLLOW` traversal, so it rejects the candidate. Candidate cleanup then removes the failed bundle.

## Chosen design

Keep the publisher's no-follow security boundary unchanged. The preparer will materialize each manifest-referenced top-level item as a real directory/file hierarchy. It will use macOS `copyfile` clone semantics, which attempt copy-on-write cloning and fall back to ordinary copying when cloning is unavailable (including cross-volume and non-cloning filesystems). This avoids mandatory duplicate data on APFS while preserving correctness on ExFAT and other filesystems.

Candidate construction remains transactional at its existing temporary candidate path. A materialization error aborts candidate preparation and is surfaced to the operation; publication never observes a partially accepted bundle. The source bundle remains the provenance origin, but every declared viewer payload and its checksummed descriptor resolves inside the final viewer bundle after atomic publication.

## Alternatives considered

1. Relax the publisher to follow origin-scoped symlinks. Rejected: it weakens a deliberate no-follow boundary and reintroduces path-swap/escape risk during hashing and rehydration.
2. Copy only manifest-declared leaf files. Viable but more complex and risks omitting companion files or changing existing bundle semantics. Recursive top-level materialization preserves the current selection behavior.
3. Always perform byte-for-byte copies. Correct but needlessly doubles large reference storage on clone-capable filesystems.

## Verification contract

The regression must use the real `MappingViewerBundlePreparer`, real `BAMImportService`, and real `MappingViewerBundlePublicationService`. Before the production change it must fail at publication because the preparer emits a symlink. Afterward it must prove:

- every manifest-declared payload component is a real file/directory, not a symlink;
- the final manifest, reference, BAM, index, import provenance, mapping result, mapping provenance, and canonical provenance resolve at final paths;
- checksums and sizes in provenance match the final payloads;
- candidate paths are rehydrated out of BAM metadata/import provenance;
- `MappingResult.viewerBundleURL` and stored `viewerBundlePath` point to the final bundle;
- the existing publisher symlink-rejection regression continues to pass.

Focused Swift tests, relevant broader tests, a debug app build, and the strongest available deterministic/XCUI mapping path will be run. No claim of a live GUI fix will be made unless the final viewer is actually attached and readable.
