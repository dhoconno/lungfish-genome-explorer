// NativeTool.swift - The native bioinformatics tools and where each one is found
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - NativeToolLocation

public enum NativeToolLocation: Sendable, Hashable {
    case bundled(relativePath: String)
    case managed(environment: String, executableName: String)
}


// MARK: - NativeTool

/// Represents a native bioinformatics tool required by the app.
///
/// Most active tools are resolved from managed environments under
/// `~/.lungfish/conda/envs`. Only the bundled bootstrap/resource subset remains
/// under the app's `Resources/Tools` directory.
public enum NativeTool: String, CaseIterable, Sendable {
    case samtools
    case bcftools
    case bgzip
    case tabix
    case bedGraphToBigWig
    case pigz
    case seqkit
    case fastp
    case vsearch
    case blastn
    case cutadapt
    case trimGalore
    case ribodetector
    case clumpify
    case bbduk
    case bbmerge
    case repair
    case tadpole
    case reformat
    case bbmap
    case mapPacBio
    // SRA toolkit
    case fasterqDump
    case prefetch
    // Deacon human-read scrubber (conda-installed, not bundled)
    case deacon
    case lofreq
    case ivar
    case medaka
    /// medaka's `medaka_variant` wrapper: haploid variant calling in
    /// medaka 2.x, which dropped the `medaka variant` subcommand.
    case medakaVariant
    case clair3
    case whatshap
    case freyja
    /// zstd and xz, the compressors a sequence export and a reference import run (Phase 2.13 lane 13.17).
    case zstd
    case xz

    /// The executable name for this tool.
    public var executableName: String {
        switch self {
        case .samtools: return "samtools"
        case .bcftools: return "bcftools"
        case .bgzip: return "bgzip"
        case .tabix: return "tabix"
        case .bedGraphToBigWig: return "bedGraphToBigWig"
        case .pigz: return "pigz"
        case .seqkit: return "seqkit"
        case .fastp: return "fastp"
        case .vsearch: return "vsearch"
        case .blastn: return "blastn"
        case .cutadapt: return "cutadapt"
        case .trimGalore: return "trim_galore"
        case .ribodetector: return "ribodetector_cpu"
        case .clumpify: return "clumpify.sh"
        case .bbduk: return "bbduk.sh"
        case .bbmerge: return "bbmerge.sh"
        case .repair: return "repair.sh"
        case .tadpole: return "tadpole.sh"
        case .reformat: return "reformat.sh"
        case .bbmap: return "bbmap.sh"
        case .mapPacBio: return "mapPacBio.sh"
        case .fasterqDump: return "fasterq-dump"
        case .prefetch: return "prefetch"
        case .deacon: return "deacon"
        case .lofreq: return "lofreq"
        case .ivar: return "ivar"
        case .medaka: return "medaka"
        case .medakaVariant: return "medaka_variant"
        case .clair3: return "run_clair3.sh"
        case .whatshap: return "whatshap"
        case .freyja: return "freyja"
        case .zstd: return "zstd"
        case .xz: return "xz"
        }
    }

    /// Arguments that make this tool print its version and exit 0.
    ///
    /// Most tools accept `--version`, but a few (notably iVar) reject that and
    /// print usage instead. This property lets each tool override the probe
    /// used by ``NativeToolRunner/getToolVersion(_:)``.
    public var versionArguments: [String] {
        switch self {
        case .bedGraphToBigWig:
            // The probe table lists no argument for it, because none reports the version.
            return ["--version"]
        default:
            // The probe table holds the rest, such as iVar's and lofreq's `version` subcommand.
            return ManagedToolVersionProbe.probe(for: managedToolID)?.arguments ?? ["--version"]
        }
    }

    public var location: NativeToolLocation {
        switch self {
        case .samtools:
            return .managed(environment: "samtools", executableName: "samtools")
        case .bcftools:
            return .managed(environment: "bcftools", executableName: "bcftools")
        case .bgzip:
            return .managed(environment: "htslib", executableName: "bgzip")
        case .tabix:
            return .managed(environment: "htslib", executableName: "tabix")
        case .bedGraphToBigWig:
            return .managed(environment: "ucsc-bedgraphtobigwig", executableName: "bedGraphToBigWig")
        case .pigz:
            return .managed(environment: "pigz", executableName: "pigz")
        case .seqkit:
            return .managed(environment: "seqkit", executableName: "seqkit")
        case .fastp:
            return .managed(environment: "fastp", executableName: "fastp")
        case .vsearch:
            return .managed(environment: "vsearch", executableName: "vsearch")
        case .blastn:
            return .managed(environment: "blast", executableName: "blastn")
        case .cutadapt:
            return .managed(environment: "cutadapt", executableName: "cutadapt")
        case .trimGalore:
            return .managed(environment: "trim_galore", executableName: "trim_galore")
        case .ribodetector:
            return .managed(environment: "ribodetector", executableName: "ribodetector_cpu")
        case .clumpify:
            return .managed(environment: "bbtools", executableName: "clumpify.sh")
        case .bbduk:
            return .managed(environment: "bbtools", executableName: "bbduk.sh")
        case .bbmerge:
            return .managed(environment: "bbtools", executableName: "bbmerge.sh")
        case .repair:
            return .managed(environment: "bbtools", executableName: "repair.sh")
        case .tadpole:
            return .managed(environment: "bbtools", executableName: "tadpole.sh")
        case .reformat:
            return .managed(environment: "bbtools", executableName: "reformat.sh")
        case .bbmap:
            return .managed(environment: "bbtools", executableName: "bbmap.sh")
        case .mapPacBio:
            return .managed(environment: "bbtools", executableName: "mapPacBio.sh")
        case .fasterqDump:
            return .managed(environment: "sra-tools", executableName: "fasterq-dump")
        case .prefetch:
            return .managed(environment: "sra-tools", executableName: "prefetch")
        case .deacon:
            return .managed(environment: "deacon", executableName: "deacon")
        case .lofreq:
            return .managed(environment: "lofreq", executableName: "lofreq")
        case .ivar:
            return .managed(environment: "ivar", executableName: "ivar")
        case .medaka:
            return .managed(environment: "medaka", executableName: "medaka")
        case .medakaVariant:
            return .managed(environment: "medaka", executableName: "medaka_variant")
        case .clair3:
            return .managed(environment: "clair3", executableName: "run_clair3.sh")
        case .whatshap:
            return .managed(environment: "phasing", executableName: "whatshap")
        case .freyja:
            return .managed(environment: "freyja", executableName: "freyja")
        case .zstd:
            return .managed(environment: "zstd", executableName: "zstd")
        case .xz:
            return .managed(environment: "xz", executableName: "xz")
        }
    }

