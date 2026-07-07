// BuildDbCommandTests.swift - Tests for the build-db CLI command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbCommandTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManagedSamtoolsHome() throws -> (home: URL, samtoolsPath: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("BuildDbManagedHome-\(UUID().uuidString)", isDirectory: true)
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
            input="-"
            output="-"
            while [ $# -gt 0 ]; do
              case "$1" in
                -m)
                  shift
                  ;;
                *)
                  if [ "$input" = "-" ]; then
                    input="$1"
                  else
                    output="$1"
                  fi
                  shift
                  ;;
              esac
            done
            if [ "$output" = "-" ]; then
              if [ "$input" = "-" ]; then
                cat
              else
                cat "$input"
              fi
            else
              if [ "$input" = "-" ]; then
                cat > "$output"
              else
                cat "$input" > "$output"
              fi
            fi
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

    private func writeTaxTriageTopReport(
        at url: URL,
        abundance: String = "0.01",
        cladeFragmentsCovered: String = "31.0",
        numberFragmentsAssigned: String = "30.0",
        rank: String = "S",
        taxID: Int = 2697049,
        name: String = "Severe acute respiratory syndrome coronavirus 2"
    ) throws {
        let content = """
        abundance\tclade_fragments_covered\tnumber_fragments_assigned\trank\ttaxid\tname
        \(abundance)\t\(cladeFragmentsCovered)\t\(numberFragmentsAssigned)\t\(rank)\t\(taxID)\t\(name)
        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Locates the taxtriage-mini fixture directory by walking up from the source file.
    private func findFixtureDir(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        fatalError("Could not find fixture directory: \(name)")
    }

    // MARK: - Tests

    /// Verifies that the command parses confidence TSV, resolves BAM paths and
    /// accessions, and produces a valid SQLite database.
    func testBuildDbTaxTriage() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Run command with --quiet to suppress output
        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        // Verify database was created
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                       "Database file should exist after build")

        // Open and verify contents
        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 3, "Should have 3 samples (SRR35517702, SRR35517703, SRR35517705)")

        let allSampleIds = samples.map(\.sample).sorted()
        XCTAssertEqual(allSampleIds, ["SRR35517702", "SRR35517703", "SRR35517705"])

        let allRows = try db.fetchRows(samples: allSampleIds)
        XCTAssertEqual(allRows.count, 15, "Fixture has 15 data rows")

        // Verify a specific row has expected fields
        let sarscov2Rows = allRows.filter { $0.organism.contains("Severe acute respiratory syndrome") }
        XCTAssertEqual(sarscov2Rows.count, 3, "SARS-CoV-2 appears in all 3 samples")

        // Check one specific row in detail
        let srr702Sars = sarscov2Rows.first { $0.sample == "SRR35517702" }
        XCTAssertNotNil(srr702Sars)
        if let row = srr702Sars {
            XCTAssertEqual(row.taxId, 2697049)
            XCTAssertEqual(row.status, "established")
            XCTAssertEqual(row.tassScore, 0.66, accuracy: 0.01)
            XCTAssertEqual(row.readsAligned, 31)
            XCTAssertNotNil(row.uniqueReads, "Unique reads should be computed from BAM dedup")
            if let unique = row.uniqueReads {
                XCTAssertLessThanOrEqual(unique, row.readsAligned,
                    "Unique reads cannot exceed total aligned reads")
            }
            XCTAssertEqual(row.highConsequence, true)
            XCTAssertEqual(row.isAnnotated, true)
            XCTAssertEqual(row.confidence, "Unknown")
            XCTAssertNotNil(row.primaryAccession, "Should have accession from gcfmap")
            XCTAssertEqual(row.primaryAccession, "NC_045512.2")
            XCTAssertEqual(row.bamPath, "minimap2/SRR35517702.SRR35517702.dwnld.references.bam")
            XCTAssertEqual(row.bamIndexPath, "minimap2/SRR35517702.SRR35517702.dwnld.references.bam.bai")
        }

        // Verify BAM path resolution
        let withBam = allRows.filter { $0.bamPath != nil }
        XCTAssertEqual(withBam.count, allRows.count, "All rows should have BAM paths (fixtures include BAM files)")

        // Verify metadata
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool"], "taxtriage")
        XCTAssertNotNil(meta["created_at"])
    }

    func testBuildDbTaxTriageFallsBackToTopReportsWithoutConfidenceFileOrSamtools() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let fm = FileManager.default
        try fm.removeItem(at: resultDir.appendingPathComponent("report/multiqc_data/multiqc_confidences.txt"))
        try fm.removeItem(at: resultDir.appendingPathComponent("minimap2"))
        try writeTaxTriageTopReport(
            at: resultDir.appendingPathComponent("top/SRR35517702.top_report.tsv")
        )

        try await withHomeDirectory(home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        XCTAssertTrue(fm.fileExists(atPath: dbURL.path),
                      "Database file should exist after top-report fallback import")

        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.map(\.sample), ["SRR35517702"])

        let rows = try db.fetchRows(samples: ["SRR35517702"])
        XCTAssertEqual(rows.count, 1)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sample, "SRR35517702")
        XCTAssertEqual(row.organism, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertEqual(row.taxId, 2697049)
        XCTAssertEqual(row.readsAligned, 31)
        XCTAssertEqual(try XCTUnwrap(row.pctReads), 0.01, accuracy: 0.0001)
        XCTAssertEqual(row.k2Reads, 30)
        XCTAssertEqual(row.tassScore, 0.0, accuracy: 0.0001)
        XCTAssertEqual(row.primaryAccession, "NC_045512.2")
        XCTAssertNil(row.bamPath)
        XCTAssertNil(row.uniqueReads)
        XCTAssertEqual(row.isSpecies, true)
    }

    func testBuildDbTaxTriageResolvesDownsampledMiniBAMNames() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let minimap2Dir = resultDir.appendingPathComponent("minimap2", isDirectory: true)
        let canonicalBAM = minimap2Dir.appendingPathComponent("SRR35517702.SRR35517702.dwnld.references.bam")
        let canonicalBAI = minimap2Dir.appendingPathComponent("SRR35517702.SRR35517702.dwnld.references.bam.bai")
        let downsampledBAM = minimap2Dir.appendingPathComponent("SRR35517702.downsampled.minibam.bam")
        let downsampledBAI = minimap2Dir.appendingPathComponent("SRR35517702.downsampled.minibam.bam.bai")
        try FileManager.default.moveItem(at: canonicalBAM, to: downsampledBAM)
        try FileManager.default.moveItem(at: canonicalBAI, to: downsampledBAI)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let db = try TaxTriageDatabase(at: resultDir.appendingPathComponent("taxtriage.sqlite"))
        let rows = try db.fetchRows(samples: ["SRR35517702"])
        let row = try XCTUnwrap(rows.first { $0.primaryAccession == "NC_045512.2" })
        XCTAssertEqual(row.bamPath, "minimap2/SRR35517702.downsampled.minibam.bam")
        XCTAssertEqual(row.bamIndexPath, "minimap2/SRR35517702.downsampled.minibam.bam.bai")
        XCTAssertEqual(row.uniqueReads, 25)
        XCTAssertEqual(row.readsAligned, 31)
        if let bamPath = row.bamPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resultDir.appendingPathComponent(bamPath).path))
        }
        if let bamIndexPath = row.bamIndexPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resultDir.appendingPathComponent(bamIndexPath).path))
        }
    }

    func testBuildDbTaxTriageDoesNotAssignUnmatchedSingleBAMToSample() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try writeTaxTriageTopReport(
            at: resultDir
                .appendingPathComponent("top", isDirectory: true)
                .appendingPathComponent("Alpha.top_report.tsv"),
            name: "Alpha virus"
        )

        let minimap2Dir = resultDir.appendingPathComponent("minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2Dir, withIntermediateDirectories: true)
        try Data("wrong sample bam\n".utf8).write(
            to: minimap2Dir.appendingPathComponent("Beta.downsampled.minibam.bam")
        )

        try await withHomeDirectory(home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let db = try TaxTriageDatabase(at: resultDir.appendingPathComponent("taxtriage.sqlite"))
        let row = try XCTUnwrap(try db.fetchRows(samples: ["Alpha"]).first)
        XCTAssertNil(row.bamPath)
        XCTAssertNil(row.bamIndexPath)
    }

    func testBuildDbTaxTriageDoesNotChooseAmbiguousEqualScoreMiniBAMs() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try writeTaxTriageTopReport(
            at: resultDir
                .appendingPathComponent("top", isDirectory: true)
                .appendingPathComponent("Alpha.top_report.tsv"),
            name: "Alpha virus"
        )

        let minimap2Dir = resultDir.appendingPathComponent("minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2Dir, withIntermediateDirectories: true)
        try Data("first bam\n".utf8).write(
            to: minimap2Dir.appendingPathComponent("Alpha.downsampled.minibam.first.bam")
        )
        try Data("second bam\n".utf8).write(
            to: minimap2Dir.appendingPathComponent("Alpha.downsampled.minibam.second.bam")
        )

        try await withHomeDirectory(home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let db = try TaxTriageDatabase(at: resultDir.appendingPathComponent("taxtriage.sqlite"))
        let row = try XCTUnwrap(try db.fetchRows(samples: ["Alpha"]).first)
        XCTAssertNil(row.bamPath)
        XCTAssertNil(row.bamIndexPath)
    }

    func testBuildDbTaxTriageParsesSerialSampleSubdirectories() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let resultDir = tmpDir.appendingPathComponent("taxtriage-batch")
        try writeTaxTriageTopReport(
            at: resultDir
                .appendingPathComponent("Alpha", isDirectory: true)
                .appendingPathComponent("top", isDirectory: true)
                .appendingPathComponent("Alpha.top_report.tsv"),
            taxID: 111,
            name: "Alpha virus"
        )
        try writeTaxTriageTopReport(
            at: resultDir
                .appendingPathComponent("Beta", isDirectory: true)
                .appendingPathComponent("top", isDirectory: true)
                .appendingPathComponent("Beta.top_report.tsv"),
            cladeFragmentsCovered: "17.0",
            numberFragmentsAssigned: "16.0",
            taxID: 222,
            name: "Beta virus"
        )

        try await withHomeDirectory(home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "--no-cleanup", "-q"])
            try await cmd.run()
        }

        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples().map(\.sample).sorted()
        XCTAssertEqual(samples, ["Alpha", "Beta"])

        let rows = try db.fetchRows(samples: samples).sorted { $0.sample < $1.sample }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.organism), ["Alpha virus", "Beta virus"])
        XCTAssertEqual(rows.map(\.readsAligned), [31, 17])
        XCTAssertNil(rows[0].bamPath)
        XCTAssertNil(rows[1].bamPath)
    }

    func testBuildDbTaxTriageCleansSerialSampleIntermediates() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let resultDir = tmpDir.appendingPathComponent("taxtriage-batch")
        let sampleDir = resultDir.appendingPathComponent("Alpha", isDirectory: true)
        try writeTaxTriageTopReport(
            at: sampleDir
                .appendingPathComponent("top", isDirectory: true)
                .appendingPathComponent("Alpha.top_report.tsv"),
            taxID: 111,
            name: "Alpha virus"
        )

        let fm = FileManager.default
        for dirname in ["count", "filterkraken", "get", "map", "samtools", "bedtools"] {
            let dir = sampleDir.appendingPathComponent(dirname, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent("dummy.txt").path, contents: Data("test".utf8))
        }
        let fastpDir = sampleDir.appendingPathComponent("fastp", isDirectory: true)
        try fm.createDirectory(at: fastpDir, withIntermediateDirectories: true)
        fm.createFile(atPath: fastpDir.appendingPathComponent("Alpha.fastp.fastq.gz").path, contents: Data("fastq".utf8))
        fm.createFile(atPath: fastpDir.appendingPathComponent("Alpha.fastp.html").path, contents: Data("report".utf8))
        fm.createFile(atPath: fastpDir.appendingPathComponent("Alpha.fastp.json").path, contents: Data("report".utf8))

        try await withHomeDirectory(home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        XCTAssertFalse(fm.fileExists(atPath: sampleDir.appendingPathComponent("count").path),
                       "serial sample count/ should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: sampleDir.appendingPathComponent("get").path),
                       "serial sample get/ should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: sampleDir.appendingPathComponent("filterkraken").path),
                       "serial sample filterkraken/ should be removed by cleanup")
        XCTAssertTrue(fm.fileExists(atPath: fastpDir.appendingPathComponent("Alpha.fastp.html").path),
                      "serial sample fastp HTML report should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: fastpDir.appendingPathComponent("Alpha.fastp.json").path),
                      "serial sample fastp JSON report should be preserved")
        XCTAssertFalse(fm.fileExists(atPath: fastpDir.appendingPathComponent("Alpha.fastp.fastq.gz").path),
                       "serial sample fastp FASTQ should be removed by cleanup")
    }

    func testLocateSamtoolsPrefersManagedHome() throws {
        let fixture = try makeManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let resolved = BuildDbCommand.locateSamtools(homeDirectory: fixture.home)
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

        XCTAssertNil(BuildDbCommand.locateSamtools(homeDirectory: home))
    }

    /// Verifies that the command skips building when a database already exists
    /// and --force is not specified.
    func testBuildDbSkipsExisting() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create empty DB file as a sentinel
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())

        // Run without --force — should skip
        let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // DB should still be empty (0 bytes) — not rebuilt
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertEqual(attrs[.size] as? Int, 0,
                       "Database should remain empty when --force is not specified")
    }

    /// Verifies that --force causes an existing database to be rebuilt.
    func testBuildDbForceRebuild() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create empty DB file
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())

        // Run WITH --force — should rebuild
        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "--force", "-q"])
            try await cmd.run()
        }

        // DB should now have content
        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        XCTAssertGreaterThan(attrs[.size] as? Int ?? 0, 0,
                             "Database should be rebuilt with --force")
    }

    /// Verifies that post-build cleanup removes intermediate directories and fastp
    /// FASTQ files while preserving QC reports and essential result directories.
    func testTaxTriageCleanupRemovesIntermediateFiles() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create fake intermediate directories that cleanup should remove
        let fm = FileManager.default
        for dirname in ["count", "filterkraken", "get", "map", "samtools", "bedtools"] {
            let dir = resultDir.appendingPathComponent(dirname)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Add a dummy file so directory isn't empty
            fm.createFile(atPath: dir.appendingPathComponent("dummy.txt").path, contents: Data("test".utf8))
        }

        // Create fastp/ with both FASTQ (should be removed) and HTML/JSON (should be kept)
        let fastpDir = resultDir.appendingPathComponent("fastp")
        try fm.createDirectory(at: fastpDir, withIntermediateDirectories: true)
        fm.createFile(atPath: fastpDir.appendingPathComponent("sample.fastp.fastq.gz").path, contents: Data("fastq".utf8))
        fm.createFile(atPath: fastpDir.appendingPathComponent("sample.fastp.html").path, contents: Data("report".utf8))
        fm.createFile(atPath: fastpDir.appendingPathComponent("sample.fastp.json").path, contents: Data("report".utf8))

        // Run build-db (cleanup enabled by default)
        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        // Verify intermediate dirs are gone
        XCTAssertFalse(fm.fileExists(atPath: resultDir.appendingPathComponent("count").path),
                       "count/ should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: resultDir.appendingPathComponent("filterkraken").path),
                       "filterkraken/ should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: resultDir.appendingPathComponent("get").path),
                       "get/ should be removed by cleanup")

        // Verify essential dirs are kept
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("report").path),
                      "report/ should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("minimap2").path),
                      "minimap2/ should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("combine").path),
                      "combine/ should be preserved")

        // Verify fastp/ HTML and JSON reports are kept, FASTQ removed
        XCTAssertTrue(fm.fileExists(atPath: fastpDir.appendingPathComponent("sample.fastp.html").path),
                      "fastp HTML report should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: fastpDir.appendingPathComponent("sample.fastp.json").path),
                      "fastp JSON report should be preserved")
        XCTAssertFalse(fm.fileExists(atPath: fastpDir.appendingPathComponent("sample.fastp.fastq.gz").path),
                       "fastp FASTQ file should be removed by cleanup")
    }

    // MARK: - EsViritu Tests

    /// Verifies that the command parses detection TSVs, resolves BAM paths,
    /// and produces a valid SQLite database.
    func testBuildDbEsViritu() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("esviritu-mini")
        let resultDir = tmpDir.appendingPathComponent("esviritu")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let dbURL = resultDir.appendingPathComponent("esviritu.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                       "Database file should exist after build")

        let db = try EsVirituDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 3, "Should have 3 samples")

        let allSampleIds = samples.map(\.sample).sorted()
        XCTAssertEqual(allSampleIds, ["SRR35517702", "SRR35517703", "SRR35517705"])

        let allRows = try db.fetchRows(samples: allSampleIds)
        XCTAssertGreaterThan(allRows.count, 0, "Should have detection rows")

        // Verify a specific row
        let sarscov2Rows = allRows.filter { $0.virusName.contains("Severe acute respiratory syndrome") }
        XCTAssertGreaterThan(sarscov2Rows.count, 0, "Should have SARS-CoV-2 detections")

        if let row = sarscov2Rows.first(where: { $0.sample == "SRR35517702" }) {
            XCTAssertEqual(row.accession, "OM695287.1")
            XCTAssertEqual(row.readCount, 26)
            XCTAssertNotNil(row.uniqueReads, "Unique reads should be computed from BAM dedup")
            if let unique = row.uniqueReads {
                XCTAssertLessThanOrEqual(unique, row.readCount,
                    "Unique reads cannot exceed total read count")
            }
            XCTAssertNotNil(row.rpkmf)
            XCTAssertNotNil(row.meanCoverage)
        }

        // Verify BAM paths were resolved
        let withBam = allRows.filter { $0.bamPath != nil }
        XCTAssertEqual(withBam.count, allRows.count,
                       "All rows should have BAM paths (fixtures include BAM files)")

        // Verify metadata
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool"], "esviritu")
        XCTAssertNotNil(meta["created_at"])
    }

    /// Verifies that EsViritu cleanup removes _temp dirs and intermediate TSVs
    /// while preserving detection TSVs.
    func testEsVirituCleanupRemovesIntermediateFiles() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("esviritu-mini")
        let resultDir = tmpDir.appendingPathComponent("esviritu")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let fm = FileManager.default

        // Run build-db (cleanup enabled by default)
        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        // Verify _temp dirs are removed
        let sampleDir = resultDir.appendingPathComponent("SRR35517702")
        XCTAssertFalse(fm.fileExists(atPath: sampleDir.appendingPathComponent("SRR35517702_temp").path),
                       "_temp/ should be removed by cleanup")

        // Verify intermediate TSVs are removed
        XCTAssertFalse(fm.fileExists(atPath: sampleDir.appendingPathComponent("SRR35517702.virus_coverage_windows.tsv").path),
                       "virus_coverage_windows.tsv should be removed by cleanup")
        XCTAssertFalse(fm.fileExists(atPath: sampleDir.appendingPathComponent("SRR35517702.detected_virus.assembly_summary.tsv").path),
                       "assembly_summary.tsv should be removed by cleanup")

        // Verify detection TSV and database are preserved
        XCTAssertTrue(fm.fileExists(atPath: sampleDir.appendingPathComponent("SRR35517702.detected_virus.info.tsv").path),
                      "detected_virus.info.tsv should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("esviritu.sqlite").path),
                      "esviritu.sqlite should be preserved")
    }

    // MARK: - Kraken2 Tests

    /// Verifies that the command parses kreport files, builds the SQLite database,
    /// and produces the expected sample and row counts.
    func testBuildDbKraken2() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("kraken2-mini")
        let resultDir = tmpDir.appendingPathComponent("kraken2")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let cmd = try BuildDbCommand.Kraken2Subcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        let dbURL = resultDir.appendingPathComponent("kraken2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path),
                      "Database file should exist after build")

        let db = try Kraken2Database(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 3, "Should have 3 samples")

        let allSampleIds = samples.map(\.sample).sorted()
        XCTAssertEqual(allSampleIds, ["SRR35517702", "SRR35517703", "SRR35517705"])

        let allRows = try db.fetchRows(samples: allSampleIds)
        XCTAssertGreaterThan(allRows.count, 0, "Should have classification rows")

        // Verify metadata
        let meta = try db.fetchMetadata()
        XCTAssertEqual(meta["tool"], "kraken2")
        XCTAssertNotNil(meta["created_at"])
    }

    func testBuildDbKraken2ExplicitSampleDirsExcludeSiblingKreports() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("kraken2-mini")
        let resultDir = tmpDir.appendingPathComponent("kraken2")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let includedSampleDir = resultDir.appendingPathComponent("SRR35517702")
        let excludedSampleDir = resultDir.appendingPathComponent("SRR35517703")
        let excludedKreport = resultDir
            .appendingPathComponent(excludedSampleDir.lastPathComponent)
            .appendingPathComponent("classification.kreport")
        let excludedRawOutput = excludedSampleDir.appendingPathComponent("classification.kraken")
        let excludedRawIndex = excludedSampleDir.appendingPathComponent("classification.kraken.idx.sqlite")
        let fm = FileManager.default
        fm.createFile(
            atPath: excludedRawOutput.path,
            contents: Data("""
            C\tread-1\t12345\t150\t12345:150
            U\tread-2\t0\t150\t0:150
            """.utf8)
        )
        fm.createFile(atPath: excludedRawIndex.path, contents: Data("excluded index".utf8))

        let cmd = try BuildDbCommand.Kraken2Subcommand.parse([
            resultDir.path,
            "--sample-dir", includedSampleDir.path,
            "-q",
        ])
        try await cmd.run()

        let dbURL = resultDir.appendingPathComponent("kraken2.sqlite")
        let db = try Kraken2Database(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.map(\.sample), ["SRR35517702"])

        let provenance = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: resultDir))
        XCTAssertTrue(provenance.argv.contains("--sample-dir"))
        XCTAssertTrue(provenance.argv.contains(includedSampleDir.standardizedFileURL.path))

        let explicitSampleDirs = provenance.options.explicit["sampleDirs"]?.arrayValue?
            .compactMap(\.fileValue)
            .map { $0.standardizedFileURL.path }
        XCTAssertEqual(explicitSampleDirs, [includedSampleDir.standardizedFileURL.path])

        let provenancePaths = Set(provenance.files.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        XCTAssertFalse(provenancePaths.contains(excludedKreport.standardizedFileURL.path))

        XCTAssertTrue(fm.fileExists(atPath: excludedRawOutput.path))
        XCTAssertTrue(fm.fileExists(atPath: excludedRawIndex.path))
        let provenanceOutputPaths = Set(provenance.outputs.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        XCTAssertFalse(provenanceOutputPaths.contains(excludedRawOutput.standardizedFileURL.path))
        XCTAssertFalse(provenanceOutputPaths.contains(excludedRawIndex.standardizedFileURL.path))
        XCTAssertFalse(fm.fileExists(atPath: excludedRawOutput.appendingPathExtension("gz").path))
    }

    func testBuildDbKraken2ExplicitSampleDirsRejectDuplicateSampleIds() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("kraken2-mini")
        let resultDir = tmpDir.appendingPathComponent("kraken2")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let firstParent = tmpDir.appendingPathComponent("first")
        let secondParent = tmpDir.appendingPathComponent("second")
        let firstSample = firstParent.appendingPathComponent("duplicate")
        let secondSample = secondParent.appendingPathComponent("duplicate")
        try FileManager.default.createDirectory(at: firstSample, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSample, withIntermediateDirectories: true)

        let cmd = try BuildDbCommand.Kraken2Subcommand.parse([
            resultDir.path,
            "--sample-dir", firstSample.path,
            "--sample-dir", secondSample.path,
            "-q",
        ])

        do {
            try await cmd.run()
            XCTFail("Expected duplicate sample directory basenames to be rejected")
        } catch let error as ValidationError {
            XCTAssertTrue(
                String(describing: error).contains("Duplicate --sample-dir sample identifier"),
                "Unexpected error: \(error)"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Verifies that Kraken2 cleanup compacts per-read output, writes the
    /// classified-read index sidecar, and keeps the report and result metadata.
    func testKraken2CleanupCompactsPerReadOutputAndRemovesRawIndex() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("kraken2-mini")
        let resultDir = tmpDir.appendingPathComponent("kraken2")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let fm = FileManager.default

        // Create fake intermediate files that cleanup should remove
        let sampleDir = resultDir.appendingPathComponent("SRR35517702")
        let krakenOutput = sampleDir.appendingPathComponent("classification.kraken")
        let krakenIndex = sampleDir.appendingPathComponent("classification.kraken.idx.sqlite")
        fm.createFile(
            atPath: krakenOutput.path,
            contents: Data("""
            C\tread-1\t12345\t150\t12345:150
            U\tread-2\t0\t150\t0:150
            C\tread-3\t12345\t150\t12345:150
            """.utf8)
        )
        fm.createFile(atPath: krakenIndex.path, contents: Data("kraken index".utf8))

        // Run build-db (cleanup enabled by default)
        let cmd = try BuildDbCommand.Kraken2Subcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        let compressedOutput = krakenOutput.appendingPathExtension("gz")
        let retainedIndex = KrakenIndexDatabase.indexURL(for: compressedOutput)

        // Verify the per-read output is retained in compact form for downstream
        // extraction, while the old raw-output index sidecar is cleaned up.
        XCTAssertFalse(fm.fileExists(atPath: krakenOutput.path),
                       "classification.kraken should be removed after compact retention succeeds")
        XCTAssertTrue(fm.fileExists(atPath: compressedOutput.path),
                      "classification.kraken.gz should be preserved for downstream read extraction")
        XCTAssertTrue(fm.fileExists(atPath: retainedIndex.path),
                      "classification.kraken.gz.idx.sqlite should be preserved for indexed extraction")
        XCTAssertFalse(fm.fileExists(atPath: krakenIndex.path),
                       "classification.kraken.idx.sqlite should be removed by cleanup")

        let retainedDatabase = try KrakenIndexDatabase(url: retainedIndex)
        XCTAssertTrue(retainedDatabase.isClassifiedOnly)
        XCTAssertTrue(retainedDatabase.canResolve(taxIds: [12345]))
        XCTAssertFalse(retainedDatabase.canResolve(taxIds: [0]))

        let sidecar = try ClassificationResult.load(from: sampleDir)
        XCTAssertEqual(sidecar.outputURL.lastPathComponent, "classification.kraken.gz")

        // Verify kreport and result JSON are preserved
        XCTAssertTrue(fm.fileExists(atPath: sampleDir.appendingPathComponent("classification.kreport").path),
                      "classification.kreport should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: sampleDir.appendingPathComponent("classification-result.json").path),
                      "classification-result.json should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("kraken2.sqlite").path),
                      "kraken2.sqlite should be preserved")

        let provenance = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: resultDir))
        let provenanceOutputPaths = Set(provenance.outputs.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        XCTAssertTrue(provenanceOutputPaths.contains(compressedOutput.standardizedFileURL.path))
        XCTAssertTrue(provenanceOutputPaths.contains(retainedIndex.standardizedFileURL.path))
    }

    func testKraken2CleanupFallbackRecordsRetainedRawOutputProvenance() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureDir = findFixtureDir("kraken2-mini")
        let resultDir = tmpDir.appendingPathComponent("kraken2")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        let sampleDir = resultDir.appendingPathComponent("SRR35517702")
        let rawOutput = sampleDir.appendingPathComponent("classification.kraken")
        try "not a kraken per-read record\n".write(to: rawOutput, atomically: true, encoding: .utf8)

        let cmd = try BuildDbCommand.Kraken2Subcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: rawOutput.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawOutput.appendingPathExtension("gz").path))

        let provenance = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: resultDir))
        let provenanceOutputPaths = Set(provenance.outputs.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        XCTAssertTrue(provenanceOutputPaths.contains(rawOutput.standardizedFileURL.path))

        let rawSidecar = ProvenanceRecorder.fileSidecarURL(for: rawOutput.standardizedFileURL)
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(fromSidecar: rawSidecar))
    }

    /// Verifies that --no-cleanup preserves all intermediate directories.
    func testTaxTriageNoCleanupPreservesAll() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        // Create fake intermediate directories
        let fm = FileManager.default
        for dirname in ["count", "filterkraken"] {
            let dir = resultDir.appendingPathComponent(dirname)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent("dummy.txt").path, contents: Data("test".utf8))
        }

        // Run with --no-cleanup
        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "--no-cleanup", "-q"])
            try await cmd.run()
        }

        // All directories should still exist
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("count").path),
                      "count/ should be preserved with --no-cleanup")
        XCTAssertTrue(fm.fileExists(atPath: resultDir.appendingPathComponent("filterkraken").path),
                      "filterkraken/ should be preserved with --no-cleanup")
    }

    func testBuildDbTaxTriageProvenanceRecordsSamtoolsSubsteps() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let provenance = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: resultDir))
        assertBuildDbProvenanceRecordsSamtoolsSubsteps(
            provenance,
            databaseURL: resultDir.appendingPathComponent("taxtriage.sqlite")
        )
        XCTAssertTrue(
            provenance.steps.contains { $0.toolName == "samtools" && $0.argv.dropFirst().contains("idxstats") },
            "TaxTriage build-db provenance must include the samtools idxstats accession-length pass"
        )
    }

    func testBuildDbEsVirituProvenanceRecordsSamtoolsSubsteps() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        defer { try? FileManager.default.removeItem(at: managedHome.home) }

        let fixtureDir = findFixtureDir("esviritu-mini")
        let resultDir = tmpDir.appendingPathComponent("esviritu")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "-q"])
            try await cmd.run()
        }

        let provenance = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: resultDir))
        assertBuildDbProvenanceRecordsSamtoolsSubsteps(
            provenance,
            databaseURL: resultDir.appendingPathComponent("esviritu.sqlite")
        )
    }

    private func assertBuildDbProvenanceRecordsSamtoolsSubsteps(
        _ provenance: ProvenanceEnvelope,
        databaseURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(provenance.exitStatus, 0, file: file, line: line)
        XCTAssertTrue(
            provenance.outputs.contains(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == databaseURL.standardizedFileURL.path
                    && $0.checksumSHA256 != nil
                    && ($0.fileSize ?? 0) > 0
            }),
            "build-db provenance must include the final SQLite database with checksum and size",
            file: file,
            line: line
        )

        let samtoolsSteps = provenance.steps.filter { $0.toolName == "samtools" }
        XCTAssertTrue(
            samtoolsSteps.contains { $0.argv.dropFirst().contains("markdup") },
            "build-db provenance must include the samtools markdup mutation step",
            file: file,
            line: line
        )
        XCTAssertTrue(
            samtoolsSteps.contains { $0.argv.dropFirst().contains("index") },
            "build-db provenance must include the samtools index mutation step",
            file: file,
            line: line
        )
        XCTAssertTrue(
            samtoolsSteps.contains {
                $0.argv.dropFirst().contains("view")
                    && $0.argv.contains("-c")
                    && $0.argv.contains("-F")
            },
            "build-db provenance must include samtools view count steps used to update unique_reads",
            file: file,
            line: line
        )

        for step in samtoolsSteps {
            XCTAssertEqual(step.exitStatus, 0, file: file, line: line)
            XCTAssertNotNil(step.wallTimeSeconds, file: file, line: line)
            XCTAssertFalse(step.reproducibleCommand.isEmpty, file: file, line: line)
        }

        XCTAssertTrue(
            samtoolsSteps.contains(where: { step in
                step.outputs.contains(where: { output in
                    output.path.hasSuffix(".bam")
                        && output.checksumSHA256 != nil
                        && (output.fileSize ?? 0) > 0
                })
            }),
            "samtools markdup step must record the mutated BAM output with checksum and size",
            file: file,
            line: line
        )
        XCTAssertTrue(
            samtoolsSteps.contains(where: { step in
                step.outputs.contains(where: { output in
                    output.path.hasSuffix(".bam.bai")
                        && output.checksumSHA256 != nil
                        && output.fileSize != nil
                })
            }),
            "samtools index step must record the BAM index output with checksum and size",
            file: file,
            line: line
        )

        if let bamOutput = provenance.outputs.first(where: { $0.path.hasSuffix(".bam") }) {
            let bamSidecar = ProvenanceRecorder.fileSidecarURL(
                for: URL(fileURLWithPath: bamOutput.path).standardizedFileURL
            )
            XCTAssertNotNil(
                ProvenanceRecorder.loadEnvelope(fromSidecar: bamSidecar),
                "mutated BAM outputs must receive focused build-db provenance sidecars",
                file: file,
                line: line
            )
        }
        if let indexOutput = provenance.outputs.first(where: { $0.path.hasSuffix(".bam.bai") }) {
            let indexSidecar = ProvenanceRecorder.fileSidecarURL(
                for: URL(fileURLWithPath: indexOutput.path).standardizedFileURL
            )
            XCTAssertNotNil(
                ProvenanceRecorder.loadEnvelope(fromSidecar: indexSidecar),
                "mutated BAM index outputs must receive focused build-db provenance sidecars",
                file: file,
                line: line
            )
        }
    }

    func testBuildDbTaxTriageFailsWithoutManagedSamtools() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let fixtureDir = findFixtureDir("taxtriage-mini")
        let resultDir = tmpDir.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixtureDir, to: resultDir)

        do {
            try await withHomeDirectory(home) {
                let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
                try await cmd.run()
            }
            XCTFail("Expected build-db to fail without managed samtools")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Managed samtools is required"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))

        let provenance = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: resultDir))
        XCTAssertEqual(provenance.exitStatus, 1)
        XCTAssertTrue(provenance.stderr?.contains("Managed samtools is required") == true)
        XCTAssertEqual(provenance.options.resolvedDefaults["samtoolsAvailable"]?.booleanValue, false)
        XCTAssertFalse(provenance.outputs.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == dbURL.standardizedFileURL.path
        })
        XCTAssertNil(
            ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: dbURL.standardizedFileURL))
        )
    }
}
