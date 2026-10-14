// BuildDbIndexRunHarness.swift - Runs a build-db core as an analysis run's index step and stops it at a fault point
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// Where a test stops an index build inside its `build-db` core, QA's fault point per step boundary (lane S33).
enum BuildDbIndexFault: Sendable {
    /// No fault. The run completes.
    case none
    /// Cancels the run's task once the build hands the root record its `ordinal`th step named `toolName`. The
    /// build hands a step over on its own task, the run's, so the cancel lands at that boundary on every run.
    case cancelAfterStep(String, ordinal: Int = 1)
    /// Cancels the run's task at the first line of the build that the closure accepts.
    case cancelAtLine(@Sendable (String) -> Bool)
    /// Asks for the cancel through the services' `cancelRequested` and the builder's hook once the build hands
    /// over the `ordinal`th step named `toolName`, as a SIGTERM counted before the task is cancelled does. The
    /// run's task is never cancelled.
    case requestAfterStep(String, ordinal: Int = 1)
    /// Asks for the cancel through the hooks, as `requestAfterStep` does, at the first line the closure accepts.
    case requestAtLine(@Sendable (String) -> Bool)
}

/// One analysis run whose finalize built the viewer index of a prepared result folder through a real index
/// builder over its `build-db` core, as the finalizes of Kraken2, EsViritu and TaxTriage do (2.9 R6, lane S33).
///
/// The run's one unit copies the prepared folder into the run's root and records a launch step that names each
/// file it copied with its digest and size, as a tool's launch names what it wrote. The finalize passes those
/// files to the build, whose cleanup names them as it removes them, and turns a build that throws into a
/// warning, as the tools' finalizes do. The record is the root record the executor wrote.
struct BuildDbIndexRun {
    static let launchToolName = "probe-launch"

    let report: AnalysisRunReport
    /// The steps the build handed to the root record, in the order it handed them over, each once.
    let handedOver: [ProvenanceStep]
    /// How long the run went on after the fault fired, or nil when it never fired.
    let afterTheFault: Duration?

    func folder() throws -> URL {
        try XCTUnwrap(report.analysisDirectory)
    }

    func record() throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(report.recordURL)))
    }

    /// The names of the root record's steps, the launch's first.
    func stepNames() throws -> [String] {
        try record().steps.map(\.toolName)
    }

    /// Runs `prepared` through the executor as a `toolID` run in a folder under `scratch`, with the index builder
    /// that `indexer` makes from the run's cancel hook, and stops it at `fault`. `home` is the HOME of the build,
    /// where it finds its managed samtools. `afterCopy` takes the run's root once the unit recorded its launch step.
    static func run(
        _ toolID: AnalysisToolID,
        prepared: URL,
        in scratch: URL,
        home: URL? = nil,
        fault: BuildDbIndexFault = .none,
        afterCopy: (@Sendable (URL) throws -> Void)? = nil,
        indexer: (@escaping @Sendable () -> Bool) -> any AnalysisResultIndexing
    ) async throws -> BuildDbIndexRun {
        let hook = CancelHook()
        let faulting = FaultingIndexer(base: indexer { hook.requested }, fault: fault, hook: hook)
        let request = AnalysisRunRequest(
            inputs: [prepared],
            destination: .directory(scratch.appendingPathComponent("run-\(toolID.rawValue)", isDirectory: true)),
            commandLine: ["lungfish-cli", "probe", toolID.rawValue]
        )
        let services = AnalysisRunServices(indexing: faulting, cancelRequested: { hook.requested })
        let tool = IndexBuildProbeTool(toolID: toolID, home: home, afterCopy: afterCopy)
        let report = await Task {
            await AnalysisRunExecutor(services: services).execute(tool, request, events: AnalysisRunEvents { _ in })
        }.value
        return BuildDbIndexRun(
            report: report,
            handedOver: faulting.handedOver,
            afterTheFault: faulting.firedAt.map { ContinuousClock.now - $0 }
        )
    }

    /// Runs `body` with `HOME` at `home`, where `build-db` finds its managed samtools, or as it is when nil.
    static func withHome<T>(_ home: URL?, _ body: () async throws -> T) async rethrows -> T {
        guard let home else { return try await body() }
        let original = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
        }
        return try await body()
    }
}

