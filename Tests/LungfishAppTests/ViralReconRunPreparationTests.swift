import AppKit
import os
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Phase 2.14 lane W1T. Pressing Run in the Viral Recon sheet stages the run's inputs (the staging folder, the
/// samplesheet, the primer BED and FASTA, the bundled pin). The debug app traps a blocking ToolProcess call made on the
/// main thread (ToolProcessMainThreadGuard), and the primer FASTA is cut from the project's gzip reference through a
/// child gzip, so the staging has to run off the main thread (walk 170, W1).
@MainActor
final class ViralReconRunPreparationTests: XCTestCase {

    /// Run pressed on a sheet that holds an Illumina bundle, a project primer scheme and the project's gzip reference.
    /// The recorder stands in for the trap, and sees every blocking ToolProcess call made on the main thread.
    func testRunStagesViralReconInputsOffTheMainThread() throws {
        let fixture = try Fixture.make()
        addTeardownBlock { TestTempDirectory.cleanup(fixture.root) }
        let harness = Harness(fixture: fixture)
        defer { harness.close() }
        try harness.chooseScheme()

        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        ToolProcessMainThreadGuard.record(into: { name in calls.withLock { $0.append(name) } })
        defer { ToolProcessMainThreadGuard.record(into: nil) }

        harness.pressRun()
        harness.waitForRequests(1)

        XCTAssertEqual(harness.recorder.requests.count, 1, "Run built its request")
        XCTAssertNotNil(
            harness.recorder.requests.first?.primer.fastaURL,
            "the primer FASTA was cut from the project's gzip reference"
        )
        XCTAssertEqual(
            calls.withLock { $0 }, [],
            "no blocking ToolProcess call ran on the main thread while Run staged its inputs"
        )
    }

    /// SWIFT's seam test. The sheet hands the real builder to a detached task, so whatever the builder reads, it reads
    /// off the main thread, and `onRun` comes back on it.
    func testRunPreparesTheRequestOffTheMainThread() throws {
        let fixture = try Fixture.make()
        addTeardownBlock { TestTempDirectory.cleanup(fixture.root) }
        let builderThreads = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let harness = Harness(fixture: fixture) { inputs in
            builderThreads.withLock { $0.append(Thread.isMainThread) }
            return try ViralReconRunPreparation.buildRequest(from: inputs)
        }
        defer { harness.close() }
        try harness.chooseScheme()

        harness.pressRun()
        harness.waitForRequests(1, timeout: 30)

        XCTAssertEqual(builderThreads.withLock { $0 }, [false], "the builder ran once, off the main thread")
        XCTAssertEqual(harness.recorder.requests.count, 1, "onRun ran once")
        XCTAssertEqual(harness.recorder.onRunOnMainThread, [true], "onRun ran on the main thread")
    }

    /// SWIFT's second-run test. The builder waits on a semaphore off the main thread, Run is pressed twice, and only
    /// one preparation starts and only one request comes out.
    func testSecondRunWhilePreparingStartsNothing() throws {
        let held = try makeHeld()
        defer { held.harness.close() }
        try held.pressRunTwice()

        XCTAssertEqual(held.harness.recorder.availability.last, false, "Run reads disabled while the request prepares")
        XCTAssertEqual(held.builds.withLock { $0 }, 1, "the second press started no second preparation")
        held.gate.signal()
        held.harness.waitForRequests(1)
        held.harness.settle()

        XCTAssertEqual(held.harness.recorder.requests.count, 1, "onRun ran once")
    }

    /// UX's double-press test. It shares the harness with the test above and also reads the footer's words.
    func testRunPressedTwiceWhilePreparingLaunchesOneRun() throws {
        let held = try makeHeld()
        defer { held.harness.close() }
        try held.pressRunTwice()

        AccessibilityTreeProbe.waitUntil(timeout: 30) { held.harness.footerText == "Preparing inputs\u{2026}" }
        XCTAssertEqual(held.harness.footerText, "Preparing inputs\u{2026}", "the footer says what is happening")
        held.gate.signal()
        held.harness.waitForRequests(1)
        held.harness.settle()

        XCTAssertEqual(held.harness.recorder.requests.count, 1, "one Run launched one request")
        XCTAssertEqual(held.harness.recorder.availability.last, true, "Run is on again once the request is ready")
        XCTAssertNotEqual(held.harness.footerText, "Preparing inputs\u{2026}", "the footer left the preparing words")
    }

