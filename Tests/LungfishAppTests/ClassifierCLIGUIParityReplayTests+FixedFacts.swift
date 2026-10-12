// ClassifierCLIGUIParityReplayTests+FixedFacts.swift - Facts every side of a classifier case must hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision T2 and the BIO memo's amendment. Two sides can agree and both be wrong when a
// shared pipeline changes, so each side is also held to values that come from the fixtures and
// never from a tool build: the subset holds 55 reads (never its 10 preview reads or its 100 root
// reads), the merge bundle holds 100 fragments as 23 pairs and 77 merged reads with its read-set
// plan, pairs run as pairs (`--paired`, `-p paired`), and the thresholds and thread count are
// the ones the wizard chose. Every file a record names in the project exists with the digest
// the record states. The Operations rows of sides A and C are held to today's labels (UX memo
// T2, E15).

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

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
    /// Whether the reads come from the SARS-CoV-2 fixture, so every classifier must find a
    /// virus in them. A fact of the fixture, not of a database build.
    let sarsCoV2: Bool

    static func forBundle(_ path: String) -> ClassifierParitySampleFacts {
        switch path {
        case ClassifierParityFixtures.mergeBundlePath:
            // BBMerge's merged reads and unmerged pairs of the SARS-CoV-2 pairs.
            return .init(sampleID: "merge", fragments: 100, materializedReads: nil, readSetComposition: (23, 77), runsAsPairs: true, esVirituReadsBeforeFilter: nil, sarsCoV2: true)
        case ClassifierParityFixtures.pairBundlePath:
            // EsViritu counts reads, so the 100 pairs are 200 reads before its filter.
            return .init(sampleID: "sarscov2-pair", fragments: 100, materializedReads: nil, readSetComposition: nil, runsAsPairs: true, esVirituReadsBeforeFilter: 200, sarsCoV2: true)
        case ClassifierParityFixtures.negativeControlBundlePath:
            return .init(sampleID: "negative-control", fragments: 40, materializedReads: nil, readSetComposition: nil, runsAsPairs: false, esVirituReadsBeforeFilter: nil, sarsCoV2: false)
        case ClassifierParityFixtures.lowSignalControlBundlePath:
            // The negative control's 40 reads and five that K1 classifies under Betacoronavirus
            // pandemicum (taxid 3418604).
            return .init(sampleID: "low-signal-control", fragments: 45, materializedReads: nil, readSetComposition: nil, runsAsPairs: false, esVirituReadsBeforeFilter: nil, sarsCoV2: true)
        default:
            let subset = ClassifierParityFixtures.subsetReads
            return .init(sampleID: "len-150-any-00000000", fragments: subset, materializedReads: subset, readSetComposition: nil, runsAsPairs: false, esVirituReadsBeforeFilter: subset, sarsCoV2: true)
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
        // Every case is expected to complete, the controls K5 and K6 with a degraded Bracken
        // profile (F2 bio ruling 1, E4). The facts of a run that did not are not read.
        guard run.terminal.succeeded else {
            return [ClassifierParityDifference(id: "fact: the run completes", detail: "\(run.side) \(run.terminal)")]
        }
        guard let analysis = run.analysisFolder, FileManager.default.fileExists(atPath: analysis.path) else {
            return [ClassifierParityDifference(id: "fact: the run made its analysis folder", detail: "\(run.side) \(run.terminal)")]
        }
        var violations = try namedFileViolations(of: run)
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
                // A Kraken2 batch through the executor keeps the materialized inputs of its samples
                // at the batch root.
                let ownInputs = materializedInputs(in: folder)
                let kept = ownInputs.isEmpty && parityCase.isBatch && parityCase.tool == .kraken2
                    ? materializedInputs(in: analysis)
                    : ownInputs
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
            if parityCase == .k6, totals.classified != 5 {
                violate("low-signal control classifies its five SARS-CoV-2 reads", "classified \(totals.classified)")
            }
            if expected.sarsCoV2, totals.classified == 0 {
                violate("kreport classifies SARS-CoV-2 reads", "classified 0 of \(total)")
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
            brackenViolations(parityCase, folder: folder, facts: facts, violate: violate)
        }
    }

    /// What Bracken did, from the fixtures alone (F2 bio ruling 1). K5's report has no species
    /// row, so the preflight degrades the profile with exit 2 before Bracken runs. K6's one
    /// species holds five reads, under the threshold of ten, so Bracken runs and its
    /// est_abundance finds no reads. The installed `bracken` driver then exits 1, not 0 as the
    /// ruling read it, so the pipeline degrades with `toolFailed`, on both routes alike. Every
    /// other profile runs Bracken at species level.
    private func brackenViolations(
        _ parityCase: ClassifierParityCase,
        folder: URL,
        facts: [ProvenanceCompatFacts.Value],
        violate: (String, String) -> Void
    ) {
        let bracken = invocations(of: "bracken", in: facts)
        let steps = Self.steps(in: facts)
        func stepText(_ step: [String: ProvenanceCompatFacts.Value]) -> String {
            "\(step["toolName"].map(String.init(describing:)) ?? "?") exit \(step["exitStatus"].map(String.init(describing:)) ?? "?")"
        }
        func ran(_ tool: String, exit: Int64, saying text: String) -> Bool {
            steps.contains { step in
                guard case .string(tool)? = step["toolName"], case .integer(exit)? = step["exitStatus"] else { return false }
                if case .string(let stderr)? = step["stderr"] { return stderr.contains(text) }
                return false
            }
        }
        let degradedReason: BrackenProfileDegradationReason?
        switch parityCase {
        case .k5:
            degradedReason = .rankAbsentFromReport
            if !bracken.isEmpty {
                violate("runs no Bracken", bracken.map { $0.joined(separator: " ") }.joined(separator: "; "))
            }
            if !ran("Lungfish Bracken Preflight", exit: 2, saying: "The Kraken report has no rows at resolved rank S (Species).") {
                violate("records the Bracken preflight with exit 2 and its reason", steps.map(stepText).joined(separator: ", "))
            }
        case .k6:
            degradedReason = .toolFailed
            if !ran("bracken", exit: 1, saying: "Error: no reads found. Please check your Kraken report") {
                violate("records Bracken's exit 1 and its no reads found", steps.map(stepText).joined(separator: ", "))
            }
        default:
            degradedReason = nil
            if bracken.isEmpty {
                violate("records its Bracken argv", "no record step runs bracken")
            }
        }
        for argv in bracken where Self.value(of: "-l", in: argv) != "S" || Self.value(of: "-r", in: argv) != "150" || Self.value(of: "-t", in: argv) != "10" {
            violate("runs Bracken at species level with -r 150 and -t 10", argv.joined(separator: " "))
        }
        guard let degradedReason else { return }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("classification.bracken").path) {
            violate("writes no Bracken profile", "classification.bracken exists")
        }
        let outcome = (try? ClassificationResult.load(from: folder))?.profileOutcome
        if outcome?.state != .degraded || outcome?.reason != degradedReason {
            violate("degrades its profile with \(degradedReason.rawValue)", "classification-result.json: \(outcome.map { "\($0.state) \($0.reason?.rawValue ?? "no reason")" } ?? "unreadable")")
        }
        let recorded = Self.values(named: "profileReason", in: facts)
        let encoded = (try? JSONEncoder().encode(recorded)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !encoded.contains("\"\(degradedReason.rawValue)\"") {
            violate("records profileReason \(degradedReason.rawValue)", encoded)
        }
    }

    /// Every step object of every record in the facts.
    static func steps(in facts: [ProvenanceCompatFacts.Value]) -> [[String: ProvenanceCompatFacts.Value]] {
        facts.flatMap { record -> [[String: ProvenanceCompatFacts.Value]] in
            guard case .object(let run) = record, case .array(let steps)? = run["steps"] else { return [] }
            return steps.compactMap { step in
                if case .object(let members) = step { return members }
                return nil
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
        if expected.sarsCoV2 {
            let table = folder.appendingPathComponent("\(expected.sampleID).detected_virus.info.tsv")
            let detections = try? ClassifierParityFixtures.esVirituDetections(table)
            if (detections?.viruses ?? 0) == 0 {
                violate("EsViritu detects a virus in the SARS-CoV-2 reads", detections.map { "\(table.lastPathComponent) lists \($0.viruses)" } ?? "no readable \(table.lastPathComponent)")
            }
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
            if Self.value(of: "-q", in: argv) != "True" {
                violate("runs EsViritu with -q True", argv.joined(separator: " "))
            }
        }
    }

    // MARK: - Side A's row

    /// Today's Operations row, which sides A and C must both show (UX memo T2, E15): its title,
    /// first detail, final state, completion detail, alert and log levels, and for a run that
    /// builds the viewer database at its end the detail and the overlay of that build.
    func rowOutcomeViolations(
        _ parityCase: ClassifierParityCase,
        run: ClassifierParitySideRun
    ) throws -> [ClassifierParityDifference] {
        guard let row = run.row else {
            return [ClassifierParityDifference(id: "row: side \(run.side) has a row", detail: "\(run.terminal)")]
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
            if parityCase == .k5 || parityCase == .k6 {
                // The controls (F2 bio ruling 1, E4). Lane BR's parser reads K5's report of one
                // unclassified line, so both controls complete with a degraded Bracken profile:
                // no alert, the viewer loads the result, the folder stays, and one warning line
                // names the reason.
                // K6's reason is Bracken's stderr, which names its scratch report first.
                let reason = parityCase == .k5
                    ? "The Kraken report has no rows at resolved rank S (Species)."
                    : "Error: no reads found. Please check your Kraken report"
                check("state", row.stateLabel, "Completed with Warnings")
                let detail = "\(classified); Bracken profiling degraded at resolved rank S: "
                if parityCase == .k5 {
                    check("completion detail", row.completionDetail, detail + reason)
                } else if !row.completionDetail.hasPrefix(detail) || !row.completionDetail.contains(reason) {
                    check("completion detail", row.completionDetail, detail + "<Bracken's stderr with> " + reason)
                }
                let warnings = row.logLines.filter { $0.level == "warning" || $0.level == "error" }
                if warnings.count != 1 || warnings.first?.message.contains(reason) != true {
                    violations.append(ClassifierParityDifference(
                        id: "row: one warning line names the reason",
                        detail: warnings.map(\.description).joined(separator: "\n")
                    ))
                }
                check("alert", row.alertText, nil)
                check("error message", row.errorMessage, nil)
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
            // From side A's own detection table, as the Kraken2 detail comes from its kreport,
            // so a route that reads its result back wrongly cannot pass with today's form. The
            // fixed facts reject a SARS-CoV-2 table that lists no virus.
            let table = run.analysisFolder.map {
                sampleFolder(of: parityCase, analysis: $0, sampleID: first.sampleID)
                    .appendingPathComponent("\(first.sampleID).detected_virus.info.tsv")
            }
            let detections = table.flatMap { try? ClassifierParityFixtures.esVirituDetections($0) }
            check("completion detail", row.completionDetail, detections.map {
                $0.viruses == 0 ? "No viral hits detected" : "\($0.viruses) viruses detected in \($0.families) families"
            })
            check("log Building esviritu.sqlite", row.logLines.first { $0.message.hasPrefix("Building esviritu.sqlite") }?.description, "[info] Building esviritu.sqlite from single-sample result")
        case (.esViritu, true):
            check("title", row.title, "EsViritu Batch (\(samples.count) samples)")
            check("first detail", row.firstDetail, "Starting EsViritu batch\u{2026}")
            check("state", row.stateLabel, "Completed")
            check("completion detail", row.completionDetail, "\(samples.count) of \(samples.count) samples completed")
            check("log Building esviritu.sqlite", row.logLines.first { $0.message.hasPrefix("Building esviritu.sqlite") }?.description, "[info] Building esviritu.sqlite from \(samples.count) sample(s)")
        }
        // X1 review fix 1. While the viewer database builds, the detail reads today's words and the
        // overlay keeps the sample's last line, so neither the detail nor the log line shows there.
        // A single Kraken2 row builds no database at its end today (D19).
        if parityCase.tool == .esViritu || parityCase.isBatch {
            let buildDetail = parityCase.tool == .kraken2 ? "Building Kraken2 database\u{2026}" : "Building EsViritu database\u{2026}"
            if !row.details.contains(buildDetail) {
                violations.append(ClassifierParityDifference(id: "row: shows \(buildDetail) as a detail", detail: row.details.suffix(4).joined(separator: " | ")))
            }
            let overlaid = row.overlayLines.filter { $0 == buildDetail || $0.contains(".sqlite") }
            if !overlaid.isEmpty {
                violations.append(ClassifierParityDifference(id: "row: the overlay never shows the database build", detail: overlaid.joined(separator: " | ")))
            }
        }
        check("alert", row.alertText, nil)
        check("error message", row.errorMessage, nil)
        let warnings = row.logLines.filter { $0.level == "warning" || $0.level == "error" }.map(\.description)
        check("warning and error log lines", warnings.joined(separator: "\n"), "")
        return violations
    }

    // MARK: - Named files

    /// Every file a record under the side root names in the project that does not exist, or
    /// that holds another digest than the record states (QA checklist 4, BIO checklist 7), and
    /// that the result does not account for (`namedFileDifferences`). Two sides that share the
    /// fault cannot show it in a pair comparison, which leaves the digest of a file both trees
    /// hold to the folder comparison. Paths under `<storage-root>/` and `<external>/` are not
    /// checked, and a folder is checked for existence only.
    func namedFileViolations(of run: ClassifierParitySideRun) throws -> [ClassifierParityDifference] {
        let records = try ClassifierParityComparison.recordPaths(under: run.root).map {
            (path: $0, facts: try ClassifierParityComparison.factsTree(of: run, record: $0))
        }
        var digests: [String: String] = [:]
        return try Self.namedFileDifferences(side: "\(run.side)", records: records) { relativePath in
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
    }

    /// What a named path holds in the project. Nil when it does not exist.
    enum NamedPathState {
        case folder
        /// A file, with a function that returns its SHA-256.
        case file(() throws -> String)
    }

    /// The named-file differences of `records`, the facts of each record under a side root by
    /// its relative path, where `state` reads a path below `<project>/`. One difference per
    /// record and named path, however often the record names it.
    ///
    /// Panel decision P1 of Phase 2.8. Step facts stay as they were, so a file that is missing
    /// or holds another digest is accepted only when a later step of the same record names it
    /// with the stated digest as input, or a removal step of the same result names it by path.
    /// A removal step says `operation` `remove` in its resolved options and names each removed
    /// path as an input. A record's step list is the only order a record states, so a later step
    /// is one later in the same record, and nothing comes later than the run level. A later
    /// consumer can excuse an earlier naming but never the last one, so a removed or rewritten
    /// file is accepted only through a removal step. The result of a record is its folder under
    /// `Analyses/`, which holds every record of a run, a batch's sample records included.
    static func namedFileDifferences(
        side: String,
        records: [(path: String, facts: ProvenanceCompatFacts.Value)],
        state: (String) throws -> NamedPathState?
    ) throws -> [ClassifierParityDifference] {
        let token = "<project>/"
        var removed: [String: Set<String>] = [:]
        for record in records {
            removed[resultFolder(of: record.path), default: []].formUnion(removedPaths(in: record.facts))
        }
        var found: [String: ClassifierParityDifference] = [:]
        for record in records {
            let namings = orderedNamings(in: record.facts)
            for (index, named) in namings.enumerated() {
                guard named.path.hasPrefix(token) else { continue }
                let problem: String
                var detail = "\(side) \(record.path) names \(named.path)"
                switch try state(String(named.path.dropFirst(token.count))) {
                case nil:
                    problem = "that does not exist"
                case .folder?:
                    continue
                case .file(let digest)?:
                    guard let recorded = named.sha256 else { continue }
                    let actual = try digest()
                    guard actual != recorded else { continue }
                    problem = "with another digest"
                    detail += ", recorded \(recorded), found \(actual)"
                }
                if removed[resultFolder(of: record.path)]?.contains(named.path) == true { continue }
                let consumedLater = namings[(index + 1)...].contains {
                    $0.step > named.step && $0.isInput && $0.path == named.path && $0.sha256 != nil && $0.sha256 == named.sha256
                }
                if consumedLater { continue }
                let id = "fact: record \(ClassifierParityComparison.maskedID(record.path)) names \(ClassifierParityComparison.maskedID(named.path)) \(problem)"
                if found[id] == nil { found[id] = ClassifierParityDifference(id: id, detail: detail) }
            }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// One path a record names, with the index of the step that names it (the step count for
    /// the run level and every other place) and whether that step reads it.
    struct Naming {
        let step: Int
        let isInput: Bool
        let path: String
        let sha256: String?
    }

    /// Every naming of `facts` in record order, the steps first and then the rest of the tree.
    /// Together they are the objects `namedFiles(in:)` finds in the whole tree.
    static func orderedNamings(in facts: ProvenanceCompatFacts.Value) -> [Naming] {
        guard case .object(var members) = facts else { return [] }
        var steps: [ProvenanceCompatFacts.Value] = []
        if case .array(let items)? = members.removeValue(forKey: "steps") { steps = items }
        func namings(_ value: ProvenanceCompatFacts.Value, step: Int, isInput: Bool) -> [Naming] {
            namedFiles(in: value).compactMap { named in
                guard case .string(let path)? = named["path"] else { return nil }
                guard case .string(let sha256)? = named["sha256"] else {
                    return Naming(step: step, isInput: isInput, path: path, sha256: nil)
                }
                return Naming(step: step, isInput: isInput, path: path, sha256: sha256)
            }
        }
        var found: [Naming] = []
        for (index, step) in steps.enumerated() {
            guard case .object(var stepMembers) = step else { continue }
            let inputs = stepMembers.removeValue(forKey: "inputs")
            found += inputs.map { namings($0, step: index, isInput: true) } ?? []
            found += namings(.object(stepMembers), step: index, isInput: false)
        }
        return found + namings(.object(members), step: steps.count, isInput: false)
    }

    /// The paths the removal steps of `facts` name.
    static func removedPaths(in facts: ProvenanceCompatFacts.Value) -> Set<String> {
        guard case .object(let members) = facts, case .array(let steps)? = members["steps"] else { return [] }
        var paths: Set<String> = []
        for case .object(let step) in steps {
            guard case .object(let options)? = step["resolvedOptions"],
                  case .object(let operation)? = options["operation"],
                  operation["value"] == .string("remove"),
                  case .array(let inputs)? = step["inputs"] else { continue }
            for case .object(let input) in inputs {
                if case .string(let path)? = input["path"] { paths.insert(path) }
            }
        }
        return paths
    }

    /// The folder of the result that holds the record at `recordPath`, relative to the side
    /// root. A record outside `Analyses/` is its own result, its folder.
    static func resultFolder(of recordPath: String) -> String {
        let components = recordPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let analyses = components.firstIndex(of: "Analyses"), analyses + 2 < components.count {
            return components[...(analyses + 1)].joined(separator: "/")
        }
        return components.dropLast().joined(separator: "/")
    }

    /// Every object in `value` with a `path` string and a `role`, the files a record names.
    static func namedFiles(in value: ProvenanceCompatFacts.Value) -> [[String: ProvenanceCompatFacts.Value]] {
        switch value {
        case .object(let members):
            var found: [[String: ProvenanceCompatFacts.Value]] = []
            if case .string(_)? = members["path"], members["role"] != nil { found.append(members) }
            return found + members.values.flatMap(namedFiles(in:))
        case .array(let items):
            return items.flatMap(namedFiles(in:))
        default:
            return []
        }
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
