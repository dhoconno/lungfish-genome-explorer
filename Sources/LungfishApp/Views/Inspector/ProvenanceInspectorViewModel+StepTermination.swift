// ProvenanceInspectorViewModel+StepTermination.swift - The lines a step's observation adds to its disclosure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// The lines of a step's disclosure that its `observation` adds (Phase 2.10 lane U37, decision P2 of Phase 2.8).
///
/// The step's own rows already give its exit status, its wall time and its stderr, so a line shows only when it
/// adds something to them.
///
/// - Termination says how the step ended when Exit Status does not. A step that exited on its own adds nothing,
///   since Exit Status gives its code. A step ToolProcess stopped, a step a signal ended (Exit Status then holds
///   the signal number and reads like a code), a step whose status something else took and a step that never ran
///   add the line. A time limit is the limit the step reached and never how long it ran.
/// - Output reads Incomplete when an output of the step was cut short, and Not recorded when a step that ran and
///   did not exit 0 recorded nothing about its output. Output read whole adds nothing, and neither does a step that
///   never started, since Termination says so.
/// - Environment is one line, what the step's adapter changed. An inherited environment it left alone adds nothing.
///   The line names the variables and never their values or the PATH entries, which a decoded record resolves to
///   folders of the Mac that reads it. No rule reads a particular name, `TMPDIR` among them.
///
/// A step with no observation, a record written before a step could carry one, an observation this build cannot
/// read and an observation that adds no line all have no display, so the disclosure reads as it always did.
struct ProvenanceStepTerminationDisplay: Equatable, Sendable {
    /// One line of the step's disclosure. The cases are declared in the order the disclosure, the Copy text and
    /// VoiceOver read them. Environment follows the Command, Termination follows Exit Status and Output follows
    /// Wall Time.
    enum Line: CaseIterable, Sendable {
        case environment
        case termination
        case output

        var label: String {
            switch self {
            case .environment: return "Environment"
            case .termination: return "Termination"
            case .output: return "Output"
            }
        }

        /// The accessibility identifier of the line's value, beside `provenance-step-command`.
        var identifier: String {
            switch self {
            case .environment: return "provenance-step-environment"
            case .termination: return "provenance-step-termination"
            case .output: return "provenance-step-output"
            }
        }
    }

    let environment: String?
    let termination: String?
    let output: String?

    /// The lines `observation` adds, or nil when the step has no observation or it adds none.
    init?(_ observation: ProvenanceStepObservation?) {
        guard let observation else { return nil }
        let environment = Self.environmentText(observation.environment)
        let termination = Self.terminationText(observation)
        let output = Self.outputText(observation)
        guard environment != nil || termination != nil || output != nil else { return nil }
        self.environment = environment
        self.termination = termination
        self.output = output
    }

    /// The text of `line`, or nil when the line does not show.
    func text(of line: Line) -> String? {
        switch line {
        case .environment: return environment
        case .termination: return termination
        case .output: return output
        }
    }

    /// The shown lines, for the Lineage search.
    var searchText: String {
        Line.allCases.compactMap { text(of: $0) }.joined(separator: "\n")
    }

    // MARK: - Termination

    private static func terminationText(_ observation: ProvenanceStepObservation) -> String? {
        guard let stop = observation.stop else { return endedText(observation.termination) }
        let headline: String
        switch stop {
        case .cancelled:
            headline = "Cancelled"
        case .timedOut(.wallClock, let seconds):
            headline = "Timed out at its limit of \(LungfishFormatters.formatDuration(seconds))"
        case .timedOut(.idle, let seconds):
            headline = "Timed out at its limit of \(LungfishFormatters.formatDuration(seconds)) without output"
        case .pipelineStageFailed:
            headline = "Stopped because another stage of its pipeline failed"
        }
        guard let detail = endedDetail(observation.termination) else { return headline }
        return "\(headline) (\(detail))"
    }

