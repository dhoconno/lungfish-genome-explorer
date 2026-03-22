// WelcomeWindowController.swift - Launch experience and project selection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead - HIG Expert (Role 2)

import AppKit
import SwiftUI
import LungfishCore
import os.log

/// Logger for welcome window
private let logger = Logger(subsystem: LogSubsystem.app, category: "WelcomeWindow")

// MARK: - Recent Projects Manager

/// Manages the list of recently opened projects
@MainActor
public final class RecentProjectsManager: ObservableObject {
    /// Singleton instance
    public static let shared = RecentProjectsManager()

    /// Maximum number of recent projects to track
    private let maxRecentProjects = 10

    /// UserDefaults key for recent projects
    private let recentProjectsKey = "com.lungfish.recentProjects"

    /// Last used project key
    private let lastProjectKey = "com.lungfish.lastProject"

    /// Recent project entries
    @Published public private(set) var recentProjects: [RecentProject] = []

    private init() {
        loadRecentProjects()
    }

    /// Adds a project to the recent list
    public func addRecentProject(url: URL, name: String) {
        logger.info("Adding recent project: \(name, privacy: .public) at \(url.path, privacy: .public)")

        // Remove any existing entry for this URL
        recentProjects.removeAll { $0.url == url }

        // Add to front
        let entry = RecentProject(url: url, name: name, lastOpened: Date())
        recentProjects.insert(entry, at: 0)

        // Trim to max size
        if recentProjects.count > maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(maxRecentProjects))
        }

        saveRecentProjects()
        saveLastProject(url: url)
    }

    /// Removes a project from the recent list
    public func removeRecentProject(at index: Int) {
        guard index >= 0 && index < recentProjects.count else { return }
        recentProjects.remove(at: index)
        saveRecentProjects()
    }

    /// Clears all recent projects
    public func clearRecentProjects() {
        recentProjects = []
        saveRecentProjects()
    }

    /// Gets the last opened project URL
    public var lastProjectURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: lastProjectKey) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        // Verify it still exists
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private

    private func loadRecentProjects() {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else {
            recentProjects = []
            return
        }

        // Filter out projects that no longer exist
        recentProjects = projects.filter { project in
            FileManager.default.fileExists(atPath: project.url.path)
        }
    }

    private func saveRecentProjects() {
        guard let data = try? JSONEncoder().encode(recentProjects) else { return }
        UserDefaults.standard.set(data, forKey: recentProjectsKey)
    }

    private func saveLastProject(url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastProjectKey)
    }
}

/// Represents a recently opened project
public struct RecentProject: Codable, Identifiable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let lastOpened: Date

    /// Checks if the project still exists on disk
    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Formatted last opened date
    public var lastOpenedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastOpened, relativeTo: Date())
    }
}

// MARK: - Welcome View Model

@MainActor
final class WelcomeViewModel: ObservableObject {
    @Published var selectedAction: WelcomeAction?
    @Published var isLoading = false

    let recentProjects = RecentProjectsManager.shared

    var onCreateProject: ((URL) -> Void)?
    var onOpenProject: ((URL) -> Void)?
    var onOpenFiles: (() -> Void)?
    var onDismiss: (() -> Void)?
}