    public var isBundled: Bool {
        if case .bundled = location {
            return true
        }
        return false
    }

    /// Relative path from the tools root directory.
    ///
    /// Most tools are rooted directly under `Tools/`. Multi-file distributions
    /// (BBTools and bundled JRE) are nested under subdirectories.
    public var relativeExecutablePath: String {
        switch self {
        case .clumpify:
            return "bbtools/clumpify.sh"
        case .bbduk:
            return "bbtools/bbduk.sh"
        case .bbmerge:
            return "bbtools/bbmerge.sh"
        case .repair:
            return "bbtools/repair.sh"
        case .tadpole:
            return "bbtools/tadpole.sh"
        case .reformat:
            return "bbtools/reformat.sh"
        case .bbmap:
            return "bbtools/bbmap.sh"
        case .mapPacBio:
            return "bbtools/mapPacBio.sh"
        case .fasterqDump:
            return "sra-tools/fasterq-dump"
        case .prefetch:
            return "sra-tools/prefetch"
        default:
            return executableName
        }
    }

    /// The source package this tool comes from.
    public var sourcePackage: String {
        switch self {
        case .samtools: return "samtools"
        case .bcftools: return "bcftools"
        case .bgzip, .tabix: return "htslib"
        case .bedGraphToBigWig: return "ucsc-tools"
        case .pigz: return "pigz"
        case .seqkit: return "seqkit"
        case .fastp: return "fastp"
        case .vsearch: return "vsearch"
        case .blastn: return "ncbi-blast"
        case .cutadapt: return "cutadapt"
        case .trimGalore: return "trim-galore"
        case .ribodetector: return "ribodetector"
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat, .bbmap, .mapPacBio: return "bbmap"
        case .fasterqDump, .prefetch: return "sra-tools"
        case .deacon: return "deacon"
        case .lofreq: return "lofreq"
        case .ivar: return "ivar"
        case .medaka, .medakaVariant: return "medaka"
        case .clair3: return "clair3"
        case .whatshap: return "whatshap"
        case .freyja: return "freyja"
        case .zstd: return "zstd"
        case .xz: return "xz"
        }
    }

    /// Whether this tool is a BBTools shell script that doesn't properly quote `$@`.
    ///
    /// Every one of these wrappers ends with `CMD="java ... $@"; eval $CMD`, so
    /// the shell re-splits any argument containing whitespace. `NativeToolRunner`
    /// routes them through ``BBToolsArgumentStaging``, which rewrites path
    /// arguments onto a whitespace-free staging root and moves outputs back.
    public var isBBToolsShellScript: Bool {
        switch self {
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat, .bbmap, .mapPacBio: return true
        default: return false
        }
    }

    /// License information for this tool.
    public var license: String {
        switch self {
        case .samtools, .bcftools, .bgzip, .tabix:
            return "MIT/Expat"
        case .bedGraphToBigWig:
            return "MIT (UCSC Genome Browser)"
        case .pigz:
            return "zlib License"
        case .seqkit:
            return "MIT License"
        case .fastp:
            return "MIT License"
        case .vsearch:
            return "GPL-3.0 or BSD-2-Clause (dual)"
        case .blastn:
            return "Public Domain (NCBI)"
        case .cutadapt:
            return "MIT License"
        case .trimGalore:
            return "GPL-3.0-only"
        case .ribodetector:
            return "GPL-3.0-or-later"
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat, .bbmap, .mapPacBio:
            return "BBMap License"
        case .fasterqDump, .prefetch:
            return "Public Domain (NCBI)"
        case .deacon:
            return "MIT License"
        case .lofreq:
            return "MIT License"
        case .ivar:
            return "GPL-3.0-or-later"
        case .medaka, .medakaVariant:
            return "MPL-2.0"
        case .clair3:
            return "BSD-3-Clause"
        case .whatshap:
            return "MIT License"
        case .freyja:
            return "BSD-2-Clause"
        case .zstd:
            return "BSD-3-Clause or GPL-2.0-only (dual)"
        case .xz:
            return "0BSD and LGPL-2.1-or-later and GPL-2.0-or-later"
        }
    }

    /// Whether this tool is part of htslib (bgzip, tabix).
    public var isHtslib: Bool {
        self == .bgzip || self == .tabix
    }
}
