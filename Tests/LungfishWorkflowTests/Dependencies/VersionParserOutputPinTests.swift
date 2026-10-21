// VersionParserOutputPinTests.swift - What the production version parsers return on real output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Pins the value the one version parser returns on captured real probe output.
///
/// `ProbeVersionText.reading(exitCode:stdout:stderr:storageRoot:)` is the only parser, and three
/// entry points call it. `NativeToolRunner.parseVersionProbe` serves `getToolVersion`. `parseToolVersion(from:)`
/// serves `detectToolVersion`, which `ManagedMappingPipeline` and `ManagedAssemblyPipeline` call.
/// `CLIProvenanceSupport.parseCondaToolVersion` serves `detectCondaToolVersion`, which lives in the
/// CLI target inside a function that runs a process, so `CLIProvenanceSupportVersionTests` pins its
/// two production tools (deacon and ribodetector_cpu) from the CLI test target. The table keeps a
/// column for each of the first two entry points, so a change to either shows as a diff.
///
/// The table holds one capture for every tool a parser probes in production. That is each case of
/// `NativeTool` (any of them can reach `getToolVersion`), each tool `detectToolVersion` is called
/// with (kraken2, EsViritu, minimap2, bwa-mem2, bowtie2, mafft, gatk and the assemblers)
/// and the two the CLI parser probes. `testEveryProbedToolHasACapture` fails when a `NativeTool`
/// case or a listed tool has no row, so a parser rule cannot move a version no row pins.
///
/// The outputs are captured by running each probe the way production runs it, with the storage
/// root replaced by `/Users/test/.lungfish/conda`. The golden environment
/// (`LUNGFISH_STORAGE_ROOT=/Users/Shared/lungfish-golden/storage`) holds samtools, seqkit, kraken2,
/// minimap2, EsViritu and the BBTools wrappers, and those rows come from it. It lacks every other
/// tool, so the other rows come from the owner's managed install under `~/.lungfish/conda` on the
/// same Mac, and the golden and owner captures agree wherever both exist. The wrong values sit
/// in `knownDefects`. They are pinned so a parser change shows as a deliberate diff. Phase 2.6
/// fixed the rows its plan names, and Phase 2.7 merges the parsers and fixes the rest. Each must
/// update this table in the same commit.
final class VersionParserOutputPinTests: XCTestCase {
    private struct Capture {
        let name: String
        let exitCode: Int32
        let stdout: String
        let stderr: String
        /// What `NativeToolRunner.parseVersionProbe` returns.
        let native: String?
        /// What `parseToolVersion(from:stderr:exitCode:storageRoot:)` returns.
        let detect: String?
        /// The version the tool really reports, for defect rows. Nil when the probe reports none, as
        /// bedGraphToBigWig, medaka_variant and bwa-mem2 reject it. Their version comes from the lock
        /// or conda-meta, and a parser must say nothing rather than record the error line.
        let correct: String?
        /// The conda root the probe ran under, for a row whose output holds that root. Production
        /// passes it to the parser, and the other rows write the shared `root` and need no help.
        var storageRoot: String? = nil
    }

    private static let root = "/Users/test/.lungfish/conda"

    private static func bbtoolsBanner(javaLine: String, tail: String) -> String {
        "Detected 67108864KB total memory on macOS, estimating 43620761KB available\n"
            + "Detected 36971360KB free memory on macOS (vm_stat)\n"
            + javaLine + "\n" + tail
    }

    /// A captured output written one line per element, each ending in a newline. An empty element
    /// is a blank line.
    private static func lines(_ items: String...) -> String {
        items.joined(separator: "\n") + "\n"
    }

    // MARK: - Clean outputs, both entry points right

