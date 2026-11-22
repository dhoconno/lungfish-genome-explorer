#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: validate-fixture.sh <fixture-dir>"
  exit 2
fi

DIR="$1"
fail=0

require_file() {
  [[ -f "$DIR/$1" ]] || { echo "MISSING: $1" >&2; fail=1; }
}

require_section() {
  grep -q "^## $1\b" "$DIR/README.md" || { echo "README.md missing section: $1" >&2; fail=1; }
}

require_file README.md
# Paired FASTQ naming (fixtures/README.md:27-33): no dot-delimited mate suffix, and every _R1 file has its _R2 twin.
while IFS= read -r f; do
  base=$(basename "$f")
  case "$base" in
    *.R1.f*q*|*.R2.f*q*|*.1.f*q*|*.2.f*q*) echo "DOT MATE SUFFIX: $f" >&2; fail=1 ;;
  esac
  case "$base" in
    *_R1*) twin="$(dirname "$f")/${base/_R1/_R2}"; [[ -f "$twin" ]] || { echo "NO R2 TWIN: $f" >&2; fail=1; } ;;
  esac
done < <(find "$DIR" -type f \( -name '*.fastq*' -o -name '*.fq*' \))

for section in Source License Citation Size "Internal consistency"; do
  require_section "$section"
done

# Size caps
TOTAL=$(du -sk "$DIR" | cut -f1)
if [[ $TOTAL -gt 51200 ]]; then
  echo "TOTAL SIZE ${TOTAL}K exceeds 50 MB cap" >&2
  fail=1
fi
while IFS= read -r f; do
  SIZE=$(wc -c <"$f")
  if [[ $SIZE -gt 10485760 ]]; then
    echo "FILE SIZE exceeds 10 MB: $f ($SIZE bytes)" >&2
    fail=1
  fi
done < <(find "$DIR" -type f ! -name "*.md" ! -name "fetch.sh")

exit $fail
