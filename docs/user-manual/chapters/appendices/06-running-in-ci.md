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

Lungfish CLI workflows run without a display server. The explicit CI entry point is `lungfish run-headless <workflow>`, a discoverable alias for `lungfish workflow run --quiet <workflow>`. Reach for `workflow run` directly when you need the full set of workflow flags. Reach for `run-headless` in a CI script when all you want is "run this workflow quietly and fail the job on error".

Every headless run writes the same provenance sidecars the app does: the tool names and versions, the argv, the resolved options, the runtime identity, the input and output paths, the checksums, the file sizes, the exit status, the wall time, and useful stderr. When the job produces scientific output, keep the resulting `.lungfish*` bundle or run directory as a CI artifact.

## Cache conda packs, not live roots

CI runners are disposable, so re-downloading conda packages on every job is both slow and fragile. Better to keep an offline conda pack, either checked into a private release artifact or restored from CI cache, and install that pack into a job-local conda root.

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

The offline install and export commands take the same `<conda-root>/.install.lock` that interactive plugin installs use. If a second process is already mutating the root, Lungfish prints `waiting for conda lock held by pid <n>` and blocks until the first operation exits. On a shared read-only root, a mutation command fails with `conda root is read-only; reinstall as the admin user`.

## GitHub Actions

This example restores the cached offline packs, installs them into a per-job root, runs the workflow, and keeps both the scientific output and the provenance as artifacts.

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

CircleCI splits the work into separate `restore_cache` and `save_cache` steps. The pattern is otherwise identical: restore the offline packs, install into a writable job-local root, run the headless workflow, and store the outputs.

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

Do not cache a mutable live conda root across CI jobs unless the cache is restored read-only and managed by an admin process. A shared root is easy to corrupt when several jobs update it at once. Offline packs sidestep the problem: they are portable artifacts that carry their own provenance.