// MARK: - What a run kept

extension BuildDbIndexRun {
    /// The run ended as cancelled within 5 seconds of the fault, with exit 125 in its report and its root record,
    /// and the record names the launch step first and then each step the build handed over, in that order.
    func assertCancelledKeepingTheHandedOverSteps(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(report.status, .cancelled, report.message, file: file, line: line)
        XCTAssertEqual(report.exitCode, 125, file: file, line: line)
        let after = try XCTUnwrap(afterTheFault, "the fault fired", file: file, line: line)
        XCTAssertLessThan(after, .seconds(5), "the run ended within the grace", file: file, line: line)
        let record = try record()
        XCTAssertEqual(record.status, .cancelled, file: file, line: line)
        XCTAssertEqual(record.exitStatus, 125, file: file, line: line)
        XCTAssertEqual(record.steps.first?.toolName, Self.launchToolName, "the units' step is kept", file: file, line: line)
        XCTAssertEqual(
            try Self.encoded(Array(record.steps.dropFirst())), try Self.encoded(handedOver),
            "the record keeps each step the build handed over, as it was handed over", file: file, line: line
        )
    }

    /// The names of the build's steps in the root record that are not removal steps, in their order.
    func buildStepNamesBesideTheRemovals() throws -> [String] {
        try record().steps.dropFirst().filter { !Self.isRemoval($0) }.map(\.toolName)
    }

    /// Each file a step of the build names as an output is on disk with the digest and size the step took,
    /// unless a later step names it with that digest as a file it read, moved or removed.
    func assertEachBuildOutputIsOnDisk(file: StaticString = #filePath, line: UInt = #line) throws {
        let steps = try record().steps
        for (index, step) in steps.enumerated() where step.toolName != Self.launchToolName {
            for output in step.outputs where !Self.isOnDisk(output) {
                let later = steps.dropFirst(index + 1).contains { $0.inputs.contains { Self.same($0, output) } }
                XCTAssertTrue(later, "\(step.toolName) names \(output.path), which is not on disk with that digest", file: file, line: line)
            }
        }
    }

    /// Each file a step of the record names as an output, the launch's included, is on disk with the digest and
    /// size the step took, or a later removal step names it with that digest (2.8 P1, BIO 6).
    func assertEachGoneFileHasARemovalStep(file: StaticString = #filePath, line: UInt = #line) throws {
        let steps = try record().steps
        for (index, step) in steps.enumerated() {
            for output in step.outputs where !Self.isOnDisk(output) {
                let removal = steps.dropFirst(index + 1).first { Self.isRemoval($0) && $0.inputs.contains { Self.same($0, output) } }
                XCTAssertNotNil(removal, "\(step.toolName) names \(output.path), which is gone with no removal step", file: file, line: line)
            }
        }
    }

    /// The root folder holds no `name` and the record names none, so it holds no digest of a database the
    /// cancel removed (BIO 4).
    func assertNoDigestOf(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try record()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try folder().appendingPathComponent(name).path),
            "\(name) is not kept", file: file, line: line
        )
        let named = (record.files + record.outputs + record.steps.flatMap { $0.inputs + $0.outputs }).map(\.path)
        XCTAssertFalse(named.contains { $0.hasSuffix("/\(name)") }, "the record names no \(name)", file: file, line: line)
    }

    static func isRemoval(_ step: ProvenanceStep) -> Bool {
        step.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation)
    }

    static func isOnDisk(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        guard let taken = try? ProvenanceFileDescriptor.file(url: URL(fileURLWithPath: descriptor.path), role: .output) else {
            return false
        }
        return taken.checksumSHA256 == descriptor.checksumSHA256 && taken.fileSize == descriptor.fileSize
    }

    /// Whether two descriptors name one file with one digest, `/var` and `/private/var` being one place.
    static func same(_ first: ProvenanceFileDescriptor, _ second: ProvenanceFileDescriptor) -> Bool {
        key(first.path) == key(second.path) && first.checksumSHA256 == second.checksumSHA256
    }

    static func key(_ path: String) -> String {
        path.replacingOccurrences(of: "/private/var/", with: "/var/")
    }

    /// `steps` as the root record writes them, with one form of the temporary folder's path.
    static func encoded(_ steps: [ProvenanceStep]) throws -> String {
        key(String(decoding: try ProvenanceJSON.encoder.encode(steps), as: UTF8.self))
    }
}

