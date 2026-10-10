// MapReadSetStandIn.swift - Stand-in mappers and samtools that record what each run was handed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// A managed toolchain of stand-ins: minimap2, bwa-mem2 and bowtie2 behind a
/// stand-in micromamba, BBMap and samtools in a stand-in managed home. Every
/// mapper and samtools call writes its argv to `logDirectory`, one file per
/// call in call order, and writes a header-only SAM where the real tool
/// writes its alignments.
///
/// The stand-ins answer version probes the way the real tools do. The
/// micromamba fails with real micromamba's message for an environment that
/// does not exist under its root. The BBTools wrappers echo their `java`
/// command line with the install path on stderr, `mapPacBio.sh` with its
/// `minratio=0.40`, then print `BBTools version 39.01`, a version unlike the
/// lock pin.
struct MapReadSetStandIn {
    static let bbToolsVersion = "39.01"

    let rootURL: URL
    let logDirectory: URL
    let referenceURL: URL
    let condaRootURL: URL
    let pipeline: ManagedMappingPipeline

    static func make(in rootURL: URL) throws -> MapReadSetStandIn {
        let fileManager = FileManager.default
        let logDirectory = rootURL.appendingPathComponent("calls", isDirectory: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let referenceURL = rootURL.appendingPathComponent("reference.fa")
        try ">chr1\n\(String(repeating: "ACGTTGCA", count: 20))\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let condaRoot = rootURL.appendingPathComponent("conda", isDirectory: true)
        for (environment, executables) in [
            ("minimap2", ["minimap2"]),
            ("bwa-mem2", ["bwa-mem2"]),
            ("bowtie2", ["bowtie2", "bowtie2-build"]),
        ] {
            let bin = condaRoot.appendingPathComponent("envs/\(environment)/bin", isDirectory: true)
            try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
            for executable in executables {
                try writeExecutable("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent(executable))
            }
        }
        let micromamba = rootURL.appendingPathComponent("stand-in-micromamba")
        try writeExecutable(micromambaScript(logDirectory: logDirectory.path), to: micromamba)
        let condaManager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )

        let home = try ManagedSamtoolsHome.makeStub(
            rootURL: rootURL,
            namePrefix: "home",
            script: samtoolsScript(logDirectory: logDirectory.path)
        )
        for (executable, javaArguments) in [
            ("bbmap.sh", "-Xmx27928m -Xms27928m -cp %@ align2.BBMap build=1 overwrite=true fastareadlen=500"),
            ("mapPacBio.sh", "-Xmx27928m -Xms27928m -cp %@ align2.BBMapPacBio build=1 overwrite=true minratio=0.40 fastareadlen=6000"),
            ("reformat.sh", "-Xmx300m -Xms300m -cp %@ jgi.ReformatReads"),
        ] {
            let url = CoreToolLocator.executableURL(
                environment: "bbtools",
                executableName: executable,
                homeDirectory: home.homeURL
            )
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let installPath = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("opt/bbmap-\(bbToolsVersion)-0/current", isDirectory: true).path + "/"
            let javaLine = "java -ea   " + javaArguments.replacingOccurrences(of: "%@", with: installPath) + " --version"
            try writeExecutable(
                bbToolsScript(executable: executable, javaLine: javaLine, logDirectory: logDirectory.path),
                to: url
            )
        }
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home.homeURL)

        return MapReadSetStandIn(
            rootURL: rootURL,
            logDirectory: logDirectory,
            referenceURL: referenceURL,
            condaRootURL: condaRoot,
            pipeline: ManagedMappingPipeline(condaManager: condaManager, nativeToolRunner: runner)
        )
    }

    /// One recorded call.
    struct Call: Equatable {
        let tool: String
        let argv: [String]
    }

