# Kraken Index ExFAT Portability Hotfix — Plan

1. Capture the failing ExFAT behavior and verify index integrity without mutating the scientific batch.
2. Add failing tests for portable build finalization and the legacy empty-WAL immutable-read decision.
3. Implement one shared read-opening policy and checked WAL-to-DELETE build finalization.
4. Run focused tests, relevant full tests, static checks, and a read-only query against the affected batch.
5. Obtain Sol's diagnosis and code-review approval, merge the clean hotfix branch to `main`, and push.
6. Update beta28 release notes and perform the documented same-version recovery with a fresh signed, notarized DMG and increased Sparkle build number.
7. Verify GitHub, DMG checksum/signature/notarization, embedded versions, both Sparkle feeds, updater visibility, and preserve unrelated worktrees.
