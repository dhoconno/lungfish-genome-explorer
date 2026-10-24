// HTCondorSubmitTemplateTests.swift - The sample.sub text of one recipe (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The template's rendered text is its output. These tests read that text line by line, as condor_submit reads it.

import LungfishPortable
import XCTest
@testable import LungfishWorkflow

final class HTCondorSubmitTemplateTests: XCTestCase {
    static let staging = "file:///staging/groups/oconnor_group/32748/lge-chtc-test"
    static let executorDigest = String(repeating: "ab", count: 32)
    static let indexDigest = String(repeating: "cd", count: 32)

    static func input(heapBytes: Int64 = 4 << 30, reports: [String] = []) -> HTCondorSubmitTemplateInput {
        HTCondorSubmitTemplateInput(
            containerImageURL: "\(staging)/images/lge-c0-tools-c42530259944.sif",
            executor: HTCondorStagedFile(
                url: "\(staging)/shared/lungfish-executor-\(executorDigest)",
                relativePath: "bin/lungfish-executor"
            ),
            databases: [
                HTCondorStagedFile(
                    url: "\(staging)/db/\(indexDigest).idx",
                    relativePath: "databases/panhuman-1.k31w15.idx"
                ),
            ],
            heapBytes: heapBytes,
            requestCpus: 1,
            payloadRelativePath: "out/sample.fastq.gz",
            payloadStagingFolderURL: "\(staging)/h",
            reportRelativePaths: reports
        )
    }

    /// The value of the one line that sets `command`.
    private func value(of command: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let prefix = "\(command) = "
        let lines = text.split(separator: "\n").filter { $0.hasPrefix(prefix) }
        XCTAssertEqual(lines.count, 1, "lines that set \(command)", file: file, line: line)
        return String(try XCTUnwrap(lines.first, file: file, line: line).dropFirst(prefix.count))
    }

    /// The words of a new-style `arguments` value, split as condor_submit splits them: whitespace outside single quotes
    /// ends a word. `quoted` says the whole word sat inside one pair of single quotes.
    private func words(ofArguments value: String) throws -> [(text: String, quoted: Bool)] {
        XCTAssertTrue(value.hasPrefix("\"") && value.hasSuffix("\""), "new-style arguments sit inside double quotes")
        let body = value.dropFirst().dropLast()
        var words: [(text: String, quoted: Bool)] = []
        var current = ""
        var inQuote = false
        var quotedWhole = false
        var started = false
        for character in body {
            if character == "'" {
                if !inQuote && !started { quotedWhole = true }
                inQuote.toggle()
                started = true
            } else if character == " " && !inQuote {
                if started { words.append((current, quotedWhole)) }
                current = ""
                quotedWhole = false
                started = false
            } else {
                if !inQuote { quotedWhole = false }
                current.append(character)
                started = true
            }
        }
        XCTAssertFalse(inQuote, "every single quote is closed")
        if started { words.append((current, quotedWhole)) }
        return words
    }

