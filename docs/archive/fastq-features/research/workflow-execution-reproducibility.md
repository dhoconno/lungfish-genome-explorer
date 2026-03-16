# Workflow Execution & Reproducibility in Desktop Bioinformatics

**Research Date:** 2026-03-09
**Scope:** How desktop bioinformatics tools handle workflow execution, provenance, and reproducibility, with recommendations for Lungfish's Apple Container architecture.

---

## 1. Galaxy Project

### Workflow Formats
- **Legacy `.ga` format**: JSON-based, machine-generated, not human-readable. Encodes tool IDs, parameter states, and step connections.
- **gxformat2 (`.gxwf.yml`)**: YAML-based, human-readable/writable. Converges with CWL concepts. Supported on Galaxy 19.09+. Defines inputs, steps with tool references, and connections between them.
- **Abstract CWL export**: Galaxy can export an abstract CWL representation of any workflow for cross-platform portability.

### Provenance Tracking
Galaxy is the gold standard for desktop-accessible provenance:
- Every workflow invocation is logged with full parameter values, tool versions, input datasets, and output datasets.
- Exports provenance as **Workflow Run RO-Crate** (WRROC profile), including the executed workflow in `.ga`, `gxformat2`, and abstract CWL formats.
- Also supports **BioCompute Objects (BCO)** (IEEE 2791-2020) for clinical/regulatory provenance.
- Exports can be sent to Dropbox, Google Drive, FTP, S3, or downloaded directly.
- Galaxy's job cache (2026) explicitly records reuse of cached results in the provenance chain.

### Key Takeaway
Galaxy demonstrates that a workflow system can simultaneously support a simple internal format (`.ga`), a human-friendly format (gxformat2), and standards-compliant export (RO-Crate, CWL, BCO) without forcing users to learn any standard directly.

---

## 2. Geneious Prime

### Workflow Engine
- Built-in visual workflow designer: drag-and-drop operations into a pipeline.
- Step types: Add Operation, For Each Document, Group Documents, Group Sequences.
- Options can be preconfigured or "exposed" for runtime configuration.
- Workflows can nest (a workflow step can invoke another workflow).

### Execution Model
- All tools run **locally within the Geneious process** (Java). No external container orchestration.
- CLI mode: exported `.geneiousWorkflow` files can be invoked from command line with `-w workflow_name.geneiousWorkflow`.
- No external workflow engine integration (no Nextflow, Snakemake, CWL support).

### Provenance
- **No standards-based provenance export.** History is tracked internally per document but not exportable as RO-Crate, CWL, or similar.
- Workflows are shared via export/import of `.geneiousWorkflow` files or shared database.

### Key Takeaway
Geneious proves that a polished desktop experience does not require standards compliance. Its success comes from tight tool integration and a simple visual builder. However, reproducibility is limited to the Geneious ecosystem.

---

## 3. CLC Genomics Workbench (QIAGEN)

### Workflow Engine
- Visual workflow designer with branching, iteration, and conditional logic.
- Workflows execute locally or on CLC Genomics Server (for HPC offloading).
- Supports custom tool integration via "External Applications" framework.

### Provenance
- **Audit trail**: All edits and data processing are logged. Exportable to PDF.
- **No standards-based provenance export** (no RO-Crate, CWL, BCO).
- Workflow history is tied to the CLC data model and not portable.

### Key Takeaway
CLC's audit trail targets regulatory compliance (clinical genomics) more than scientific reproducibility. The PDF export is useful for documentation but not for computational re-execution.

---

## 4. IGV / UGENE / Benchling

### IGV (Integrative Genomics Viewer)
- **Not a workflow tool.** Purely a visualization application.
- Supports batch scripts (`-b` flag) for automated screenshot/navigation sequences.
- Batch commands: load files, navigate to loci, set track properties, save screenshots.
- No provenance, no workflow chaining, no tool execution.

### UGENE
- **Workflow Designer**: Visual pipeline builder similar to Galaxy but fully local.
- Workflows stored in a custom text format, shareable and reusable.
- Elements correspond to UGENE's integrated algorithms (BLAST, MUSCLE, etc.).
- Can create custom elements from command-line tools or scripts.
- Runs via GUI or command line.
- **No standards-based provenance.** No container support. No RO-Crate/CWL export.

### Benchling
- Cloud-based R&D platform, not a bioinformatics workflow engine.
- "Workflows" mean lab task management (ordering, ELN entries, sample tracking).
- Molecular biology tools (primer design, cloning, alignment) are built-in, not containerized.
- **Not relevant** to computational pipeline reproducibility.

---

## 5. Nextflow-in-Docker

