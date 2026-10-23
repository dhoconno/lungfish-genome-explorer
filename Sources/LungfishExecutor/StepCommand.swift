import Dispatch
import Foundation
import LungfishPortable

/// `lungfish-executor step`, one tool run under the launcher with its record. Lane K4's `run --plan` replaces it as the
/// executor's command, and keeps it as the unit the plan's steps run through.
///
/// Grammar: `lungfish-executor step --record <file> --stdout <file> --stderr <file> [--grace <seconds>]
/// [--deadline <seconds>] [--output <file>]... [--env NAME=VALUE]... [--sweep-interval-ms <n>] -- <absolute program>
/// [<argument>...]`. The tool's environment is exactly the `--env` pairs. Exit codes are `ExecutorExitCode`.
enum StepCommand {
    static let usage = "usage: lungfish-executor step --record <file> --stdout <file> --stderr <file> [--grace <seconds>] "
        + "[--deadline <seconds>] [--output <file>]... [--env NAME=VALUE]... [--sweep-interval-ms <n>] -- <program> [<argument>...]\n"

    /// The plan's default grace and the most a plan may ask for (C3 design section 4).
    static let defaultGraceSeconds = 30.0
    static let maximumGraceSeconds = 120.0
    /// The longest deadline a plan may ask for, one year. A longer one is refused before any tool starts, so the controller's
    /// millisecond arithmetic cannot overflow once the tool is running.
    static let maximumDeadlineSeconds = 31_536_000.0

    struct Options: Equatable {
        var record = ""
        var stdout = ""
        var stderr = ""
        var grace = StepCommand.defaultGraceSeconds
        var deadline: Double?
        var outputs: [String] = []
        var environment: [String: String] = [:]
        var sweepIntervalMilliseconds = 1000
        var program: [String] = []
    }

    /// A usage error's message.
    struct UsageError: Error, Equatable, ExpressibleByStringInterpolation {
        let message: String
        init(stringLiteral value: String) { message = value }
    }