    /// Review fix 3. The Operations dialog shows its readiness text beside the disabled Run. While the request
    /// prepares, the sheet gives the dialog the words "Preparing inputs..." through `onReadinessDetailChange` and
    /// takes them back before `onRun`, so the dialog never tells the user to complete settings that are complete.
    func testDialogStatusReadsPreparingWhileTheRequestPrepares() throws {
        let held = try makeHeld()
        defer { held.harness.close() }
        try held.pressRunTwice()

        XCTAssertEqual(
            held.harness.recorder.details, ["Preparing inputs\u{2026}"],
            "the dialog status reads the preparing words once, and the refused second press added nothing"
        )
        held.gate.signal()
        held.harness.waitForRequests(1)

        XCTAssertEqual(
            held.harness.recorder.details, ["Preparing inputs\u{2026}", nil],
            "the sheet took the preparing words back before the request reached the dialog"
        )
    }

    /// UX's cancel test. The sheet closes while the builder runs, and no request reaches the dialog, so no Operations
    /// row is begun for a run the user cancelled.
    func testCancelWhilePreparingLaunchesNothing() throws {
        let held = try makeHeld()
        defer { held.harness.close() }
        held.harness.pressRun()
        AccessibilityTreeProbe.waitUntil(timeout: 30) { held.builds.withLock { $0 } >= 1 }
        XCTAssertEqual(held.builds.withLock { $0 }, 1, "the builder started")

        held.harness.close()
        held.gate.signal()
        AccessibilityTreeProbe.waitUntil(timeout: 30) { held.finishes.withLock { $0 } >= 1 }
        XCTAssertEqual(held.finishes.withLock { $0 }, 1, "the builder finished")
        held.harness.settle()

        XCTAssertEqual(held.harness.recorder.requests.count, 0, "no onRun after the sheet closed")
    }

    /// Review fix 4. A project without MN908947.3 stages only the primer BED at Run, so the launch path downloads the
    /// reference and cuts the primer FASTA out of it. The cut gunzips the downloaded reference through a child gzip,
    /// which the debug app traps when the service makes the call on the main thread.
    func testDeferredPrimerFASTAIsCutOffTheMainThread() throws {
        enum RunOutcome: Sendable {
            case finished(URL)
            case failed(String)
        }
        let fixture = try Fixture.make(withReference: false)
        addTeardownBlock { TestTempDirectory.cleanup(fixture.root) }
        let harness = Harness(fixture: fixture)
        defer { harness.close() }
        try harness.chooseScheme()
        harness.pressRun()
        harness.waitForRequests(1)
        let request = try XCTUnwrap(harness.recorder.requests.first)
        let stagedFASTA = request.primer.fastaURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        XCTAssertFalse(stagedFASTA, "the project holds no reference, so Run staged only the primer BED")

        // The download copies a reference written before the run, so the downloader starts no child process.
        let downloadable = fixture.root.appendingPathComponent("downloadable.lungfishref", isDirectory: true)
        try Fixture.writeReference(into: downloadable)
        let service = ViralReconWorkflowExecutionService(
            operationCenter: OperationCenter(),
            processRunner: IdleProcessRunner(),
            referenceDownloader: { _, destination in
                try FileManager.default.copyItem(
                    at: downloadable,
                    to: destination.appendingPathComponent(ViralReconReferenceCatalog.bundleFilename, isDirectory: true)
                )
            },
            resultIngest: { _ in }
        )
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        ToolProcessMainThreadGuard.record(into: { name in calls.withLock { $0.append(name) } })
        defer { ToolProcessMainThreadGuard.record(into: nil) }

        // The sheet's host needs the run loop, so the test is synchronous and waits for the service the way it waits
        // for the sheet. An async test body holds the main queue and the sheet never draws.
        let outcome = OSAllocatedUnfairLock<RunOutcome?>(initialState: nil)
        let bundleRoot = fixture.project.appendingPathComponent("Analyses", isDirectory: true)
        let project = fixture.project
        Task {
            do {
                let result = try await service.run(request, bundleRoot: bundleRoot, projectURL: project)
                outcome.withLock { $0 = .finished(result.bundleURL) }
            } catch {
                outcome.withLock { $0 = .failed("\(error)") }
            }
        }
        AccessibilityTreeProbe.waitUntil(timeout: 30) { outcome.withLock { $0 } != nil }

        guard case .finished(let bundleURL)? = outcome.withLock({ $0 }) else {
            return XCTFail("the service run did not finish, it reported \(String(describing: outcome.withLock { $0 }))")
        }
        let cutFASTA = bundleURL.appendingPathComponent("inputs/primers/primers.fasta")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cutFASTA.path),
            "the service cut the primer FASTA out of the downloaded reference"
        )
        XCTAssertEqual(
            calls.withLock { $0 }, [],
            "no blocking ToolProcess call ran on the main thread while the service cut the primer FASTA"
        )
    }
}