enum WelcomeAction: String, Identifiable {
    case createProject = "Create Project"
    case openProject = "Open Project"
    case openFiles = "Open Files"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .createProject: return "folder.badge.plus"
        case .openProject: return "folder"
        case .openFiles: return "doc.on.doc"
        }
    }

    var description: String {
        switch self {
        case .createProject: return "Create a new project folder to organize your sequences and downloads"
        case .openProject: return "Open an existing Lungfish project"
        case .openFiles: return "Open sequence files without creating a project"
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @ObservedObject var viewModel: WelcomeViewModel
    @State private var hoveredAction: WelcomeAction?

    var body: some View {
        HStack(spacing: 0) {
            // Left panel - branding and actions
            VStack(alignment: .leading, spacing: 0) {
                // App icon and title
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: Self.loadLogo())
                        .resizable()
                        .frame(width: 64, height: 64)

                    Text("Lungfish Genome Explorer")
                        .font(.system(size: 22, weight: .bold))

                    Text("Seeing the invisible. Informing action.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 32)

                // Action buttons
                VStack(alignment: .leading, spacing: 12) {
                    ForEach([WelcomeAction.createProject, .openProject, .openFiles]) { action in
                        ActionButton(
                            action: action,
                            isHovered: hoveredAction == action,
                            onTap: { performAction(action) }
                        )
                        .onHover { isHovered in
                            hoveredAction = isHovered ? action : nil
                        }
                    }
                }

                Spacer()

                // Version info
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(width: 280)
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Right panel - recent projects
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Projects")
                    .font(.headline)
                    .padding(.bottom, 12)

                if viewModel.recentProjects.recentProjects.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("No Recent Projects")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Create or open a project to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.6))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.recentProjects.recentProjects) { project in
                                RecentProjectRow(project: project) {
                                    viewModel.onOpenProject?(project.url)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 300)
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 650, height: 400)
    }

    private static func loadLogo() -> NSImage {
        if let url = Bundle.module.url(forResource: "about-logo", withExtension: "png", subdirectory: "Images"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }

    private func performAction(_ action: WelcomeAction) {
        switch action {
        case .createProject:
            Task { @MainActor in
                await showCreateProjectPanel()
            }
        case .openProject:
            Task { @MainActor in
                await showOpenProjectPanel()
            }
        case .openFiles:
            viewModel.onOpenFiles?()
        }
    }

    private func showCreateProjectPanel() async {
        let savePanel = NSSavePanel()
        savePanel.title = "Create New Project"
        savePanel.message = "Choose a location for your new Lungfish project"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "My Genome Project"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.folder]
        savePanel.isExtensionHidden = false

        guard let window = NSApp.keyWindow else { return }
        let response = await savePanel.beginSheetModal(for: window)
        if response == .OK, let url = savePanel.url {
            // Create the project directory with .lungfish extension
            let projectURL = url.deletingPathExtension().appendingPathExtension("lungfish")
            viewModel.onCreateProject?(projectURL)
        }
    }

    private func showOpenProjectPanel() async {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Project"
        openPanel.message = "Select a Lungfish project folder"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = false

        guard let window = NSApp.keyWindow else { return }
        let response = await openPanel.beginSheetModal(for: window)
        if response == .OK, let url = openPanel.url {
            viewModel.onOpenProject?(url)
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let action: WelcomeAction
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: action.icon)
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text(action.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recent Project Row

struct RecentProjectRow: View {
    let project: RecentProject
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(project.url.path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(project.lastOpenedFormatted)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Welcome Window Controller

@MainActor
public final class WelcomeWindowController: NSWindowController {

    private var viewModel: WelcomeViewModel!

    /// Completion handler called when user makes a selection
    public var onProjectSelected: ((URL) -> Void)?
    public var onOpenFilesSelected: (() -> Void)?

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Lungfish Genome Explorer"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        super.init(window: window)

        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        viewModel = WelcomeViewModel()

        viewModel.onCreateProject = { [weak self] url in
            logger.info("Creating project at: \(url.path, privacy: .public)")
            self?.createProject(at: url)
        }

        viewModel.onOpenProject = { [weak self] url in
            logger.info("Opening project at: \(url.path, privacy: .public)")
            self?.openProject(at: url)
        }

        viewModel.onOpenFiles = { [weak self] in
            logger.info("User chose to open files without project")
            self?.window?.close()
            self?.onOpenFilesSelected?()
        }

        let welcomeView = WelcomeView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: welcomeView)
        window?.contentView = hostingView
    }

    private func createProject(at url: URL) {
        do {
            // Create the project
            let project = try DocumentManager.shared.createProject(
                at: url,
                name: url.deletingPathExtension().lastPathComponent
            )

            // Add to recent projects
            RecentProjectsManager.shared.addRecentProject(
                url: project.url,
                name: project.name
            )

            // Close welcome window and notify
            window?.close()
            onProjectSelected?(project.url)

        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Create Project"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            if let window = self.window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func openProject(at url: URL) {
        do {
            // Open the project
            let project = try DocumentManager.shared.openProject(at: url)

            // Add to recent projects
            RecentProjectsManager.shared.addRecentProject(
                url: project.url,
                name: project.name
            )

            // Close welcome window and notify
            window?.close()
            onProjectSelected?(project.url)

        } catch {
            // If it's not a valid .lungfish project, treat it as a working directory
            let alert = NSAlert()
            alert.messageText = "Open as Working Directory?"
            alert.informativeText = "This folder is not a Lungfish project. Would you like to use it as a working directory for downloads and file operations?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Use as Working Directory")
            alert.addButton(withTitle: "Cancel")

            if let window = self.window {
                Task { @MainActor [weak self] in
                    let response = await alert.beginSheetModal(for: window)
                    if response == .alertFirstButtonReturn {
                        // Set as working directory without creating a full project
                        self?.setWorkingDirectory(url)
                    }
                }
            }
        }
    }

    private func setWorkingDirectory(_ url: URL) {
        // Add to recent projects for easy access
        RecentProjectsManager.shared.addRecentProject(
            url: url,
            name: url.lastPathComponent
        )

        // Close welcome window and notify
        window?.close()
        onProjectSelected?(url)
    }

    /// Shows the welcome window
    public func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