    /// Parses the arguments after `step`, or returns the usage error.
    static func parse(_ arguments: [String]) -> Result<Options, UsageError> {
        var options = Options()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--" {
                options.program = Array(arguments[(index + 1)...])
                break
            }
            guard let text = value() else { return .failure("\(flag) needs a value") }
            switch flag {
            case "--record": options.record = text
            case "--stdout": options.stdout = text
            case "--stderr": options.stderr = text
            case "--output": options.outputs.append(text)
            case "--grace":
                guard let seconds = Double(text), seconds.isFinite else { return .failure("--grace needs a number") }
                options.grace = seconds
            case "--deadline":
                guard let seconds = Double(text), seconds.isFinite, seconds > 0 else {
                    return .failure("--deadline needs a positive number")
                }
                options.deadline = seconds
            case "--sweep-interval-ms":
                guard let milliseconds = Int(text), (1...60_000).contains(milliseconds) else {
                    return .failure("--sweep-interval-ms needs 1 to 60000")
                }
                options.sweepIntervalMilliseconds = milliseconds
            case "--env":
                guard let equals = text.firstIndex(of: "="), equals != text.startIndex else {
                    return .failure("--env needs NAME=VALUE")
                }
                options.environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
            default:
                return .failure("unknown option \(flag)")
            }
            index += 1
        }
        guard !options.record.isEmpty, !options.stdout.isEmpty, !options.stderr.isEmpty else {
            return .failure("--record, --stdout and --stderr are required")
        }
        guard !options.program.isEmpty else { return .failure("no program after --") }
        return .success(options)
    }

    /// Why the run may not start, checked before any tool runs, or nil. The executor must be a child subreaper on Linux, so
    /// `subreaperRequired` defaults to `isLinux`. A test passes true to reach the refusal on any platform.
    static func refusal(
        _ options: Options,
        subreaper: ChildSubreaper.Report,
        subreaperRequired: Bool = StepCommand.isLinux
    ) -> String? {
        if subreaperRequired && !subreaper.isSet {
            let code = subreaper.setterResult != 0 ? subreaper.setterResult : subreaper.getterResult
            let name = code != 0 ? ChildSubreaper.errnoName(code) : "a getter value of \(subreaper.getterValue ?? 0)"
            return StepReason.subreaperRefused(errnoName: name)
        }
        if options.grace < 0 || options.grace > maximumGraceSeconds {
            return "The grace of \(StepController.format(options.grace)) seconds is outside 0 to 120 seconds. No tool ran."
        }
        if !options.program[0].hasPrefix("/") {
            return "The program \(options.program[0]) is not an absolute path. No tool ran."
        }
        if let deadline = options.deadline, deadline > maximumDeadlineSeconds {
            return "The deadline of \(StepController.format(deadline)) seconds is above 31536000 seconds. No tool ran."
        }
        return nil
    }

    /// Runs the step mode. Called from `main` after the termination signals are blocked and before any thread exists.
    static func main(_ arguments: [String]) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .success(let parsed): options = parsed
        case .failure(let error):
            FileHandle.standardError.write(Data("lungfish-executor: \(error.message)\n\(usage)".utf8))
            return ExecutorExitCode.usage
        }
        // Before any thread or child exists (tally-r2 K3-1). Off Linux both calls return ENOSYS and change nothing.
        let subreaper = ChildSubreaper.setAndConfirm()
        var record = StepRecord(
            executorVersion: ExecutorCommand.version,
            executorPID: getpid(),
            outcome: "refused",
            exitCode: ExecutorExitCode.refused,
            orphanSweep: subreaper.isSet ? "subreaper" : "parentWalkOnly",
            subreaper: StepRecord.Subreaper(
                state: subreaper.isSet ? "set" : (isLinux ? "notSet" : "unavailable"),
                setterResult: subreaper.setterResult,
                setterResultName: ChildSubreaper.errnoName(subreaper.setterResult),
                getterResult: subreaper.getterResult,
                getterValue: subreaper.getterValue
            ),
            argv: options.program,
            environmentNames: options.environment.keys.sorted(),
            graceSeconds: options.grace,
            deadlineSeconds: options.deadline,
            escalatedToSIGKILL: false,
            stoppedProcesses: [],
            adoptedOrphansReaped: 0,
            wallSeconds: 0,
            outputs: []
        )
        if let reason = refusal(options, subreaper: subreaper) {
            record.reason = reason
            return finish(record, at: options.record)
        }

        ExecutorSignals.ignoreBrokenPipe()
        ExecutorSpawn.markInheritedDescriptorsCloseOnExec()
        let controller = StepController()
        let sources = ExecutorSignals.watch(queue: DispatchQueue(label: "lungfish-executor.signals")) { signal in
            controller.interrupt(signal)
        }
        let spec = StepSpec(
            executable: options.program[0],
            arguments: Array(options.program.dropFirst()),
            environment: options.environment,
            stdoutPath: options.stdout,
            stderrPath: options.stderr,
            outputs: options.outputs,
            graceSeconds: options.grace,
            deadlineSeconds: options.deadline,
            sweepIntervalSeconds: Double(options.sweepIntervalMilliseconds) / 1000
        )
        var result = withExtendedLifetime(sources) { controller.run(spec) }
        if result.outcome != .interrupted, let signal = controller.interruptSignal {
            // A signal that arrived after the tool's end still ends the run as interrupted, with nothing left running.
            result.outcome = .interrupted
            result.signal = signal
            result.outputs = []
            result.reason = "The executor received \(ExecutorSignals.name(signal)) and stopped the step."
        }
        record.outcome = result.outcome.rawValue
        record.reason = result.reason
        record.signal = result.signal
        record.signalName = result.signal.map(ExecutorSignals.name)
        record.toolPID = result.toolPID
        if case .exited(let code)? = result.exit?.termination { record.toolExitCode = code }
        if case .signaled(let signal)? = result.exit?.termination { record.toolSignal = signal }
        record.peakResidentBytes = result.exit?.peakResidentBytes
        record.escalatedToSIGKILL = result.escalatedToSIGKILL
        record.stoppedProcesses = result.stoppedProcesses
        record.adoptedOrphansReaped = result.adoptedOrphansReaped
        record.wallSeconds = result.wallSeconds
        record.outputs = result.outputs
        switch result.outcome {
        case .succeeded: record.exitCode = ExecutorExitCode.succeeded
        case .failed: record.exitCode = ExecutorExitCode.failed
        case .interrupted: record.exitCode = ExecutorExitCode.interrupted
        }
        return finish(record, at: options.record)
    }

    static var isLinux: Bool {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }

    private static func finish(_ record: StepRecord, at path: String) -> Int32 {
        do {
            try record.write(to: path)
        } catch {
            FileHandle.standardError.write(Data("lungfish-executor: \(error)\n".utf8))
            return ExecutorExitCode.failed
        }
        if let reason = record.reason {
            FileHandle.standardError.write(Data("lungfish-executor: \(record.outcome): \(reason)\n".utf8))
        }
        return record.exitCode
    }
}