    private static let clean: [Capture] = [
        Capture(name: "samtools", exitCode: 0,
            stdout: lines(
                "samtools 1.24",
                "Using htslib 1.24",
                "Copyright (C) 2026 Genome Research Ltd.",
                "",
                "Samtools compilation details:",
                "    Features:       build=configure curses=yes ",
                "    CC:             arm64-apple-darwin20.0.0-clang -std=gnu23",
                "    CPPFLAGS:       -D_FORTIFY_SOURCE=2 -isystem \(root)/envs/samtools/include -mmacosx-version-min=11.3 -mmacosx-version-min=11.0",
                "    CFLAGS:         -Wall -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem \(root)/envs/samtools/include -fdebug-prefix-map=/opt/mambaforge/envs/bioconda/conda-bld/samtools_1784061835497/work=/usr/local/src/conda/samtools-1.24 -fdebug-prefix-map=\(root)/envs/samtools=/usr/local/src/conda-prefix",
                "    LDFLAGS:        -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs -Wl,-rpath,\(root)/envs/samtools/lib -L\(root)/envs/samtools/lib",
                "    HTSDIR:         ",
                "    LIBS:           ",
                "    CURSES_LIB:     -ltinfow -lncursesw",
                "",
                "HTSlib compilation details:",
                "    Features:       build=configure libcurl=yes S3=yes GCS=yes libdeflate=yes lzma=yes bzip2=yes plugins=yes plugin-path=\(root)/envs/samtools/libexec/htslib htscodecs=1.6.7",
                "    CC:             arm64-apple-darwin20.0.0-clang -std=gnu23",
                "    CPPFLAGS:       -D_FORTIFY_SOURCE=2 -isystem \(root)/envs/samtools/include -mmacosx-version-min=11.3 -mmacosx-version-min=11.0",
                "    CFLAGS:         -Wall -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -isystem \(root)/envs/samtools/include -fdebug-prefix-map=/opt/mambaforge/envs/bioconda/conda-bld/htslib_1783611483345/work=/usr/local/src/conda/htslib-1.24 -fdebug-prefix-map=\(root)/envs/samtools=/usr/local/src/conda-prefix -fvisibility=hidden",
                "    LDFLAGS:        -Wl,-headerpad_max_install_names -Wl,-dead_strip_dylibs -Wl,-rpath,\(root)/envs/samtools/lib -L\(root)/envs/samtools/lib -fvisibility=hidden -rdynamic",
                "",
                "HTSlib URL scheme handlers present:",
                "    built-in:\t file, preload, data",
                "    Google Cloud Storage:\t gs+http, gs+https, gs",
                "    libcurl:\t gophers, smtp, wss, rtsp, tftp, mqtts, pop3, imaps, pop3s, ws, ftps, ftp, gopher, imap, http, https, sftp, smtps, scp, dict, mqtt, telnet",
                "    Amazon S3:\t s3+https, s3, s3+http",
                "    crypt4gh-needed:\t crypt4gh",
                "    mem:\t mem"),
            stderr: "",
            native: "1.24", detect: "1.24", correct: "1.24"),
        Capture(name: "minimap2", exitCode: 0, stdout: "2.31-r1302\n", stderr: "",
                native: "2.31", detect: "2.31", correct: "2.31"),
        Capture(name: "kraken2", exitCode: 0,
                stdout: "Kraken version 2.17.1\nCopyright 2013-2023, Derrick Wood (dwood@cs.jhu.edu)\n", stderr: "",
                native: "2.17.1", detect: "2.17.1", correct: "2.17.1"),
        Capture(name: "seqkit", exitCode: 0, stdout: "seqkit v2.13.0\n", stderr: "",
                native: "2.13.0", detect: "2.13.0", correct: "2.13.0"),
        Capture(name: "blastn", exitCode: 0,
                stdout: "blastn: 2.16.0+\n Package: blast 2.16.0, build Mar 28 2025 16:33:14\n", stderr: "",
                native: "2.16.0", detect: "2.16.0", correct: "2.16.0"),
        Capture(name: "lofreq", exitCode: 0,
                stdout: "version: 2.1.5\ncommit: unknown\nbuild-date: Jul 15 2026\n", stderr: "",
                native: "2.1.5", detect: "2.1.5", correct: "2.1.5"),
        Capture(name: "ivar", exitCode: 0,
                stdout: "iVar version 1.4.4\n\nPlease raise issues and bug reports at https://github.com/andersen-lab/ivar/\n\n", stderr: "",
                native: "1.4.4", detect: "1.4.4", correct: "1.4.4"),
        Capture(name: "freyja", exitCode: 0, stdout: "freyja, version 2.0.3\n", stderr: "",
                native: "2.0.3", detect: "2.0.3", correct: "2.0.3"),
        Capture(name: "mafft", exitCode: 0, stdout: "", stderr: "v7.526 (2024/Apr/26)\n",
                native: "7.526", detect: "7.526", correct: "7.526"),
        Capture(name: "flye", exitCode: 0, stdout: "2.9.6-b1802\n", stderr: "",
                native: "2.9.6", detect: "2.9.6", correct: "2.9.6"),
        Capture(name: "spades.py", exitCode: 0, stdout: "SPAdes genome assembler v4.3.0\n", stderr: "",
                native: "4.3.0", detect: "4.3.0", correct: "4.3.0"),
        Capture(name: "skesa", exitCode: 0, stdout: "SKESA 2.5.1\n", stderr: "skesa --version \n\n",
                native: "2.5.1", detect: "2.5.1", correct: "2.5.1"),
        Capture(name: "bowtie2", exitCode: 0,
            stdout: lines(
                "\(root)/envs/bowtie2/bin/bowtie2-align-s version 2.5.5",
                "64-bit",
                "Built on VM-8b0b7afd3b",
                "Tue Feb 17 04:30:57 UTC 2026",
                "Compiler: InstalledDir: /opt/mambaforge/envs/bioconda/conda-bld/bowtie2_1771302597904/_build_env/bin",
                "Options: -O3 -funroll-loops -g3 -ftree-vectorize -fPIC -fstack-protector-strong -O2 -pipe -stdlib=libc++ -fvisibility-inlines-hidden -fmessage-length=0 -isystem \(root)/envs/bowtie2/include -fdebug-prefix-map=/opt/mambaforge/envs/bioconda/conda-bld/bowtie2_1771302597904/work=/usr/local/src/conda/bowtie2-2.5.5 -fdebug-prefix-map=\(root)/envs/bowtie2=/usr/local/src/conda-prefix -O3" + String(repeating: "\u{0}", count: 432),
                "Sizeof {int, long, long long, void*, size_t, off_t}: {4, 8, 8, 8, 8, 8}"),
            stderr: "",
            native: "2.5.5", detect: "2.5.5", correct: "2.5.5"),
        Capture(name: "fasterq-dump", exitCode: 0,
                stdout: "\(root)/envs/sra-tools/bin/fasterq-dump : 3.4.1\n\n", stderr: "",
                native: "3.4.1", detect: "3.4.1", correct: "3.4.1"),
        // Every entry point skips the echoed java command and the install path in it, so each reads the banner.
        Capture(name: "reformat.sh", exitCode: 0, stdout: "",
                stderr: "java -ea   -Xmx300m -Xms300m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.ReformatReads --version\n"
                    + "BBTools version 40.02\nFor help, please run the shellscript with no parameters, or look in /docs/.\n",
                native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "clumpify.sh", exitCode: 0, stdout: "",
                stderr: bbtoolsBanner(
                    javaLine: "java -ea   -Xmx29205m -Xms29205m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ clump.Clumpify --version",
                    tail: "BBTools version 40.02\nFor help, please run the shellscript with no parameters, or look in /docs/.\n"),
                native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "bcftools", exitCode: 0,
            stdout: lines(
                "bcftools 1.24",
                "Using htslib 1.24",
                "Copyright (C) 2026 Genome Research Ltd.",
                "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>",
                "This is free software: you are free to change and redistribute it.",
                "There is NO WARRANTY, to the extent permitted by law."),
            stderr: "",
            native: "1.24", detect: "1.24", correct: "1.24"),
        Capture(name: "bgzip", exitCode: 0,
            stdout: lines(
                "bgzip (htslib) 1.24",
                "Copyright (C) 2026 Genome Research Ltd."),
            stderr: "",
            native: "1.24", detect: "1.24", correct: "1.24"),
        Capture(name: "tabix", exitCode: 0,
            stdout: lines(
                "tabix (htslib) 1.24",
                "Copyright (C) 2026 Genome Research Ltd."),
            stderr: "",
            native: "1.24", detect: "1.24", correct: "1.24"),
        Capture(name: "pigz", exitCode: 0,
            stdout: "pigz 2.8\n",
            stderr: "",
            native: "2.8", detect: "2.8", correct: "2.8"),
        Capture(name: "zstd", exitCode: 0,
            stdout: "*** Zstandard CLI (64-bit) v1.5.7, by Yann Collet ***\n",
            stderr: "",
            native: "1.5.7", detect: "1.5.7", correct: "1.5.7"),
        Capture(name: "xz", exitCode: 0,
            stdout: lines(
                "xz (XZ Utils) 5.8.3",
                "liblzma 5.8.3"),
            stderr: "",
            native: "5.8.3", detect: "5.8.3", correct: "5.8.3"),
        Capture(name: "fastp", exitCode: 0,
            stdout: "fastp 1.3.6\n",
            stderr: "",
            native: "1.3.6", detect: "1.3.6", correct: "1.3.6"),
        Capture(name: "cutadapt", exitCode: 0,
            stdout: "5.2\n",
            stderr: "",
            native: "5.2", detect: "5.2", correct: "5.2"),
        Capture(name: "trim_galore", exitCode: 0,
            stdout: lines(
                "trim_galore 2.3.0",
                "unknown \u{2014} macos/aarch64 \u{2014} built 2026-06-27T16:16:29Z"),
            stderr: "",
            native: "2.3.0", detect: "2.3.0", correct: "2.3.0"),
        Capture(name: "ribodetector_cpu", exitCode: 0,
            stdout: "ribodetector_cpu 0.3.3\n",
            stderr: "",
            native: "0.3.3", detect: "0.3.3", correct: "0.3.3"),
        Capture(name: "prefetch", exitCode: 0,
            stdout: lines(
                "\(root)/envs/sra-tools/bin/prefetch : 3.4.1",
                ""),
            stderr: "",
            native: "3.4.1", detect: "3.4.1", correct: "3.4.1"),
        Capture(name: "deacon", exitCode: 0,
            stdout: "deacon 0.16.0\n",
            stderr: "",
            native: "0.16.0", detect: "0.16.0", correct: "0.16.0"),
        Capture(name: "medaka", exitCode: 0,
            stdout: "medaka 2.2.2\n",
            stderr: "",
            native: "2.2.2", detect: "2.2.2", correct: "2.2.2"),
        Capture(name: "run_clair3.sh", exitCode: 0,
            stdout: "Clair3 v2.0.2\n",
            stderr: "",
            native: "2.0.2", detect: "2.0.2", correct: "2.0.2"),
        Capture(name: "whatshap", exitCode: 0,
            stdout: "2.3\n",
            stderr: "",
            native: "2.3", detect: "2.3", correct: "2.3"),
        Capture(name: "megahit", exitCode: 0,
            stdout: "MEGAHIT v1.2.9\n",
            stderr: "",
            native: "1.2.9", detect: "1.2.9", correct: "1.2.9"),
        Capture(name: "hifiasm", exitCode: 0,
            stdout: "0.25.0-r726\n",
            stderr: "",
            native: "0.25.0", detect: "0.25.0", correct: "0.25.0"),
        Capture(name: "bbduk.sh", exitCode: 0,
            stdout: "",
            stderr: lines(
                "Detected 67108864KB total memory on macOS, estimating 43620761KB available",
                "Detected 30420544KB free memory on macOS (vm_stat)",
                "java -ea   -Xmx12272m -Xms12272m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ bbduk.BBDukS --version",
                "BBTools version 40.02",
                "For help, please run the shellscript with no parameters, or look in /docs/."),
            native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "bbmerge.sh", exitCode: 0,
            stdout: "",
            stderr: lines(
                "java -ea   -Xmx1000m -Xms1000m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.BBMerge --version",
                "BBTools version 40.02",
                "For help, please run the shellscript with no parameters, or look in /docs/."),
            native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "repair.sh", exitCode: 0,
            stdout: "",
            stderr: lines(
                "Detected 67108864KB total memory on macOS, estimating 43620761KB available",
                "Detected 30350784KB free memory on macOS (vm_stat)",
                "java -ea   -Xmx24486m -Xms24486m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.SplitPairsAndSingles rp --version",
                "BBTools version 40.02",
                "For help, please run the shellscript with no parameters, or look in /docs/."),
            native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "tadpole.sh", exitCode: 0,
            stdout: "",
            stderr: lines(
                "Detected 67108864KB total memory on macOS, estimating 43620761KB available",
                "Detected 30127744KB free memory on macOS (vm_stat)",
                "java -ea   -Xmx24304m -Xms24304m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ assemble.Tadpole --version",
                "BBTools version 40.02",
                "For help, please run the shellscript with no parameters, or look in /docs/."),
            native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "bbmap.sh", exitCode: 0,
            stdout: "",
            stderr: lines(
                "Detected 67108864KB total memory on macOS, estimating 43620761KB available",
                "Detected 28539296KB free memory on macOS (vm_stat)",
                "java -ea   -Xmx23000m -Xms23000m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ align2.BBMap build=1 overwrite=true fastareadlen=500 --version",
                "BBTools version 40.02",
                "For help, please run the shellscript with no parameters, or look in /docs/."),
            native: "40.02", detect: "40.02", correct: "40.02"),
        // mapPacBio.sh echoes its java command, and the command holds minratio=0.40. Every parser skips
        // an echoed java command, so each reads the banner (2.7). The detect parser used to read 0.40.
        // This is the real golden output.
        Capture(name: "mapPacBio.sh minratio", exitCode: 0, stdout: "",
                stderr: lines(
                    "Detected 67108864KB total memory on macOS, estimating 43620761KB available",
                    "Detected 28822704KB free memory on macOS (vm_stat)",
                    "java -ea   -Xmx23233m -Xms23233m -cp \(root)/envs/bbtools/opt/bbmap-40.02-0/current/ align2.BBMapPacBio build=1 overwrite=true minratio=0.40 fastareadlen=6000 ambiguous=best minscaf=100 startpad=10000 stoppad=10000 midpad=6000 --version",
                    "BBTools version 40.02",
                    "For help, please run the shellscript with no parameters, or look in /docs/."),
                native: "40.02", detect: "40.02", correct: "40.02"),
        // EsViritu prints its site-packages path first, and the path holds Python's 3.14. A token that
        // holds a slash is a path, so the native parser skips it as the detect parser does (2.6). This
        // is the real golden output.
        Capture(name: "EsViritu python3.14 path", exitCode: 0,
                stdout: "\(root)/envs/esviritu/lib/python3.14/site-packages/EsViritu\n1.3.3\n", stderr: "",
                native: "1.3.3", detect: "1.3.3", correct: "1.3.3"),
        // The same two outputs on a root whose volume is named "LGE 2.0", the real output with the root
        // written as that volume. The native parser used to read the volume's 2.0 (2.6).
        Capture(name: "BBTools wrapper under a root named LGE 2.0", exitCode: 0, stdout: "",
                stderr: "java -ea   -Xmx300m -Xms300m -cp /Volumes/LGE 2.0/conda/envs/bbtools/opt/bbmap-40.02-0/current/ jgi.ReformatReads --version\n"
                    + "BBTools version 40.02\nFor help, please run the shellscript with no parameters, or look in /docs/.\n",
                native: "40.02", detect: "40.02", correct: "40.02"),
        Capture(name: "EsViritu under a root named LGE 2.0", exitCode: 0,
                stdout: "/Volumes/LGE 2.0/conda/envs/esviritu/lib/python3.14/site-packages/EsViritu\n1.3.3\n", stderr: "",
                native: "1.3.3", detect: "1.3.3", correct: "1.3.3"),
        // A root named with three words, such as a volume "Lab 2.0 Disk", leaves its middle word bare
        // when a path is split on spaces, so a parser removes the storage root from each line before it
        // splits (2.7). The two parsers read 2.0 before. The head of the real bowtie2 output, with the
        // root written as that volume.
        Capture(name: "bowtie2 under a root named Lab 2.0 Disk", exitCode: 0,
                stdout: lines(
                    "/Volumes/Lab 2.0 Disk/conda/envs/bowtie2/bin/bowtie2-align-s version 2.5.5",
                    "64-bit",
                    "Built on VM-8b0b7afd3b"),
                stderr: "",
                native: "2.5.5", detect: "2.5.5", correct: "2.5.5",
                storageRoot: "/Volumes/Lab 2.0 Disk/conda"),
        // vsearch prints its citation and a zlib line on stdout and its banner on stderr. A token written
        // v2.31.0 is the tool naming its own version, so both entry points prefer it to a bare number such as
        // zlib's 1.2.12 or a DOI (2.6). The real output from the owner's install, which the golden
        // environment lacks.
        Capture(name: "vsearch citation", exitCode: 0,
                stdout: lines(
                    "Rognes T, Flouri T, Nichols B, Quince C, Mahe F (2016)",
                    "VSEARCH: a versatile open source tool for metagenomics",
                    "PeerJ 4:e2584 doi: 10.7717/peerj.2584 https://doi.org/10.7717/peerj.2584",
                    "",
                    "Compiled with support for gzip-compressed files, and the library is loaded.",
                    "zlib version 1.2.12, compile flags 2a9",
                    "Compiled with support for bzip2-compressed files, and the library is loaded."),
                stderr: lines(
                    "vsearch v2.31.0_macos_aarch64, 64.0GB RAM, 20 cores",
                    "https://github.com/torognes/vsearch",
                    ""),
                native: "2.31.0", detect: "2.31.0", correct: "2.31.0"),
        // GATK prints four parts, 4.6.2.0, and the version pattern used to stop at three (2.6). The real
        // output from the owner's install, which the golden environment lacks. GATK echoes its own
        // java command last, and the native parser skips it.
        Capture(name: "gatk 4.6.2.0", exitCode: 0,
                stdout: lines(
                    "The Genome Analysis Toolkit (GATK) v4.6.2.0",
                    "HTSJDK Version: 4.2.0",
                    "Picard Version: 3.4.0"),
                stderr: lines(
                    "Using GATK jar \(root)/envs/gatk-core/share/gatk4-4.6.2.0-1/gatk-package-4.6.2.0-local.jar",
                    "Running:",
                    "    java -Dsamjdk.use_async_io_read_samtools=false -Dsamjdk.use_async_io_write_samtools=true "
                        + "-Dsamjdk.use_async_io_write_tribble=false -Dsamjdk.compression_level=2 -jar "
                        + "\(root)/envs/gatk-core/share/gatk4-4.6.2.0-1/gatk-package-4.6.2.0-local.jar --version"),
                native: "4.6.2.0", detect: "4.6.2.0", correct: "4.6.2.0"),
        // primalscheme3 prints "PrimalScheme3-LGE version: 3.3.0+lge.5", and the pattern used to drop the
        // local build suffix (2.6). The real output from the owner's install, which the golden
        // environment lacks.
        Capture(name: "primalscheme3 +lge.5", exitCode: 0,
                stdout: "PrimalScheme3-LGE version: 3.3.0+lge.5\n", stderr: "",
                native: "3.3.0+lge.5", detect: "3.3.0+lge.5", correct: "3.3.0+lge.5"),
        // A probe that prints only an error line has no version, so a parser records none (2.6). The
        // detect parser used to record the first line and the CLI parser too. These are real outputs
        // from the owner's install, which the golden environment lacks. bwa-mem2 rejects --version and
        // then -v, which is the order detectToolVersion tries, and the mapping pipeline reads its
        // version from conda-meta instead.
        Capture(name: "bwa-mem2 --version", exitCode: 1, stdout: "",
                stderr: "ERROR: unknown command '--version'\n",
                native: nil, detect: nil, correct: nil),
        Capture(name: "bwa-mem2 -v", exitCode: 1, stdout: "",
                stderr: "ERROR: unknown command '-v'\n",
                native: nil, detect: nil, correct: nil),
        Capture(name: "bedGraphToBigWig --version", exitCode: 255, stdout: "",
                stderr: "--version is not a valid option\n",
                native: nil, detect: nil, correct: nil),
        Capture(name: "medaka_variant --version", exitCode: 1, stdout: "",
                stderr: "Invalid option: --.\n",
                native: nil, detect: nil, correct: nil),
        // A missing conda environment prints micromamba's own complaint and exits 1. The probe reports
        // no version, so a parser says nothing (2.7). The detect parser used to record that first line.
        // The environment's version comes from conda-meta or the lock.
        Capture(name: "micromamba missing environment", exitCode: 1, stdout: "",
                stderr: "critical libmamba The given prefix does not exist: \"\(root)/envs/bbmap\"\n",
                native: nil, detect: nil, correct: nil),
        // hifiasm -h prints usage text, and its -D default [5.0] comes before any version. Usage text
        // holds no version, so no parser reads one from it (2.7). The assembly pipeline no longer falls
        // back to -h, and its version comes from --version. The text is the head of the real output.
        Capture(name: "hifiasm -h help text", exitCode: 0, stdout: "",
                stderr: lines(
                    "Usage: hifiasm [options] <in_1.fq> <in_2.fq> <...>",
                    "Options:",
                    "  Input/Output:",
                    "    -o STR       prefix of output files [hifiasm.asm]",
                    "    -t INT       number of threads [1]",
                    "    -h           show help information",
                    "    --version    show version number",
                    "  Preset options:",
                    "    --ont        assemble Oxford Nanopore reads",
                    "  Overlap/Error correction:",
                    "    -k INT       k-mer length (must be <64) [51]",
                    "    -w INT       minimizer window size [51]",
                    "    -f INT       number of bits for bloom filter; 0 to disable [37]",
                    "    -D FLOAT     drop k-mers occurring >FLOAT*coverage times [5.0]"),
                native: nil, detect: nil, correct: nil),
    ]

