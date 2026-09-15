# Local build retention and installed dependencies

Local cleanup is explicit maintenance. Packaging and publication never prune
candidate or recovery evidence automatically.

## Retain recent builds

Run from the repository, choosing a new report filename for every invocation:

```sh
python3 scripts/local-retention.py --keep 2 --report /tmp/lungfish-retention-plan.json
python3 scripts/local-retention.py --keep 2 --apply --report /tmp/lungfish-retention-applied.json
```

The default retains the two highest build numbers in each channel. It removes
only recognized app/archive/DMG payloads from older receipted candidates.
Receipts, logs, signing journals, gate evidence, unknown files and scientific
outputs remain. Unreceipted candidates and unfinished signing transactions are
held for investigation. An accepted notarization also requires a published
release of the same channel and an exact remote tag/commit match. Read-only
GitHub access through `gh` and Git is required; the command never publishes.

The command rejects active compiler processes, tracked files and open target
files, and rechecks each payload's metadata tree before deleting it. Its report
records exact paths, allocated size, metadata hashes, deletion outcomes and
remote publication proof. Allocated bytes removed are not a promise of physical
free space: APFS clones and snapshots can retain blocks. Run during an idle build
window; a detected compiler aborts remaining deletions, and a later invocation
can continue with a new report.

Do not delete `.build` or `build` wholesale. They can contain rescue snapshots,
modified dependency checkouts, scientific fixtures and recovery transactions.
Compiler-cache cleanup requires a separate inventory and open-file check.

## App installation and dependency roots

The canonical upstream installed names are `Lungfish.app`,
`Lungfish Preview.app` and `Lungfish Debug.app` in `/Applications`. The Debug
coordinator already reuses `build/Debug/Lungfish Debug.app`; avoid timestamped
installed wrappers or accumulating `previous-installed` copies. Verify source
and copied bundle identity/signature before removing an obsolete backup, and
do not replace a running app. Release apps retain their original signed bytes.

The updated source assigns Stable to `~/.lungfish-stable`, configured by
`~/.config/lungfish-stable/storage-location.json`. It does not silently adopt
the old shared config or database preference. Preview retains `~/.lungfish`
and `~/.config/lungfish/storage-location.json`. Debug automatically borrows
Preview's root only when installed manifests and the dependency receipt are
compatible; explicit Debug configuration or incompatibility keeps its separate
`~/.lungfish-debug` root. Every GUI channel passes its resolved storage and
conda roots to CLI children. Fork namespaces and explicit overrides remain
supported. No existing dependency data is moved or deleted by this change.

This policy requires binaries built from the updated source. Stable 2026.9.4
uses the historical shared config, and its GUI launches CLI children without
storage overrides. A GUI preference alone cannot guarantee its isolation.
Rebuilding/installing a properly signed fixed Stable app is required; editing
its signed plist, symlinking dependency roots, or adding a launcher wrapper is
not part of this cleanup.
