#!/bin/bash
# lane_start.sh <full base>
#
# The guarded reset that starts a lane, continuation or fix agent in its own
# isolation worktree. Run it from that worktree as the agent's first command:
#   bash scripts/session/lane_start.sh <40 hex characters of the base commit>
#
# It refuses, and changes nothing, when
#   - the base is not 40 hex characters or not the hash of a commit of this repository,
#   - the current branch is not a worktree-agent-* branch (a detached head included),
#   - git status --short is not empty.
# Otherwise it runs git reset --hard <base> and prints the full hash of HEAD, one
# line and nothing else on stdout.
#
# Exit codes: 0 reset done and HEAD equals the base, 2 refused (one line
# "lane_start: refused: <reason>" on stderr), 1 the reset failed.
#
# Serves docs/contracts/RUNNING-A-PHASE-SESSION.md, section "Rules for the manager",
# row "Fresh worktrees" (the guarded reset). It replaces git merge --ff-only as a start.
set -u

refuse() {
    echo "lane_start: refused: $1" >&2
    exit 2
}

[ "$#" -eq 1 ] || refuse "usage: lane_start.sh <full base> (40 hex characters)"
base="$1"
printf '%s' "$base" | grep -Eq '^[0-9a-fA-F]{40}$' || refuse "the base is not 40 hex characters: $base"
base="$(printf '%s' "$base" | tr 'A-F' 'a-f')"
resolved="$(git rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null)"
[ "$resolved" = "$base" ] || refuse "the base is not the hash of a commit of this repository: $base"
branch="$(git branch --show-current 2>/dev/null)"
case "$branch" in
    worktree-agent-?*) ;;
    *) refuse "the branch is '$branch', not a worktree-agent-* branch" ;;
esac
[ -z "$(git status --short 2>/dev/null)" ] || refuse "the tree is not clean (git status --short lists changes)"

if ! git reset --hard "$base" > /dev/null; then
    echo "lane_start: git reset --hard $base failed" >&2
    exit 1
fi
head="$(git log -1 --format=%H)"
if [ "$head" != "$base" ]; then
    echo "lane_start: HEAD is $head after the reset, not the base $base" >&2
    exit 1
fi
echo "$head"
