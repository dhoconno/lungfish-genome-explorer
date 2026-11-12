// ToolProcessMemoryStop.swift - The one route where a tool the Mac stopped for memory becomes words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization

/// A tool that ended by SIGKILL, or by exit 137 from a wrapper such as `micromamba run` that reports its killed
/// child that way, when ToolProcess sent no stop of its own. macOS ends a process like this when the Mac runs out of
/// memory. This is the one route where such an end becomes words. Every pipeline error type that words a tool's end
/// asks it first, as it asks ``ToolProcessResult/incompleteOutputReason``, so the reason reads the same whichever
/// pipeline ran the tool. A tool that words its own memory failure (BBTools, SPAdes) exits with its own status and
/// never reaches it.
package struct ToolProcessMemoryStop: Sendable, Equatable {
    /// The status a wrapper reports for a child ended by SIGKILL (128 + 9).
    package static let killedExitCode: Int32 = 137

    /// The next step when the caller has none of its own.
    package static let defaultNextStep =
        "Close other apps and run it again, or run fewer or smaller samples at a time, or use a Mac with more memory."

    /// The tool's name, as the person knows it.
    package let tool: String
    /// The peak resident memory of the tool and the children it waited for, from `wait4`, or nil when unknown.
    package let peakMemoryBytes: UInt64?
    /// This Mac's memory.
    package let physicalMemoryBytes: UInt64

    /// A stop when `termination` is SIGKILL or exit 137 and `stop` is nil, and nil for any other end.
    package init?(
        tool: String,
        termination: ToolProcessTermination,
        stop: ToolProcessStop?,
        peakMemoryBytes: UInt64?,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        guard stop == nil else { return nil }
        switch termination {
        case .signaled(signal: SIGKILL), .exited(code: Self.killedExitCode):
            break
        default:
            return nil
        }
        self.tool = tool
        self.peakMemoryBytes = peakMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// The stop of `result`, named by its label. The result does not carry the peak, so pass the one an
    /// observation read, or nil.
    package init?(
        result: ToolProcessResult,
        tool: String? = nil,
        peakMemoryBytes: UInt64? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.init(
            tool: tool ?? result.label, termination: result.termination, stop: result.stop,
            peakMemoryBytes: peakMemoryBytes, physicalMemoryBytes: physicalMemoryBytes
        )
    }

    /// The stop of a pipeline that kept only the exit status of its tool, as a `micromamba run` caller does.
    package init?(
        tool: String,
        exitCode: Int32,
        peakMemoryBytes: UInt64? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.init(
            tool: tool, termination: .exited(code: exitCode), stop: nil,
            peakMemoryBytes: peakMemoryBytes, physicalMemoryBytes: physicalMemoryBytes
        )
    }

    /// What happened, in two sentences that name the tool, its peak when known and this Mac's memory.
    package var reason: String {
        let what = "\(tool) stopped before it finished, most likely because the Mac ran out of memory."
        let ram = MemoryWords.bytes(physicalMemoryBytes)
        guard let peakMemoryBytes else {
            return "\(what) It ran on a Mac with \(ram)."
        }
        return "\(what) It reached \(MemoryWords.bytes(peakMemoryBytes)) at its peak on a Mac with \(ram)."
    }

    /// The reason followed by what to try next.
    package func message(nextStep: String = Self.defaultNextStep) -> String {
        "\(reason) \(nextStep)"
    }
}

/// Memory sizes in the words LGE shows, in binary units as macOS reports memory, so a 64 GB Mac reads 64 GB.
package enum MemoryWords {
    /// `bytes` in GB, MB or KB, with one decimal below 10 when it is not whole.
    package static func bytes(_ bytes: UInt64) -> String {
        let units: [(size: Double, name: String)] = [(1_073_741_824, "GB"), (1_048_576, "MB")]
        for unit in units where Double(bytes) >= unit.size {
            return number(Double(bytes) / unit.size) + " " + unit.name
        }
        return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }

    private static func number(_ value: Double) -> String {
        if value >= 10 {
            return String(Int(value.rounded()))
        }
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}

/// Keeps how the one launch in its scope ended and its peak, for a caller whose adapter hands back no result, such
/// as `CondaManager.runTool`. It forwards the observation unchanged to the observer it wraps, so the step's
/// provenance record is the same as without it. Bind ``observer(forwardingTo:)`` around one launch only.
package final class ToolProcessEndCapture: Sendable {
    private struct End {
        var label: String
        var termination: ToolProcessTermination
        var stop: ToolProcessStop?
        var peakMemoryBytes: UInt64?
    }

    private let end = Mutex<End?>(nil)

    package init() {}

    /// An observer that keeps the last launched stage's end and then hands the observation to `inner`. Pass the
    /// step's own observer, or the task's binding when the step has none, so binding this changes nothing else.
    package func observer(forwardingTo inner: ToolProcessObserver?) -> ToolProcessObserver {
        ToolProcessObserver { [self] observation in
            if let stage = observation.stages.last(where: { $0.ending.launched }),
               case .terminated(let termination) = stage.ending {
                let kept = End(
                    label: stage.label, termination: termination,
                    stop: stage.stop ?? observation.stop, peakMemoryBytes: stage.observedPeakMemoryBytes
                )
                end.withLock { $0 = kept }
            }
            inner?.deliver(observation)
        }
    }

    /// The memory stop of the captured launch, or nil when it ended any other way or never ran.
    package func memoryStop(
        tool: String? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ToolProcessMemoryStop? {
        guard let kept = end.withLock({ $0 }) else { return nil }
        return ToolProcessMemoryStop(
            tool: tool ?? kept.label, termination: kept.termination, stop: kept.stop,
            peakMemoryBytes: kept.peakMemoryBytes, physicalMemoryBytes: physicalMemoryBytes
        )
    }
}
