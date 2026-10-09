// ToolProcessSpec.swift - What ToolProcess runs and how its streams are wired
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a process reads its standard input from.
public enum ToolProcessInput: Sendable, Equatable {
    /// `/dev/null`, so the process never inherits the caller's terminal or stdin.
    case null
    /// The bytes of a file, opened read-only before launch.
    case file(URL)
    /// These bytes, written through a pipe that is closed after the last byte.
    /// A process that exits without reading them all is not an error.
    case data(Data)
}

/// Where a process writes one of its output streams.
public enum ToolProcessOutput: Sendable, Equatable {
    /// Read through a pipe from launch until end of file. Every line is
    /// delivered as a ``ToolProcessEvent/output(stream:line:)`` event, and the
    /// bytes are kept in the result. With a `limit`, only the last `limit`
    /// bytes are kept and the result marks the stream truncated. A limit of 0
    /// streams lines without keeping any bytes.
    case capture(limit: Int? = nil)
    /// Written by the process straight into this file, created or truncated
    /// before launch. No line events are delivered for the stream. The run
    /// waits for the stage's process group to empty, so a descendant still
    /// writing the file holds it. A descendant that left the group with
    /// setsid or setpgid is not seen and can write after the run returns.
    case file(URL)
    /// Sent to `/dev/null`. No line events are delivered for the stream.
    case discard
    /// Read raw by the caller through ``ToolProcessRun/stdout`` while the
    /// process runs, so the bytes keep every CR and no line is cut, and the
    /// pipe holds the process back when the caller reads slower than it
    /// writes. Only standard output of a run started with
    /// ``ToolProcess/start(_:onEvent:onLaunch:)`` can stream. No line events
    /// are delivered and the result keeps no bytes. Once the process exits, a
    /// descendant still writing the stream gets ``ToolProcessSpec/drainGracePeriod``,
    /// so a reader slower than that sees it killed and the output incomplete.
    case stream

    var isCaptured: Bool {
        if case .capture = self { return true }
        return false
    }
}

/// Everything ``ToolProcess`` needs to run one external process.
///
/// The environment is the complete environment of the child. Nothing is
/// inherited unless the caller puts it there, for example with
/// ``inheritedEnvironment(overriding:)``.
public struct ToolProcessSpec: Sendable {
    /// The executable to launch.
    public var executableURL: URL
    /// Arguments after the executable, without argv[0].
    public var arguments: [String]
    /// The complete environment of the child process.
    public var environment: [String: String]
    /// The working directory, or nil for the caller's current directory.
    public var workingDirectory: URL?
    /// Standard input.
    public var stdin: ToolProcessInput
    /// Standard output.
    public var stdout: ToolProcessOutput
    /// Standard error.
    public var stderr: ToolProcessOutput
    /// Wall-clock limit from launch, measured on a monotonic clock. Nil means none.
    public var timeout: Duration?
    /// Limit on the time with no output on any captured stream, and with no
    /// bytes taken by the reader of a streamed stdout. Nil means none. It
    /// needs at least one stream set to ``ToolProcessOutput/capture(limit:)``
    /// or stdout set to ``ToolProcessOutput/stream``. A streamed stdout counts
    /// only what the reader takes, so a reader that stops reading lets the
    /// limit fire even while the process waits on the full pipe.
    public var idleTimeout: Duration?
    /// How long a cancelled or timed-out process tree has between SIGTERM and
    /// SIGKILL. A tree that exits sooner ends the wait at once. It applies to
    /// a cancellation and a timeout only. Descendants
    /// still holding output when ``drainGracePeriod`` runs out get a short
    /// fixed grace of their own, because the run is already over for them.
    public var terminationGracePeriod: Duration
    /// How long to wait for end of file on captured streams after the process
    /// exits. A background descendant that inherited a pipe can hold it open
    /// long after the process exits, and the run must not wait for it.
    public var drainGracePeriod: Duration
    /// The longest line, in bytes, that a captured stream delivers as one
    /// ``ToolProcessEvent/output(stream:line:)`` event. A longer line arrives
    /// in pieces of at most this many bytes. Raise it for a stream of
    /// structured lines, such as JSON events, that must not be cut.
    public var maxLineBytes: Int
    /// A short name for logs and errors.
    public var label: String

    /// The default ``drainGracePeriod``. Five seconds gives a helper that a
    /// launcher script forked, such as a JVM or a Python worker of medaka or
    /// clair3, room to flush its last lines on a loaded Mac, and still bounds
    /// a daemonized grandchild that never closes the pipe.
    public static let defaultDrainGracePeriod: Duration = .seconds(5)

    /// The default stderr capture keeps the last 4 MB. Diagnostics and the
    /// summaries tools print at the end, such as BBTools statistics, live in
    /// the tail, and a run that logs for hours cannot grow memory without
    /// bound. A caller that parses more sets its own limit.
    public static let defaultStderrCaptureLimit = 4 * 1024 * 1024

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectory: URL? = nil,
        stdin: ToolProcessInput = .null,
        stdout: ToolProcessOutput = .capture(),
        stderr: ToolProcessOutput = .capture(limit: ToolProcessSpec.defaultStderrCaptureLimit),
        timeout: Duration? = nil,
        idleTimeout: Duration? = nil,
        terminationGracePeriod: Duration = .milliseconds(500),
        drainGracePeriod: Duration = ToolProcessSpec.defaultDrainGracePeriod,
        maxLineBytes: Int = ProcessOutputLineFramer.defaultMaxLineBytes,
        label: String? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.terminationGracePeriod = terminationGracePeriod
        self.drainGracePeriod = drainGracePeriod
        self.maxLineBytes = maxLineBytes
        self.label = label ?? executableURL.lastPathComponent
    }

    /// The exact argv of the launch, with the executable path as argv[0].
    public var argv: [String] {
        [executableURL.path] + arguments
    }

    /// The caller's own environment with `overrides` laid over it.
    ///
    /// A run that should not depend on the user's shell builds its
    /// environment by hand instead.
    public static func inheritedEnvironment(
        overriding overrides: [String: String] = [:]
    ) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
    }
}
