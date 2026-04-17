// BuildDbCommandMarkdupTests.swift - Tests that build-db uses markdup pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandMarkdupTests: XCTestCase {
    private func findFixtureDir(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        fatalError("Could not find fixture: \(name)")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbMarkdupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManagedSamtoolsHome() throws -> (home: URL, samtoolsPath: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("BuildDbMarkdupManagedHome-\(UUID().uuidString)", isDirectory: true)
        let samtoolsPath = home
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin/samtools", isDirectory: false)
        try fm.createDirectory(at: samtoolsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        exit 0
        """.write(to: samtoolsPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsPath.path)
        return (home, samtoolsPath)
    }

    private func makeFunctionalManagedSamtoolsHome() throws -> (home: URL, samtoolsPath: URL) {
        let fixture = try makeManagedSamtoolsHome()
        try writeScriptedSamtools(at: fixture.samtoolsPath)
        return fixture
    }

    private func writeScriptedSamtools(at samtoolsPath: URL) throws {
        try """
        #!/bin/sh
        set -eu

        cmd="${1:-}"
        if [ $# -gt 0 ]; then
          shift
        fi

        case "$cmd" in
          sort)
            output=""
            input="-"
            while [ $# -gt 0 ]; do
              case "$1" in
                -o)
                  output="$2"
                  shift 2
                  ;;
                -@)
                  shift 2
                  ;;
                -n|-m)
                  shift
                  ;;
                -)
                  input="-"
                  shift
                  ;;
                *)
                  input="$1"
                  shift
                  ;;
              esac
            done
            if [ -n "$output" ]; then
              if [ "$input" = "-" ]; then
                cat > "$output"
              else
                cat "$input" > "$output"
              fi
            else
              if [ "$input" = "-" ]; then
                cat
              else
                cat "$input"
              fi
            fi
            ;;
          fixmate)
            cat
            ;;
          markdup)
            input="${1:--}"
            output="${2:?missing output path}"
            {
              printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
              if [ "$input" = "-" ]; then
                cat
              else
                cat "$input"
              fi
            } > "$output"
            ;;
          index)
            : > "$1.bai"
            ;;
          idxstats)
            cat <<'EOF'
        NC_045512.2	29903	31	0
        OM695287.1	29674	26	0
        *	0	0	0
        EOF
            ;;
          view)
            header=0
            count=0
            flag=""
            bam=""
            accession=""
            while [ $# -gt 0 ]; do
              case "$1" in
                -H)
                  header=1
                  shift
                  ;;
                -c)
                  count=1
                  shift
                  ;;
                -F)
                  flag="$2"
                  shift 2
                  ;;
                *)
                  if [ -z "$bam" ]; then
                    bam="$1"
                  else
                    accession="$1"
                  fi
                  shift
                  ;;
              esac
            done
            if [ "$header" -eq 1 ]; then
              printf '@HD\\tVN:1.6\\tSO:coordinate\\n'
              if [ -n "$bam" ] && [ -f "$bam" ] && /usr/bin/grep -aq 'samtools markdup' "$bam"; then
                printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
              fi
              exit 0
            fi
            if [ "$count" -eq 1 ]; then
              if [ "$flag" = "1028" ]; then
                case "$accession" in
                  NC_045512.2) echo 25 ;;
                  OM695287.1) echo 20 ;;
                  "") echo 4 ;;
                  *) echo 5 ;;
                esac
              else
                case "$accession" in
                  NC_045512.2) echo 31 ;;
                  OM695287.1) echo 26 ;;
                  "") echo 5 ;;
                  *) echo 7 ;;
                esac
              fi
              exit 0
            fi
            exit 1
            ;;
          *)
            exit 1
            ;;
        esac
        """.write(to: samtoolsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsPath.path)
    }

    private func withHomeDirectory<T>(_ home: URL, perform block: () async throws -> T) async throws -> T {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        return try await block()
    }

    func testLocateSamtoolsPrefersManagedHome() throws {
        let fixture = try makeManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let resolved = MarkdupCommand.locateSamtools(homeDirectory: fixture.home)
        XCTAssertEqual(resolved, fixture.samtoolsPath.path)
    }

    func testLocateSamtoolsIgnoresPathFallbacks() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let fakePathDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: fakePathDir) }

        let fakeSamtools = fakePathDir.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        exit 0
        """.write(to: fakeSamtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSamtools.path)

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", fakePathDir.path, 1)
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        XCTAssertNil(MarkdupCommand.locateSamtools(homeDirectory: home))
    }

    /// build-db taxtriage should run markdup on all BAMs in the result directory.
    func testBuildDbTaxTriageRunsMarkdup() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtoolsPath = managedHome.samtoolsPath.path

        let tmp = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: managedHome.home)
        }

        let fixture = findFixtureDir("taxtriage-mini")
        let resultDir = tmp.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixture, to: resultDir)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        // Verify every BAM in minimap2/ has been marked
        let minimap2Dir = resultDir.appendingPathComponent("minimap2")
        let contents = try FileManager.default.contentsOfDirectory(at: minimap2Dir, includingPropertiesForKeys: nil)
        let bams = contents.filter { $0.pathExtension == "bam" }
        XCTAssertGreaterThan(bams.count, 0, "Fixture must have BAM files")
        for bam in bams {
            XCTAssertTrue(
                MarkdupService.isAlreadyMarkduped(bamURL: bam, samtoolsPath: samtoolsPath),
                "BAM \(bam.lastPathComponent) should have been marked by build-db"
            )
        }

        // Verify unique_reads values in DB are consistent with samtools view -c -F 0x404
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        let allRows = try db.fetchRows(samples: samples.map(\.sample))
        let rowsWithBAM = allRows.filter { $0.bamPath != nil && $0.primaryAccession != nil && $0.uniqueReads != nil }
        XCTAssertGreaterThan(rowsWithBAM.count, 0, "At least some rows should have unique reads populated")

        if let row = rowsWithBAM.first {
            let bamURL = resultDir.appendingPathComponent(row.bamPath!)
            let expected = try MarkdupService.countReads(
                bamURL: bamURL,
                accession: row.primaryAccession!,
                flagFilter: 0x404,
                samtoolsPath: samtoolsPath
            )
            XCTAssertEqual(row.uniqueReads, expected, "DB unique_reads must match samtools count")
        }
    }
}
