# Container Integration Design for Lungfish Genome Explorer

**Document ID:** DESIGN-003-CONTAINER-INTEGRATION
**Date:** 2026-02-02
**Status:** Final Design
**Author:** DevOps Engineering Team

## Executive Summary

Lungfish Genome Explorer uses Apple's native Containerization framework exclusively, requiring macOS 26 (Tahoe) or later. This provides optimal performance, native Swift API integration, and eliminates external dependencies like Docker Desktop.

---

## 1. System Requirements

| Requirement | Value |
|-------------|-------|
| **Minimum macOS** | macOS 26 (Tahoe) |
| **Architecture** | Apple Silicon (ARM64) only |
| **Container Framework** | Apple Containerization.framework |
| **External Dependencies** | None |

---

## 2. Apple Containerization Framework

### 2.1 Overview

Apple's Containerization framework (introduced in macOS 26) provides native container support with:

- **Native Swift async/await API** - First-class Swift integration
- **VM-per-container isolation** - Each container runs in its own lightweight VM
- **Sub-second startup** - Optimized for Apple Silicon
- **No daemon required** - Direct framework integration
- **Dedicated networking** - Per-container IP via vmnet

### 2.2 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Lungfish Genome Explorer                       │
│                         (AppKit UI)                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ContainerRuntimeFactory                       │
│                 (returns AppleContainerRuntime)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   AppleContainerRuntime                          │
│              (Sources/LungfishWorkflow/Engines/)                 │
│                                                                  │
│  import Containerization                                         │
│  import ContainerizationOCI                                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Linux Container (VM)                         │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  Bioinformatics Tool (e.g., BWA, samtools)                  ││
│  │  - Mounted workspace: /workspace                             ││
│  │  - Input/output via bind mounts                              ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 Swift API Usage

```swift
import Containerization
import ContainerizationOCI

@MainActor
class AppleContainerRuntime: ContainerRuntimeProtocol {

    func pullImage(reference: String) async throws -> ContainerImage {
        let registry = OCIRegistry()
        let manifest = try await registry.pull(reference: reference)
        return ContainerImage(reference: reference, manifest: manifest)
    }

    func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfiguration
    ) async throws -> Container {
        let containerConfig = Containerization.Configuration()
        containerConfig.rootFileSystem = image.rootFS
        containerConfig.memoryLimit = config.memoryLimitMB * 1024 * 1024
        containerConfig.cpuCount = config.cpuLimit

        // Add bind mounts
        for mount in config.mounts {
            containerConfig.mounts.append(
                Containerization.Mount(
                    source: mount.source,
                    destination: mount.destination,
                    readOnly: mount.readOnly
                )
            )
        }

        let container = try await Containerization.Container.create(
            name: name,
            configuration: containerConfig
        )

        return Container(id: container.id, name: name, nativeContainer: container)
    }

    func startContainer(_ container: Container) async throws {
        try await container.nativeContainer.start()
    }

    func exec(
        in container: Container,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) async throws -> ContainerProcess {
        let process = try await container.nativeContainer.exec(
            path: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        return ContainerProcess(nativeProcess: process)
    }

    func stopContainer(_ container: Container) async throws {
        try await container.nativeContainer.stop()
    }

    func removeContainer(_ container: Container) async throws {
        try await container.nativeContainer.remove()
    }
}
```

---

## 3. Bioinformatics Tool Containers

### 3.1 ARM64 Native Tools (Recommended)

These tools have native ARM64 container images from BioContainers:

| Tool | Image | Category |
|------|-------|----------|
| **BWA** | `biocontainers/bwa:0.7.17--h7132678_9` | Aligner |
| **minimap2** | `biocontainers/minimap2:2.26--he4a0461_2` | Aligner |
| **Bowtie2** | `biocontainers/bowtie2:2.5.2--py39h6fed5c7_0` | Aligner |
| **STAR** | `biocontainers/star:2.7.11a--h0c69c05_0` | RNA-Seq Aligner |
| **samtools** | `biocontainers/samtools:1.18--h50ea8bc_1` | BAM/SAM Tools |
| **bcftools** | `biocontainers/bcftools:1.18--h8b25389_0` | VCF Tools |
| **BLAST+** | `biocontainers/blast:2.14.1--pl5321h6f7f691_0` | Sequence Search |
| **bedtools** | `biocontainers/bedtools:2.31.0--h7d7f7ad_1` | Interval Tools |
| **FastQC** | `biocontainers/fastqc:0.12.1--hdfd78af_0` | QC |
| **MultiQC** | `biocontainers/multiqc:1.17--pyhdfd78af_0` | QC Aggregation |
| **MEGAHIT** | `biocontainers/megahit:1.2.9--h43eeafb_4` | Assembly |
| **Flye** | `biocontainers/flye:2.9.2--py39h6935b12_0` | Long-read Assembly |

### 3.2 x86_64-Only Tools (Rosetta 2 Required)

Some tools lack ARM64 builds and require Rosetta 2 emulation:

| Tool | Image | Notes |
|------|-------|-------|
| **SPAdes** | `biocontainers/spades:3.15.5--h95f258a_1` | Complex assembly optimizations |
| **Trinity** | `biocontainers/trinity:2.15.1--h84d9f34_0` | Transcriptome assembly |
| **Canu** | `biocontainers/canu:2.2--ha47f30e_0` | Long-read assembly |

**Performance Note:** Rosetta 2 emulation has ~3-5x overhead. For large datasets, consider ARM64 alternatives like MEGAHIT or Flye.

### 3.3 Tool Architecture Registry