    /// How a step ToolProcess did not stop ended, or nil when Exit Status says it.
    private static func endedText(_ termination: ProvenanceStepObservation.Termination) -> String? {
        switch termination {
        case .exited:
            return nil
        case .signaled(let signal):
            return "Ended by signal \(signal)" + (signalName(signal).map { " (\($0))" } ?? "")
        case .statusLost:
            return "Exit status taken by another process"
        case .launchFailed(let reason):
            let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Could not start" + (text.isEmpty ? "" : " (\(text))")
        case .notLaunched:
            return "Did not start"
        }
    }

    /// The same facts as the parenthesis after the headline of a step ToolProcess stopped.
    private static func endedDetail(_ termination: ProvenanceStepObservation.Termination) -> String? {
        switch termination {
        case .exited:
            return nil
        case .signaled(let signal):
            return "signal \(signal)" + (signalName(signal).map { ", \($0)" } ?? "")
        case .statusLost:
            return "exit status taken by another process"
        case .launchFailed(let reason):
            let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return "could not start" + (text.isEmpty ? "" : ", \(text)")
        case .notLaunched:
            return "did not start"
        }
    }

    /// The name of a signal this Mac defines, or nil for any other number. A record of this app is written on a Mac.
    private static func signalName(_ signal: Int) -> String? {
        switch Int32(truncatingIfNeeded: signal) {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGBUS: return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        default: return nil
        }
    }

    // MARK: - Output

    private static func outputText(_ observation: ProvenanceStepObservation) -> String? {
        if observation.outputComplete == false { return "Incomplete" }
        guard observation.outputComplete == nil else { return nil }
        switch observation.termination {
        case .exited(code: 0), .launchFailed, .notLaunched: return nil
        case .exited, .signaled, .statusLost: return "Not recorded"
        }
    }

    // MARK: - Environment

    /// The PATH the adapter set does not end with the inherited PATH, so the record's `pathPrefix` is the whole PATH
    /// the step got (Phase 2.10 S8, the review of S36). The line says that and never that the PATH was dropped.
    private static let replacedPathText = "PATH set to a value that does not end with the inherited PATH"

    private static func environmentText(_ environment: ProvenanceStepObservation.Environment?) -> String? {
        guard let environment else { return nil }
        switch environment.base {
        case .hermetic:
            // A hermetic base inherits no PATH to replace, so a stored flag on it means nothing.
            return environment.changed.isEmpty
                ? "Empty"
                : "Empty, with \(list(environment.changed)) set"
        case .inherited:
            let replaced = environment.pathReplaced
            let others = environment.changed.filter { !(replaced && $0 == "PATH") }
            var changes: [String] = []
            if !others.isEmpty { changes.append("\(list(others)) set") }
            if replaced { changes.append(replacedPathText) }
            if !environment.unset.isEmpty { changes.append("\(list(environment.unset)) removed") }
            guard !changes.isEmpty else { return nil }
            return "Inherited from Lungfish, with \(list(changes))"
        }
    }

    /// `a`, `a and b` or `a, b and c`.
    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension ProvenanceInspectorViewModel {
    /// The Copy text lines of a Lineage step, in the order its disclosure shows its rows and VoiceOver reads them.
    func appendStepLines(of step: ProvenanceLineageStep, to lines: inout [String]) {
        appendIfPresent("Command", step.command, to: &lines)
        appendStepLine(.environment, of: step, to: &lines)
        for line in ProvenanceStepStorageDisplay.Line.allCases {
            appendIfPresent(line.label, step.storage?.text(of: line) ?? "", to: &lines)
        }
        appendList("Inputs", step.inputPaths, to: &lines)
        appendList("Outputs", step.outputPaths, to: &lines)
        appendIfPresent("Exit Status", step.exitStatus.map(String.init) ?? "", to: &lines)
        appendStepLine(.termination, of: step, to: &lines)
        appendIfPresent("Wall Time", step.wallTimeSeconds.map { "\(String(format: "%.2f", $0)) s" } ?? "", to: &lines)
        appendStepLine(.output, of: step, to: &lines)
        appendIfPresent("stderr", step.stderr ?? "", to: &lines)
    }

    private func appendStepLine(
        _ line: ProvenanceStepTerminationDisplay.Line,
        of step: ProvenanceLineageStep,
        to lines: inout [String]
    ) {
        appendIfPresent(line.label, step.observation?.text(of: line) ?? "", to: &lines)
    }
}
