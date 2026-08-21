import AppKit
import Foundation
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow
import XCTest
import LungfishKit

// Duplicated (not shared) into Tests/LungfishAppViewTests/MappingResultViewControllerTests.swift
// as a private type after the task 11 AppKit-view test split: this file also defines
// App-only assembly-result fixtures used by stayers here, so it was not promoted to
// LungfishTestSupport, and this type alone is small enough (<20 lines) to duplicate.
@MainActor
final class RecordingPasteboard: PasteboardWriting {
    private(set) var lastString: String?

    func setString(_ string: String) {
        lastString = string
    }
}

// `AsyncGate`, `FakeAssemblyContigCatalog`, and the `AssemblyContigCatalogProviding`
// fake now live in Tests/LungfishAssemblyUITests, alongside the viewport unit tests
// that moved into the LungfishAssemblyUI leaf module.

@MainActor
func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}

func makeAssemblyResult() throws -> AssemblyResult {
    try makeAssemblyResult(writeFASTAIndex: true)
}

func makeAssemblyResult(writeFASTAIndex: Bool) throws -> AssemblyResult {
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("assembly-viewport-test-\(UUID().uuidString).lungfish", isDirectory: true)
    let root = projectRoot
        .appendingPathComponent("Analyses", isDirectory: true)
        .appendingPathComponent("spades-2026-04-19T21-40-00", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let contigsURL = root.appendingPathComponent("contigs.fasta")
    try """
    >contig_7 annotated header
    AACCGGTT
    >contig_9 secondary header
    ATATAT
    """.write(to: contigsURL, atomically: true, encoding: .utf8)
    if writeFASTAIndex {
        try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
    }

    let result = AssemblyResult(
        tool: .spades,
        readType: .illuminaShortReads,
        contigsPath: contigsURL,
        graphPath: root.appendingPathComponent("assembly_graph.gfa"),
        logPath: root.appendingPathComponent("spades.log"),
        assemblerVersion: "4.0.0",
        commandLine: "spades.py -o \(root.path)",
        outputDirectory: root,
        statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
        wallTimeSeconds: 15,
        scaffoldsPath: root.appendingPathComponent("scaffolds.fasta"),
        paramsPath: root.appendingPathComponent("params.txt")
    )
    try result.save(to: root)
    return result
}

func makeEmptyAssemblyResult(
    outcome: AssemblyOutcome = .completedWithNoContigs
) throws -> AssemblyResult {
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("assembly-empty-viewport-test-\(UUID().uuidString).lungfish", isDirectory: true)
    let root = projectRoot
        .appendingPathComponent("Analyses", isDirectory: true)
        .appendingPathComponent("spades-2026-04-19T21-40-00", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let contigsURL = root.appendingPathComponent("contigs.fasta")
    try "".write(to: contigsURL, atomically: true, encoding: .utf8)

    let result = AssemblyResult(
        tool: .spades,
        readType: .illuminaShortReads,
        outcome: outcome,
        contigsPath: contigsURL,
        graphPath: root.appendingPathComponent("assembly_graph.gfa"),
        logPath: root.appendingPathComponent("spades.log"),
        assemblerVersion: "4.0.0",
        commandLine: "spades.py -o \(root.path)",
        outputDirectory: root,
        statistics: AssemblyStatisticsCalculator.computeFromLengths([]),
        wallTimeSeconds: 15,
        scaffoldsPath: root.appendingPathComponent("scaffolds.fasta"),
        paramsPath: root.appendingPathComponent("params.txt")
    )
    try result.save(to: root)
    return result
}