// MARK: - Held builder

extension ViralReconRunPreparationTests {
    /// A sheet whose builder waits on `gate` off the main thread. `builds` counts entries into the builder and
    /// `finishes` its exits.
    @MainActor
    struct Held {
        let harness: Harness
        let gate: DispatchSemaphore
        let builds: OSAllocatedUnfairLock<Int>
        let finishes: OSAllocatedUnfairLock<Int>

        /// Presses Run, waits until the sheet reports Run off and the builder holds on the gate, then presses Run
        /// again and lets the sheet take the press. Waiting on the builder makes the second press a real double press
        /// on a busy machine too, where the detached task can start late.
        func pressRunTwice() throws {
            harness.pressRun()
            AccessibilityTreeProbe.waitUntil(timeout: 30) { harness.recorder.availability.last == false }
            XCTAssertEqual(harness.recorder.availability.last, false, "the first press turned Run off")
            AccessibilityTreeProbe.waitUntil(timeout: 30) { builds.withLock { $0 } >= 1 }
            XCTAssertEqual(builds.withLock { $0 }, 1, "the builder started before the second press")
            harness.pressRun()
            harness.settle()
        }
    }

    func makeHeld() throws -> Held {
        let fixture = try Fixture.make()
        addTeardownBlock { TestTempDirectory.cleanup(fixture.root) }
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal() }
        let builds = OSAllocatedUnfairLock<Int>(initialState: 0)
        let finishes = OSAllocatedUnfairLock<Int>(initialState: 0)
        let harness = Harness(fixture: fixture) { inputs in
            builds.withLock { $0 += 1 }
            gate.wait()
            defer { finishes.withLock { $0 += 1 } }
            return try ViralReconRunPreparation.buildRequest(from: inputs)
        }
        try harness.chooseScheme()
        return Held(harness: harness, gate: gate, builds: builds, finishes: finishes)
    }
}

// MARK: - Fixture

extension ViralReconRunPreparationTests {
    /// A project with one Illumina bundle, a project primer scheme written against MN908947.3 and, unless asked
    /// otherwise, the project's own MN908947.3 reference as a gzip FASTA, which is what makes the primer staging gunzip.
    struct Fixture {
        static let schemeTitle = "Run Preparation Test Scheme (Project)"

        let root: URL
        let project: URL
        let bundle: URL

