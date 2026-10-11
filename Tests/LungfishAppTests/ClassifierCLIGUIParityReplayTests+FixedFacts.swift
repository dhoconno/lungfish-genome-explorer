// ClassifierCLIGUIParityReplayTests+FixedFacts.swift - Facts every side of a classifier case must hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision T2 and the BIO memo's amendment. Two sides can agree and both be wrong when a
// shared pipeline changes, so each side is also held to values that come from the fixtures and
// never from a tool build: the subset holds 55 reads (never its 10 preview reads or its 100 root
// reads), the merge bundle holds 100 fragments as 23 pairs and 77 merged reads with its read-set
// plan, pairs run as pairs (`--paired`, `-p paired`), and the thresholds and thread count are
// the ones the wizard chose. Side A's Operations row is held to today's labels (UX memo T2).

import Foundation
import XCTest
import LungfishTestSupport

/// What one sample of a case must show, from the fixtures alone.
struct ClassifierParitySampleFacts {
    let sampleID: String
    /// The fragments Kraken2 counts, classified plus unclassified.
    let fragments: Int
    /// The records of the materialized input a side keeps, when the bundle is virtual.
    let materializedReads: Int?
    /// 23 pairs and 77 merged reads, when the bundle holds both.
    let readSetComposition: (pairs: Int, merged: Int)?
    /// Whether the tool runs the sample as pairs.
    let runsAsPairs: Bool
    /// What EsViritu's read statistics count before its quality filter, when fixed.
    let esVirituReadsBeforeFilter: Int?

    static func forBundle(_ path: String) -> ClassifierParitySampleFacts {
        switch path {
        case ClassifierParityFixtures.mergeBundlePath:
            return .init(sampleID: "merge", fragments: 100, materializedReads: nil, readSetComposition: (23, 77), runsAsPairs: true, esVirituReadsBeforeFilter: nil)
        case ClassifierParityFixtures.pairBundlePath:
            // EsViritu counts reads, so the 100 pairs are 200 reads before its filter.
            return .init(sampleID: "sarscov2-pair", fragments: 100, materializedReads: nil, readSetComposition: nil, runsAsPairs: true, esVirituReadsBeforeFilter: 200)
        case ClassifierParityFixtures.negativeControlBundlePath:
            return .init(sampleID: "negative-control", fragments: 40, materializedReads: nil, readSetComposition: nil, runsAsPairs: false, esVirituReadsBeforeFilter: nil)
        default:
            let subset = ClassifierParityFixtures.subsetReads
            return .init(sampleID: "len-150-any-00000000", fragments: subset, materializedReads: subset, readSetComposition: nil, runsAsPairs: false, esVirituReadsBeforeFilter: subset)
        }
    }
}

extension ClassifierCLIGUIParityReplayTests {
    /// The fixed facts `run` does not hold, one difference each, named by sample.
    func fixedFactViolations(
        _ parityCase: ClassifierParityCase,
        run: ClassifierParitySideRun
    ) throws -> [ClassifierParityDifference] {
        if case .notRun = run.terminal { return [] }
        // Every case is expected to complete. K5 does not today, which
        // ClassifierParityKnownDifferences declares. The facts of a run that did not are not
        // read.
        guard run.terminal.succeeded else {
            return [ClassifierParityDifference(id: "fact: the run completes", detail: "\(run.side) \(run.terminal)")]
        }
        guard let analysis = run.analysisFolder, FileManager.default.fileExists(atPath: analysis.path) else {
            return [ClassifierParityDifference(id: "fact: the run made its analysis folder", detail: "\(run.side) \(run.terminal)")]
        }
        var violations: [ClassifierParityDifference] = []
        for bundle in parityCase.bundlePaths {
            let expected = ClassifierParitySampleFacts.forBundle(bundle)
            let folder = sampleFolder(of: parityCase, analysis: analysis, sampleID: expected.sampleID)
            let facts = try recordFacts(in: folder, run: run)
            func violate(_ fact: String, _ detail: String) {
                violations.append(ClassifierParityDifference(id: "fact: \(expected.sampleID) \(fact)", detail: detail))
            }
            switch parityCase.tool {
            case .kraken2:
                kraken2Violations(parityCase, expected, folder: folder, facts: facts, violate: violate)
            case .esViritu:
                esVirituViolations(expected, folder: folder, facts: facts, violate: violate)
            }
            if let reads = expected.materializedReads {
                let kept = materializedInputs(in: folder)
                let counts = try kept.map { try ClassifierParityFixtures.fastqRecordCount($0) }
                if parityCase.tool == .kraken2, kept.isEmpty {
                    violate("keeps its materialized input", "no FASTQ under the sample's materialization folders")
                }
                if !kept.isEmpty, counts.reduce(0, +) != reads || counts.contains(where: { [10, 100].contains($0) }) {
                    violate("materialized \(reads) reads, never 10 or 100", "\(zip(kept.map(\.lastPathComponent), counts).map { "\($0) \($1)" })")
                }
            }
        }
        return violations
    }

