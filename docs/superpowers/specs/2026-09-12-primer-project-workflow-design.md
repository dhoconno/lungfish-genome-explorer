# Project-owned primer analyses

The requested changes continue the approved primer-pack implementation in the isolated PCR worktree. GUI runs belong to the originating project and produce a named `.lungfishprimeranalysis` bundle under its Analyses directory. The dialog has no filesystem destination chooser or MHC example shortcuts. Project containment is checked against resolved filesystem paths; collisions and unsafe names fail before execution. Completion registers and opens the result in the originating project.

Extend the existing versioned custom bundle rather than introduce a competing format: retain native files, reference/input mappings, configuration and provenance. Add a deterministic vendor-neutral order CSV as a bundle artifact, with pool and primer identifiers, sequences and original alternative rows. It must not invent ordering quantities or silently collapse alternatives. The viewer groups by result and pool and surfaces primer sequences and inspection metrics. Order files remain inside the project and share the bundle integrity/provenance contract.

Expose additional supported PrimalScheme options with typed validation and explicit argv/provenance: dimer score, mispriming database, independent-scheme circular/backtracking/N handling, combined equal/entropy mode and optional amplicon limits. Preserve CPU count and terminal-gap policy. Fixed mapping to the first sequence remains necessary for existing coordinate/reference semantics. The pinned native create commands accept target size and derive integer minimum/maximum at 90%/110%; display that configured range clearly rather than imply arbitrary endpoints are supported. Experimental controls incompatible with observed-only discovery remain absent.

Verification covers project containment and symlink escape, originating-project completion, option/subcommand compatibility, order-sheet escaping and stable row retention, bundle integrity and GUI state. A refreshed Debug is produced through the standard coordinator after tests pass.

Known pinned-fork limitation: combined-panel pairing passes the configured maximum as both pairing bounds. The dialog discloses this distinction; the displayed configured interval must not be interpreted as independently enforced panel bounds. Independent scheme creation passes the configured minimum and maximum separately. Arbitrary minimum/maximum creation controls remain unavailable in this release.

## Verification

The focused suite passed 45 tests on September 12, 2026, covering project containment, option validation, publication of worksheets with distinct derivation provenance, CSV escaping/alternative retention, viewer integrity/relocation, and read-only reopening of retained native MHC analyses. Offscreen dialog and results snapshots were inspected. Logs and snapshots are retained under `.build/primer-project-*` in the isolated worktree. No biological design engine code or public fork release was changed in this revision.