```swift
struct BioinformaticsToolRegistry {

    enum ArchitectureSupport: Sendable {
        case nativeARM64           // Full ARM64 support
        case requiresRosetta       // x86_64 only, needs emulation
    }

    static let tools: [String: ArchitectureSupport] = [
        // Aligners
        "bwa": .nativeARM64,
        "minimap2": .nativeARM64,
        "bowtie2": .nativeARM64,
        "star": .nativeARM64,

        // Variant calling
        "samtools": .nativeARM64,
        "bcftools": .nativeARM64,
        "gatk": .nativeARM64,

        // Assembly
        "megahit": .nativeARM64,
        "flye": .nativeARM64,
        "spades": .requiresRosetta,
        "trinity": .requiresRosetta,
        "canu": .requiresRosetta,

        // Utilities
        "blast": .nativeARM64,
        "bedtools": .nativeARM64,
        "fastqc": .nativeARM64,
    ]

    static func requiresRosetta(_ tool: String) -> Bool {
        tools[tool.lowercased()] == .requiresRosetta
    }
}
```

---

## 4. Implementation

### 4.1 Existing Code Structure

```
Sources/LungfishWorkflow/
├── Containers/
│   ├── Container.swift              # Container model
│   ├── ContainerConfiguration.swift # Resource limits, mounts
│   ├── ContainerImage.swift         # OCI image model
│   ├── ContainerLogStreamer.swift   # Log streaming
│   └── ContainerProcess.swift       # Process execution
├── Engines/
│   ├── ContainerRuntimeProtocol.swift  # Runtime abstraction
│   ├── ContainerRuntimeFactory.swift   # Runtime selection
│   └── AppleContainerRuntime.swift     # macOS 26+ native
└── ProcessManager.swift             # Process spawning
```

### 4.2 Runtime Factory

```swift
public actor ContainerRuntimeFactory {

    public static func createRuntime() async -> (any ContainerRuntimeProtocol)? {
        // macOS 26+ required - Apple Containerization only
        guard #available(macOS 26, *) else {
            return nil
        }

        return try? await AppleContainerRuntime()
    }

    public static func isContainerizationAvailable() -> Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }
}
```

### 4.3 Container Execution Example

```swift
@MainActor
func runBWAAlignment(
    referenceGenome: URL,
    reads: URL,
    outputDir: URL
) async throws {
    guard let runtime = await ContainerRuntimeFactory.createRuntime() else {
        throw BioinformaticsError.containerizationUnavailable
    }

    // Pull the image
    let image = try await runtime.pullImage(
        reference: "biocontainers/bwa:0.7.17--h7132678_9"
    )

    // Configure container
    let config = ContainerConfiguration.bioinformaticsDefault(
        workspacePath: outputDir
    )
    config.mounts.append(
        MountBinding(source: referenceGenome.path, destination: "/reference", readOnly: true)
    )
    config.mounts.append(
        MountBinding(source: reads.path, destination: "/reads", readOnly: true)
    )

    // Create and start container
    let container = try await runtime.createContainer(
        name: "bwa-\(UUID().uuidString.prefix(8))",
        image: image,
        config: config
    )
    try await runtime.startContainer(container)

    // Execute alignment
    let process = try await runtime.exec(
        in: container,
        command: "bwa",
        arguments: [
            "mem", "-t", "\(ProcessInfo.processInfo.activeProcessorCount)",
            "/reference/genome.fa",
            "/reads/reads.fastq"
        ],
        environment: [:],
        workingDirectory: "/workspace"
    )

    try await process.start()
    let exitCode = try await process.wait()

    // Cleanup
    try await runtime.stopContainer(container)
    try await runtime.removeContainer(container)

    guard exitCode == 0 else {
        throw BioinformaticsError.toolFailed(tool: "bwa", exitCode: exitCode)
    }
}
```

---

## 5. User Experience

### 5.1 System Requirements Check

On app launch, Lungfish checks for macOS 26+:

```swift
func checkContainerizationSupport() {
    guard #available(macOS 26, *) else {
        let alert = NSAlert()
        alert.messageText = "macOS 26 Required"
        alert.informativeText = """
            Lungfish Genome Explorer requires macOS 26 (Tahoe) or later for
            container-based bioinformatics tools.

            Please update your operating system to use assembly, alignment,
            and variant calling features.
        """
        alert.alertStyle = .warning
        alert.runModal()
        return
    }
}
```

### 5.2 Rosetta 2 Warning

For x86_64-only tools:

```swift
func showRosettaWarningIfNeeded(for tool: String) -> Bool {
    guard BioinformaticsToolRegistry.requiresRosetta(tool) else { return true }

    let alert = NSAlert()
    alert.messageText = "Performance Notice"
    alert.informativeText = """
        \(tool) requires x86_64 emulation via Rosetta 2.

        Expected performance: 3-5x slower than native ARM64.

        For large datasets, consider using an ARM64-native alternative:
        • SPAdes → MEGAHIT or Flye
        • Trinity → alternate pipelines
    """
    alert.addButton(withTitle: "Continue Anyway")
    alert.addButton(withTitle: "Cancel")

    return alert.runModal() == .alertFirstButtonReturn
}
```

---

## 6. Benefits of Native Approach

| Aspect | Apple Containerization | Docker Desktop |
|--------|----------------------|----------------|
| **Performance** | Optimal (native VM) | Good (20% overhead) |
| **Resource Usage** | Minimal | 1-2 GB idle |
| **Startup Time** | Sub-second | 15-30 seconds |
| **Dependencies** | None | Docker Desktop app |
| **Licensing** | Free | Business license required |
| **Swift Integration** | Native async/await | Process() subprocess |
| **Updates** | OS updates | Separate app updates |

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-02 | Initial research with Docker fallback |
| 2.0 | 2026-02-02 | **Simplified to Apple Containerization only** |
