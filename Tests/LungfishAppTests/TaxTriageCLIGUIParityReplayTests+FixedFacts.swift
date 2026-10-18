// TaxTriageCLIGUIParityReplayTests+FixedFacts.swift - Facts every side of a TaxTriage parity case must hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Section 2.2 of the 2.9 QA inventory. Two sides can agree and both be wrong when a shared step
// changes, so each side is also held to values that come from the fixtures and the request:
//
// - the records the engine counted in each samplesheet column, the subset's 55 (never its 10
//   preview reads or its 100 root reads), both mates of the pair in one row,
// - one Nextflow per sample on the GUI route and one for every sample on the pooled command
//   (2.8 T2), each launch with the engine's profile, writing below the side's analysis folder,
// - each sample's report in the result, and a record whose TaxTriage step names the command that
//   launched the engine (2.8 T16),
// - a `taxtriage.sqlite` that lists every sample, with the five organisms of the stand-in's
//   report, and source manifest entries that name the run, on a side that writes them,
// - every file a record names in the project exists, or a later removal step names it (2.8 P1,
//   the rule of ClassifierCLIGUIParityReplayTests.namedFileDifferences),
// - side C's row with its label, detail and recorded command.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension TaxTriageParityHarness {
    /// The fixed facts `run` does not hold, one difference each. Facts of every end come first: no
    /// stand-in process outlives the run, and a cancelled request or a failed sample writes nothing
    /// into its bundle (+Faults.swift). A cancelled case then checks its cancel, and every other
    /// case its end and its result.
    func fixedFactViolations(
        _ parityCase: TaxTriageParityCase,
        run: TaxTriageParitySideRun,
        engine: TaxTriageParityEngine,
        pristineProject: URL
    ) throws -> [TaxTriageParityDifference] {
        if case .notRun = run.terminal { return [] }
        var violations: [TaxTriageParityDifference] = []
        func violate(_ fact: String, _ detail: String) {
            violations.append(TaxTriageParityDifference(id: "fact: \(fact)", detail: "\(run.side) \(detail)"))
        }
        let samples = parityCase.bundlePaths.map(TaxTriageParitySampleFacts.forBundle)
        leftoverProcessViolations(run: run, violate: violate)
        untouchedBundleViolations(parityCase, run: run, pristineProject: pristineProject, violate: violate)
        let analysis = run.analysisFolder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        if parityCase.expectedEnd == .cancelled {
            if let analysis {
                violations += try namedFileViolations(of: run)
                if engine.standIn != nil {
                    launchViolations(parityCase, samples: samples, run: run, analysis: analysis, engine: engine, violate: violate)
                }
            }
            cancelledViolations(run: run, violate: violate)
            return violations
        }
        // What the engine received is a fact of the request whatever the end, so a side that
        // ends otherwise than the case expects still freezes its launches.
        if let analysis, engine.standIn != nil {
            launchViolations(parityCase, samples: samples, run: run, analysis: analysis, engine: engine, violate: violate)
        }
        let end = TaxTriageParityComparison.outcome(of: run)
        guard end == parityCase.expectedEnd.rawValue else {
            // The id holds the end itself, so a declared end pins how the side ends.
            violate("the run ends \(parityCase.expectedEnd.rawValue), not \(run.terminal)", end)
            return violations
        }
        guard let analysis else {
            violate("the run made its analysis folder", "\(run.terminal)")
            return violations
        }
        violations += try namedFileViolations(of: run)
        resultViolations(parityCase, samples: samples, analysis: analysis, violate: violate)
        try databaseViolations(parityCase, samples: samples, analysis: analysis, engine: engine, violate: violate)
        manifestViolations(parityCase, run: run, analysis: analysis, violate: violate)
        if let row = run.row {
            rowViolations(parityCase, samples: samples, row: row, run: run, analysis: analysis, engine: engine, violate: violate)
        }
        if parityCase.rebuildsAfterTheCleanup {
            rebuildViolations(run: run, keepsTop: parityCase.keepsTop(on: run.side), violate: violate)
        }
        if parityCase == .x8 {
            pooledRequestViolations(parityCase, analysis: analysis, violate: violate)
        }
        return violations
    }

    // MARK: - Launches

    /// What the stand-in received while the side ran. The GUI route runs one Nextflow per sample,
    /// as a replayed command of one sample and a `--project` run of sides C and C' do, and side
    /// B's pooled command and X8's plain `--output` run one Nextflow for every sample of the
    /// request (2.8 T2).
    private func launchViolations(
        _ parityCase: TaxTriageParityCase,
        samples: [TaxTriageParitySampleFacts],
        run: TaxTriageParitySideRun,
        analysis: URL,
        engine: TaxTriageParityEngine,
        violate: (String, String) -> Void
    ) {
        let pooled = parityCase.runsPooled(on: run.side)
        let expected = pooled ? [samples.map(\.sampleID).sorted()] : samples.map { [$0.sampleID] }
        let launched = run.launches.map { Set($0.fastqRecords.map(\.sample)).sorted() }
        if launched.map({ $0.joined(separator: ",") }).sorted() != expected.map({ $0.joined(separator: ",") }).sorted() {
            let fact = pooled ? "one Nextflow runs all \(samples.count) samples" : "one Nextflow runs each sample"
            violate(fact, "launches ran \(launched)")
        }

        for sample in samples {
            let holding = run.launches.filter { launch in launch.fastqRecords.contains { $0.sample == sample.sampleID } }
            guard let launch = holding.first, holding.count == 1 else {
                violate("\(sample.sampleID) runs in one launch", "\(holding.count) launches name it")
                continue
            }
            let rows = Self.samplesheetRows(launch.samplesheet).filter { $0.first == sample.sampleID }
            if rows.count != 1 {
                violate("\(sample.sampleID) is one samplesheet row", "\(rows.count) rows in \(String(decoding: launch.samplesheet, as: UTF8.self).debugDescription)")
            }
            let counted = ["fastq_1", "fastq_2"].compactMap { column in
                launch.fastqRecords.first { $0.sample == sample.sampleID && $0.column == column }?.records
            }
            if counted != sample.records {
                let never = sample.records == [ClassifierParityFixtures.subsetReads] ? ", never 10 or 100" : ""
                let what = sample.isPair ? "both mates in its row, \(sample.records[0]) records each" : "\(sample.records[0]) records\(never)"
                violate("the engine counts \(sample.sampleID) as \(what)", "counted \(counted) in \(launch.fastqRecords)")
            }
        }

        let analysisPath = Self.resolved(analysis.path)
        for launch in run.launches {
            let number = launch.folder.lastPathComponent
            // A launch ends as its samples do, 1 when the stand-in fails one of them, by a signal when
            // the run is cancelled, else 0. Its record states the same, a cancel as 125 (E5).
            let failing = !Set(launch.fastqRecords.map(\.sample)).isDisjoint(with: parityCase.failingSamples)
            let expectedExit: Int32? = parityCase.expectedEnd == .cancelled ? nil : (failing ? 1 : 0)
            if launch.exitStatus != expectedExit {
                violate(
                    "every launch exits as its samples do",
                    "launch \(number) exited \(launch.exitStatus.map(String.init) ?? "by a signal"), not \(expectedExit.map(String.init) ?? "by a signal")"
                )
            }
            if launch.value(after: "-profile") != engine.profile {
                violate("every launch runs the \(engine.profile) profile", "launch \(number) ran \(launch.value(after: "-profile") ?? "none")")
            }
            guard let outdir = launch.value(after: "--outdir"),
                  Self.resolved(outdir) == analysisPath || Self.resolved(outdir).hasPrefix(analysisPath + "/") else {
                violate("every launch writes below the analysis folder", "launch \(number) wrote \(launch.value(after: "--outdir") ?? "nowhere")")
                continue
            }
            let step = ProvenanceRecorder.load(from: URL(fileURLWithPath: outdir, isDirectory: true))?
                .steps.first { $0.toolName == "taxtriage" }
            if step?.exitCode != (expectedExit ?? 125) || step.map({ Array($0.command.suffix(launch.arguments.count)) }) != launch.arguments {
                violate(
                    "the record of each launch names the command that launched the engine",
                    "launch \(number), step \(step.map { "exit \($0.exitCode.map(String.init) ?? "none"), \($0.command)" } ?? "missing")"
                )
            }
        }
    }

    /// The rows of a samplesheet after its header, each split at its commas.
    static func samplesheetRows(_ samplesheet: Data) -> [[String]] {
        String(decoding: samplesheet, as: UTF8.self)
            .split(separator: "\n")
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Result, database and manifests

    /// The result `taxtriage-result.json` describes: exit 0, every sample, the organism report of
    /// each sample that did not fail, which exists, each failed sample and each ignored task
    /// failure.
    private func resultViolations(
        _ parityCase: TaxTriageParityCase,
        samples: [TaxTriageParitySampleFacts],
        analysis: URL,
        violate: (String, String) -> Void
    ) {
        guard let result = try? TaxTriageResult.load(from: analysis) else {
            violate("the analysis folder holds its result", "no readable taxtriage-result.json in \(analysis.lastPathComponent)")
            return
        }
        let identifiers = samples.map(\.sampleID).sorted()
        if result.exitCode != 0 || result.config.samples.map(\.sampleId).sorted() != identifiers {
            violate("the result holds every sample with exit 0", "exit \(result.exitCode), samples \(result.config.samples.map(\.sampleId))")
        }
        let reported = identifiers.filter { !parityCase.failingSamples.contains($0) }
        let reports = result.reportFiles.map(\.lastPathComponent).sorted()
        let missing = result.reportFiles.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if reports != reported.map({ "\($0).odr.txt" }) || !missing.isEmpty {
            violate("the result names each sample's organism report", "reports \(reports), missing \(missing.map(\.lastPathComponent))")
        }
        let failed = result.sampleFailures.map(\.sampleID).sorted()
        if failed != parityCase.failingSamples.sorted() {
            violate("the result lists each failed sample", "\(failed)")
        }
        if result.ignoredFailures.count != parityCase.ignoredFailuresPerSample * samples.count {
            violate("the result lists each ignored task failure", "\(result.ignoredFailures.count) for \(samples.count) samples")
        }
    }

    /// A `taxtriage.sqlite` lists every sample, each with the five organisms of the stand-in's
    /// report (the 3.3.8 fixture), on a side that builds one.
    private func databaseViolations(
        _ parityCase: TaxTriageParityCase,
        samples: [TaxTriageParitySampleFacts],
        analysis: URL,
        engine: TaxTriageParityEngine,
        violate: (String, String) -> Void
    ) throws {
        let database = analysis.appendingPathComponent("taxtriage.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        let listed = try TaxTriageDatabase(at: database).fetchSamples().sorted { $0.sample < $1.sample }
        let organisms = engine.standIn == nil ? nil : parityCase.standInOrganisms
        let indexed = samples.map(\.sampleID).filter { !parityCase.failingSamples.contains($0) }.sorted()
        if listed.map(\.sample) != indexed
            || organisms.map({ count in listed.contains { $0.organismCount != count } }) == true {
            violate("taxtriage.sqlite lists every sample with the report's organisms", "\(listed)")
        }
    }

    /// A source bundle's manifest, where a side writes one, holds one TaxTriage entry, which names
    /// the run's analysis folder.
    private func manifestViolations(
        _ parityCase: TaxTriageParityCase,
        run: TaxTriageParitySideRun,
        analysis: URL,
        violate: (String, String) -> Void
    ) {
        for bundlePath in parityCase.bundlePaths {
            let bundle = run.project.appendingPathComponent(bundlePath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent(AnalysisManifest.filename).path) else { continue }
            let entries = AnalysisManifestStore.load(bundleURL: bundle, projectURL: run.project).analyses.filter { $0.tool == "taxtriage" }
            if entries.count != 1 || entries.contains(where: { ($0.analysisDirectoryName as NSString).lastPathComponent != analysis.lastPathComponent }) {
                violate(
                    "the source manifest names the run once",
                    "\(bundlePath) holds \(entries.map(\.analysisDirectoryName)) for \(analysis.lastPathComponent)"
                )
            }
        }
    }

    // MARK: - Row

    /// Side C's row as the Tools menu launch writes it: its title and first detail, Completed, the
    /// result's summary as its detail, no error and no alert, and the command of the run.
    private func rowViolations(
        _ parityCase: TaxTriageParityCase,
        samples: [TaxTriageParitySampleFacts],
        row: TaxTriageParityRow,
        run: TaxTriageParitySideRun,
        analysis: URL,
        engine: TaxTriageParityEngine,
        violate: (String, String) -> Void
    ) {
        let count = samples.count
        let title = "TaxTriage (\(count) sample\(count == 1 ? "" : "s"))"
        if row.title != title || row.firstDetail != "Starting TaxTriage pipeline\u{2026}" {
            violate("the row reads \(title), Starting TaxTriage pipeline", "\(row.title), \(row.firstDetail)")
        }
        let warnings = row.logLines.filter { $0.hasPrefix("[warning]") }
        if parityCase.expectedEnd == .completed {
            let lines = row.completionDetail.components(separatedBy: "\n")
            if row.stateLabel != "Completed" || lines.first != "TaxTriage pipeline completed successfully"
                || !lines.contains("Samples: \(count)") || !lines.contains("Reports: \(count)") {
                violate("the row completes with the result's summary", "\(row.stateLabel), \(row.completionDetail.debugDescription)")
            }
        } else {
            // Completed with Warnings, a detail that names the failures and counts the reports, and
            // one warning line per failure (2.8 T8, D4): one per failed sample, and one for the
            // errored tasks of the run.
            let reports = samples.filter { !parityCase.failingSamples.contains($0.sampleID) }.count
            let failed = parityCase.failingSamples.count
            let counted = "(\(reports) report\(reports == 1 ? "" : "s"))"
            let detailHolds = failed > 0
                ? row.completionDetail == "\(failed) failed sample\(failed == 1 ? "" : "s") \(counted)"
                : row.completionDetail.hasSuffix(" \(counted)") && row.completionDetail.contains("MINIMAP2_ALIGN")
            let expectedWarnings = failed + (parityCase.ignoredFailuresPerSample > 0 ? 1 : 0)
            if row.stateLabel != TaxTriageParityCase.End.completedWithWarnings.rawValue || !detailHolds || warnings.count != expectedWarnings {
                violate(
                    "the row completes with warnings, one warning line per failure",
                    "\(row.stateLabel), \(row.completionDetail.debugDescription), \(warnings)"
                )
            }
        }
        if row.errorMessage != nil || row.alertText != nil {
            violate("the row shows no error and no alert", "error \(row.errorMessage ?? "none"), alert \(row.alertText ?? "none")")
        }

        cliRouteCommandViolations(parityCase, samples: samples, run: run, analysis: analysis, engine: engine, violate: violate)
    }

    /// The command side C's row records on the CLI route (Phase 2.11 U30 M3), the only route since
    /// Phase 2.12 K1. It is `taxtriage run --project` with one `--input` per bundle, `--sample` for one
    /// sample and `--batch` for several, so a request of several samples records its command. It is also the argv the result's root
    /// record names, so Copy CLI Command replays what ran (BIO's 2.10 requirement), which side C'
    /// runs.
    private func cliRouteCommandViolations(
        _ parityCase: TaxTriageParityCase,
        samples: [TaxTriageParitySampleFacts],
        run: TaxTriageParitySideRun,
        analysis: URL,
        engine: TaxTriageParityEngine,
        violate: (String, String) -> Void
    ) {
        let parsed = try? RecordedCLICommand.parse(run.recordedCommand) as? TaxTriageCommand.RunSubcommand
        let bundles = parityCase.bundlePaths.map { Self.resolved(run.project.appendingPathComponent($0, isDirectory: true).path) }
        guard let parsed,
              parsed.inputs.map(Self.resolved).sorted() == bundles.sorted(),
              parsed.input2 == nil,
              parsed.sampleId == (samples.count == 1 ? samples[0].sampleID : nil),
              parsed.batch == (samples.count > 1),
              parsed.project.map(Self.resolved) == Self.resolved(run.project.path),
              parsed.outputDir == nil,
              parsed.databasePath.map(Self.resolved) == Self.resolved(engine.databasePath.path),
              parsed.nfProfile == engine.profile,
              parsed.maxCpus == engine.maxCpus else {
            violate("the row records the taxtriage run --project command of the run", run.recordedCommand ?? "nil")
            return
        }
        let words = run.recordedCommand.flatMap { try? RecordedCLICommand.arguments(of: $0) }
        let recorded = (try? ProvenanceEnvelopeReader.load(from: analysis)).map { Array($0.argv.dropFirst()) }
        if words == nil || words != recorded {
            violate("the row's command is the argv the root record names", "row \(words ?? []), record \(recorded ?? [])")
        }
        // Q32's live class runs `routedCommand` as side C (the legacy row's words with --project in place of
        // --output, TaxTriageParityLiveConformanceTests.swift:204), so for one sample the route must run the
        // same words, else the real-engine evidence is for a command that does not ship (review of U30 M3).
        // The transport adds --format json, which `routedCommand` leaves to the binary runner.
        if samples.count == 1, let words {
            let routed = try? routedCommand(parityCase, root: run.project.deletingLastPathComponent(), engine: engine)
            let ran = Self.withoutFormat(words)
            if routed.map(Self.withoutFormat) != ran {
                violate("the route's command is the command Q32's live class runs as side C", "route \(ran), routed \(routed ?? [])")
            }
        }
    }

    /// `words` without its `--format <value>` pair.
    private nonisolated static func withoutFormat(_ words: [String]) -> [String] {
        guard let index = words.firstIndex(of: "--format"), index + 1 < words.count else { return words }
        return Array(words[..<index]) + Array(words[(index + 2)...])
    }

    // MARK: - Named files

    /// Every file a record under the side root names in the project that does not exist, or that
    /// holds another digest than the record states, and that no later removal step accounts for.
    func namedFileViolations(of run: TaxTriageParitySideRun) throws -> [TaxTriageParityDifference] {
        let records = try TaxTriageParityComparison.Rules.recordPaths(under: run.root).map {
            (path: $0, facts: try TaxTriageParityComparison.factsTree(of: run, record: $0))
        }
        var digests: [String: String] = [:]
        return try ClassifierCLIGUIParityReplayTests.namedFileDifferences(side: "\(run.side)", records: records) { relativePath in
            let file = run.project.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else { return nil }
            guard !isDirectory.boolValue else { return .folder }
            return .file {
                let actual = try digests[file.path] ?? ClassifierParityFixtures.sha256(of: file)
                digests[file.path] = actual
                return actual
            }
        }
        .map { TaxTriageParityDifference(id: $0.id, detail: $0.detail) }
    }
}