    // MARK: - Known defects, left for 2.7

    /// Each row pins a wrong value as it is today. `correct` is what the tool reports. A row stays
    /// here until the parser change that fixes it lands, and that commit moves the row to `clean`.
    /// Phases 2.6 and 2.7 moved their rows out. The bwa-mem2 and Bracken banners name a version the
    /// package does not run.
    private static let knownDefects: [Capture] = [
        // The installed 2.3 build prints a stale 2.2.1 from the version subcommand, so both entry points
        // read a version the package does not have. Only conda-meta says 2.3 (the lock pin). The
        // mapping pipeline reads conda-meta for bwa-mem2 since 2.6 (`MappingToolVersionProbe`), so
        // nothing parses this output in production, and the row stays to show why.
        Capture(name: "bwa-mem2 version subcommand", exitCode: 0, stdout: "2.2.1\n", stderr: "",
                native: "2.2.1", detect: "2.2.1", correct: "2.3"),
        // The 3.1 build prints a stale v3.0.1, and since 2.6 production reads the overlay's 3.1 (S20).
        // The real output from the owner's install, which the golden environment lacks.
        Capture(name: "bracken", exitCode: 0,
                stdout: "Bracken v3.0.1\n", stderr: "",
                native: "3.0.1", detect: "3.0.1", correct: "3.1"),
    ]