    private func kraken2Violations(
        _ parityCase: ClassifierParityCase,
        _ expected: ClassifierParitySampleFacts,
        folder: URL,
        facts: [ProvenanceCompatFacts.Value],
        violate: (String, String) -> Void
    ) {
        let kreport = folder.appendingPathComponent("classification.kreport")
        if let totals = try? ClassifierParityFixtures.kreportTotals(kreport) {
            let total = totals.classified + totals.unclassified
            if total != expected.fragments || [10, 100].contains(total) && expected.fragments == ClassifierParityFixtures.subsetReads {
                violate("kreport counts \(expected.fragments) fragments", "classified \(totals.classified), unclassified \(totals.unclassified)")
            }
            if parityCase == .k5, totals.classified != 0 {
                violate("negative control classifies nothing", "classified \(totals.classified)")
            }
        } else {
            violate("kreport counts \(expected.fragments) fragments", "no readable \(kreport.lastPathComponent)")
        }

        let kraken2 = invocations(of: "kraken2", in: facts)
        if kraken2.isEmpty {
            violate("records its kraken2 argv", "no record step runs kraken2")
        }
        for argv in kraken2 {
            for (option, value) in [("--confidence", "0.2"), ("--minimum-hit-groups", "2"), ("--threads", "1")]
            where Self.value(of: option, in: argv) != value {
                violate("runs kraken2 with \(option) \(value)", argv.joined(separator: " "))
            }
            if argv.contains("--paired") != expected.runsAsPairs {
                violate(expected.runsAsPairs ? "runs kraken2 with --paired" : "runs kraken2 without --paired", argv.joined(separator: " "))
            }
        }

        if let composition = expected.readSetComposition {
            let plans = Self.values(named: "readSetPlan", in: facts)
            let counts = plans.compactMap(Self.composition(of:))
            if !counts.contains(where: { $0.pairs == composition.pairs && $0.merged == composition.merged }) {
                violate("records its readSetPlan of \(composition.pairs) pairs and \(composition.merged) merged reads", "\(plans.count) readSetPlan value(s), compositions \(counts)")
            }
        }

        if parityCase.profiles {
            let bracken = invocations(of: "bracken", in: facts)
            if bracken.isEmpty {
                violate("records its Bracken argv", "no record step runs bracken")
            }
            for argv in bracken where Self.value(of: "-l", in: argv) != "S" || Self.value(of: "-r", in: argv) != "150" || Self.value(of: "-t", in: argv) != "10" {
                violate("runs Bracken at species level with -r 150 and -t 10", argv.joined(separator: " "))
            }
        }
    }