// MARK: - The run

/// A run of one unit, which copies the prepared folder into the run's root, and a finalize that builds the
/// root's viewer index through the executor's index builder with `home` as its HOME.
private struct IndexBuildProbeTool: AnalysisRunTool {
    typealias Unit = URL
    typealias UnitResult = URL

    let identity: AnalysisRunIdentity
    let home: URL?
    let afterCopy: (@Sendable (URL) throws -> Void)?

    init(toolID: AnalysisToolID, home: URL?, afterCopy: (@Sendable (URL) throws -> Void)?) {
        identity = AnalysisRunIdentity(toolID: toolID, workflowName: "lungfish.build-db-index-probe")
        self.home = home
        self.afterCopy = afterCopy
    }

    func plan(_ request: AnalysisRunRequest, context: AnalysisRunPlanningContext) async throws -> AnalysisRunPlan<URL> {
        AnalysisRunPlan(layout: .singleFolder, units: request.inputs.map { AnalysisRunPlannedUnit(label: "probe", value: $0) })
    }

    func run(_ unit: AnalysisRunUnit<URL>, context: AnalysisRunUnitContext) async throws -> AnalysisUnitOutcome<URL> {
        let fileManager = FileManager.default
        let root = context.rootDirectory
        var outputs: [ProvenanceFileDescriptor] = []
        let items = try fileManager.contentsOfDirectory(at: unit.value, includingPropertiesForKeys: nil)
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let destination = root.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: destination)
            let files = (fileManager.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [destination])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.path < $1.path }
            outputs += try files.map { try ProvenanceFileDescriptor.file(url: $0, role: .output) }
        }
        context.recordStep(ProvenanceStep(
            toolName: BuildDbIndexRun.launchToolName, toolVersion: "1.0",
            argv: [BuildDbIndexRun.launchToolName, unit.value.path, root.path], inputs: [], outputs: outputs, exitStatus: 0
        ))
        try afterCopy?(root)
        return .completed(root)
    }

    func finalize(_ units: [AnalysisUnitReport<URL>], context: AnalysisRunFinalizeContext) async throws -> AnalysisRunFinalization {
        let recordedFiles = context.recordedSteps.flatMap(\.outputs)
        do {
            let index = try await BuildDbIndexRun.withHome(home) {
                try await context.buildIndex(recordedFiles: recordedFiles)
            }
            return AnalysisRunFinalization(outputs: index.outputs, warnings: index.warnings)
        } catch {
            return AnalysisRunFinalization(warnings: ["The viewer index was not built: \(error.localizedDescription)"])
        }
    }
}

/// The cancel a test asks for through the services' hook.
private final class CancelHook: Sendable {
    private let flag = Mutex(false)

    var requested: Bool {
        flag.withLock { $0 }
    }

    func request() {
        flag.withLock { $0 = true }
    }
}

/// Runs a real index builder, hands each step and line of the build on as it comes, and fires the fault.
private final class FaultingIndexer: AnalysisResultIndexing {
    private struct State {
        var handedOver: [ProvenanceStep] = []
        var seen: Set<UUID> = []
        var counts: [String: Int] = [:]
        var firedAt: ContinuousClock.Instant?
    }

    private let base: any AnalysisResultIndexing
    private let fault: BuildDbIndexFault
    private let hook: CancelHook
    private let state = Mutex(State())

    init(base: any AnalysisResultIndexing, fault: BuildDbIndexFault, hook: CancelHook) {
        self.base = base
        self.fault = fault
        self.hook = hook
    }

    var handedOver: [ProvenanceStep] {
        state.withLock { $0.handedOver }
    }

