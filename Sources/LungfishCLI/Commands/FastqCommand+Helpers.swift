// FastqCommand+Helpers.swift - The input and environment helpers the fastq subcommands share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Builds the environment variables needed for BBTools shell scripts.
func bbToolsEnvironment(runner: NativeToolRunner) async -> [String: String] {
    var env: [String: String] = [:]
    if let toolsDir = await runner.getToolsDirectory() {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
        env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
        let javaURL = jreBinDir.appendingPathComponent("java")
        let javaHome = toolsDir.appendingPathComponent("jre")
        if FileManager.default.fileExists(atPath: javaURL.path) {
            env["JAVA_HOME"] = javaHome.path
            env["BBMAP_JAVA"] = javaURL.path
        }
    }
    return env
}

/// Parses a `--mode` token (`cut-right`, `cut-front`, `cut-tail`, `cut-both`).
func parseQualityTrimMode(_ token: String) throws -> FASTQQualityTrimMode {
    guard let mode = FASTQQualityTrimMode(cliToken: token) else {
        throw ValidationError("Invalid trim mode: \(token). Use: \(FASTQQualityTrimMode.cliTokens.joined(separator: ", "))")
    }
    return mode
}

func validateInput(_ path: String) throws -> URL {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CLIError.inputFileNotFound(path: path)
    }
    return URL(fileURLWithPath: path)
}