    // MARK: - Tests

    func testCleanOutputsReturnTheirVersionFromBothParsers() {
        for capture in Self.clean {
            assertPins(capture)
            XCTAssertEqual(capture.native, capture.correct, "native parser on \(capture.name)")
            XCTAssertEqual(capture.detect, capture.correct, "detect parser on \(capture.name)")
        }
    }

    func testKnownDefectsAreStillPinnedAsTheyAre() {
        for capture in Self.knownDefects {
            assertPins(capture)
        }
    }

    func testEveryKnownDefectIsWrongInAtLeastOneParser() {
        for capture in Self.knownDefects {
            XCTAssertTrue(
                capture.native != capture.correct || capture.detect != capture.correct,
                "\(capture.name) is listed as a defect but both entry points return \(capture.correct)"
            )
        }
    }

    func testRequiredCapturesArePresent() {
        let names = Set((Self.clean + Self.knownDefects).map(\.name))
        for required in [
            "gatk 4.6.2.0", "primalscheme3 +lge.5", "EsViritu python3.14 path", "mapPacBio.sh minratio",
            "micromamba missing environment", "bwa-mem2 --version", "vsearch citation",
            "BBTools wrapper under a root named LGE 2.0", "samtools", "minimap2", "kraken2",
        ] {
            XCTAssertTrue(names.contains(required), required)
        }
    }