### Official Status
Nextflow provides an official Docker image (`nextflow/nextflow`) but **actively discourages** running Nextflow inside Docker when pipeline tasks also use containers.

### Known Issues
1. **Docker-in-Docker (DinD)**: Requires `--privileged` mode, which is a major security concern. Each task container must be spawned from within the Nextflow container, requiring either DinD or Docker socket mounting.
2. **Docker Socket Mounting**: The alternative to DinD. Mount `/var/run/docker.sock` into the Nextflow container. Task containers then run as siblings on the host. But file paths inside the Nextflow container differ from host paths, causing "No such file or directory" errors for work directories.
3. **Volume Path Translation**: The fundamental problem. Nextflow writes work directories relative to its own filesystem view. When it spawns a sibling container via the host's Docker socket, the host Docker daemon interprets those paths from the host's perspective, where they don't exist.
4. **`-dockerize` flag**: Deprecated/discouraged. "Brings more issues than solutions."

### Nextflow's Recommendation
> "Nextflow is easy enough to install and Java is practically everywhere, so you should be able to run nextflow natively wherever you are."

### Implications for Apple Containers
Apple Containers are VM-per-container with virtiofs mounts. There is no Docker socket to mount. There is no DinD capability (each container is an isolated VM). **Running Nextflow inside an Apple Container and having it spawn additional Apple Containers is not possible.** The host would need to orchestrate container creation on behalf of Nextflow, which would require a custom shim.

---

## 6. Snakemake-in-Docker

### Official Status
Snakemake provides an official Docker image (`snakemake/snakemake`). Container support is primarily designed for **per-rule containers** (each rule can specify a Docker/Singularity image), not for running Snakemake itself inside a container.

### Known Issues
1. **Same DinD/socket problems as Nextflow**: If Snakemake runs inside a container and needs to spawn per-rule containers, the same path translation issues apply.
2. **Singularity preferred**: Snakemake's container integration works better with Singularity (no daemon, user-space execution), but Singularity is Linux-only.
3. **Symlink breakage**: Container boundaries break symlinks in parameters.
4. **`run:` directive limitation**: The `container:` directive for rules with `run:` blocks only affects `shell()` calls, not Python code within the `run:` block.

### Implications for Apple Containers
Same fundamental problem as Nextflow: Snakemake cannot spawn Apple Containers from inside an Apple Container. The orchestrator must run on the host.

---

## 7. Common Workflow Language (CWL)

### Adoption Trend: Stable Niche, Not Growing
- CWL occupies a **specific niche**: consortium-mandated workflows, cross-platform portability requirements, regulatory compliance.
- Nextflow dominates community mindshare (3.2k GitHub stars, nf-core ecosystem with curated pipelines).
- Snakemake is preferred by Python-centric groups.
- CWL and WDL are perceived as **verbose and less intuitive** compared to Nextflow/Snakemake.
- CWL adoption is driven by institutional mandates (GA4GH, ELIXIR, NIH), not grassroots developer preference.

### Should Lungfish Support CWL?
**Not as a primary format.** CWL's value is in portability and standards compliance. If Lungfish needs to interoperate with GA4GH/ELIXIR ecosystem, supporting CWL import (read-only) makes sense. But building a CWL execution engine is high cost for low user benefit. Galaxy's approach (export abstract CWL from internal format) is the right model.

---

## 8. RO-Crate / PROV-O

### Standards Landscape

| Standard | Purpose | Adoption |
|----------|---------|----------|
| **W3C PROV-O** | Ontology for provenance (entities, activities, agents) | Foundation layer; used by RO-Crate internally |
| **RO-Crate** | FAIR packaging of research objects (data + metadata + provenance) | Growing; adopted by Galaxy, Nextflow (nf-prov), WorkflowHub |
| **Workflow Run RO-Crate (WRROC)** | Extension of RO-Crate for workflow execution provenance | Active development; supported by Galaxy, nf-prov plugin, COMPSs |
| **BioCompute Object (BCO)** | IEEE 2791-2020; clinical/regulatory provenance for HTS pipelines | Niche; FDA-facing workflows |
| **CWLProv** | CWL-specific provenance using RO bundles | Declining; superseded by WRROC |

### RO-Crate Details
- Based on Schema.org and JSON-LD.
- A "crate" is a directory (or ZIP) with a `ro-crate-metadata.json` file.
- The metadata file describes all files in the crate, their relationships, and provenance.
- WRROC profile adds: workflow definition, input/output files, parameter values, tool versions, execution timestamps, exit codes.
- Active community with regular meetings; new use cases emerging in geoscience, bioimaging, and workflow execution (as of late 2025).

