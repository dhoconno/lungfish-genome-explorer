#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

fixtures=(
  "Tests/Fixtures/analyses/esviritu-2026-01-15T10-00-00"
  "Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00"
  "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00"
  "Tests/Fixtures/analyses/minimap2-2026-01-15T14-00-00"
  "Tests/Fixtures/analyses/spades-2026-01-15T13-00-00"
  "Tests/Fixtures/analyses/taxtriage-2026-01-15T12-00-00"
  "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish"
)

failures=0
for fixture in "${fixtures[@]}"; do
  fixture_path="${repo_root}/${fixture}"
  sidecar_path="${fixture_path}/.lungfish-provenance.json"

  if [[ ! -d "${fixture_path}" ]]; then
    echo "missing retained fixture directory: ${fixture_path}" >&2
    failures=$((failures + 1))
    continue
  fi

  if [[ ! -f "${sidecar_path}" ]]; then
    echo "missing provenance sidecar: ${sidecar_path}" >&2
    failures=$((failures + 1))
  fi
done

if [[ "${failures}" -ne 0 ]]; then
  echo "fixture provenance audit failed: ${failures} issue(s)" >&2
  exit 1
fi

echo "fixture provenance audit passed"
