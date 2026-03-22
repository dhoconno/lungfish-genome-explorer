# Conda Plugin System — Experimental Findings (2026-03-22)

## Micromamba Binary
- **Source**: `https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-osx-arm64`
- **Version**: 2.5.0
- **Size**: 14 MB standalone binary
- **Architecture**: Mach-O 64-bit arm64
- **Dependencies**: None (statically linked)
- **Verified**: Works on macOS 26 arm64

## Storage Location
- Tested: `~/Library/Application Support/Lungfish/conda/`
- Works correctly with `MAMBA_ROOT_PREFIX` env var
- Environments stored in `$MAMBA_ROOT_PREFIX/envs/<name>/`

## Environment Tests

### samtools (C binary, native macOS arm64)
- **Install**: `micromamba create -n test-env -c bioconda -c conda-forge samtools --yes`
- **Version**: samtools 1.23.1 / htslib 1.23.1
- **Size**: 20 MB
- **Status**: WORKS perfectly

### pbaa (PacBio tool)
- **Install**: Succeeded but binary is Linux x86-64 ELF
- **Architecture**: `ELF 64-bit LSB executable, x86-64, version 1 (GNU/Linux)`
- **Status**: CANNOT execute natively on macOS arm64
- **All builds**: `noarch` on bioconda — contains Linux binary
- **Resolution**: Must use Apple Container runtime with Rosetta for Linux-only tools

### freyja (Python-based, native macOS arm64)
- **Install**: `micromamba create -n freyja-env -c bioconda -c conda-forge freyja --yes`
- **Version**: freyja 2.0.3
- **Size**: 1.3 GB (Python + numpy + scipy + samtools + minimap2 + usher + etc.)
- **Status**: WORKS perfectly, native arm64

## Key Architectural Findings

### 1. Per-tool environments are necessary
- Freyja (1.3 GB) vs samtools (20 MB) — wildly different sizes
- Dependency conflicts between Python-heavy and C-only tools
- `micromamba run -n <env> <tool>` cleanly isolates execution

### 2. Linux-only tools need container fallback
- Some bioconda packages only have Linux builds (pbaa, some legacy tools)
- App already has AppleContainerRuntime with Rosetta for amd64
- Architecture: try native conda first → fall back to container if Linux-only

### 3. Micromamba invocation pattern
```
MAMBA_ROOT_PREFIX=~/Library/Application Support/Lungfish/conda \
  micromamba run -n <env-name> <tool> [args...]
```

### 4. Channel priority
Always specify: `-c bioconda -c conda-forge`
bioconda requires conda-forge as a dependency channel.
```