### Nextflow nf-prov Plugin
- Official Nextflow plugin for provenance.
- Supports both BCO and WRROC output formats.
- Zero pipeline modification required -- just add plugin config.
- Outputs `ro-crate-metadata.json` at end of run.

### Recommendation for Lungfish
**RO-Crate (WRROC profile) is the right provenance standard to adopt.** It is:
- The most actively developed standard.
- Supported by the two dominant workflow engines (Galaxy natively, Nextflow via plugin).
- JSON-LD based (easy to generate from Swift).
- Self-contained (crate = directory with metadata + data files).
- Compatible with WorkflowHub for sharing.

---

## 9. Synthesis: Recommendations for Lungfish

### The Core Constraint
Apple Containers are VM-per-container with no Docker daemon, no DinD, and no shared container runtime. Each container is an isolated Linux VM with virtiofs mounts for host filesystem access. This means:

1. **Workflow engines (Nextflow/Snakemake) cannot run inside Apple Containers** and spawn additional containers. The orchestrator must be on the host.
2. **Each bioinformatics tool runs in its own Apple Container**, with input/output via virtiofs-mounted directories.
3. **The host macOS process (Lungfish) is the orchestrator**, managing container lifecycle directly via `ContainerRuntimeProtocol`.

### Recommended Architecture

```
+------------------------------------------------------+
|  Lungfish macOS App (Host Orchestrator)               |
|                                                       |
|  WorkflowEngine (Swift)                               |
|    - Parses workflow definition                       |
|    - Resolves dependencies (DAG)                      |
|    - Schedules steps                                  |
|    - Records provenance (RO-Crate)                    |
|                                                       |
|  ContainerRuntimeProtocol                             |
|    - AppleContainerRuntime (primary)                  |
|    - DockerRuntime (fallback)                         |
|                                                       |
|  For each workflow step:                              |
|    1. Create Apple Container with tool image          |
|    2. Mount input dir (virtiofs, read-only)           |
|    3. Mount output dir (virtiofs, read-write)         |
|    4. Run command, capture exit code + logs           |
|    5. Record step provenance                          |
|    6. Destroy container                               |
|    7. Feed outputs to next step                       |
+------------------------------------------------------+
         |              |              |
    +---------+   +---------+   +---------+
    | VM: bwa |   | VM:     |   | VM:     |
    | (arm64) |   | samtools|   | bcftools|
    |         |   | (arm64) |   | (arm64) |
    | /input  |   | /input  |   | /input  |
    | /output |   | /output |   | /output |
    +---------+   +---------+   +---------+
```

### Workflow Definition Format

Use a **Lungfish-native JSON/YAML format** inspired by Galaxy's gxformat2:
- Human-readable YAML with step definitions, tool references, parameter schemas.
- Each step references an OCI image and a command template.
- DAG-based dependency resolution (output of step A feeds input of step B).
- Export to Nextflow/Snakemake for users who want to run on HPC (already scaffolded in `NextflowExporter.swift` and `SnakemakeExporter.swift`).
- Export to abstract CWL for standards compliance.

### Provenance Strategy

Adopt **Workflow Run RO-Crate (WRROC)** as the provenance output format:
1. After each workflow run, generate a crate directory containing:
   - `ro-crate-metadata.json` (JSON-LD with Schema.org + WRROC terms)
   - The workflow definition file
   - Input file references (or copies for small files)
   - Output file references
   - Per-step metadata: tool image digest, command, parameters, exit code, timestamps, log excerpts
2. Optionally bundle the crate as a ZIP for sharing.
3. The crate is self-documenting and can be uploaded to WorkflowHub.

### What NOT to Build

1. **Do not embed Nextflow/Snakemake inside containers.** The path translation problem is unsolvable without a custom Docker-shim layer that would be fragile and unmaintainable.
2. **Do not implement a CWL execution engine.** CWL's value is in portability, which Lungfish achieves via export. Executing CWL directly requires a full CWL runner (cwltool), which has its own container orchestration assumptions.
3. **Do not try to make Apple Containers Docker-socket-compatible.** Apple's VM-per-container model is fundamentally different from Docker's shared-kernel model. Embrace the difference.
4. **Do not build Geneious-style in-process tool execution.** Containerized tools provide reproducibility that in-process execution cannot match.

### Implementation Priority

