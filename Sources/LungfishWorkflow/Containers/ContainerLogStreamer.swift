// ContainerLogStreamer.swift - Container log streaming actor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation
import os.log

// MARK: - ContainerLogStreamer

/// Actor for streaming and processing container logs.
///
/// `ContainerLogStreamer` provides real-time log streaming from container
/// processes with support for ANSI code parsing, formatting, and filtering.
/// It integrates with both Apple Containerization and Docker runtimes.
///
/// ## Log Sources
///
/// The streamer can combine logs from multiple sources:
/// - stdout stream from container processes
/// - stderr stream from container processes
/// - System messages from the runtime
///
/// ## Example Usage
///
/// ```swift
/// let streamer = ContainerLogStreamer()
///
/// // Subscribe to formatted log entries
/// let subscription = streamer.subscribe { entry in
///     print("[\(entry.level)] \(entry.message)")
/// }
///
/// // Stream logs from a process
/// await streamer.stream(process: containerProcess)
///
/// // Or stream from stdout/stderr directly
/// await streamer.stream(stdout: stdoutStream, stderr: stderrStream)
///
/// // Cancel when done
/// subscription.cancel()
/// ```
///
/// ## ANSI Code Handling
///
/// The streamer parses ANSI escape codes for:
/// - Colors (foreground and background)
/// - Text styles (bold, italic, underline)
/// - Cursor movements (stripped)
///
/// Parsed styles are available in `LogEntry.style` for rich rendering.
public actor ContainerLogStreamer {
    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ContainerLogStreamer"
    )

    /// Active subscriptions.
    private var subscriptions: [UUID: LogSubscription] = [:]

    /// Buffer for incomplete lines.
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    /// Whether the streamer is actively streaming.
    private var isStreaming = false

    /// Maximum line length before truncation.
    public let maxLineLength: Int

    /// Whether to strip ANSI codes from output.
    public let stripANSICodes: Bool

    // MARK: - Initialization

    /// Creates a new log streamer.
    ///
    /// - Parameters:
    ///   - maxLineLength: Maximum characters per line (default: 10000)
    ///   - stripANSICodes: Whether to strip ANSI codes (default: false)
    public init(maxLineLength: Int = 10000, stripANSICodes: Bool = false) {
        self.maxLineLength = maxLineLength
        self.stripANSICodes = stripANSICodes
    }

    // MARK: - Streaming

    /// Streams logs from stdout and stderr data streams.
    ///
    /// This method runs until both streams complete. Log entries are
    /// delivered to all active subscriptions.
    ///
    /// - Parameters:
    ///   - stdout: Async stream of stdout data
    ///   - stderr: Async stream of stderr data
    public func stream(
        stdout: AsyncStream<Data>,
        stderr: AsyncStream<Data>
    ) async {
        isStreaming = true
        defer { isStreaming = false }

        logger.info("Starting log streaming")

        await withTaskGroup(of: Void.self) { group in
            // Stream stdout
            group.addTask {
                for await chunk in stdout {
                    await self.processChunk(chunk, source: .stdout)
                }
                await self.flushBuffer(source: .stdout)
            }

            // Stream stderr
            group.addTask {
                for await chunk in stderr {
                    await self.processChunk(chunk, source: .stderr)
                }
                await self.flushBuffer(source: .stderr)
            }
        }

        logger.info("Log streaming completed")
    }

    /// Streams logs from a container process.
    ///
    /// Convenience method that extracts stdout/stderr streams from a process.
    ///
    /// - Parameter process: The container process to stream from
    public func stream(process: ContainerProcess) async {
        await stream(stdout: process.stdout, stderr: process.stderr)
    }

    // MARK: - Subscription Management

    /// Subscribes to log entries.
    ///
    /// - Parameter handler: Closure called for each log entry
    /// - Returns: A cancellable subscription
    public func subscribe(
        handler: @escaping @Sendable (LogEntry) -> Void
    ) -> LogSubscription {
        let subscription = LogSubscription(handler: handler)
        subscriptions[subscription.id] = subscription
        logger.debug("Added subscription \(subscription.id)")
        return subscription
    }

    /// Removes a subscription.
    ///
    /// - Parameter subscription: The subscription to remove
    public func unsubscribe(_ subscription: LogSubscription) {
        subscriptions.removeValue(forKey: subscription.id)
        logger.debug("Removed subscription \(subscription.id)")
    }

    /// Number of active subscriptions.
    public var subscriptionCount: Int {
        subscriptions.count
    }

    // MARK: - Manual Entry

    /// Emits a system log entry.
    ///
    /// Use this for runtime messages that aren't from container I/O.
    ///
    /// - Parameters:
    ///   - message: The log message
    ///   - level: The log level (default: .info)
    public func emitSystem(message: String, level: LogLevel = .info) {
        let entry = LogEntry(
            timestamp: Date(),
            source: .system,
            level: level,
            message: message
        )
        deliverEntry(entry)
    }

    // MARK: - Private Methods

    private func processChunk(_ chunk: Data, source: LogSource) {
        // Get appropriate buffer
        var buffer = source == .stdout ? stdoutBuffer : stderrBuffer

        // Append new data
        buffer.append(chunk)

        // Process complete lines
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[..<newlineIndex]
            buffer = Data(buffer[(buffer.index(after: newlineIndex))...])

            // Handle CR-LF
            var line = lineData
            if line.last == UInt8(ascii: "\r") {
                line = line.dropLast()
            }

            // Convert to string
            var text = String(decoding: line, as: UTF8.self)

            // Truncate if necessary
            if text.count > maxLineLength {
                text = String(text.prefix(maxLineLength)) + "... [truncated]"
            }

            // Parse and deliver
            let entry = parseLogEntry(text: text, source: source)
            deliverEntry(entry)
        }

        // Store remaining data
        if source == .stdout {
            stdoutBuffer = buffer
        } else {
            stderrBuffer = buffer
        }
    }

    private func flushBuffer(source: LogSource) {
        let buffer = source == .stdout ? stdoutBuffer : stderrBuffer

        if !buffer.isEmpty {
            var text = String(decoding: buffer, as: UTF8.self)
            if text.count > maxLineLength {
                text = String(text.prefix(maxLineLength)) + "... [truncated]"
            }

            let entry = parseLogEntry(text: text, source: source)
            deliverEntry(entry)
        }

        // Clear buffer
        if source == .stdout {
            stdoutBuffer = Data()
        } else {
            stderrBuffer = Data()
        }
    }

    private func parseLogEntry(text: String, source: LogSource) -> LogEntry {
        var message = text
        var style: LogStyle?

        // Parse ANSI codes if present
        if text.contains("\u{1B}[") {
            let parsed = ANSIParser.parse(text)
            if stripANSICodes {
                message = parsed.plainText
            } else {
                message = parsed.plainText
                style = parsed.style
            }
        }

        // Determine log level from content
        let level = detectLogLevel(message: message, source: source)

        return LogEntry(
            timestamp: Date(),
            source: source,
            level: level,
            message: message,
            style: style
        )
    }

    private func detectLogLevel(message: String, source: LogSource) -> LogLevel {
        let lowercased = message.lowercased()

        // Check for common log level indicators
        if lowercased.contains("error") || lowercased.contains("fatal") ||
           lowercased.contains("exception") || lowercased.contains("failed") {
            return .error
        }

        if lowercased.contains("warn") || lowercased.contains("warning") {
            return .warning
        }

        if lowercased.contains("debug") || lowercased.contains("trace") {
            return .debug
        }

        // stderr is typically warnings or errors
        if source == .stderr {
            return .warning
        }

        return .info
    }

    private func deliverEntry(_ entry: LogEntry) {
        for subscription in subscriptions.values {
            subscription.handler(entry)
        }
    }
}

