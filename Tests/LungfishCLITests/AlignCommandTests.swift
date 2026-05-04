import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class AlignCommandTests: XCTestCase {
    func testMAFFTCommandPassesRequestToRuntimeAndEmitsJSONEvents() async throws {
        let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
        let input = project.appendingPathComponent("input.fasta")
        let output = project.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        let command = try AlignCommand.MAFFTSubcommand.parse([
            "mafft",
            input.path,
            "--project", project.path,
            "--output", output.path,
            "--name", "Aligned",
            "--strategy", "linsi",
            "--output-order", "input",
            "--extra-mafft-options", "--op 1.53 --leavegappyregion",
            "--threads", "3",
            "--format", "json",
        ])

        let runtime = AlignCommand.MAFFTSubcommand.Runtime(
            runMAFFT: { request, progress in
                XCTAssertEqual(request.inputSequenceURLs, [input])
                XCTAssertEqual(request.projectURL, project)
                XCTAssertEqual(request.outputBundleURL, output)
                XCTAssertEqual(request.name, "Aligned")
                XCTAssertEqual(request.strategy, .linsi)
            XCTAssertEqual(request.outputOrder, .input)
            XCTAssertEqual(request.threads, 3)
            XCTAssertEqual(request.extraArguments, ["--op", "1.53", "--leavegappyregion"])
            XCTAssertTrue(request.wrapperArgv.contains("--extra-mafft-options"))
            XCTAssertTrue(request.wrapperArgv.contains("--sequence-type"))
            XCTAssertTrue(request.wrapperArgv.contains("auto"))
            XCTAssertTrue(request.wrapperArgv.contains("--adjust-direction"))
            XCTAssertTrue(request.wrapperArgv.contains("off"))
            XCTAssertTrue(request.wrapperArgv.contains("--symbols"))
            XCTAssertTrue(request.wrapperArgv.contains("strict"))

            progress(0.25, "Running MAFFT...")
                return MSAAlignmentRunResult(
                    bundleURL: output,
                    rowCount: 2,
                    alignedLength: 6,
                    warnings: ["Duplicate row names were rewritten."],
                    wallTimeSeconds: 1.25
                )
            }
        )

        let recorder = SendableLineRecorder()
        _ = try await command.executeForTesting(runtime: runtime) { recorder.append($0) }
        let lines = recorder.lines()

        XCTAssertTrue(lines.contains { $0.contains(#""event":"msaAlignmentStart""#) })
        XCTAssertTrue(lines.contains { $0.contains(#""event":"msaAlignmentProgress""#) && $0.contains("Running MAFFT") })
        XCTAssertTrue(lines.contains { $0.contains(#""event":"msaAlignmentWarning""#) })
        let complete = try XCTUnwrap(lines.first { $0.contains(#""event":"msaAlignmentComplete""#) })
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(complete.contains(output.path))
        XCTAssertTrue(complete.contains(#""rowCount":2"#))
        XCTAssertTrue(complete.contains(#""alignedLength":6"#))
    }

    func testMAFFTCommandUsesAutoStrategyByDefault() throws {
        let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
        let input = project.appendingPathComponent("input.fasta")
        let command = try AlignCommand.MAFFTSubcommand.parse([
            "mafft",
            input.path,
            "--project", project.path,
        ])

        let request = try command.makeRequestForTesting()

        XCTAssertEqual(request.strategy, .auto)
        XCTAssertEqual(request.outputOrder, .input)
        XCTAssertNil(request.threads)
        XCTAssertEqual(request.inputSequenceURLs, [input])
        XCTAssertEqual(request.projectURL, project)
    }
}

private final class SendableLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