    var firedAt: ContinuousClock.Instant? {
        state.withLock { $0.firedAt }
    }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        let faulting = AnalysisResultIndexRequest(
            toolID: request.toolID,
            resultDirectory: request.resultDirectory,
            layout: request.layout,
            recordedFiles: request.recordedFiles,
            log: { level, message in
                request.log(level, message)
                self.take(line: message)
            },
            recordStep: { step in
                request.recordStep(step)
                self.take(step: step)
            }
        )
        return try await base.buildIndex(faulting)
    }

    private func take(step: ProvenanceStep) {
        let fires = state.withLock { state -> Bool in
            guard state.seen.insert(step.id).inserted else { return false }
            state.handedOver.append(step)
            state.counts[step.toolName, default: 0] += 1
            switch fault {
            case .cancelAfterStep(let name, let ordinal), .requestAfterStep(let name, let ordinal):
                guard state.firedAt == nil, step.toolName == name, state.counts[name] == ordinal else { return false }
                state.firedAt = .now
                return true
            case .none, .cancelAtLine, .requestAtLine:
                return false
            }
        }
        if fires { fire() }
    }

    private func take(line: String) {
        let accepts: (@Sendable (String) -> Bool)?
        switch fault {
        case .cancelAtLine(let lineAccepted), .requestAtLine(let lineAccepted):
            accepts = lineAccepted
        case .none, .cancelAfterStep, .requestAfterStep:
            accepts = nil
        }
        guard let accepts, accepts(line) else { return }
        let fires = state.withLock { state -> Bool in
            guard state.firedAt == nil else { return false }
            state.firedAt = .now
            return true
        }
        if fires { fire() }
    }

    private func fire() {
        switch fault {
        case .requestAfterStep, .requestAtLine:
            hook.request()
        case .none, .cancelAfterStep, .cancelAtLine:
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}

// MARK: - Prepared folders

/// The result folders the cases copy into a run, and the stand-in samtools of their builds.
enum BuildDbIndexFixtures {
    /// `kraken2-mini`, three sample folders that each hold a kreport, a result sidecar and the per-read output.
    static func kraken2(in scratch: URL) throws -> URL {
        try copy("kraken2-mini", to: scratch.appendingPathComponent("prepared-kraken2", isDirectory: true))
    }

    /// The third sample of `esviritu-mini` in a folder of its own, with its BAM and index in `<sample>_temp`.
    static func esViritu(in scratch: URL) throws -> URL {
        let prepared = scratch.appendingPathComponent("prepared-esviritu", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        _ = try copy("esviritu-mini/SRR35517705", to: prepared.appendingPathComponent("SRR35517705", isDirectory: true))
        return prepared
    }

    /// `taxtriage-mini`, with its BAMs unless `withBAMs` is false, holding files the executor's cleanup removes, as
    /// A18's cases hold them.
    static func taxTriage(in scratch: URL, named name: String = "prepared-taxtriage", withBAMs: Bool = true) throws -> URL {
        let prepared = try copy("taxtriage-mini", to: scratch.appendingPathComponent(name, isDirectory: true))
        if !withBAMs {
            try FileManager.default.removeItem(at: prepared.appendingPathComponent("minimap2", isDirectory: true))
        }
        for relative in ["count/S.fastq.gz", "fastp/S.fastp.fastq.gz", "get/S.get.tsv"] {
            let url = prepared.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(relative)\n".utf8).write(to: url)
        }
        return prepared
    }

    /// A HOME whose managed samtools is a stand-in. Its header probe reports a BAM that `samtools markdup` has
    /// marked, so no BAM is rewritten, `view -c` counts 2 reads and `idxstats` names one reference.
    static func samtoolsHome(in scratch: URL) throws -> URL {
        try ManagedSamtoolsHome.makeStub(rootURL: scratch, namePrefix: "Home", script: standInSamtools).homeURL
    }

    private static let standInSamtools = """
        #!/bin/sh
        case "$1" in
          --version) echo "samtools 1.21" ;;
          view)
            case "$2" in
              -H) printf '@HD\\tVN:1.6\\n@PG\\tID:samtools\\tPN:samtools\\tCL:samtools markdup in.bam out.bam\\n' ;;
              -c) echo 2 ;;
            esac ;;
          idxstats) printf 'ref\\t1000\\t2\\t0\\n*\\t0\\t0\\t0\\n' ;;
          index) : > "$2.bai" ;;
          *) exit 1 ;;
        esac
        exit 0
        """

    private static func copy(_ fixture: String, to destination: URL) throws -> URL {
        try FileManager.default.copyItem(
            at: BuildDbStreamCapture.fixturesFolder.appendingPathComponent(fixture, isDirectory: true), to: destination
        )
        return destination
    }
}
