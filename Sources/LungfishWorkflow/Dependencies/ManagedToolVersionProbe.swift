import Foundation
import LungfishIO

/// How to ask a managed tool for its version, one entry per lock id.
///
/// The table holds only the probe executable, its arguments and the dialect. It parses
/// nothing, because the production parsers disagree on real output and move together in a
/// later phase. Every executable is one the lock declares for that entry, and a test holds
/// the table to the lock ids, so a new lock entry cannot ship without a probe.
public struct ManagedToolVersionProbe: Sendable, Hashable {
    /// How the version is read from the tool.
    public enum Dialect: Sendable, Hashable {
        /// The probe prints the pinned version.
        case selfReported
        /// The probe prints the pinned version, or its `--help` output does when `--version` does not.
        case selfReportedWithHelpFallback
        /// The probe cannot be trusted for the version, so conda-meta supplies it.
        /// The probe only shows that the executable runs.
        case condaMetaOnly
        /// The tool prints no version at all. The probe only shows that the executable runs.
        case notSelfReported
    }

    public let executable: String
    public let arguments: [String]
    public let dialect: Dialect

    /// The probe for a lock id, nil for an id the lock does not carry.
    public static func probe(for id: ManagedToolID) -> ManagedToolVersionProbe? {
        table[id.rawValue]
    }

    /// Every lock id the table covers.
    public static var probedIDs: [ManagedToolID] {
        table.keys.sorted().map { ManagedToolID(rawValue: $0) }
    }

    private static func entry(
        _ id: String, _ executable: String, _ arguments: [String], _ dialect: Dialect = .selfReported
    ) -> (String, ManagedToolVersionProbe) {
        (id, ManagedToolVersionProbe(executable: executable, arguments: arguments, dialect: dialect))
    }

    private static let table: [String: ManagedToolVersionProbe] = Dictionary([
        // tools
        entry("nextflow", "nextflow", ["-version"]),
        entry("snakemake", "snakemake", ["--version"]),
        // One lightweight wrapper probes the whole package. bbmap.sh, mapPacBio.sh and clumpify.sh
        // start a JVM sized to free memory, and mapPacBio.sh also echoes `minratio=0.40`.
        entry("bbtools", "reformat.sh", ["--version"]),
        entry("fastp", "fastp", ["--version"]),
        entry("deacon", "deacon", ["--version"]),
        entry("samtools", "samtools", ["--version"]),
        entry("bcftools", "bcftools", ["--version"]),
        entry("htslib", "bgzip", ["--version"]),
        entry("seqkit", "seqkit", ["version"]),
        entry("cutadapt", "cutadapt", ["--version"]),
        entry("trim_galore", "trim_galore", ["--version"]),
        entry("vsearch", "vsearch", ["--version"]),
        entry("pigz", "pigz", ["--version"]),
        entry("sra-tools", "fasterq-dump", ["--version"]),
        // Rejects --version and prints usage, so there is no argument that reports 482.
        entry("ucsc-bedgraphtobigwig", "bedGraphToBigWig", [], .notSelfReported),
        entry("pysam", "python", ["-c", "import pysam;print(pysam.__version__)"]),
        entry("openpyxl", "python", ["-c", "import openpyxl;print(openpyxl.__version__)"]),
        // pack tools
        entry("minimap2", "minimap2", ["--version"]),
        // The 2.3 build prints 2.2.1 from `version` and errors on `--version`.
        entry("bwa-mem2", "bwa-mem2", ["version"], .condaMetaOnly),
        entry("bowtie2", "bowtie2", ["--version"]),
        entry("savont", "savont", ["--version"], .selfReportedWithHelpFallback),
        entry("blast", "blastn", ["-version"]),
        // primer3_core has no version flag. `-about` prints `libprimer3 release 2.6.1`.
        entry("primer3", "primer3_core", ["-about"]),
        // Prints `PrimalScheme3-LGE version: 3.3.0+lge.5`, the Python runtime version.
        entry("primalscheme3", "primalscheme3", ["--version"]),
        // Prints `olivar-upstream.py v1.3.3`.
        entry("olivar", "olivar", ["--version"]),
        entry("varvamp", "varvamp", ["--version"]),
        // `lofreq --version` fails with "FATAL ... Unrecognized command". The `version`
        // subcommand prints "version: 2.1.5".
        entry("lofreq", "lofreq", ["version"]),
        // iVar rejects `--version` as "Unknown command" and prints "iVar version 1.4.4"
        // for the `version` subcommand.
        entry("ivar", "ivar", ["version"]),
        entry("medaka", "medaka", ["--version"]),
        entry("clair3", "run_clair3.sh", ["--version"]),
        entry("gatk4", "gatk", ["--version"]),
        entry("whatshap", "whatshap", ["--version"]),
        entry("spades", "spades.py", ["--version"]),
        entry("megahit", "megahit", ["--version"]),
        entry("skesa", "skesa", ["--version"]),
        entry("flye", "flye", ["--version"]),
        entry("hifiasm", "hifiasm", ["--version"]),
        entry("mafft", "mafft", ["--version"]),
        entry("iqtree", "iqtree3", ["--version"]),
        entry("kraken2", "kraken2", ["--version"]),
        // The 1.0.0 wrapper prints a usage error and the source build prints `Bracken v3.0.1`.
        entry("bracken", "bracken", ["-v"], .condaMetaOnly),
        // Prints its site-packages path first, which holds python3.14, then the version.
        entry("esviritu", "EsViritu", ["--version"]),
        // The executable LGE runs. The package also ships ribodetector, the GPU entry point.
        entry("ribodetector", "ribodetector_cpu", ["-v"]),
        entry("freyja", "freyja", ["--version"]),
    ], uniquingKeysWith: { first, _ in first })
}