        static func make(withReference: Bool = true) throws -> Fixture {
            let fileManager = FileManager.default
            let root = try TestTempDirectory.make(prefix: "viralrecon-run-prep")
            let project = root.appendingPathComponent("Project", isDirectory: true)
            let bundle = project.appendingPathComponent("Imports/sample.lungfishfastq", isDirectory: true)
            try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

            var fastq = ""
            for index in 0..<12 {
                fastq += "@A00123:45:HXXXXXXXX:1:1101:\(1000 + index):\(2000 + index) 1:N:0:ACGTACGT\n"
                fastq += String(repeating: "ACGT", count: 37) + "AC\n+\n" + String(repeating: "I", count: 150) + "\n"
            }
            let reads = bundle.appendingPathComponent("reads.fastq")
            try fastq.write(to: reads, atomically: true, encoding: .utf8)
            try gzip(reads)

            if withReference {
                try writeReference(
                    into: project.appendingPathComponent("Reference Sequences/MN908947.3.lungfishref", isDirectory: true)
                )
            }

            let schemes = try PrimerSchemesFolder.ensureFolder(in: project)
            let scheme = schemes.appendingPathComponent("RunPrepScheme.lungfishprimers", isDirectory: true)
            try fileManager.createDirectory(at: scheme, withIntermediateDirectories: true)
            let manifest = """
            {
              "schema_version": 1,
              "name": "run-prep-scheme",
              "display_name": "Run Preparation Test Scheme",
              "description": "Viral Recon run preparation test",
              "organism": "SARS-CoV-2",
              "reference_accessions": [
                { "accession": "MN908947.3", "canonical": true }
              ],
              "primer_count": 2,
              "amplicon_count": 1
            }
            """
            try manifest.write(to: scheme.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try "MN908947.3\t0\t8\tamplicon_1_LEFT\t1\t+\nMN908947.3\t12\t20\tamplicon_1_RIGHT\t1\t-\n"
                .write(to: scheme.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
            try "Test fixture.\n".write(
                to: scheme.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8
            )
            return Fixture(root: root, project: project, bundle: bundle)
        }

        /// Writes MN908947.3 into `referenceBundle` as a gzip FASTA. The project holds it as a reference bundle, and
        /// the service's downloader writes it as the download.
        static func writeReference(into referenceBundle: URL) throws {
            try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
            let reference = referenceBundle.appendingPathComponent("sequence.fa")
            try (">MN908947.3\n" + String(repeating: "ACGT", count: 20) + "\n")
                .write(to: reference, atomically: true, encoding: .utf8)
            try gzip(reference)
        }

        private static func gzip(_ url: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-f", url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw HarnessError.gzipFailed(url.lastPathComponent) }
        }
    }

    enum HarnessError: Error, CustomStringConvertible {
        case gzipFailed(String)
        case noContentView
        case noSchemePopUp(String)
        case runStayedDisabled([Bool])

        var description: String {
            switch self {
            case .gzipFailed(let name): return "gzip failed on \(name)"
            case .noContentView: return "the sheet window has no content view"
            case .noSchemePopUp(let titles): return "no pop-up holds the project scheme, pop-ups hold \(titles)"
            case .runStayedDisabled(let history): return "the sheet never reported Run ready, it reported \(history)"
            }
        }
    }

    /// A process runner that ends every run at once, so a service run goes through without a pipeline.
    @MainActor
    final class IdleProcessRunner: ViralReconWorkflowProcessRunning {
        func runLungfishCLI(
            arguments: [String],
            workingDirectory: URL,
            outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
        ) async throws -> ViralReconWorkflowProcessResult {
            .init(exitCode: 0, standardOutput: "", standardError: "")
        }

        func cancel() {}
    }

    // MARK: Harness

    /// What the sheet reported to its host.
    final class Recorder {
        var requests: [ViralReconRunRequest] = []
        var availability: [Bool] = []
        var onRunOnMainThread: [Bool] = []
        var details: [String?] = []
    }

    /// Hosts the sheet the way the Operations dialog does. The dialog bumps `embeddedRunTrigger` when Run is pressed,
    /// so the harness does the same, and the sheet's `onRun`, `onRunnerAvailabilityChange` and
    /// `onReadinessDetailChange` land in the recorder.
    @MainActor
    final class Harness {
        final class TriggerModel: ObservableObject {
            @Published var value = 0
        }

        struct Host: View {
            @ObservedObject var model: TriggerModel
            let inputFiles: [URL]
            let projectURL: URL
            let prepareRun: @Sendable (ViralReconRunInputs) throws -> ViralReconRunRequest
            let onRun: (ViralReconRunRequest) -> Void
            let onAvailability: (Bool) -> Void
            let onReadinessDetail: (String?) -> Void

            var body: some View {
                ViralReconWizardSheet(
                    inputFiles: inputFiles,
                    projectURL: projectURL,
                    embeddedInOperationsDialog: true,
                    embeddedRunTrigger: model.value,
                    onRun: onRun,
                    onRunnerAvailabilityChange: onAvailability,
                    prepareRun: prepareRun,
                    onReadinessDetailChange: onReadinessDetail
                )
            }
        }

        let recorder = Recorder()
        let model = TriggerModel()
        let window: NSWindow

        init(
            fixture: Fixture,
            prepareRun: @escaping @Sendable (ViralReconRunInputs) throws -> ViralReconRunRequest
                = ViralReconRunPreparation.buildRequest(from:)
        ) {
            let recorder = self.recorder
            window = AccessibilityTreeProbe.host(
                Host(
                    model: model,
                    inputFiles: [fixture.bundle],
                    projectURL: fixture.project,
                    prepareRun: prepareRun,
                    onRun: {
                        recorder.requests.append($0)
                        recorder.onRunOnMainThread.append(Thread.isMainThread)
                    },
                    onAvailability: { recorder.availability.append($0) },
                    onReadinessDetail: { recorder.details.append($0) }
                ),
                size: CGSize(width: 560, height: 900)
            )
        }

        func close() {
            window.contentView = NSView()
            window.orderOut(nil)
        }

        func pressRun() {
            model.value += 1
        }

        func waitForRequests(_ count: Int, timeout: TimeInterval = 30) {
            AccessibilityTreeProbe.waitUntil(timeout: timeout) { recorder.requests.count >= count }
        }

        /// Lets the run loop take whatever the sheet does after a press or a release. A condition that never holds
        /// has nothing to return early on, so this is a short fixed spin.
        func settle() {
            AccessibilityTreeProbe.waitUntil(timeout: 1) { false }
        }

        /// The words of the sheet's footer, read the way VoiceOver reads them.
        var footerText: String? {
            AccessibilityTreeProbe.element(in: window, identifier: ViralReconAccessibilityID.readinessLabel)
                .flatMap { AccessibilityTreeProbe.label($0) ?? AccessibilityTreeProbe.value($0) }
        }

        /// Picks the project scheme in the sheet's Scheme pop-up, the way a user does, and waits until the sheet
        /// reports Run ready. A pick is the only way to ready the sheet, since the picker starts empty.
        func chooseScheme() throws {
            guard let root = window.contentView else { throw HarnessError.noContentView }
            var popUp: NSPopUpButton?
            AccessibilityTreeProbe.waitUntil(timeout: 30) {
                popUp = Self.popUps(in: root).first { $0.itemTitles.contains(Fixture.schemeTitle) }
                return popUp != nil
            }
            guard let popUp else {
                throw HarnessError.noSchemePopUp(Self.popUps(in: root).map(\.itemTitles).description)
            }
            popUp.selectItem(withTitle: Fixture.schemeTitle)
            if let action = popUp.action { popUp.sendAction(action, to: popUp.target) }
            if let menu = popUp.menu {
                menu.performActionForItem(at: menu.indexOfItem(withTitle: Fixture.schemeTitle))
            }
            AccessibilityTreeProbe.waitUntil(timeout: 30) { recorder.availability.last == true }
            guard recorder.availability.last == true else {
                throw HarnessError.runStayedDisabled(recorder.availability)
            }
        }

        private static func popUps(in view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? [] + view.subviews.flatMap { popUps(in: $0) }
        }
    }
}
