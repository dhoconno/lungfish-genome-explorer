// DemoProjectsViewModel.swift - State and actions for Help > Demo Projects…
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import Observation
import os

// MARK: - Operation reporting

/// The slice of ``OperationCenter`` the demo download uses, so tests can observe it.
@MainActor
protocol DemoProjectOperationReporting: AnyObject {
    func begin(title: String, detail: String, cliCommand: String) -> UUID?
    func setCancelHandler(id: UUID, handler: @escaping @Sendable () -> Void)
    func report(id: UUID, phase: DemoProjectInstallPhase)
    func complete(id: UUID, projectURL: URL)
    func fail(id: UUID, message: String)
    func acknowledgeCancellation(id: UUID)
}

/// Routes demo downloads through the Operations panel.
@MainActor
final class OperationCenterDemoProjectReporter: DemoProjectOperationReporting {
    private let center: OperationCenter

    init(center: OperationCenter = .shared) {
        self.center = center
    }

    func begin(title: String, detail: String, cliCommand: String) -> UUID? {
        center.begin(title: title, detail: detail, operationType: .download, cliCommand: cliCommand).startedID
    }

    func setCancelHandler(id: UUID, handler: @escaping @Sendable () -> Void) {
        center.setCancelCallback(for: id, callback: handler)
    }

    func report(id: UUID, phase: DemoProjectInstallPhase) {
        switch phase {
        case .downloading(let received, let total):
            center.updateBytes(id: id, bytesDownloaded: received, totalBytes: total)
            let fraction = total.map { $0 > 0 ? Double(received) / Double($0) : 0 } ?? 0
            center.update(id: id, progress: fraction * 0.9, detail: DemoProjectsViewModel.detailText(for: phase))
        case .verifying, .extracting, .installing:
            let progress: Double = phase == .verifying ? 0.9 : (phase == .extracting ? 0.93 : 0.98)
            center.updateWithLog(id: id, progress: progress, detail: DemoProjectsViewModel.detailText(for: phase))
        }
    }

    func complete(id: UUID, projectURL: URL) {
        center.log(id: id, level: .info, message: "Installed at \(projectURL.path)")
        center.complete(id: id, detail: "Installed at \(projectURL.path)", outputURLs: [projectURL])
    }

    func fail(id: UUID, message: String) {
        center.log(id: id, level: .error, message: message)
        center.fail(id: id, detail: message, errorMessage: message)
    }

    func acknowledgeCancellation(id: UUID) {
        center.acknowledgeCancellation(id: id)
    }
}

// MARK: - Environment

/// Everything the view model does outside itself, injected so tests stay off the network,
/// the real Documents folder and the real app windows.
@MainActor
struct DemoProjectsEnvironment {
    var loadManifest: () throws -> DemoProjectManifest
    var installer: DemoProjectInstaller
    var locationStore: DemoProjectLocationStore
    var operations: any DemoProjectOperationReporting
    var openProject: (URL) -> Void
    var revealInFinder: (URL) -> Void
    var openURL: (URL) -> Void
    var isProjectOpen: (URL) -> Bool
}

// MARK: - View model

@MainActor
@Observable
final class DemoProjectsViewModel {
    struct DownloadState: Equatable {
        var fraction: Double?
        var detail: String
    }

    struct AlertContent: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var projects: [DemoProject] = []
    private(set) var manifestError: String?
    private(set) var statuses: [String: DemoProjectInstallStatus] = [:]
    private(set) var downloads: [String: DownloadState] = [:]
    private(set) var installDirectory: URL

    var alert: AlertContent?
    /// A project whose folder already exists and whose "Download & Open" needs a decision.
    var existingCopyPrompt: DemoProject?
    /// A project the user asked to replace, awaiting confirmation.
    var replaceConfirmation: DemoProject?

    /// Called when the sheet should close (after a project opens).
    @ObservationIgnored var onDismiss: (() -> Void)?
    /// Called when the user asks to choose another folder.
    @ObservationIgnored var onChooseFolder: (() -> Void)?

    @ObservationIgnored private let environment: DemoProjectsEnvironment

