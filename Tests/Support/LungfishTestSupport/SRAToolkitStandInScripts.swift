// SRAToolkitStandInScripts.swift - Two scripts that stand in for prefetch and fasterq-dump for the built lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A folder of two executable scripts, `prefetch` and `fasterq-dump`, that a debug build of
/// `lungfish-cli` runs in place of the managed sra-tools environment when the child's environment names
/// the folder in ``variable`` (Phase 2.10 lane A45 M3, decision G1).
///
/// `prefetch` makes the stand-in archive `<output>/<accession>/<accession>.sra`. `fasterq-dump` copies the
/// files recorded for the run in `Tests/Fixtures/sra/fasterq-dump-split-3/<accession>/` into its `-O`
/// folder, as `SRAToolkitRecordedRunner` does in process, and fails with status 1 for a run with no
/// recorded files. With a marker, `prefetch` touches the marker and waits for a SIGTERM, for a test that
/// cancels the run while the toolkit works.
public enum SRAToolkitStandInScripts {
    /// The variable of the child's environment that names the folder.
    public static let variable = "LUNGFISH_SRA_TOOLKIT_STAND_IN_DIR"

    /// Writes the two scripts into `folder`.
    ///
    /// - Parameters:
    ///   - fixtures: `Tests/Fixtures/sra/fasterq-dump-split-3`.
    ///   - waitingMarker: When given, `prefetch` touches this file and then waits.
    public static func write(into folder: URL, fixtures: URL, waitingMarker: URL? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefetchBody: String
        if let waitingMarker {
            // exec makes the SIGTERM of a cancel reach the sleep.
            prefetchBody = "touch '\(waitingMarker.path)'\nexec sleep 600\n"
        } else {
            prefetchBody = """
            acc="$1"; out=""
            while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift 2;; *) shift;; esac; done
            mkdir -p "$out/$acc" && : > "$out/$acc/$acc.sra"

            """
        }
        let fasterqBody = """
        sra="$1"; out=""
        while [ $# -gt 0 ]; do case "$1" in -O) out="$2"; shift 2;; *) shift;; esac; done
        acc=$(basename "$sra" .sra)
        cp '\(fixtures.path)'/"$acc"/*.fastq "$out"/ 2>/dev/null || { echo "no recorded reads for $acc" >&2; exit 1; }

        """
        try write("#!/bin/sh\n" + prefetchBody, to: folder.appendingPathComponent("prefetch"))
        try write("#!/bin/sh\n" + fasterqBody, to: folder.appendingPathComponent("fasterq-dump"))
    }

    private static func write(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `Tests/Fixtures/sra/fasterq-dump-split-3`, found above the calling test's `#filePath`.
    public static func fixturesFolder(testFile: String) -> URL {
        var folder = URL(fileURLWithPath: testFile).deletingLastPathComponent()
        while folder.path != "/",
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) {
            folder = folder.deletingLastPathComponent()
        }
        return folder.appendingPathComponent("Tests/Fixtures/sra/fasterq-dump-split-3", isDirectory: true)
    }
}
