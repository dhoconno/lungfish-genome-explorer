// TerminalFormatter.swift - Terminal formatting utilities
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ANSI Colors

/// ANSI color codes for terminal output
enum ANSIColor: String {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"
    case italic = "\u{001B}[3m"
    case underline = "\u{001B}[4m"

    case black = "\u{001B}[30m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"

    case brightBlack = "\u{001B}[90m"
    case brightRed = "\u{001B}[91m"
    case brightGreen = "\u{001B}[92m"
    case brightYellow = "\u{001B}[93m"
    case brightBlue = "\u{001B}[94m"
    case brightMagenta = "\u{001B}[95m"
    case brightCyan = "\u{001B}[96m"
    case brightWhite = "\u{001B}[97m"

    case bgBlack = "\u{001B}[40m"
    case bgRed = "\u{001B}[41m"
    case bgGreen = "\u{001B}[42m"
    case bgYellow = "\u{001B}[43m"
    case bgBlue = "\u{001B}[44m"
    case bgMagenta = "\u{001B}[45m"
    case bgCyan = "\u{001B}[46m"
    case bgWhite = "\u{001B}[47m"
}

// MARK: - Terminal Formatter

/// Utilities for formatting terminal output
struct TerminalFormatter {
    let useColors: Bool

    init(useColors: Bool) {
        self.useColors = useColors
    }

    // MARK: - Text Styling

    /// Apply color to text
    func colored(_ text: String, _ color: ANSIColor) -> String {
        guard useColors else { return text }
        return "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)"
    }

    /// Apply bold styling
    func bold(_ text: String) -> String {
        guard useColors else { return text }
        return "\(ANSIColor.bold.rawValue)\(text)\(ANSIColor.reset.rawValue)"
    }

    /// Apply dim styling
    func dim(_ text: String) -> String {
        guard useColors else { return text }
        return "\(ANSIColor.dim.rawValue)\(text)\(ANSIColor.reset.rawValue)"
    }

    // MARK: - Semantic Styling

    /// Format success message
    func success(_ text: String) -> String {
        colored("✓ \(text)", .green)
    }

    /// Format error message
    func error(_ text: String) -> String {
        colored("✗ \(text)", .red)
    }

    /// Format warning message
    func warning(_ text: String) -> String {
        colored("⚠ \(text)", .yellow)
    }

    /// Format info message
    func info(_ text: String) -> String {
        colored("ℹ \(text)", .cyan)
    }

    /// Format a header/title
    func header(_ text: String) -> String {
        bold(text)
    }

    /// Format a label
    func label(_ text: String) -> String {
        colored(text, .brightBlack)
    }

    /// Format a value
    func value(_ text: String) -> String {
        colored(text, .brightWhite)
    }

    /// Format a file path
    func path(_ text: String) -> String {
        colored(text, .cyan)
    }

    /// Format a number
    func number(_ value: Any) -> String {
        colored(String(describing: value), .yellow)
    }

    // MARK: - Progress Bar

    /// Create a progress bar string
    func progressBar(progress: Double, width: Int = 40, showPercent: Bool = true) -> String {
        let percent = min(max(progress, 0), 1)
        let filled = Int(percent * Double(width))
        let empty = width - filled

        let filledBar = String(repeating: "█", count: filled)
        let emptyBar = String(repeating: "░", count: empty)

        var bar = "[\(filledBar)\(emptyBar)]"

        if useColors {
            let color: ANSIColor = percent < 0.5 ? .yellow : .green
            bar = "[\(colored(filledBar, color))\(dim(emptyBar))]"
        }

        if showPercent {
            bar += " \(Int(percent * 100))%"
        }

        return bar
    }

    /// Create a spinner frame
    func spinner(frame: Int) -> String {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        let char = frames[frame % frames.count]
        return useColors ? colored(char, .cyan) : char
    }

    // MARK: - Tables