    init(environment: DemoProjectsEnvironment) {
        self.environment = environment
        self.installDirectory = environment.locationStore.directory
        reload()
    }

    // MARK: Loading

    func reload() {
        do {
            projects = try environment.loadManifest().projects
            manifestError = nil
        } catch {
            projects = []
            manifestError = error.localizedDescription
        }
        refreshStatuses()
    }

    func refreshStatuses() {
        var result: [String: DemoProjectInstallStatus] = [:]
        for project in projects {
            result[project.id] = DemoProjectInstaller.status(for: project, in: installDirectory)
        }
        statuses = result
    }

    func status(for project: DemoProject) -> DemoProjectInstallStatus {
        statuses[project.id] ?? .notDownloaded
    }

    // MARK: Folder

    var isUsingDefaultFolder: Bool { environment.locationStore.isUsingDefault }

    func setInstallDirectory(_ url: URL) {
        environment.locationStore.directory = url
        installDirectory = environment.locationStore.directory
        refreshStatuses()
    }

    func resetInstallDirectory() {
        environment.locationStore.resetToDefault()
        installDirectory = environment.locationStore.directory
        refreshStatuses()
    }

    func chooseFolder() {
        onChooseFolder?()
    }

    // MARK: Presentation helpers

    func sizeText(for project: DemoProject) -> String {
        guard !project.archive.isPlaceholder else { return "Not yet published" }
        return ByteCountFormatter.string(fromByteCount: project.archive.bytes, countStyle: .file)
    }

    func statusText(for project: DemoProject) -> String {
        switch status(for: project) {
        case .updateAvailable(_, let available):
            return "Update available (\(available))"
        case let other:
            return other.label
        }
    }

    func primaryButtonTitle(for project: DemoProject) -> String {
        if case .downloaded = status(for: project) { return "Open" }
        return "Download & Open"
    }

    func unsupportedReason(for project: DemoProject) -> String? {
        guard !project.isSupported(byAppVersion: environment.installer.appVersion) else { return nil }
        return "Requires Lungfish Genome Explorer \(project.minimumAppVersion ?? "") or later"
    }

    func isDownloading(_ project: DemoProject) -> Bool {
        downloads[project.id] != nil
    }

    nonisolated static func detailText(for phase: DemoProjectInstallPhase) -> String {
        switch phase {
        case .downloading(let received, let total):
            let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            if let total, total > 0 {
                let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                return "Downloading \(receivedText) of \(totalText)"
            }
            return "Downloading \(receivedText)"
        case .verifying:
            return "Verifying size and SHA-256…"
        case .extracting:
            return "Unpacking…"
        case .installing:
            return "Installing…"
        }
    }

    // MARK: Actions

    /// "Download & Open" or "Open", depending on what is on disk.
    func performPrimaryAction(for project: DemoProject) {
        switch status(for: project) {
        case .downloaded:
            open(project)
        case .updateAvailable:
            existingCopyPrompt = project
        case .notDownloaded:
            if FileManager.default.fileExists(atPath: projectURL(for: project).path) {
                existingCopyPrompt = project
            } else {
                download(project, replaceExisting: false)
            }
        }
    }

    func requestReplace(_ project: DemoProject) {
        replaceConfirmation = project
    }

    func projectURL(for project: DemoProject) -> URL {
        DemoProjectInstaller.projectURL(for: project, in: installDirectory)
    }

    func open(_ project: DemoProject) {
        let url = projectURL(for: project)
        guard FileManager.default.fileExists(atPath: url.path) else {
            refreshStatuses()
            alert = AlertContent(title: "Project Not Found", message: "\(project.title) is no longer in \(installDirectory.path).")
            return
        }
        onDismiss?()
        environment.openProject(url)
    }

    func reveal(_ project: DemoProject) {
        let url = projectURL(for: project)
        if FileManager.default.fileExists(atPath: url.path) {
            environment.revealInFinder(url)
        } else {
            refreshStatuses()
        }
    }

    func openChapter(_ chapter: DemoProject.Chapter) {
        guard let url = chapter.url else { return }
        environment.openURL(url)
    }

