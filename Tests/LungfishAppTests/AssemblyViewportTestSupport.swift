import AppKit
import Foundation
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow
import XCTest

@MainActor
final class RecordingPasteboard: PasteboardWriting {
    private(set) var lastString: String?

    func setString(_ string: String) {
        lastString = string
    }
}

actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor FakeAssemblyContigCatalog {
    let fakeRecords: [AssemblyContigRecord]
    let sequenceByName: [String: String]
    let summaryByNames: [Set<String>: AssemblyContigSelectionSummary]
    let delayedSequenceGates: [String: AsyncGate]

    init(
        records: [AssemblyContigRecord],
        sequenceByName: [String: String],
        summaryByNames: [Set<String>: AssemblyContigSelectionSummary] = [:],
        delayedSequenceGates: [String: AsyncGate] = [:]
    ) {
        self.fakeRecords = records
        self.sequenceByName = sequenceByName
        self.summaryByNames = summaryByNames
        self.delayedSequenceGates = delayedSequenceGates
    }
}

extension FakeAssemblyContigCatalog: AssemblyContigCatalogProviding {
    func records() async throws -> [AssemblyContigRecord] {
        fakeRecords
    }

    func sequenceFASTA(for name: String, lineWidth: Int) async throws -> String {
        if let gate = delayedSequenceGates[name] {
            await gate.wait()
        }
        return sequenceByName[name] ?? ""
    }

    func selectionSummary(for names: [String]) async throws -> AssemblyContigSelectionSummary {
        if let explicit = summaryByNames[Set(names)] {
            return explicit
        }
        throw NSError(domain: "FakeAssemblyContigCatalog", code: 1, userInfo: nil)
    }
}

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
    try FASTAIndexBuilder.buildAndWrite(for: contigsURL)

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
