#!/usr/bin/env bash
# Re-downloads source data for the sarscov2-clinical fixture.
# Run from this directory. No-op if files are already present.
set -euo pipefail
echo "Fixture files are committed in this repository."
echo "If a file is missing, restore from git or re-derive following the README."
