#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SKILLS_ROOT=${CODEX_SKILLS_ROOT:-"${CODEX_HOME:-$HOME/.codex}/skills"}

REPLACE_MANAGED_LINK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skills-root)
      [ "$#" -ge 2 ] || { echo "usage: $0 [--skills-root PATH] [--replace-managed-link]" >&2; exit 64; }
      SKILLS_ROOT=$2
      shift 2
      ;;
    --replace-managed-link)
      REPLACE_MANAGED_LINK=1
      shift
      ;;
    *)
      echo "usage: $0 [--skills-root PATH] [--replace-managed-link]" >&2
      exit 64
      ;;
  esac
done

DESTINATION="$SKILLS_ROOT/releasing-lungfish"
mkdir -p "$SKILLS_ROOT"

if [ -L "$DESTINATION" ]; then
  EXISTING=$(CDPATH= cd -- "$(dirname -- "$DESTINATION")" && python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DESTINATION")
  if [ "$EXISTING" = "$SKILL_ROOT" ]; then
    echo "Release skill already installed: $DESTINATION -> $SKILL_ROOT"
    exit 0
  fi
  if [ "$REPLACE_MANAGED_LINK" -eq 1 ] \
      && [ -f "$EXISTING/SKILL.md" ] \
      && grep -q '^name: releasing-lungfish$' "$EXISTING/SKILL.md"; then
    unlink "$DESTINATION"
    ln -s "$SKILL_ROOT" "$DESTINATION"
    echo "Relinked managed release skill: $DESTINATION -> $SKILL_ROOT"
    exit 0
  fi
  echo "Refusing to replace unrelated symlink: $DESTINATION -> $EXISTING" >&2
  exit 1
fi

if [ -e "$DESTINATION" ]; then
  echo "Refusing to replace existing path: $DESTINATION" >&2
  exit 1
fi

ln -s "$SKILL_ROOT" "$DESTINATION"
echo "Installed release skill: $DESTINATION -> $SKILL_ROOT"