    /// The executables `detectToolVersion` and `CLIProvenanceSupport.detectCondaToolVersion` are called
    /// with in production, beyond the `NativeTool` cases. The assemblers come from
    /// `ManagedAssemblyPipeline`, the mappers from `MappingToolVersionProbe` and the rest from the
    /// classification, EsViritu and MSA pipelines and the two CLI fastq commands.
    private static let condaProbedExecutables = [
        "kraken2", "EsViritu", "minimap2", "bwa-mem2", "bowtie2", "mafft", "gatk",
        "spades.py", "megahit", "skesa", "flye", "hifiasm", "deacon", "ribodetector_cpu",
    ]

    /// Every tool a parser probes in production has a row. A new `NativeTool` case fails here until
    /// its probe is captured, so a parser rule cannot move a version no row pins.
    func testEveryProbedToolHasACapture() {
        let names = Set((Self.clean + Self.knownDefects).map(\.name))
        func hasRow(_ executable: String) -> Bool {
            names.contains { $0 == executable || $0.hasPrefix(executable + " ") }
        }
        for tool in NativeTool.allCases {
            XCTAssertTrue(hasRow(tool.executableName), "NativeTool.\(tool.rawValue) has no capture row")
        }
        for executable in Self.condaProbedExecutables {
            XCTAssertTrue(hasRow(executable), "\(executable) is probed through micromamba and has no capture row")
        }
    }

