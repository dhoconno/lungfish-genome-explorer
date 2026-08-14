# Managed Bracken Source Installation

**Date:** 2026-08-14
**Status:** Approved for autonomous implementation

## Problem

The Metagenomics pack pins `bioconda::bracken=1.0.0` but now requires both
`bracken` and `bracken-build`. The noarch Bracken 1.0 package contains only
the legacy abundance scripts and cannot provide `bracken-build`. Reinstalling
therefore recreates the same incomplete environment, the pack remains in
`Needs reinstall`, and SILVA/Greengenes installation fails during tool
preflight before any command executes.

Modern Bioconda Bracken builds are Linux-only. A Homebrew fallback would not
fit Lungfish's managed conda execution, offline export, readiness, or runtime
provenance contracts. Relaxing the executable check would only defer the same
failure until database installation.

## Design

Keep Bracken in its existing `~/.lungfish/conda/envs/bracken` managed
environment, but replace the impossible Bracken 1.0 package contract with a
versioned, checksum-pinned source overlay:

- install pinned conda build/runtime dependencies (`python`, `cxx-compiler`,
  and `llvm-openmp`);
- download the official Bracken v3.1 source archive and require SHA-256
  `c0a35331a8aac1e0dbb14c2a92c4de6f89f0aac540101c05c2eec54032107560`;
- reject unsafe archive entries and require the expected scripts and C++
  sources;
- compile `kmer2read_distr` with the managed compiler and OpenMP runtime;
- stage the complete overlay, then atomically replace `bin/bracken`,
  `bin/bracken-build`, and their private `bin/src` payload;
- write a managed-tool installation record containing the release version,
  source URL, source checksum, installed file checksums/sizes, commands,
  exit status, stderr, runtime identity, and wall time.

The source-overlay descriptor is part of `PackToolRequirement`, so status
evaluation can require the exact overlay record rather than treating
arbitrary executable files as valid. The overlay record participates in the
pack fingerprint and is copied automatically by the existing offline-pack
export because that workflow copies the complete environment.

Pack installation treats overlay installation as part of the requirement's
transaction. A download, checksum, extraction, compile, publication, or final
readiness failure throws and rolls back the attempted environment. The CLI and
GUI must never report installation success while the recomputed pack status is
not ready.

Database-build provenance resolves `bracken-build` from the overlay record
before consulting conda package metadata. This prevents the obsolete 1.0
package identity from appearing in new scientific provenance.

## Safety and Failure Handling

- Source identity is immutable: HTTPS URL, release version, and SHA-256 are all
  pinned in the pack definition.
- Extraction does not trust archive paths; entries that are absolute, contain
  `..`, or escape the staging root are rejected.
- Existing working tools remain untouched until compile and smoke validation
  succeed.
- Publication uses same-filesystem staged replacement with rollback on any
  failure.
- Captured stderr is bounded through the existing provenance normalization
  policy.
- The final pack verification is authoritative and failure is surfaced to the
  caller rather than converted to "verification pending."

## Test Strategy

Tests first reproduce the real contract failure: a nominal Bracken environment
without `bracken-build` cannot become ready, and an install action that leaves
the pack non-ready must throw. Source-installer unit tests use a tiny synthetic
archive and injected process runner to cover checksum rejection, unsafe paths,
compile failure, atomic publication, manifest contents, and cancellation.

A live opt-in proof installs the pinned dependencies in a temporary micromamba
root, installs the real v3.1 overlay, verifies `bracken --help`,
`bracken-build -v`, and `kmer2read_distr --help`, then exports/imports the
environment through the offline-pack service. Focused Swift tests and the
broader workflow suite run after the red-green cycle.

## Alternatives Considered

1. **Managed source overlay (selected):** works now on Apple Silicon, preserves
   conda isolation/offline export/provenance, and can later be replaced by an
   internal conda package without changing consumers.
2. **Internal macOS conda package:** ideal distribution shape, but Lungfish has
   no maintained channel/artifact today; introducing external publication is
   outside this patch.
3. **Homebrew fallback or remove `bracken-build` readiness:** host-dependent or
   functionally incomplete, and incompatible with the accepted special-database
   design.

## Acceptance Criteria

1. Reinstalling the Metagenomics pack produces runnable `bracken` and
   `bracken-build` in the managed Bracken environment.
2. The pack reports ready only after the exact v3.1 overlay record and smoke
   checks pass; otherwise installation throws and rolls back.
3. SILVA/Greengenes preflight resolves the managed `bracken-build` and records
   the source-overlay version in provenance.
4. Offline export/import preserves the installed overlay and its identity.
5. Existing scientific database-install provenance requirements remain intact.