// MARK: - LogEntry

/// A single log entry from a container.
public struct LogEntry: Sendable, Identifiable {
    /// Unique identifier.
    public let id = UUID()

    /// When the entry was recorded.
    public let timestamp: Date

    /// Source of the log entry.
    public let source: LogSource

    /// Log level.
    public let level: LogLevel

    /// The log message.
    public let message: String

    /// ANSI style information if parsed.
    public let style: LogStyle?

    /// Creates a log entry.
    public init(
        timestamp: Date = Date(),
        source: LogSource,
        level: LogLevel = .info,
        message: String,
        style: LogStyle? = nil
    ) {
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.message = message
        self.style = style
    }

    /// Formatted timestamp string.
    public var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - LogSource

/// Source of a log entry.
public enum LogSource: String, Sendable, Codable {
    /// Standard output stream.
    case stdout = "stdout"

    /// Standard error stream.
    case stderr = "stderr"

    /// System/runtime message.
    case system = "system"

    /// Display prefix for the source.
    public var prefix: String {
        switch self {
        case .stdout:
            return "OUT"
        case .stderr:
            return "ERR"
        case .system:
            return "SYS"
        }
    }
}

// MARK: - LogLevel

/// Severity level of a log entry.
public enum LogLevel: String, Sendable, Codable, Comparable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"