    func testCaptureNamesAreUnique() {
        let names = (Self.clean + Self.knownDefects).map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "a capture name appears twice")
    }

    /// The assembly pipeline asks hifiasm for its version with the one argument the probe table
    /// declares. It used to fall back to `-h`, whose help text holds no version (2.7).
    func testHifiasmIsProbedWithTheDeclaredArgumentOnly() {
        let declared = ManagedToolVersionProbe.probe(for: ManagedToolID(rawValue: "hifiasm"))?.arguments
        XCTAssertEqual(declared, ["--version"])
        XCTAssertEqual(ManagedAssemblyPipeline.versionFlags(for: .hifiasm), declared)
    }

    /// The reading names the output line each version came from (2.7). Nothing records it yet.
    func testTheReadingKeepsTheLineItCameFrom() throws {
        let lines = [
            "samtools": "samtools 1.24",
            "minimap2": "2.31-r1302",
            "mafft": "v7.526 (2024/Apr/26)",
            "reformat.sh": "BBTools version 40.02",
            "mapPacBio.sh minratio": "BBTools version 40.02",
            "vsearch citation": "vsearch v2.31.0_macos_aarch64, 64.0GB RAM, 20 cores",
            "EsViritu python3.14 path": "1.3.3",
            "gatk 4.6.2.0": "The Genome Analysis Toolkit (GATK) v4.6.2.0",
        ]
        for (name, line) in lines {
            let capture = try XCTUnwrap((Self.clean + Self.knownDefects).first { $0.name == name }, name)
            let reading = ProbeVersionText.reading(
                exitCode: capture.exitCode, stdout: capture.stdout, stderr: capture.stderr)
            XCTAssertEqual(reading?.version, capture.correct, name)
            XCTAssertEqual(reading?.reportedLine, line, name)
        }
    }

    func testDetectParserOnEmptyOutputReturnsNil() {
        XCTAssertNil(parseToolVersion(from: ""))
        XCTAssertNil(NativeToolRunner.parseVersionProbe(exitCode: 0, stdout: "", stderr: ""))
    }

    private func assertPins(_ capture: Capture, file: StaticString = #filePath, line: UInt = #line) {
        let root = capture.storageRoot.map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(
            NativeToolRunner.parseVersionProbe(
                exitCode: capture.exitCode, stdout: capture.stdout, stderr: capture.stderr, storageRoot: root),
            capture.native, "native parser on \(capture.name)", file: file, line: line
        )
        XCTAssertEqual(
            parseToolVersion(
                from: capture.stdout, stderr: capture.stderr, exitCode: capture.exitCode, storageRoot: root),
            capture.detect, "detect parser on \(capture.name)", file: file, line: line
        )
    }
}