    private func esVirituViolations(
        _ expected: ClassifierParitySampleFacts,
        folder: URL,
        facts: [ProvenanceCompatFacts.Value],
        violate: (String, String) -> Void
    ) {
        let stats = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasSuffix("_esviritu.readstats.yaml") }
        if let reads = expected.esVirituReadsBeforeFilter {
            let counted = stats.flatMap { try? ClassifierParityFixtures.esVirituReadStats($0)["reads pre-quality filter"] }
            if counted != reads {
                violate("EsViritu reads \(reads) reads before its filter, never 10 or 100", "reads pre-quality filter \(counted.map(String.init) ?? "absent")")
            }
        } else if stats == nil {
            violate("EsViritu writes its read statistics", "no _esviritu.readstats.yaml")
        }
        let esViritu = invocations(of: "EsViritu", in: facts)
        if esViritu.isEmpty {
            violate("records its EsViritu argv", "no record runs EsViritu")
        }
        for argv in esViritu {
            let format = expected.runsAsPairs ? "paired" : "unpaired"
            if Self.value(of: "-p", in: argv) != format {
                violate("runs EsViritu with -p \(format)", argv.joined(separator: " "))
            }
            if Self.value(of: "-t", in: argv) != "1" {
                violate("runs EsViritu with -t 1", argv.joined(separator: " "))
            }
        }
    }

    // MARK: - Side A's row

    /// Today's Operations row of side A (UX memo T2): its title, first detail, final state,
    /// completion detail, alert and log levels.
    func rowOutcomeViolations(
        _ parityCase: ClassifierParityCase,
        run: ClassifierParitySideRun
    ) throws -> [ClassifierParityDifference] {
        guard let row = run.row else {
            return [ClassifierParityDifference(id: "row: side A has a row", detail: "\(run.terminal)")]
        }
        var violations: [ClassifierParityDifference] = []
        func check(_ field: String, _ actual: String?, _ expected: String?) {
            if actual != expected {
                violations.append(ClassifierParityDifference(id: "row: \(field)", detail: "expected \(expected ?? "none"), found \(actual ?? "none")"))
            }
        }
        let samples = parityCase.bundlePaths.map(ClassifierParitySampleFacts.forBundle)
        let first = samples[0]
        let bundleName = (parityCase.bundlePaths[0] as NSString).lastPathComponent
        switch (parityCase.tool, parityCase.isBatch) {
        case (.kraken2, false):
            let kreport = run.analysisFolder?.appendingPathComponent("classification.kreport")
            let totals = kreport.flatMap { try? ClassifierParityFixtures.kreportTotals($0) }
            let classified = "\(totals?.classified ?? -1) of \(first.fragments) reads classified"
            check("title", row.title, "\(parityCase.profiles ? "Profiling" : "Classifying") \(bundleName)")
            check("first detail", row.firstDetail, "Starting Kraken2 with Viral...")
            if parityCase == .k5 {
                // Today's row of a known defect (F2 bio ruling 1). Kraken2 classifies none of
                // the 40 reads, KreportParser rejects the report of one unclassified line as
                // empty, and the run fails before the Bracken preflight.
                // ClassifierParityKnownDifferences declares the run's failure. Lane BR's parser
                // fix and lane A8 move this branch to Completed with Warnings and one warning
                // line (E4).
                check("state", row.stateLabel, "Failed")
                check("completion detail", row.completionDetail, "Empty Kraken2 report")
                check("error message", row.errorMessage, nil)
                check("log warning lines", row.logLines.filter { $0.level == "warning" }.map(\.description).joined(separator: "\n"), "")
                check("log error lines", row.logLines.filter { $0.level == "error" }.map(\.description).joined(separator: "\n"), "[error] Failed: Empty Kraken2 report")
                check("alert", row.alertText, "Classification Failed\nEmpty Kraken2 report")
                return violations
            } else {
                check("state", row.stateLabel, "Completed")
                check("completion detail", row.completionDetail, classified)
            }
        case (.kraken2, true):
            check("title", row.title, "Classification Batch (\(samples.count) samples)")
            check("first detail", row.firstDetail, "Starting Kraken2/Bracken batch\u{2026}")
            check("state", row.stateLabel, "Completed")
            check("completion detail", row.completionDetail, "\(samples.count) of \(samples.count) samples returned valid Kraken2 classifications")
            check("log Building kraken2.sqlite", row.logLines.first { $0.message.hasPrefix("Building kraken2.sqlite") }?.description, "[info] Building kraken2.sqlite from \(samples.count) sample(s)")
        case (.esViritu, false):
            check("title", row.title, "EsViritu \(first.sampleID)")
            check("first detail", row.firstDetail, "Starting EsViritu viral detection\u{2026}")
            check("state", row.stateLabel, "Completed")
            let detected = row.completionDetail == "No viral hits detected"
                || row.completionDetail.range(of: "^[0-9]+ viruses detected in [0-9]+ families$", options: .regularExpression) != nil
            check("completion detail", detected ? "today's form" : row.completionDetail, "today's form")
            check("log Building esviritu.sqlite", row.logLines.first { $0.message.hasPrefix("Building esviritu.sqlite") }?.description, "[info] Building esviritu.sqlite from single-sample result")
        case (.esViritu, true):
            check("title", row.title, "EsViritu Batch (\(samples.count) samples)")
            check("first detail", row.firstDetail, "Starting EsViritu batch\u{2026}")
            check("state", row.stateLabel, "Completed")
            check("completion detail", row.completionDetail, "\(samples.count) of \(samples.count) samples completed")
            check("log Building esviritu.sqlite", row.logLines.first { $0.message.hasPrefix("Building esviritu.sqlite") }?.description, "[info] Building esviritu.sqlite from \(samples.count) sample(s)")
        }
        check("alert", row.alertText, nil)
        check("error message", row.errorMessage, nil)
        let warnings = row.logLines.filter { $0.level == "warning" || $0.level == "error" }.map(\.description)
        check("warning and error log lines", warnings.joined(separator: "\n"), "")
        return violations
    }

    // MARK: - Evidence

    /// The folder of one sample: the analysis folder for a single Kraken2 run, else the
    /// sample's subfolder.
    func sampleFolder(of parityCase: ClassifierParityCase, analysis: URL, sampleID: String) -> URL {
        parityCase.tool == .kraken2 && !parityCase.isBatch ? analysis : analysis.appendingPathComponent(sampleID, isDirectory: true)
    }

    /// The facts of every provenance record in `folder`, deepest included.
    func recordFacts(in folder: URL, run: ClassifierParitySideRun) throws -> [ProvenanceCompatFacts.Value] {
        let relative = ClassifierParityComparison.relativeFiles(under: run.root)
            .filter(ClassifierParityComparison.isRecordName)
            .filter { run.root.appendingPathComponent($0).standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") }
        return try relative.map { try ClassifierParityComparison.factsTree(of: run, record: $0) }
    }

    /// The FASTQ files a run kept as its materialized or planned input.
    func materializedInputs(in folder: URL) -> [URL] {
        let folders = [".lungfish-classify-inputs", ".lungfish-esviritu-inputs", ".lungfish-provenance/intermediates"]
        return folders.flatMap { name -> [URL] in
            let base = folder.appendingPathComponent(name, isDirectory: true)
            return ClassifierParityComparison.relativeFiles(under: base)
                .filter { [".fastq", ".fq", ".fastq.gz", ".fq.gz"].contains(where: $0.lowercased().hasSuffix) }
                .map { base.appendingPathComponent($0) }
        }
    }

    /// Every argv in the facts whose program is `tool`, from the run and from each step.
    func invocations(of tool: String, in facts: [ProvenanceCompatFacts.Value]) -> [[String]] {
        var found: [[String]] = []
        func argv(_ value: ProvenanceCompatFacts.Value?) -> [String]? {
            guard case .array(let items)? = value else { return nil }
            let words = items.compactMap { item -> String? in
                if case .string(let word) = item { return word }
                return nil
            }
            guard let program = words.first, (program as NSString).lastPathComponent == tool else { return nil }
            return words
        }
        for case .object(let run) in facts {
            if let words = argv(run["argv"]) { found.append(words) }
            if case .array(let steps)? = run["steps"] {
                for case .object(let step) in steps {
                    if let words = argv(step["argv"]) { found.append(words) }
                }
            }
        }
        return found
    }

    static func value(of option: String, in argv: [String]) -> String? {
        argv.firstIndex(of: option).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
    }

    /// Every value stored under `name` at any depth of the facts.
    static func values(named name: String, in facts: [ProvenanceCompatFacts.Value]) -> [ProvenanceCompatFacts.Value] {
        var found: [ProvenanceCompatFacts.Value] = []
        func walk(_ value: ProvenanceCompatFacts.Value) {
            switch value {
            case .object(let members):
                if let match = members[name] { found.append(match) }
                members.values.forEach(walk)
            case .array(let items):
                items.forEach(walk)
            default:
                break
            }
        }
        facts.forEach(walk)
        return found
    }

    /// The pairs and merged reads a read-set plan records, as a plain or typed dictionary
    /// (`{"type": "dictionary", "value": {"pairedFragments": {"type": "integer", ...}}}`),
    /// with its counts at its top or under `composition`.
    static func composition(of plan: ProvenanceCompatFacts.Value) -> (pairs: Int, merged: Int)? {
        func unwrapped(_ value: ProvenanceCompatFacts.Value?) -> ProvenanceCompatFacts.Value? {
            if case .object(let members)? = value, members["type"] != nil, let inner = members["value"] { return inner }
            return value
        }
        guard case .object(var members)? = unwrapped(plan) else { return nil }
        if case .object(let composition)? = unwrapped(members["composition"]) { members = composition }
        func number(_ key: String) -> Int? {
            if case .integer(let value)? = unwrapped(members[key]) { return Int(value) }
            return nil
        }
        guard let pairs = number("pairedFragments") else { return nil }
        return (pairs, number("mergedReads") ?? number("mergedOrOrphanReads") ?? 0)
    }
}
