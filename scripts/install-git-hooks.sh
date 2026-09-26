#!/bin/bash
# install-git-hooks.sh - Install opt-in local git hooks for the developer iteration loop.
#
# Installs:
#   - a pre-push hook that first runs the unchecked-operation-start ratchet
#     (scripts/ratchets/unchecked-operation-start.sh), which fails the push if
#     a new caller passes a bundle target to the deprecated
#     OperationCenter.start(...) instead of begin(...) (see ARC-04/FEA-07 in
#     docs/reports/2026-09-23-best-practices-audit/), then checks that every
#     File/Tools/... menu entry point named in docs/user-manual/features.yaml
#     still resolves to a real MainMenu.swift title (FEA-16 in the same
#     audit; scripts/checks/features-yaml-entry-points.py), then py_compiles
#     every bundled Python resource script under Sources/*/Resources (SIMP-16
#     in the same audit; scripts/checks/compile-embedded-python.py), then
#     runs the unit tier of the full-suite gate (scripts/full-suite-gate.sh
#     --tier unit) before pushing, so the regression gate runs locally on
#     this fast Apple-Silicon Mac instead of on slow/usage-limited hosted CI.
#     A push of tags alone, on commits already on the remote's branches,
#     skips all of these checks, since those commits were checked when
#     their branch was pushed (release.py pushes its release tag this way).
#     The full tier (everything, serial) remains the stable-release gate;
#     run it explicitly with scripts/full-suite-gate.sh --tier full.
#   - a pre-commit hook that rejects new or modified files over 500 KB under
#     docs/ (docs/ is meant to stay small; large binaries belong in the
#     manual-media repo per docs/user-manual/media.lock). Override the limit
#     with LUNGFISH_DOCS_SIZE_LIMIT_KB, or bypass a specific commit with
#     `git commit --no-verify`.
#
# Run once per clone.
#
#   scripts/install-git-hooks.sh            # install
#   scripts/install-git-hooks.sh --uninstall
#
# Both hooks honor `git push --no-verify` / `git commit --no-verify` for the
# occasional intentional bypass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-path hooks)"
PRE_PUSH_HOOK="$HOOK_DIR/pre-push"
PRE_COMMIT_HOOK="$HOOK_DIR/pre-commit"

if [ "${1:-}" = "--uninstall" ]; then
    if [ -f "$PRE_PUSH_HOOK" ] && grep -q "full-suite-gate.sh" "$PRE_PUSH_HOOK" 2>/dev/null; then
        rm -f "$PRE_PUSH_HOOK"
        echo "Removed pre-push hook."
    else
        echo "No Lungfish pre-push hook to remove."
    fi
    if [ -f "$PRE_COMMIT_HOOK" ] && grep -q "LUNGFISH_DOCS_SIZE_LIMIT_KB" "$PRE_COMMIT_HOOK" 2>/dev/null; then
        rm -f "$PRE_COMMIT_HOOK"
        echo "Removed pre-commit hook."
    else
        echo "No Lungfish pre-commit hook to remove."
    fi
    exit 0
fi

mkdir -p "$HOOK_DIR"
cat > "$PRE_PUSH_HOOK" << 'HOOK_EOF'
#!/bin/bash
# Lungfish pre-push hook: run the local ratchets, then the full-suite gate,
# before pushing. Bypass intentionally with: git push --no-verify
REPO_ROOT="$(git rev-parse --show-toplevel)"

