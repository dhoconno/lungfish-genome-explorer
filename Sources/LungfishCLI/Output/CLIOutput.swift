// CLIOutput.swift - Output handling for CLI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - CLI Output Protocol

/// Protocol for CLI output handlers
protocol CLIOutputHandler {
    /// Write a message to output
    func write(_ message: String)

    /// Write an error message
    func writeError(_ message: String)

    /// Write structured data
    func writeData<T: Encodable>(_ data: T, label: String?)

    /// Write a progress update
    func writeProgress(_ progress: Double, message: String?)

    /// Finish output (flush buffers, close files)
    func finish()
}

// MARK: - Standard Output Handler

/// Standard output handler for text mode
class StandardOutputHandler: CLIOutputHandler {
    private let useColors: Bool
    private let outputFile: FileHandle?
    private let errorFile: FileHandle

    init(useColors: Bool, outputPath: String? = nil) {
        self.useColors = useColors
        self.errorFile = FileHandle.standardError

        if let path = outputPath {
            FileManager.default.createFile(atPath: path, contents: nil)
            self.outputFile = FileHandle(forWritingAtPath: path)
        } else {
            self.outputFile = nil
        }
    }

    func write(_ message: String) {
        let data = (message + "\n").data(using: .utf8) ?? Data()
        if let file = outputFile {
            file.write(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    func writeError(_ message: String) {
        let formatted = useColors
            ? "\u{001B}[31mError:\u{001B}[0m \(message)\n"
            : "Error: \(message)\n"
        errorFile.write(formatted.data(using: .utf8) ?? Data())
    }

    func writeData<T: Encodable>(_ data: T, label: String?) {
        // For text mode, just describe the data
        if let label = label {
            write("\(label): \(data)")
        } else {
            write("\(data)")
        }
    }

    func writeProgress(_ progress: Double, message: String?) {
        // Progress is written to stderr so it doesn't pollute stdout
        let percent = Int(progress * 100)
        let msg = message ?? ""
        let formatted = "\r[\(percent)%] \(msg)"
        errorFile.write(formatted.data(using: .utf8) ?? Data())
    }

    func finish() {
        outputFile?.closeFile()
    }
}

// MARK: - JSON Output Handler

/// JSON output handler for machine-readable output
class JSONOutputHandler: CLIOutputHandler {
    private var results: [[String: Any]] = []
    private var errors: [String] = []
    private let outputPath: String?
    private let pretty: Bool

    init(outputPath: String? = nil, pretty: Bool = true) {
        self.outputPath = outputPath
        self.pretty = pretty
    }

    func write(_ message: String) {
        // Messages are collected and output at the end
        results.append(["message": message])
    }

    func writeError(_ message: String) {
        errors.append(message)
    }

    func writeData<T: Encodable>(_ data: T, label: String?) {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        do {
            let jsonData = try encoder.encode(data)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                // Write directly to stdout
                print(jsonString)
            }
        } catch {
            writeError("Failed to encode data as JSON: \(error.localizedDescription)")
        }
    }

    func writeProgress(_ progress: Double, message: String?) {
        // Progress is written to stderr in JSON mode too
        let progressData: [String: Any] = [
            "progress": progress,
            "message": message ?? ""
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: progressData),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            FileHandle.standardError.write((jsonString + "\n").data(using: .utf8) ?? Data())
        }
    }

    func finish() {
        // Output is written incrementally, nothing to do here
    }
}

// MARK: - TSV Output Handler

/// Tab-separated values output handler
class TSVOutputHandler: CLIOutputHandler {
    private var headers: [String]?
    private var rows: [[String]] = []
    private let outputPath: String?

    init(outputPath: String? = nil) {
        self.outputPath = outputPath
    }

    func write(_ message: String) {
        // For TSV, messages become single-column rows
        rows.append([message])
    }

    func writeError(_ message: String) {
        FileHandle.standardError.write(("Error: \(message)\n").data(using: .utf8) ?? Data())
    }

    func writeData<T: Encodable>(_ data: T, label: String?) {
        // TSV output needs to be handled specially by each command
        write(String(describing: data))
    }

    func writeProgress(_ progress: Double, message: String?) {
        // Progress to stderr
        let percent = Int(progress * 100)
        let msg = message ?? ""
        FileHandle.standardError.write(("\r[\(percent)%] \(msg)").data(using: .utf8) ?? Data())
    }

    /// Set column headers for TSV output
    func setHeaders(_ headers: [String]) {
        self.headers = headers
        // Write headers immediately
        let headerLine = headers.joined(separator: "\t") + "\n"
        print(headerLine, terminator: "")
    }

    /// Add a row of data
    func addRow(_ values: [String]) {
        rows.append(values)
        let rowLine = values.joined(separator: "\t") + "\n"
        print(rowLine, terminator: "")
    }

    func finish() {
        // Rows are written incrementally
    }
}

// MARK: - Output Factory

/// Factory for creating output handlers based on options
struct CLIOutputFactory {
    static func createHandler(for options: GlobalOptions) -> CLIOutputHandler {
        switch options.outputMode {
        case .json:
            return JSONOutputHandler(outputPath: options.output, pretty: true)
        case .tsv:
            return TSVOutputHandler(outputPath: options.output)
        case .text, .debug:
            return StandardOutputHandler(useColors: options.useColors, outputPath: options.output)
        }
    }
}

// MARK: - JSON Result Wrapper

/// Standard JSON output structure for CLI results
struct CLIJSONResult<T: Encodable>: Encodable {
    let success: Bool
    let command: String
    let data: T?
    let error: CLIJSONError?
    let metadata: CLIJSONMetadata

    init(success: Bool, command: String, data: T?, error: CLIJSONError? = nil) {
        self.success = success
        self.command = command
        self.data = data
        self.error = error
        self.metadata = CLIJSONMetadata()
    }
}

/// Error information for JSON output
struct CLIJSONError: Encodable {
    let code: String
    let message: String
    let details: String?

    init(code: CLIExitCode, message: String, details: String? = nil) {
        self.code = String(code.rawValue)
        self.message = message
        self.details = details
    }
}

/// Metadata for JSON output
struct CLIJSONMetadata: Encodable {
    let version: String
    let timestamp: String
    let platform: String

    init() {
        self.version = "1.0.0"
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
