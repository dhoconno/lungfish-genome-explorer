// NativeTool+ManagedTool.swift - The managed tool lock entry behind each NativeTool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension NativeTool {
    /// The managed tool lock id of the package this tool comes from.
    ///
    /// Several cases share one package, such as the BBTools wrappers, so the id is not the
    /// raw value. The switch has no default, so a new case cannot compile without a mapping.
    public var managedToolID: ManagedToolID {
        switch self {
        case .samtools: return ManagedToolID(rawValue: "samtools")
        case .bcftools: return ManagedToolID(rawValue: "bcftools")
        case .bgzip, .tabix: return ManagedToolID(rawValue: "htslib")
        case .bedGraphToBigWig: return ManagedToolID(rawValue: "ucsc-bedgraphtobigwig")
        case .pigz: return ManagedToolID(rawValue: "pigz")
        case .seqkit: return ManagedToolID(rawValue: "seqkit")
        case .fastp: return ManagedToolID(rawValue: "fastp")
        case .vsearch: return ManagedToolID(rawValue: "vsearch")
        case .blastn: return ManagedToolID(rawValue: "blast")
        case .cutadapt: return ManagedToolID(rawValue: "cutadapt")
        case .trimGalore: return ManagedToolID(rawValue: "trim_galore")
        case .ribodetector: return ManagedToolID(rawValue: "ribodetector")
        case .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .reformat, .bbmap, .mapPacBio:
            return ManagedToolID(rawValue: "bbtools")
        case .fasterqDump, .prefetch: return ManagedToolID(rawValue: "sra-tools")
        case .deacon: return ManagedToolID(rawValue: "deacon")
        case .lofreq: return ManagedToolID(rawValue: "lofreq")
        case .ivar: return ManagedToolID(rawValue: "ivar")
        case .medaka, .medakaVariant: return ManagedToolID(rawValue: "medaka")
        case .clair3: return ManagedToolID(rawValue: "clair3")
        case .whatshap: return ManagedToolID(rawValue: "whatshap")
        case .freyja: return ManagedToolID(rawValue: "freyja")
        }
    }
}
