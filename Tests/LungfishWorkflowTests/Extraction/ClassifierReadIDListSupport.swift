// ClassifierReadIDListSupport.swift - Frozen read-ID lists and the extraction runs that are diffed against them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane IDPINS, the acceptance of task 3e of the architecture program ("per-classifier extraction
// tests diff read IDs against lists frozen in 3.1"). Each list file in `Resources/ClassifierReadIDLists` holds
// the read IDs one tool's own output gives for one selection of one fixture. The list is taken by running
// the tool directly, and the file's `# command:` line says how. It is never the app's own output (a science pin
// needs BIO's word that the pinned behaviour is right, SCOPE-AND-DELIVERY.md). A test runs the extraction a
// result viewer ends in, `ClassifierReadResolver.resolveAndExtract`, on the same selection and compares the
// read names the extraction wrote with the list, as a set, and the number of records written with the number
// the tool's own output holds.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// One frozen list: the sorted unique read IDs of a selection and the number of records it stands for.
struct FrozenReadIDList {
    let name: String
    let command: String
    let records: Int
    let ids: [String]
}

enum ClassifierReadIDListSupport {
    struct SupportError: Error, CustomStringConvertible {
        let description: String
    }

    /// The checkout that holds this file.
    static var repository: URL { ProvenanceCompatCorpus.repositoryRoot }

    /// A path under `Tests/Fixtures`.
    static func fixture(_ relative: String) -> URL {
        repository.appendingPathComponent("Tests/Fixtures/\(relative)")
    }

    /// The list file `name` in `Resources/ClassifierReadIDLists`.
    static func list(named name: String) throws -> FrozenReadIDList {
        let url = repository.appendingPathComponent("Tests/LungfishWorkflowTests/Resources/ClassifierReadIDLists/\(name).ids")
        let text = try String(contentsOf: url, encoding: .utf8)
        var command = ""
        var records: Int?
        var ids: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# command: ") {
                command = String(line.dropFirst("# command: ".count))
            } else if line.hasPrefix("# records: ") {
                records = line.dropFirst("# records: ".count).split(separator: " ").first.flatMap { Int($0) }
            } else if !line.hasPrefix("#") {
                ids.append(String(line))
            }
        }
        guard let records else { throw SupportError(description: "\(name).ids has no `# records:` line") }
        return FrozenReadIDList(name: name, command: command, records: records, ids: ids)
    }

    /// The tool `tool` from the managed tools, or the test skipped (failed under `LUNGFISH_REQUIRE_TOOLS=1`).
    @discardableResult
    static func requireTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
        do {
            return try await NativeToolRunner.shared.findTool(tool)
        } catch {
            try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is required: \(error)", file: file, line: line)
        }
    }

    // MARK: - Result folders

    /// An empty result folder `name` inside `root/Project.lungfish/Analyses`, where the resolver finds its project.
    static func makeResultFolder(in root: URL, named name: String) throws -> URL {
        let folder = root.appendingPathComponent("Project.lungfish/Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A copy of the fixture folder `relative` as result folder `name` of `root`'s project.
    static func copyFixtureFolder(_ relative: String, into root: URL, named name: String) throws -> URL {
        let folder = root.appendingPathComponent("Project.lungfish/Analyses/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture(relative), to: folder)
        return folder
    }

    /// Copies `bam` and its `.bai` into `folder` at `relative`.
    static func place(bam: URL, at relative: String, in folder: URL) throws {
        let fileManager = FileManager.default
        let destination = folder.appendingPathComponent(relative)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: bam, to: destination)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: bam.path + ".bai"),
            to: URL(fileURLWithPath: destination.path + ".bai")
        )
    }

    // MARK: - Extraction and comparison

    /// Runs the extraction the viewers end in and returns the record names it wrote, in file order.
    static func extract(
        _ tool: ClassifierTool,
        result: URL,
        _ selections: [ClassifierRowSelector],
        options: ExtractionOptions = ExtractionOptions(format: .fastq),
        to output: URL
    ) async throws -> [String] {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: tool,
            resultPath: result,
            selections: selections,
            options: options,
            destination: .file(output)
        )
        guard case .file(let url, _) = outcome else {
            throw SupportError(description: "a file destination gave \(outcome)")
        }
        return try recordNames(inFASTQ: url)
    }

    /// The record names of a plain FASTQ file, each up to its first space or tab, in file order.
    static func recordNames(inFASTQ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            throw SupportError(description: "\(url.lastPathComponent) is gzip and these pins read plain FASTQ")
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var names: [String] = []
        var index = 0
        while index < lines.count, !lines[index].isEmpty {
            guard lines[index].hasPrefix("@") else {
                throw SupportError(description: "line \(index + 1) of \(url.lastPathComponent) is not a FASTQ header")
            }
            let token = lines[index].dropFirst().split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            names.append(token.map(String.init) ?? "")
            index += 4
        }
        return names
    }

    /// Compares what an extraction wrote with a frozen list. Each difference is its own assertion, so a failure
    /// names the read IDs the extraction holds that the tool does not, those it lacks, and the record counts.
    static func assertMatches(
        _ names: [String],
        _ list: FrozenReadIDList,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let written = Set(names)
        let frozen = Set(list.ids)
        XCTAssertEqual(frozen.count, list.ids.count, "\(list.name).ids repeats a read ID", file: file, line: line)
        XCTAssertEqual(
            written.subtracting(frozen).sorted(), [],
            "\(label) wrote read IDs the tool's own output does not hold (\(list.command))", file: file, line: line
        )
        XCTAssertEqual(
            frozen.subtracting(written).sorted(), [],
            "\(label) left out read IDs the tool's own output holds (\(list.command))", file: file, line: line
        )
        XCTAssertEqual(
            names.count, list.records,
            "\(label) wrote \(names.count) records and the tool's own output holds \(list.records) (\(list.command))",
            file: file, line: line
        )
    }
}