# A push of tags alone, each on a commit already on one of this remote's
# branches, adds no code the checks have not seen: that commit went through
# this hook when its branch was pushed. release.py pushes its release tag this
# way, and its time-limited push cannot wait for the unit gate. Tag deletions
# also skip. Any branch in the push, or a tag on an unpushed commit, runs
# everything.
REMOTE="$1"
TAGS_ONLY=1
SAW_REF=0
while read -r local_ref local_sha remote_ref remote_sha; do
    SAW_REF=1
    case "$remote_ref" in
        refs/tags/*) ;;
        *) TAGS_ONLY=0; continue ;;
    esac
    case "$local_sha" in
        *[!0]*) ;;
        *) continue ;;
    esac
    if ! commit="$(git rev-parse --verify --quiet "$local_sha^{commit}")"; then
        TAGS_ONLY=0
        continue
    fi
    if [ -z "$(git for-each-ref --contains "$commit" --format='x' "refs/remotes/$REMOTE/")" ]; then
        TAGS_ONLY=0
    fi
done
if [ "$SAW_REF" -eq 1 ] && [ "$TAGS_ONLY" -eq 1 ]; then
    echo "pre-push: only tags on commits already on $REMOTE; skipping checks (they ran when those commits were pushed)."
    exit 0
fi

echo "pre-push: checking the unchecked-operation-start ratchet (use --no-verify to skip)..."
if ! python3 "$REPO_ROOT/scripts/ratchets/unchecked-operation-start.sh"; then
    echo "pre-push: unchecked-operation-start ratchet FAILED — push aborted. Migrate the new caller to OperationCenter.begin(...) or use --no-verify." >&2
    exit 1
fi

echo "pre-push: checking the shared-slider-control ratchet (use --no-verify to skip)..."
if ! python3 "$REPO_ROOT/scripts/ratchets/shared-slider-control.sh"; then
    echo "pre-push: shared-slider-control ratchet FAILED — push aborted. Use NumericSliderField (LungfishKit) instead of a raw Slider, or use --no-verify." >&2
    exit 1
fi

echo "pre-push: checking features.yaml menu entry points (use --no-verify to skip)..."
if ! python3 "$REPO_ROOT/scripts/checks/features-yaml-entry-points.py"; then
    echo "pre-push: features.yaml entry-point check FAILED — push aborted. Fix docs/user-manual/features.yaml or MainMenu.swift, or use --no-verify." >&2
    exit 1
fi

echo "pre-push: compiling bundled Python resource scripts (use --no-verify to skip)..."
if ! python3 "$REPO_ROOT/scripts/checks/compile-embedded-python.py"; then
    echo "pre-push: a bundled Python resource script FAILED to compile — push aborted. Fix the script or use --no-verify." >&2
    exit 1
fi

echo "pre-push: running unit-tier gate (use --no-verify to skip)..."
if "$REPO_ROOT/scripts/full-suite-gate.sh" --tier unit; then
    exit 0
else
    echo "pre-push: unit-tier gate FAILED — push aborted. Fix tests or use --no-verify." >&2
    exit 1
fi
HOOK_EOF
chmod +x "$PRE_PUSH_HOOK"
echo "Installed pre-push hook at $PRE_PUSH_HOOK"
echo "It runs the unchecked-operation-start and shared-slider-control ratchets, the features.yaml entry-point check, the embedded-Python compile check, then scripts/full-suite-gate.sh --tier unit, before each push (bypass with: git push --no-verify)."

cat > "$PRE_COMMIT_HOOK" << 'HOOK_EOF'
#!/bin/bash
# Lungfish pre-commit hook: reject new/modified files over 500 KB under docs/.
# docs/ is meant to stay small (see docs/README.md and
# docs/reports/2026-09-23-best-practices-audit/docs-strategy.md); large
# binaries belong in the manual-media repo, pinned by docs/user-manual/media.lock.
# Override the limit with LUNGFISH_DOCS_SIZE_LIMIT_KB, or bypass a specific
# commit with: git commit --no-verify
set -eu
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIMIT_KB="${LUNGFISH_DOCS_SIZE_LIMIT_KB:-500}"
LIMIT_BYTES=$((LIMIT_KB * 1024))
FAILED=0

while IFS= read -r -d '' file; do
    case "$file" in
        docs/*) ;;
        *) continue ;;
    esac
    [ -f "$REPO_ROOT/$file" ] || continue
    size=$(wc -c < "$REPO_ROOT/$file" | tr -d ' ')
    if [ "$size" -gt "$LIMIT_BYTES" ]; then
        human=$(( (size + 1023) / 1024 ))
        echo "pre-commit: $file is ${human} KB, over the ${LIMIT_KB} KB docs/ limit." >&2
        FAILED=1
    fi
done < <(git diff --cached --name-only --diff-filter=ACMR -z)

if [ "$FAILED" -ne 0 ]; then
    echo "pre-commit: large file(s) under docs/ blocked. Move media to the manual-media" >&2
    echo "repo (docs/user-manual/media.lock), raise LUNGFISH_DOCS_SIZE_LIMIT_KB for an" >&2
    echo "intentional exception, or bypass with: git commit --no-verify" >&2
    exit 1
fi
exit 0
HOOK_EOF
chmod +x "$PRE_COMMIT_HOOK"
echo "Installed pre-commit hook at $PRE_COMMIT_HOOK"
echo "It rejects new/modified files over ${LUNGFISH_DOCS_SIZE_LIMIT_KB:-500} KB under docs/ (override with LUNGFISH_DOCS_SIZE_LIMIT_KB, bypass with: git commit --no-verify)."
