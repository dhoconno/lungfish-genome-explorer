# Refactoring verifiers

These scripts check that a structural change kept every line of behaviour. Phase 1 of the architecture program (docs/plans/2026-10-02-architecture-program.md) used them on every pure move and comment-only commit, and later phases should too.

| Script | What it checks |
|---|---|
| `verify_pure_move.py <repo> <base> <head>` | The Swift lines removed and added over the range match as multisets, ignoring imports, `// MARK:` lines and the header comment of a new file. Prints PURE-MOVE OK or the lines that differ. A copied file-private `Logger` line is reported as INFO. |
| `verify_comment_only.py <repo> <base> <head>` | Every modified Swift, Python or shell file changes only comments (and Python docstrings). Added, deleted and renamed files are listed for a reviewer to read. |
| `type_census.py <repo> [--min-lines 800]` | Lists Swift files over the limit that hold more than one top-level type, marking each file that a test reads as source text. |
| `type_spans.py <repo> <census.tsv>` | For each movable file in a census, how many lines its secondary types would take out of it. |

Run a verifier on each commit of a move lane, for example `python3 scripts/refactoring/verify_pure_move.py . HEAD~1 HEAD`. A move that needs an access-level change is not a pure move and belongs in its own reviewed commit.
