// AssemblyConfigurationViewModel.swift - Assembly execution runner for SPAdes
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import os.log
import UserNotifications
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Logger for assembly runner operations.
private let logger = Logger(subsystem: LogSubsystem.app, category: "AssemblyRunner")

// MARK: - AssemblyRunner

/// Runs a SPAdes assembly as a background operation tracked by ``OperationCenter``.
///
/// The runner registers the assembly with ``OperationCenter`` so that
/// progress is visible in the Operations Panel and the task survives
/// sheet dismissal. Completed bundles are delivered via
/// ``OperationCenter/onBundleReady``.
///
/// ## Usage
///
/// ```swift
/// AssemblyRunner.run(config: config)
/// ```
///
/// The method returns immediately. Assembly progress and completion are
/// reported through ``OperationCenter``.
@MainActor
public enum AssemblyRunner {

    /// Launches a SPAdes assembly in the background.
    ///
    /// Registers the operation with ``OperationCenter``, then runs the
    /// pipeline in a detached task so the calling sheet can safely dismiss.
    ///
    /// - Parameter config: The fully configured ``SPAdesAssemblyConfig``.
    public static func run(config: SPAdesAssemblyConfig) {
        let projectName = config.projectName

        // Request notification permission (idempotent)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { logger.warning("Notification authorization error: \(error)") }
        }

        // Check disk space
        let diskCheck = checkDiskSpace(inputFiles: config.allInputFiles, outputDirectory: config.outputDirectory)
        if !diskCheck.sufficient {
            let requiredStr = ByteCountFormatter.string(fromByteCount: diskCheck.requiredBytes, countStyle: .file)
            let availableStr = ByteCountFormatter.string(fromByteCount: diskCheck.availableBytes, countStyle: .file)
            showDiskSpaceAlert(required: requiredStr, available: availableStr)
            return
        }

        logger.info("Starting SPAdes assembly: mode=\(config.mode.displayName, privacy: .public), project=\(projectName, privacy: .public)")

        let task = Task.detached {
            await runAssemblyOperation(config: config, projectName: projectName)
        }

        let cliCmd: String = {
            var args: [String] = []
            for r in config.forwardReads { args += ["--pe1-1", r.path] }
            for r in config.reverseReads { args += ["--pe1-2", r.path] }
            for r in config.unpairedReads { args += ["-s", r.path] }
            args += ["-o", config.outputDirectory.path]
            return "# " + OperationCenter.buildCLICommand(subcommand: "assemble", args: args)
                + " (CLI command not yet available)"
        }()