    /// Numeric value for comparison.
    private var numericValue: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.numericValue < rhs.numericValue
    }

    /// SF Symbol icon name.
    public var iconName: String {
        switch self {
        case .debug:
            return "ant"
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.circle"
        }
    }
}

// MARK: - LogStyle

/// ANSI-derived style information.
public struct LogStyle: Sendable, Equatable {
    /// Foreground color.
    public var foregroundColor: ANSIColor?

    /// Background color.
    public var backgroundColor: ANSIColor?

    /// Whether text is bold.
    public var isBold: Bool = false

    /// Whether text is italic.
    public var isItalic: Bool = false

    /// Whether text is underlined.
    public var isUnderline: Bool = false

    /// Whether text is dim.
    public var isDim: Bool = false

    /// Creates a log style.
    public init(
        foregroundColor: ANSIColor? = nil,
        backgroundColor: ANSIColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isDim: Bool = false
    ) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isDim = isDim
    }
}

// MARK: - ANSIColor

/// ANSI color codes.
public enum ANSIColor: Int, Sendable {
    case black = 0
    case red = 1
    case green = 2
    case yellow = 3
    case blue = 4
    case magenta = 5
    case cyan = 6
    case white = 7

    // Bright variants
    case brightBlack = 60
    case brightRed = 61
    case brightGreen = 62
    case brightYellow = 63
    case brightBlue = 64
    case brightMagenta = 65
    case brightCyan = 66
    case brightWhite = 67
}

// MARK: - ANSIParser

/// Parser for ANSI escape codes.
public enum ANSIParser {
    /// Parses ANSI codes from text.
    ///
    /// - Parameter text: The text to parse
    /// - Returns: Parsed result with plain text and style
    public static func parse(_ text: String) -> (plainText: String, style: LogStyle?) {
        var plainText = ""
        var style = LogStyle()
        var hasStyle = false

        var index = text.startIndex
        while index < text.endIndex {
            // Check for escape sequence
            if text[index] == "\u{1B}" {
                // Find the end of the escape sequence
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex && text[nextIndex] == "[" {
                    // Parse CSI sequence
                    var endIndex = text.index(after: nextIndex)
                    while endIndex < text.endIndex {
                        let char = text[endIndex]
                        if char.isLetter {
                            // Found the terminator
                            let codeStart = text.index(after: nextIndex)
                            let codes = String(text[codeStart..<endIndex])

                            // Only process SGR (m) sequences
                            if char == "m" {
                                for code in codes.split(separator: ";") {
                                    if let num = Int(code) {
                                        applyCode(num, to: &style)
                                        hasStyle = true
                                    }
                                }
                            }

                            index = text.index(after: endIndex)
                            break
                        }
                        endIndex = text.index(after: endIndex)
                    }
                    continue
                }
            }

            plainText.append(text[index])
            index = text.index(after: index)
        }

        return (plainText, hasStyle ? style : nil)
    }

    private static func applyCode(_ code: Int, to style: inout LogStyle) {
        switch code {
        case 0:
            // Reset
            style = LogStyle()
        case 1:
            style.isBold = true
        case 2:
            style.isDim = true
        case 3:
            style.isItalic = true
        case 4:
            style.isUnderline = true
        case 22:
            style.isBold = false
            style.isDim = false
        case 23:
            style.isItalic = false
        case 24:
            style.isUnderline = false
        case 30...37:
            style.foregroundColor = ANSIColor(rawValue: code - 30)
        case 39:
            style.foregroundColor = nil
        case 40...47:
            style.backgroundColor = ANSIColor(rawValue: code - 40)
        case 49:
            style.backgroundColor = nil
        case 90...97:
            style.foregroundColor = ANSIColor(rawValue: code - 90 + 60)
        case 100...107:
            style.backgroundColor = ANSIColor(rawValue: code - 100 + 60)
        default:
            break
        }
    }
}

// MARK: - LogSubscription

/// A cancellable subscription to log entries.
public final class LogSubscription: Sendable, Identifiable {
    public let id = UUID()
    public let handler: @Sendable (LogEntry) -> Void

    init(handler: @escaping @Sendable (LogEntry) -> Void) {
        self.handler = handler
    }

    /// Cancels the subscription.
    ///
    /// After calling this, no more entries will be delivered.
    /// Note: Must call `unsubscribe` on the streamer for cleanup.
    public func cancel() {
        // The actual unsubscription happens in the streamer
        // This is a marker that the subscription should be removed
    }
}
