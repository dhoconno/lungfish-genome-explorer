---
title: Running in CI
chapter_id: appendices/06-running-in-ci
audience: power-user
prereqs: [01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 8
task: Run Lungfish workflows from GitHub Actions or CircleCI without a display server.
tags: [ci, headless, github-actions, circleci, conda, provenance]
tools: []
entry_points:
  - "CLI: lungfish run-headless"
shots: []
illustrations: []
glossary_refs: [provenance sidecar, conda]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish CLI workflows run without a display server. The explicit CI entry point is `lungfish run-headless <workflow>`, a discoverable alias for `lungfish workflow run --quiet <workflow>`. Use `workflow run` directly when you need the full set of workflow flags; use `run-headless` in CI scripts when the important signal is "run this workflow quietly and fail the job on error".

Every headless run writes the same provenance sidecars as the app: tool names and versions, argv, resolved options, runtime identity, input and output paths, checksums, file sizes, exit status, wall time, and useful stderr. Keep the resulting `.lungfish*` bundle or run directory as a CI artifact when the job produces scientific output.

## Cache conda packs, not live roots

CI runners are disposable, so downloading conda packages on every job is slow and fragile. Prefer an offline conda pack checked into a private release artifact or restored from CI cache, then install that pack into a job-local conda root.

Prepare the pack on a machine with network access:

```bash
lungfish conda offline-export \
  --pack classification \
  --output .ci/lungfish-conda-packs/classification
```

Install it inside CI before running workflows:

```bash
export LUNGFISH_CONDA_ROOT="$RUNNER_TEMP/lungfish-conda"
lungfish conda offline-install \
  .ci/lungfish-conda-packs/classification \
  --conda-root "$LUNGFISH_CONDA_ROOT"
lungfish run-headless workflows/classify-sample.yaml
```

The offline install and export commands take the same `<conda-root>/.install.lock` used by interactive plugin installs. If a second process is already mutating the root, Lungfish prints `waiting for conda lock held by pid <n>` and blocks until the first operation exits. On shared read-only roots, mutation commands fail with `conda root is read-only; reinstall as the admin user`.

## GitHub Actions

This example restores cached offline packs, installs them into a per-job root, runs the workflow, and keeps both the scientific output and provenance as artifacts.

```yaml
name: lungfish-headless

on:
  pull_request:
  workflow_dispatch:

jobs:
  workflow:
    runs-on: macos-26
    env:
      LUNGFISH_CONDA_ROOT: ${{ runner.temp }}/lungfish-conda

    steps:
      - uses: actions/checkout@v4

      - name: Restore Lungfish offline packs
        uses: actions/cache@v4
        with:
          path: .ci/lungfish-conda-packs
          key: lungfish-conda-packs-${{ hashFiles('.ci/lungfish-conda-packs/**') }}

      - name: Install cached conda pack
        run: |
          lungfish conda offline-install \
            .ci/lungfish-conda-packs/classification \
            --conda-root "$LUNGFISH_CONDA_ROOT"

      - name: Run Lungfish workflow
        run: lungfish run-headless workflows/classify-sample.yaml

      - name: Upload Lungfish outputs
        uses: actions/upload-artifact@v4
        with:
          name: lungfish-outputs
          path: |
            outputs/
            **/*.lungfish-provenance.json
```

## CircleCI

CircleCI uses separate `restore_cache` and `save_cache` steps. The pattern is otherwise the same: restore offline packs, install into a writable job-local root, run the headless workflow, and store outputs.

```yaml
version: 2.1

jobs:
  lungfish-workflow:
    macos:
      xcode: "26.0.0"
    environment:
      LUNGFISH_CONDA_ROOT: /tmp/lungfish-conda
    steps:
      - checkout

      - restore_cache:
          keys:
            - lungfish-conda-packs-{{ checksum ".ci/lungfish-conda-packs/manifest.json" }}
            - lungfish-conda-packs-

      - run:
          name: Install cached conda pack
          command: |
            lungfish conda offline-install \
              .ci/lungfish-conda-packs/classification \
              --conda-root "$LUNGFISH_CONDA_ROOT"

      - run:
          name: Run Lungfish workflow
          command: lungfish run-headless workflows/classify-sample.yaml

      - save_cache:
          key: lungfish-conda-packs-{{ checksum ".ci/lungfish-conda-packs/manifest.json" }}
          paths:
            - .ci/lungfish-conda-packs

      - store_artifacts:
          path: outputs
          destination: lungfish-outputs
```

Do not cache a mutable live conda root across CI jobs unless the cache is restored read-only and managed by an admin process. Cached roots are easy to corrupt when multiple jobs update them at once; offline packs are portable artifacts with their own provenance.