    private func matches(_ text: String, _ pattern: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    func testSiteFactMacrosQuoteValuesAndUseSafeDefaults() throws {
        let text = try HTCondorSubmitTemplate.render(Self.input())

        // CHTC condition 4: every $$( is a whole $$(Attribute:default) macro, and no bracket form appears.
        let opened = text.components(separatedBy: "$$(").count - 1
        let macros = try matches(text, #"\$\$\([A-Za-z][A-Za-z0-9_]*:[A-Za-z0-9_./]+\)"#)
        XCTAssertEqual(opened, 9)
        XCTAssertEqual(macros.count, opened, "every $$( opens a macro with a safe default")
        XCTAssertFalse(text.contains("$$(["), "no expression form, which has no default")
        XCTAssertTrue(macros.allSatisfy { $0.hasSuffix(":lge_unset)") }, "\(macros)")

        let words = try words(ofArguments: try value(of: "arguments", in: text))
        let separator = try XCTUnwrap(words.firstIndex { $0.text == "--" })
        XCTAssertTrue(words[separator].quoted)
        var facts: [(key: String, value: String)] = []
        var index = separator + 1
        while index < words.count {
            XCTAssertEqual(words[index].text, "--site-fact")
            XCTAssertTrue(words[index].quoted, "the flag sits in single quotes")
            let pair = words[index + 1]
            XCTAssertTrue(pair.quoted, "\(pair.text) sits in single quotes")
            let parts = pair.text.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, pair.text)
            facts.append((parts[0], parts[1]))
            index += 2
        }
        XCTAssertFalse(words[..<separator].contains { $0.text.contains("$$(") }, "machine-ad macros only in site facts")

        let keys = facts.map(\.key)
        XCTAssertEqual(keys, [
            "Machine", "Arch", "Microarch", "OpSysAndVer", "OpSysMajorVer", "OSKernelRelease", "Cpus", "Memory", "Disk",
            "ClusterId", "ProcId",
        ])
        for key in keys {
            XCTAssertEqual(try matches(key, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#).count, 1, "key \(key)")
        }
        for fact in facts.dropLast(2) {
            XCTAssertEqual(fact.value, "$$(\(fact.key):lge_unset)", "the node's \(fact.key) or the dropped default")
        }
        XCTAssertEqual(facts[facts.count - 2].value, "$(Cluster)")
        XCTAssertEqual(facts[facts.count - 1].value, "$(Process)")
        for spaced in ["ApptainerVersion", "SingularityVersion", "CondorVersion", "OpSysLongName"] {
            XCTAssertFalse(text.contains(spaced), "\(spaced) waits for a node job that keeps it one argument")
        }
    }

    func testRequestMemoryIsHeapPlusMarginAtMost100GB() throws {
        let gib: Int64 = 1 << 30
        XCTAssertEqual(try value(of: "request_memory", in: HTCondorSubmitTemplate.render(Self.input(heapBytes: 4 * gib))), "12288MB")
        XCTAssertEqual(try value(of: "request_memory", in: HTCondorSubmitTemplate.render(Self.input(heapBytes: 4 * gib + 1))), "12289MB")
        XCTAssertEqual(try value(of: "request_memory", in: HTCondorSubmitTemplate.render(Self.input(heapBytes: 92 * gib))), "102400MB")

        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(Self.input(heapBytes: 92 * gib + 1))) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .requestMemoryOverLimit(requestMiB: 102_401, limitMiB: 102_400))
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "The job would request 102401 MiB of memory, the plan's heap plus a margin of 8192 MiB, which is over "
                    + "the limit of 102400 MiB for the regular pool. Lower the recipe's heap."
            )
        }
        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(Self.input(heapBytes: .max))) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .requestMemoryOverLimit(requestMiB: 8_796_093_030_400, limitMiB: 102_400))
        }
        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(Self.input(heapBytes: 0))) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .invalidValue(field: "heap", rule: "is not a positive number of bytes."))
        }
    }

    func testRetryUntilNeverRetriesRefusalOrUsage() throws {
        let text = try HTCondorSubmitTemplate.render(Self.input())
        XCTAssertEqual(try value(of: "max_retries", in: text), "3")
        let retryUntil = try value(of: "retry_until", in: text)
        XCTAssertEqual(retryUntil, "(ExitCode =?= 0) || (ExitCode =?= 2) || (ExitCode =?= 64)")
        let ending = Set(try matches(retryUntil, #"(?<==\?= )[0-9]+"#).compactMap { Int32($0) })
        XCTAssertEqual(ending, [0, 2, 64], "success, a refusal and a usage error end the job")
        XCTAssertFalse(ending.contains(1), "a failed run retries")
        XCTAssertFalse(ending.contains(3), "an interrupted run retries")
        XCTAssertEqual(try value(of: "kill_sig", in: text), "SIGTERM")
    }

    func testRequirementsNameStagingEL9AndX86() throws {
        let text = try HTCondorSubmitTemplate.render(Self.input())
        XCTAssertEqual(
            try value(of: "requirements", in: text),
            #"(TARGET.HasCHTCStaging == true) && (TARGET.OpSysMajorVer >= 9) && (TARGET.Arch == "X86_64")"#
        )
        let requirements = try value(of: "requirements", in: text)
        XCTAssertFalse(requirements.contains("Microarch"), "the executor is generic x86-64")
    }

    func testEachJobLogsToItsOwnFileAndBringsItsRecordToItsPlanFolder() throws {
        let text = try HTCondorSubmitTemplate.render(Self.input())
        XCTAssertEqual(try value(of: "log", in: text), "../logs/$(sample).log")
        XCTAssertEqual(try value(of: "initialdir", in: text), "$(sample)")
        XCTAssertEqual(try value(of: "executable", in: text), "lge-job.sh")
        XCTAssertFalse(
            try value(of: "executable", in: text).contains("/"),
            "a relative executable resolves against the folder condor_submit runs in, never initialdir"
        )
        XCTAssertEqual(try value(of: "universe", in: text), "container")
        XCTAssertEqual(try value(of: "when_to_transfer_output", in: text), "ON_EXIT")
        XCTAssertEqual(
            try value(of: "transfer_input_files", in: text),
            "$(sample_inputs), \(Self.staging)/shared/lungfish-executor-\(Self.executorDigest), "
                + "\(Self.staging)/db/\(Self.indexDigest).idx"
        )
        XCTAssertEqual(
            try value(of: "transfer_output_files", in: text),
            "plan/run-record.json, plan/logs, plan/out/sample.fastq.gz"
        )
        XCTAssertEqual(
            try value(of: "transfer_output_remaps", in: text),
            "\"sample.fastq.gz = \(Self.staging)/h/$(sample)/out/sample.fastq.gz\""
        )
        let words = try words(ofArguments: try value(of: "arguments", in: text))
        XCTAssertEqual(words[0].text, "lungfish-executor-\(Self.executorDigest)=bin/lungfish-executor")
        XCTAssertEqual(words[1].text, "\(Self.indexDigest).idx=databases/panhuman-1.k31w15.idx")
        XCTAssertEqual(words[2].text, "$(sample_placements)")
        XCTAssertFalse(words[2].quoted, "the sample's placements split into one word each")
        XCTAssertEqual(text.split(separator: "\n").last, "queue")
    }

    func testTemplateRefusesValueThatWouldSplitAnArgument() {
        var spaced = Self.input()
        spaced.databases[0].relativePath = "databases/pan human.idx"
        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(spaced)) { error in
            XCTAssertEqual(
                error as? HTCondorSubmitError,
                .invalidValue(
                    field: "shared file plan path",
                    rule: "is not a relative path of names made of letters, digits, _, . and -."
                )
            )
        }
        var escaping = Self.input()
        escaping.executor.relativePath = "../lungfish-executor"
        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(escaping))
        var reserved = Self.input()
        reserved.databases[0].url = "\(Self.staging)/db/plan.tar"
        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(reserved))
        var twice = Self.input()
        twice.databases.append(HTCondorStagedFile(url: "\(Self.staging)/other/\(Self.indexDigest).idx", relativePath: "databases/b.idx"))
        XCTAssertThrowsError(try HTCondorSubmitTemplate.render(twice)) { error in
            XCTAssertEqual(error as? HTCondorSubmitError, .duplicate(field: "shared file transfer", name: "\(Self.indexDigest).idx"))
        }
    }

    /// ARCH Optional 1 and SWIFT Fix 2 of the lane V review set 2. The run record names each report the plan writes
    /// under `work/`, and the adopt reads it in the sample's returned folder, so the job returns each report there, at its
    /// `work/` path, and nothing else under `work/`. HTCondor names a returned file after the last component of the
    /// path it was listed by, so each report has a remap that puts it back under `work/`.
    func testEachPlanReportComesHomeAtItsWorkPathAndNothingElseUnderWorkDoes() throws {
        let reports = ["work/sample_fused_fastp_report.json", "work/sample_deacon_summary.json"]
        let text = try HTCondorSubmitTemplate.render(Self.input(reports: reports))
        XCTAssertEqual(
            try value(of: "transfer_output_files", in: text),
            "plan/run-record.json, plan/logs, plan/out/sample.fastq.gz, "
                + "plan/work/sample_fused_fastp_report.json, plan/work/sample_deacon_summary.json"
        )
        XCTAssertEqual(
            try value(of: "transfer_output_remaps", in: text),
            "\"sample.fastq.gz = \(Self.staging)/h/$(sample)/out/sample.fastq.gz; "
                + "sample_fused_fastp_report.json = work/sample_fused_fastp_report.json; "
                + "sample_deacon_summary.json = work/sample_deacon_summary.json\""
        )
        // The work folder holds the large intermediates, so it is never listed, and only the named reports come from it.
        let files = try value(of: "transfer_output_files", in: text).components(separatedBy: ", ")
        XCTAssertFalse(files.contains("plan/work"))
        XCTAssertEqual(files.filter { $0.hasPrefix("plan/work") }, reports.map { "plan/" + $0 })
    }

    func testTemplateRefusesReportsThatLeaveWorkOrShareAReturnedName() {
        func refusal(_ reports: [String]) -> HTCondorSubmitError? {
            do {
                _ = try HTCondorSubmitTemplate.render(Self.input(reports: reports))
                return nil
            } catch {
                return error as? HTCondorSubmitError
            }
        }
        let notUnderWork = HTCondorSubmitError.invalidValue(field: "report path", rule: "is not a path under work/.")
        XCTAssertEqual(refusal(["out/sample_report.json"]), notUnderWork)
        XCTAssertEqual(refusal(["work"]), notUnderWork)
        XCTAssertNotNil(refusal(["work/../out/r.json"]), "a dot component leaves the work folder")
        XCTAssertNotNil(refusal(["work/sample report.json"]), "a space would split the remap")
        // HTCondor names a returned file after the last component of its path, so two reports, a report and the record,
        // or a report and the payload that share one would overwrite each other.
        XCTAssertEqual(refusal(["work/a/r.json", "work/b/r.json"]), .duplicate(field: "returned file", name: "r.json"))
        XCTAssertEqual(refusal(["work/r.json", "work/r.json"]), .duplicate(field: "returned file", name: "r.json"))
        XCTAssertEqual(refusal(["work/run-record.json"]), .duplicate(field: "returned file", name: "run-record.json"))
        XCTAssertEqual(refusal(["work/sample.fastq.gz"]), .duplicate(field: "returned file", name: "sample.fastq.gz"))
        XCTAssertNil(refusal(["work/r.json", "work/s.json"]))
    }

    /// The plan's reports are the outputs of its recipe steps that no step reads, in the plan's order, which is the
    /// rule the adopt applies to the run record (`ExecutorRunAdoption.recordedReports`).
    func testReportsAreTheRecipeOutputsNoStepReads() {
        func step(_ id: String, _ kind: PlanStepKind, inputs: [String], outputs: [String]) -> PlanStep {
            PlanStep(id: id, title: id, kind: kind, tool: nil, arguments: [], deadlineSeconds: 1, inputs: inputs, outputs: outputs)
        }
        let steps = [
            step("recipe-1", .recipe, inputs: ["inputs/R1.fastq"], outputs: ["work/sample_fused.fastq", "work/sample_fused_fastp_report.json"]),
            step("recipe-2", .recipe, inputs: ["work/sample_fused.fastq"], outputs: ["work/sample_deacon.fastq", "work/sample_deacon_summary.json"]),
            step("storage", .storage, inputs: ["work/sample_deacon.fastq"], outputs: ["out/sample.fastq.gz"]),
        ]
        XCTAssertEqual(
            HTCondorSubmitTemplate.reportRelativePaths(of: steps),
            ["work/sample_fused_fastp_report.json", "work/sample_deacon_summary.json"]
        )
        XCTAssertEqual(HTCondorSubmitTemplate.reportRelativePaths(of: [steps[2]]), [], "a storage step's payload is no report")
    }
}
