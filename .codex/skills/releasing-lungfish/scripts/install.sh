#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SKILLS_ROOT=${CODEX_SKILLS_ROOT:-"${CODEX_HOME:-$HOME/.codex}/skills"}

if [ "${1:-}" = "--skills-root" ]; then
  [ "$#" -eq 2 ] || { echo "usage: $0 [--skills-root PATH]" >&2; exit 64; }
  SKILLS_ROOT=$2
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--skills-root PATH]" >&2
  exit 64
fi

DESTINATION="$SKILLS_ROOT/releasing-lungfish"
mkdir -p "$SKILLS_ROOT"

if [ -L "$DESTINATION" ]; then
  EXISTING=$(CDPATH= cd -- "$(dirname -- "$DESTINATION")" && python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DESTINATION")
  if [ "$EXISTING" = "$SKILL_ROOT" ]; then
    echo "Release skill already installed: $DESTINATION -> $SKILL_ROOT"
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