    /// Every recorded call in call order, then cleared.
    func takeCalls() throws -> [Call] {
        let files = try FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "argv" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let calls = try files.map { url -> Call in
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let tool = String(url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1).last ?? "")
            return Call(tool: tool, argv: Array(lines.dropLast()))
        }
        for url in files { try FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: logDirectory.appendingPathComponent("counter"))
        return calls
    }

    /// The mapper calls, each as the flags that decide pairing and the read
    /// names of every FASTQ file it was handed, such as
    /// `-1 [p1/1,p2/1] -2 [p1/2,p2/2] -U [m1]`.
    static func mapperInputs(_ calls: [Call]) throws -> [String] {
        try calls.filter { ["minimap2", "bwa-mem2", "bowtie2", "bbmap.sh"].contains($0.tool) }.map { call in
            var parts: [String] = []
            var index = 0
            let argv = call.argv
            while index < argv.count {
                let argument = argv[index]
                defer { index += 1 }
                switch call.tool {
                case "bwa-mem2":
                    if argument == "-t" || argument == "-R" { index += 1; continue }
                    if argument == "-p" { parts.append(argument); continue }
                case "bowtie2":
                    if ["-1", "-2", "-U", "--interleaved"].contains(argument) { parts.append(argument); continue }
                    if ["-x", "-p", "--rg-id", "--rg", "-S", "-k"].contains(argument) { index += 1; continue }
                case "minimap2":
                    if ["-x", "-t", "-R", "-o"].contains(argument) { index += 1; continue }
                case "bbmap.sh":
                    if argument.hasPrefix("in=") || argument.hasPrefix("in2=") {
                        let key = String(argument.prefix { $0 != "=" })
                        let value = String(argument.dropFirst(key.count + 1))
                        parts.append("\(key)=\(try names(ofFiles: value))")
                        continue
                    }
                    if argument.hasPrefix("interleaved=") { parts.append(argument) }
                    continue
                default:
                    break
                }
                if let rendered = try? names(ofFiles: argument), isFASTQList(argument) {
                    parts.append(rendered)
                }
            }
            return parts.joined(separator: " ")
        }
    }

    private static func isFASTQList(_ argument: String) -> Bool {
        let paths = argument.split(separator: ",").map(String.init)
        return !paths.isEmpty && paths.allSatisfy { path in
            let lower = path.lowercased()
            return (lower.hasSuffix(".fastq") || lower.hasSuffix(".fq") || lower.hasSuffix(".fastq.gz"))
                && FileManager.default.fileExists(atPath: path)
        }
    }

    /// `[a,b,...]`, the record names of one file or of a comma list of files.
    static func names(ofFiles argument: String) throws -> String {
        let names = try argument.split(separator: ",").flatMap { try ReadSetFixtures.readNames(in: URL(fileURLWithPath: String($0))) }
        return "[\(names.joined(separator: ","))]"
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Appends one call's argv to the log, one argument per line.
    private static func logFunction(_ logDirectory: String) -> String {
        """
        log_call() {
          tool="$1"
          shift
          n=$(cat '\(logDirectory)/counter' 2>/dev/null || echo 0)
          n=$((n + 1))
          echo "$n" > '\(logDirectory)/counter'
          file='\(logDirectory)'/"$n-$tool.argv"
          : > "$file"
          for arg in "$@"; do printf '%s\\n' "$arg" >> "$file"; done
        }
        header() {
          printf '@HD\\tVN:1.6\\tSO:unsorted\\n@SQ\\tSN:chr1\\tLN:160\\n'
        }
        """
    }

    private static func micromambaScript(logDirectory: String) -> String {
        """
        #!/bin/sh
        \(logFunction(logDirectory))
        if [ "$1" = "--version" ]; then echo "2.0.0"; exit 0; fi
        [ "$1" = "run" ] || exit 64
        shift
        if [ "$1" = "-n" ]; then
          prefix="$MAMBA_ROOT_PREFIX/envs/$2"
          if [ ! -d "$prefix" ]; then
            echo "critical libmamba The given prefix does not exist: \\"$prefix\\"" >&2
            exit 1
          fi
          shift 2
        fi
        tool="$1"
        shift
        case "$1" in --version|-v|version) echo "2.2.1"; exit 0 ;; esac
        if [ "$tool" = "bowtie2-build" ]; then exit 0; fi
        if [ "$tool" = "bwa-mem2" ] && [ "$1" = "index" ]; then exit 0; fi
        log_call "$tool" "$@"
        out=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "-o" ] || [ "$prev" = "-S" ]; then out="$arg"; fi
          prev="$arg"
        done
        if [ -n "$out" ]; then header > "$out"; else header; fi
        exit 0
        """
    }

    /// A BBTools wrapper. Like the real one it echoes its `java` command line
    /// on stderr, then the tool prints its version there.
    private static func bbToolsScript(executable: String, javaLine: String, logDirectory: String) -> String {
        """
        #!/bin/sh
        \(logFunction(logDirectory))
        case "$1" in
          --version|-v|version)
            echo '\(javaLine)' >&2
            echo "BBTools version \(bbToolsVersion)" >&2
            echo "For help, please run the shellscript with no parameters, or look in /docs/." >&2
            exit 0
            ;;
        esac
        log_call "\(executable)" "$@"
        for arg in "$@"; do
          case "$arg" in out=*) header > "${arg#out=}" ;; esac
        done
        exit 0
        """
    }

    private static func samtoolsScript(logDirectory: String) -> String {
        """
        #!/bin/sh
        \(logFunction(logDirectory))
        sub="$1"
        if [ "$sub" = "--version" ]; then echo "samtools 1.21"; exit 0; fi
        shift
        case "$sub" in
          view|sort|merge)
            log_call "samtools" "$sub" "$@"
            out=""
            prev=""
            for arg in "$@"; do
              if [ "$prev" = "-o" ]; then out="$arg"; fi
              prev="$arg"
            done
            if [ -n "$out" ]; then : > "$out"; fi
            ;;
          index)
            bam=""
            for arg in "$@"; do bam="$arg"; done
            : > "$bam.bai"
            ;;
          flagstat)
            echo "2 + 0 in total (QC-passed reads + QC-failed reads)"
            echo "2 + 0 primary"
            echo "2 + 0 mapped (100.00% : N/A)"
            echo "2 + 0 primary mapped (100.00% : N/A)"
            ;;
          coverage)
            printf '#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n'
            printf 'chr1\\t1\\t160\\t2\\t160\\t100.0\\t2.0\\t30.0\\t60.0\\n'
            ;;
        esac
        exit 0
        """
    }
}