| Priority | Component | Rationale |
|----------|-----------|-----------|
| P0 | Host-side DAG executor using existing `ContainerRuntimeProtocol` | Core capability; already have runtime infrastructure |
| P0 | Per-step virtiofs mount orchestration (input/output directories) | Required for container data flow |
| P1 | Lungfish workflow YAML format + parser | User-facing workflow definition |
| P1 | RO-Crate metadata generator (WRROC profile) | Provenance and reproducibility |
| P2 | Nextflow/Snakemake export (already scaffolded) | HPC portability |
| P2 | Visual workflow builder UI | Geneious-style drag-and-drop |
| P3 | Abstract CWL export | Standards compliance for consortia |
| P3 | WorkflowHub integration | Workflow sharing |

### Existing Lungfish Infrastructure (Already Built)

The following components in `LungfishWorkflow` already support this architecture:
- `ContainerRuntimeProtocol` + `AppleContainerRuntime` + `DockerRuntime`: full container lifecycle management
- `ContainerConfiguration`: CPU, memory, mounts, environment, command
- `UnifiedWorkflowSchema`: parameter schema parsing for Nextflow and Snakemake
- `NextflowExporter` + `SnakemakeExporter`: workflow export scaffolding
- `WorkflowGraph` + `WorkflowNode` + `WorkflowConnection`: DAG representation
- `NativeBundleBuilder` + `NativeToolRunner`: tool execution infrastructure
- `NFCoreRegistry` + `NFCorePipeline`: nf-core pipeline integration

The main gaps are:
1. A host-side DAG executor that sequences Apple Container runs based on `WorkflowGraph`
2. RO-Crate metadata generation
3. A workflow YAML format parser (distinct from Nextflow/Snakemake schema parsing)

---

## Sources

- [Galaxy RO-Crate Export Tutorial](https://training.galaxyproject.org/training-material/topics/fair/tutorials/ro-crate-in-galaxy/tutorial.html)
- [Galaxy Structured Data Exports](https://galaxyproject.org/news/2023-02-23-structured-data-exports-ro-bco/)
- [Galaxy gxformat2 Specification](https://galaxyproject.github.io/gxformat2/v19_09.html)
- [Galaxy gxformat2 GitHub](https://github.com/galaxyproject/gxformat2)
- [Geneious Prime Workflows Manual](https://manual.geneious.com/en/latest/Workflows.html)
- [Geneious CLI Documentation](https://manual.geneious.com/en/latest/CommandLineInterface.html)
- [CLC Genomics Workbench Workflows](https://resources.qiagenbioinformatics.com/manuals/clcgenomicsworkbench/current/index.php?manual=Workflows.html)
- [Nextflow in Docker Discussion #3177](https://github.com/nextflow-io/nextflow/discussions/3177)
- [Nextflow in Docker Discussion #3782](https://github.com/nextflow-io/nextflow/discussions/3782)
- [Nextflow DinD Issue #3335](https://github.com/nextflow-io/nextflow/issues/3335)
- [Nextflow -dockerize Issue #3811](https://github.com/nextflow-io/nextflow/issues/3811)
- [Snakemake Distribution & Reproducibility Docs](https://snakemake.readthedocs.io/en/stable/snakefiles/deployment.html)
- [Snakemake Docker vs Singularity Issue #846](https://github.com/snakemake/snakemake/issues/846)
- [Bioinformatics Pipeline Frameworks 2025 (Tracer)](https://www.tracer.cloud/resources/bioinformatics-pipeline-frameworks-2025)
- [Workflow Managers Compared (Excelra)](https://www.excelra.com/blogs/bioinformatics-workflow-managers/)
- [Recording Provenance with RO-Crate (PLOS ONE)](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0309210)
- [RO-Crate Official Site](https://www.researchobject.org/ro-crate/)
- [nf-prov Nextflow Plugin](https://github.com/nextflow-io/nf-prov)
- [nf-prov RO-Crate Use Case](https://www.researchobject.org/ro-crate/nf-prov)
- [New RO-Crate Use Cases (2025)](https://www.researchobject.org/ro-crate/blog/2025-10-20/new-use-cases-mate-nf-prov-ome)
- [Apple Containers Technical Comparison (The New Stack)](https://thenewstack.io/apple-containers-on-macos-a-technical-comparison-with-docker/)
- [Apple Containerization Internals (Anil Madhavapeddy)](https://anil.recoil.org/notes/apple-containerisation)
- [UGENE Workflow Designer](https://doc.ugene.net/wiki/display/UM/About+the+Workflow+Designer)
- [IGV Batch Commands](https://github.com/igvteam/igv/wiki/Batch-commands)
- [VZVirtioFileSystemDeviceConfiguration (Apple)](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration)
- [virtiofs Linux Kernel Docs](https://www.kernel.org/doc/html/latest/filesystems/virtiofs.html)
