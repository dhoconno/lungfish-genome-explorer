# Workflow Library Import Design

## Context

Lungfish needs a Workflow Library that looks and behaves like the Plugin Manager while solving a different problem: exposing scientific workflows, not just dependency packs. Core operations should stay visible and enabled by default. Specialized workflows, including ONT Genotyping, should be optional and dependency-gated. Users also need to import their own workflows that consume Lungfish bundles and produce valid Lungfish bundles with complete provenance.

## User Experience

The beta1 Workflow Library window uses a single Library pane with Plugin-Manager-style cards. It intentionally does not expose separate `Installed` or `Runs` tabs until those surfaces have real inspect, update, removal, and run-history behavior.

- Plugin-Manager-style cards with title, category badge, description, dependency status rows, compact primary actions, progress state, and stable accessibility identifiers.
- Built-in Core workflow groups at the top. These are enabled by default and cannot be disabled.
- Optional workflow groups below Core, grouped by logical category. The first Specialized workflow is ONT Genotyping.
- Imported user workflows appear under a `User Workflows` group with runner type, input/output contract, runtime, execution status, dependency status, and stable accessibility identifiers.
- Imported Nextflow and Snakemake packages can be enabled or disabled when they declare the beta1 Workflow Operations contract and their dependencies are ready. Imported `command` packages and packages with unsupported contracts are catalog-only in beta1 and must be labeled as such instead of presented as runnable workflows.
- An `Add Workflow...` action imports a workflow package and validates it before making it available.

## Workflow Package Contract

Imported workflows use a portable `.lungfishflowpkg` directory bundle. A package contains:

- `manifest.json`, the workflow metadata and contract.
- A runner payload, such as `main.nf`, `Snakefile`, or a command/script entry point.
- Optional parameter schema for UI generation.
- Optional examples or smoke-test fixtures.
- Optional runtime lockfiles such as `environment.yml`, `conda-lock.yml`, `Dockerfile`, or pinned container image metadata.
- Optional docs and license files.

The manifest declares:

- Workflow ID, name, version, author, description, category, and maturity.
- Runner type: `nextflow`, `snakemake`, or `command`.
- Accepted Lungfish input bundle types, such as `.lungfishfastq`, `.lungfishref`, `.lungfishbam`, `.lungfishvcf`, `.lungfishmsa`, and folder/project-scoped inputs.
- Expected Lungfish output bundle types.
- Required managed plugin pack IDs, if the workflow depends on Lungfish-managed conda packs.
- Runtime environment: Docker/container image, conda environment spec, or no external runtime.
- Parameter schema with simple and advanced options.
- Output validation rules and provenance requirements.

## Runner Types

`nextflow` packages run through the existing Nextflow-capable workflow infrastructure. The package pins the workflow entrypoint, expected profile, and container/conda settings. Lungfish passes project-safe staging paths, bundle payload paths, and a provenance output path.

`snakemake` packages run through the existing Snakemake runner surface. The package declares the Snakefile, config mapping, cores/threads behavior, and optional container or conda settings.

`command` packages describe manually defined workflows like ONT Genotyping. The manifest declares a command template that invokes either Lungfish CLI subcommands or package-local scripts. Variables are restricted to validated inputs, output directories, user parameters, threads, and provenance paths.

Beta1 validates and catalogs `command` packages but does not execute them from Workflow Operations. The Library must also treat Nextflow and Snakemake packages as catalog-only unless they declare at least one required `.lungfishref` input, at least one required `.lungfishfastq` input, and at least one output. Enablement remains blocked until a dedicated command-runner execution path or broader package-contract execution path exists.

All runner types share the same input/output bundle validation and provenance policy.

## Dependency Handling

The Workflow Library checks required plugin packs before enabling a workflow. If a workflow requires missing packs, its card shows `Install Dependencies`, matching Plugin Manager behavior. For imported packages:

- Lungfish-managed dependencies use existing Plugin Manager pack installation.
- Conda runtime specs are installed into workflow-scoped managed environments, not arbitrary user environments.
- Docker/container runtimes must be pinned by digest or local build identity.
- The UI records dependency installation attempts in Operations Panel so completion and failure can be inspected.

## Safety And Validation

Import is a validation step, not an execution step. Lungfish verifies:

- The manifest schema version is supported.
- Bundle input and output types are known.
- Runner payload files exist inside the package.
- Command templates do not reference arbitrary host paths except declared inputs, output directories, and runtime-managed locations.
- Container references are pinned when they come from public registries.
- Conda specs are stored and checksummed.
- The package can write or declare complete provenance for outputs.

Invalid packages are rejected with actionable diagnostics. Warnings are allowed for missing optional docs, examples, or UI schema metadata.

## Provenance

Every run of an imported workflow writes Lungfish provenance into the output directory or output bundle. Provenance includes:

- Workflow package ID, version, manifest checksum, and runner type.
- Exact argv or reproducible command.
- User-visible options, resolved defaults, and advanced options.
- Runtime identity, including conda package specs or container image digest.
- Input and output paths, checksums, and file sizes.
- Exit status, wall time, and stderr when useful.

GUI-imported outputs must preserve or rehydrate this provenance so final `.lungfish*` bundles point at durable payloads, not staging paths.

## First Implementation Scope

The first implementation should:

- Restyle the Workflow Library to match the Plugin Manager card/list visual language.
- Group Core workflows at the top by logical category.
- Group Optional workflows below Core, starting with Specialized ONT Genotyping.
- Add user-workflow model types for `.lungfishflowpkg` manifests and runner kinds.
- Add import validation tests for Nextflow, Snakemake, and command/manual packages.
- Add checked-in three-step Hello World workflow packages for both Nextflow and Snakemake. Each package should accept one `.lungfishref` and one `.lungfishfastq` input bundle, write a valid `.lungfishref` output bundle, and be readable enough to serve as a template for lab-authored workflows.
- Add UI affordances for `Add Workflow...`, imported workflow grouping, dependency status, and enablement.

Execution of arbitrary imported command workflows can be phased in after package import, validation, and display are stable. ONT Genotyping remains the first executable Specialized workflow.

## Open Decisions

The package should eventually support signing, but the first local implementation can rely on manifest checksums and clear local-trust warnings. Remote package registries are out of scope for the first implementation.