    /// Downloads through the Operations panel, then opens the project.
    func download(_ project: DemoProject, replaceExisting: Bool) {
        guard downloads[project.id] == nil else { return }
        do {
            try project.ensurePublished()
            guard project.isSupported(byAppVersion: environment.installer.appVersion) else {
                throw DemoProjectError.requiresNewerApp(title: project.title, minimumVersion: project.minimumAppVersion ?? "")
            }
            let target = projectURL(for: project)
            if replaceExisting, environment.isProjectOpen(target) {
                throw DemoProjectError.projectIsOpen(target)
            }
        } catch {
            alert = AlertContent(title: "Cannot Download \(project.title)", message: error.localizedDescription)
            return
        }

        let directory = installDirectory
        let cliCommand = Self.cliCommand(for: project, directory: directory, replaceExisting: replaceExisting)
        guard let operationID = environment.operations.begin(
            title: "Demo Project: \(project.title)",
            detail: "Starting download…",
            cliCommand: cliCommand
        ) else {
            alert = AlertContent(title: "Cannot Download \(project.title)", message: "The download could not be started.")
            return
        }
        downloads[project.id] = DownloadState(fraction: 0, detail: "Starting download…")

        let installer = environment.installer
        let throttle = DemoProjectProgressThrottle()
        let projectID = project.id
        let worker = Task.detached {
            try await installer.install(project, into: directory, replaceExisting: replaceExisting) { [weak self] phase in
                guard throttle.shouldReport(phase) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(phase, projectID: projectID, operationID: operationID)
                    }
                }
            }
        }
        environment.operations.setCancelHandler(id: operationID) { worker.cancel() }

        // Held strongly so a download finishes (and opens) even after the sheet closes.
        Task { @MainActor in
            let result = await worker.result
            self.finish(project, result: result, operationID: operationID)
        }
    }

    private func apply(_ phase: DemoProjectInstallPhase, projectID: String, operationID: UUID) {
        guard downloads[projectID] != nil else { return }
        let fraction: Double?
        switch phase {
        case .downloading(let received, let total):
            fraction = total.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil }
        default:
            fraction = nil
        }
        downloads[projectID] = DownloadState(fraction: fraction, detail: Self.detailText(for: phase))
        environment.operations.report(id: operationID, phase: phase)
    }

    private func finish(_ project: DemoProject, result: Result<DemoProjectInstallResult, Error>, operationID: UUID) {
        downloads[project.id] = nil
        refreshStatuses()
        switch result {
        case .success(let install):
            environment.operations.complete(id: operationID, projectURL: install.projectURL)
            onDismiss?()
            environment.openProject(install.projectURL)
        case .failure(let error):
            if let demoError = error as? DemoProjectError, demoError == .cancelled {
                environment.operations.acknowledgeCancellation(id: operationID)
                return
            }
            if error is CancellationError {
                environment.operations.acknowledgeCancellation(id: operationID)
                return
            }
            let message = error.localizedDescription
            environment.operations.fail(id: operationID, message: message)
            alert = AlertContent(title: "Could Not Download \(project.title)", message: message)
        }
    }

    static func cliCommand(for project: DemoProject, directory: URL, replaceExisting: Bool) -> String {
        var parts = ["lungfish-cli", "demo", "fetch", project.id, "--dest", shellQuoted(directory.path)]
        if replaceExisting { parts.append("--force") }
        return parts.joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Drops byte-progress callbacks that would not move the visible percentage.
final class DemoProjectProgressThrottle: Sendable {
    private let lastPercent = OSAllocatedUnfairLock<Int>(initialState: -1)

    func shouldReport(_ phase: DemoProjectInstallPhase) -> Bool {
        guard case .downloading(let received, let total) = phase else { return true }
        let percent: Int
        if let total, total > 0 {
            percent = Int(Double(received) / Double(total) * 100)
        } else {
            percent = Int(received / 1_048_576)
        }
        return lastPercent.withLock { last in
            guard percent != last else { return false }
            last = percent
            return true
        }
    }
}
