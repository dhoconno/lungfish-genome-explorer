#!/bin/bash
# install-git-hooks.sh - Install opt-in local git hooks for the developer iteration loop.
#
# Installs a pre-push hook that runs the unit tier of the full-suite gate
# (scripts/full-suite-gate.sh --tier unit) before pushing, so the regression gate
# runs locally on this fast Apple-Silicon Mac instead of on slow/usage-limited
# hosted CI. Run once per clone. The full tier (everything, serial) remains the
# stable-release gate; run it explicitly with scripts/full-suite-gate.sh --tier full.
#
#   scripts/install-git-hooks.sh            # install
#   scripts/install-git-hooks.sh --uninstall
#
# The hook honors `git push --no-verify` for the occasional intentional bypass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK_DIR="$(git -C "$PROJECT_ROOT" rev-parse --git-path hooks)"
HOOK="$HOOK_DIR/pre-push"

if [ "${1:-}" = "--uninstall" ]; then
    if [ -f "$HOOK" ] && grep -q "full-suite-gate.sh" "$HOOK" 2>/dev/null; then
        rm -f "$HOOK"
        echo "Removed pre-push hook."
    else
        echo "No Lungfish pre-push hook to remove."
    fi
    exit 0
fi

mkdir -p "$HOOK_DIR"
cat > "$HOOK" << 'HOOK_EOF'
#!/bin/bash
# Lungfish pre-push hook: run the full-suite gate locally before pushing.
# Bypass intentionally with: git push --no-verify
REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "pre-push: running unit-tier gate (use --no-verify to skip)..."
if "$REPO_ROOT/scripts/full-suite-gate.sh" --tier unit; then
    exit 0
else
    echo "pre-push: unit-tier gate FAILED — push aborted. Fix tests or use --no-verify." >&2
    exit 1
fi
HOOK_EOF
chmod +x "$HOOK"
echo "Installed pre-push hook at $HOOK"
echo "It runs scripts/full-suite-gate.sh --tier unit before each push (bypass with: git push --no-verify)."
