#!/usr/bin/env bash
# setup-worktree.sh — Post-worktree-create setup for Lungfish
#
# Symlinks gitignored binary files (JRE dylibs, etc.) from the main repo
# into a newly created worktree so that builds are fully functional.
#
# Usage:
#   scripts/setup-worktree.sh <worktree-path>
#
# Example:
#   git worktree add .claude/worktrees/my-feature feature-branch
#   scripts/setup-worktree.sh .claude/worktrees/my-feature
#
# Why this is needed:
#   *.dylib is in .gitignore (too large for git). Git worktrees only contain
#   tracked files, so the bundled JRE native libraries are absent from any
#   worktree. Without them, BBTools/Clumpify fails at runtime because the
#   java binary can't find libjli.dylib.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <worktree-path>"
    echo "  Symlinks gitignored binaries from the main repo into the worktree."
    exit 1
fi

WORKTREE="$1"

# Resolve the main repo root (the directory containing this script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d "$WORKTREE" ]; then
    echo "Error: Worktree path does not exist: $WORKTREE"
    exit 1
fi

# Resolve to absolute path
WORKTREE="$(cd "$WORKTREE" && pwd)"

echo "Setting up worktree: $WORKTREE"
echo "Main repo: $MAIN_REPO"

# ──────────────────────────────────────────────────────────────────────
# 1. JRE native libraries (*.dylib)
#    Source: Sources/LungfishWorkflow/Resources/Tools/jre/lib/
#    These are required by java binary (@rpath/libjli.dylib etc.)
# ──────────────────────────────────────────────────────────────────────

MAIN_JRE_LIB="$MAIN_REPO/Sources/LungfishWorkflow/Resources/Tools/jre/lib"
WT_JRE_LIB="$WORKTREE/Sources/LungfishWorkflow/Resources/Tools/jre/lib"

if [ -d "$MAIN_JRE_LIB" ]; then
    echo "Linking JRE dylibs..."
    mkdir -p "$WT_JRE_LIB/server"

    linked=0
    for f in "$MAIN_JRE_LIB"/*.dylib; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        if [ ! -e "$WT_JRE_LIB/$name" ]; then
            ln -s "$f" "$WT_JRE_LIB/$name"
            linked=$((linked + 1))
        fi
    done

    for f in "$MAIN_JRE_LIB/server"/*.dylib; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        if [ ! -e "$WT_JRE_LIB/server/$name" ]; then
            ln -s "$f" "$WT_JRE_LIB/server/$name"
            linked=$((linked + 1))
        fi
    done

    echo "  Linked $linked JRE dylib(s)"
else
    echo "  Warning: JRE lib directory not found in main repo, skipping"
fi

# ──────────────────────────────────────────────────────────────────────
# 2. Other gitignored binaries can be added here as needed.
#    Pattern:
#      MAIN_DIR="$MAIN_REPO/path/to/dir"
#      WT_DIR="$WORKTREE/path/to/dir"
#      mkdir -p "$WT_DIR"
#      for f in "$MAIN_DIR"/*.ext; do
#          ...ln -s...
#      done
# ──────────────────────────────────────────────────────────────────────

echo "Worktree setup complete."
