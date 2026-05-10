#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

python3 "$(dirname "${BASH_SOURCE[0]}")/fixture_provenance.py" --root "${repo_root}"