        _ = OperationCenter.shared.start(
            title: "SPAdes Assembly: \(projectName)",
            detail: "Initializing...",
            operationType: .assembly,
            cliCommand: cliCmd,
            onCancel: { task.cancel() }
        )
    }

    // MARK: - Pipeline Execution

    /// Runs the assembly pipeline and reports progress to ``OperationCenter``.
    ///
    /// This is a static method that captures no mutable external state so
    /// the calling sheet can safely dismiss while the assembly continues.
    private static func runAssemblyOperation(
        config: SPAdesAssemblyConfig,
        projectName: String
    ) async {
        let operationID: UUID? = await MainActor.run {
            OperationCenter.shared.items.first(where: {
                $0.title == "SPAdes Assembly: \(projectName)" && $0.state == .running
            })?.id
        }

        guard let opID = operationID else {
            logger.error("Assembly operation not found in OperationCenter")
            return
        }

        do {
            let runtime = try await AppleContainerRuntime()

            await MainActor.run {
                OperationCenter.shared.update(id: opID, progress: 0.02, detail: "Container runtime initialized")
                OperationCenter.shared.log(id: opID, level: .info, message: "Container runtime initialized")
            }

            let pipeline = SPAdesAssemblyPipeline()
            let result = try await pipeline.run(
                config: config,
                runtime: runtime
            ) { fraction, message in
                let scaledProgress = 0.02 + fraction * 0.93
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: scaledProgress, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            let stats = result.statistics
            logger.info("Assembly stats: contigs=\(stats.contigCount), N50=\(stats.n50), total=\(stats.totalLengthBP)bp")

            // Save config for potential reassembly
            let spadesOutputDir = config.outputDirectory.appendingPathComponent(projectName)
            try? SPAdesAssemblyPipeline.saveConfig(config, to: spadesOutputDir)

            // Clean intermediate files
            await MainActor.run {
                OperationCenter.shared.update(id: opID, progress: 0.94, detail: "Cleaning intermediate files...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Cleaning intermediate files")
            }
            let freed = try? SPAdesAssemblyPipeline.cleanIntermediates(in: spadesOutputDir)
            if let freed {
                let freedStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                logger.info("Freed \(freedStr) of intermediate files")
            }

            await MainActor.run {
                OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Creating reference bundle...")
                OperationCenter.shared.log(id: opID, level: .info, message: "Creating reference bundle")
            }

            let inputRecords = config.allInputFiles.map { url in
                ProvenanceBuilder.inputRecord(for: url)
            }
            let provenance = ProvenanceBuilder.build(
                config: config,
                result: result,
                inputRecords: inputRecords
            )

            let bundleBuilder = AssemblyBundleBuilder()
            let bundleURL = try await bundleBuilder.build(
                result: result,
                config: config,
                provenance: provenance,
                outputDirectory: config.outputDirectory,
                bundleName: projectName
            ) { fraction, message in
                let overallFraction = 0.95 + fraction * 0.05
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.update(id: opID, progress: overallFraction, detail: message)
                        OperationCenter.shared.log(id: opID, level: .info, message: message)
                    }
                }
            }

            await MainActor.run {
                OperationCenter.shared.complete(id: opID, detail: "Assembly complete", bundleURLs: [bundleURL])
            }

            postNotification(
                title: "Assembly Complete",
                body: "Project \"\(projectName)\" assembled successfully.",
                isSuccess: true
            )

        } catch is CancellationError {
            await MainActor.run {
                OperationCenter.shared.fail(id: opID, detail: "Cancelled by user")
            }
        } catch {
            let errorMessage = "\(error)"
            logger.error("Assembly failed: \(error)")
            await MainActor.run {
                OperationCenter.shared.fail(id: opID, detail: errorMessage)
            }

            postNotification(
                title: "Assembly Failed",
                body: "Project \"\(projectName)\" failed: \(errorMessage)",
                isSuccess: false
            )
        }
    }

    // MARK: - Disk Space Check

    /// Checks whether the output directory has sufficient disk space for assembly.
    ///
    /// SPAdes typically needs at least 2x input file size plus 1 GB overhead.
    private static func checkDiskSpace(
        inputFiles: [URL],
        outputDirectory: URL
    ) -> (sufficient: Bool, requiredBytes: Int64, availableBytes: Int64) {
        let totalInputBytes: Int64 = inputFiles.reduce(0) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        let requiredBytes: Int64 = totalInputBytes * 2 + 1_073_741_824

        do {
            let resourceValues = try outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let availableBytes = Int64(resourceValues.volumeAvailableCapacityForImportantUsage ?? 0)
            return (availableBytes >= requiredBytes, requiredBytes, availableBytes)
        } catch {
            logger.warning("Failed to check disk space: \(error)")
            return (true, requiredBytes, 0)
        }
    }

    // MARK: - Alerts

    /// Presents a disk space warning as a sheet modal.
    private static func showDiskSpaceAlert(required: String, available: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insufficient Disk Space"
        alert.informativeText = """
            The output directory does not have enough free space for this assembly.

            Required: \(required)
            Available: \(available)

            SPAdes needs at least 2x the total input file size plus 1 GB of overhead. \
            Please free up disk space or choose a different output directory.
            """
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        }
        logger.warning("Assembly blocked: insufficient disk space (required=\(required), available=\(available))")
    }

    // MARK: - Notifications

    /// Posts a macOS notification for assembly completion or failure.
    private static func postNotification(title: String, body: String, isSuccess: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isSuccess ? .default : UNNotificationSound.defaultCritical

        let request = UNNotificationRequest(
            identifier: "assembly-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.warning("Failed to post notification: \(error)") }
        }
    }
}
