#!/usr/bin/env bash
set -euo pipefail

# Verify every AppliedParagraphStyle / AppliedCharacterStyle referenced in
# generated ICML exists in style-map.yaml.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STYLE_MAP="$SCRIPT_DIR/../indesign/styles/style-map.yaml"
STORIES_DIR="$SCRIPT_DIR/../indesign/stories"

if [[ ! -f "$STYLE_MAP" ]]; then
  echo "style-map.yaml not found: $STYLE_MAP" >&2
  exit 1
fi

ALLOWED="$(mktemp)"
trap 'rm -f "$ALLOWED"' EXIT

python3 -c "
import yaml, sys
with open('$STYLE_MAP') as f:
    data = yaml.safe_load(f)
names = set()
for section in ('paragraph_styles', 'character_styles', 'object_styles'):
    names.update((data.get(section) or {}).keys())
for n in sorted(names):
    print(n)
" > "$ALLOWED"

fail=0
while IFS= read -r icml; do
  referenced="$(grep -oE 'Applied(Paragraph|Character)Style=\"[^\"]+\"' "$icml" | sed -E 's/.*="([^"]+)"/\1/' | awk -F/ '{print $NF}' | sort -u)"
  while IFS= read -r name; do
    if [[ -z "$name" ]]; then continue; fi
    if ! grep -qx "$name" "$ALLOWED"; then
      echo "$icml: unknown style '$name' (not in style-map.yaml)" >&2
      fail=1
    fi
  done <<<"$referenced"
done < <(find "$STORIES_DIR" -name '*.icml')

exit $fail