    /// Format a simple key-value table
    func keyValueTable(_ items: [(String, String)], keyWidth: Int? = nil) -> String {
        let maxKeyWidth = keyWidth ?? items.map { $0.0.count }.max() ?? 0

        return items.map { key, value in
            let paddedKey = key.padding(toLength: maxKeyWidth, withPad: " ", startingAt: 0)
            return "\(label(paddedKey)): \(value)"
        }.joined(separator: "\n")
    }

    /// Format a data table with headers
    func table(headers: [String], rows: [[String]], columnWidths: [Int]? = nil) -> String {
        // Calculate column widths
        let widths: [Int]
        if let provided = columnWidths {
            widths = provided
        } else {
            var calculated = headers.map { $0.count }
            for row in rows {
                for (i, cell) in row.enumerated() where i < calculated.count {
                    calculated[i] = max(calculated[i], cell.count)
                }
            }
            widths = calculated
        }

        // Format header
        let headerLine = zip(headers, widths).map { header, width in
            header.padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined(separator: "  ")

        let separator = widths.map { String(repeating: "─", count: $0) }.joined(separator: "──")

        // Format rows
        let formattedRows = rows.map { row in
            zip(row, widths).map { cell, width in
                cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }

        var lines = [bold(headerLine), separator]
        lines.append(contentsOf: formattedRows)

        return lines.joined(separator: "\n")
    }

    // MARK: - Boxes

    /// Create a boxed message
    func box(_ title: String, _ content: String) -> String {
        let lines = content.split(separator: "\n")
        let maxWidth = max(title.count, lines.map { $0.count }.max() ?? 0)
        let width = maxWidth + 4

        let top = "┌" + String(repeating: "─", count: width - 2) + "┐"
        let titleLine = "│ " + bold(title.padding(toLength: width - 4, withPad: " ", startingAt: 0)) + " │"
        let divider = "├" + String(repeating: "─", count: width - 2) + "┤"
        let contentLines = lines.map { line in
            "│ " + String(line).padding(toLength: width - 4, withPad: " ", startingAt: 0) + " │"
        }
        let bottom = "└" + String(repeating: "─", count: width - 2) + "┘"

        return ([top, titleLine, divider] + contentLines + [bottom]).joined(separator: "\n")
    }

    // MARK: - Utilities

    /// Strip ANSI codes from a string
    static func stripANSI(_ text: String) -> String {
        let pattern = "\u{001B}\\[[0-9;]*m"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Get terminal width
    static var terminalWidth: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 {
            return Int(size.ws_col)
        }
        return 80 // Default
    }
}

// MARK: - Progress Reporter

/// Real-time progress reporter for long-running operations
class ProgressReporter {
    private let formatter: TerminalFormatter
    private let showProgress: Bool
    private var lastUpdateTime: Date = Date.distantPast
    private let updateInterval: TimeInterval = 0.1 // 100ms minimum between updates

    init(formatter: TerminalFormatter, showProgress: Bool) {
        self.formatter = formatter
        self.showProgress = showProgress
    }

    /// Update progress display
    func update(progress: Double, message: String? = nil) {
        guard showProgress else { return }

        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }
        lastUpdateTime = now

        let bar = formatter.progressBar(progress: progress)
        let msg = message ?? ""

        // Clear line and write progress
        let output = "\r\u{001B}[K\(bar) \(msg)"
        FileHandle.standardError.write(output.data(using: .utf8) ?? Data())
    }

    /// Clear the progress line
    func clear() {
        guard showProgress else { return }
        FileHandle.standardError.write("\r\u{001B}[K".data(using: .utf8) ?? Data())
    }

    /// Finish with a final message
    func finish(success: Bool, message: String) {
        clear()
        let formatted = success
            ? formatter.success(message)
            : formatter.error(message)
        FileHandle.standardError.write((formatted + "\n").data(using: .utf8) ?? Data())
    }
}
