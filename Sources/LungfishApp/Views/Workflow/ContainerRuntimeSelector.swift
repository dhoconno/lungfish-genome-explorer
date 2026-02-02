// ContainerRuntimeSelector.swift - Container runtime preference selector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import os.log

/// Logger for container runtime selector operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "ContainerRuntimeSelector")

// MARK: - ContainerRuntime

/// Available container runtime options.
public enum ContainerRuntime: String, CaseIterable, Sendable {
    /// Automatically detect and use the best available runtime
    case automatic = "Automatic"

    /// Apple's native containerization (macOS 15+)
    case appleContainerization = "Apple Containerization"

    /// Docker Desktop or Docker CLI
    case docker = "Docker"

    /// Podman container runtime
    case podman = "Podman"

    /// No container runtime (local execution)
    case none = "None (Local)"

    /// Human-readable display name
    public var displayName: String {
        return rawValue
    }

    /// Description explaining this runtime option
    public var description: String {
        switch self {
        case .automatic:
            return "Automatically detect and use the best available container runtime"
        case .appleContainerization:
            return "Use Apple's native container support (requires macOS 15+)"
        case .docker:
            return "Use Docker for running containerized workflows"
        case .podman:
            return "Use Podman as an alternative to Docker"
        case .none:
            return "Run workflows locally without containers (requires local tool installation)"
        }
    }

    /// SF Symbol name for this runtime
    public var iconName: String {
        switch self {
        case .automatic:
            return "wand.and.stars"
        case .appleContainerization:
            return "apple.logo"
        case .docker:
            return "shippingbox"
        case .podman:
            return "cube"
        case .none:
            return "terminal"
        }
    }
}

// MARK: - ContainerRuntimeStatus

/// Status of a container runtime.
public enum ContainerRuntimeStatus: Sendable {
    /// Runtime is available and working
    case available(version: String?)

    /// Runtime is not installed
    case notInstalled

    /// Runtime is installed but not running
    case notRunning

    /// Runtime status is unknown or being checked
    case checking

    /// Error checking runtime status
    case error(String)

    /// Human-readable status text
    public var statusText: String {
        switch self {
        case .available(let version):
            if let version = version {
                return "Available (v\(version))"
            }
            return "Available"
        case .notInstalled:
            return "Not installed"
        case .notRunning:
            return "Not running"
        case .checking:
            return "Checking..."
        case .error(let message):
            return "Error: \(message)"
        }
    }

    /// Whether this status indicates the runtime is usable
    public var isUsable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    /// Color for status indicator
    public var indicatorColor: NSColor {
        switch self {
        case .available:
            return .systemGreen
        case .notInstalled, .notRunning:
            return .systemOrange
        case .checking:
            return .systemGray
        case .error:
            return .systemRed
        }
    }
}

// MARK: - ContainerRuntimeSelector

/// A view for selecting container runtime preferences.
///
/// `ContainerRuntimeSelector` provides:
/// - A popup button with available runtime options
/// - Status label showing the active runtime
/// - Refresh button to re-detect runtimes
/// - Color-coded status indicators
/// - Tooltips explaining each option
///
/// ## Example
///
/// ```swift
/// let selector = ContainerRuntimeSelector()
/// selector.runtimeSelectionHandler = { runtime in
///     print("Selected runtime: \(runtime)")
/// }
/// view.addSubview(selector)
///
/// // Get the current selection
/// let selected = selector.selectedRuntime
/// ```
@MainActor
public class ContainerRuntimeSelector: NSView {

    // MARK: - Constants

    private static let baseSpacing: CGFloat = 8

    // MARK: - Properties

    /// Currently selected runtime
    public private(set) var selectedRuntime: ContainerRuntime = .automatic

    /// Handler called when runtime selection changes
    public var runtimeSelectionHandler: ((ContainerRuntime) -> Void)?

    /// Status of each runtime
    private var runtimeStatuses: [ContainerRuntime: ContainerRuntimeStatus] = [:]

    // MARK: - UI Components

    private var mainStackView: NSStackView!
    private var runtimeLabel: NSTextField!
    private var runtimePopUp: NSPopUpButton!
    private var statusIndicator: NSView!
    private var statusLabel: NSTextField!
    private var refreshButton: NSButton!

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        detectRuntimes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        detectRuntimes()
    }

    // MARK: - Setup

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false

        // Main horizontal stack
        mainStackView = NSStackView()
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        mainStackView.orientation = .horizontal
        mainStackView.alignment = .centerY
        mainStackView.spacing = Self.baseSpacing
        addSubview(mainStackView)

        // Runtime label
        runtimeLabel = NSTextField(labelWithString: "Container Runtime:")
        runtimeLabel.translatesAutoresizingMaskIntoConstraints = false
        runtimeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        runtimeLabel.alignment = .right
        mainStackView.addArrangedSubview(runtimeLabel)

        // Runtime popup
        runtimePopUp = NSPopUpButton()
        runtimePopUp.translatesAutoresizingMaskIntoConstraints = false
        runtimePopUp.controlSize = .regular
        runtimePopUp.pullsDown = false
        runtimePopUp.target = self
        runtimePopUp.action = #selector(runtimeSelectionChanged(_:))
        runtimePopUp.setAccessibilityLabel("Container runtime selection")
        setupPopUpItems()
        mainStackView.addArrangedSubview(runtimePopUp)

        // Status indicator (colored dot)
        statusIndicator = NSView()
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.wantsLayer = true
        statusIndicator.layer?.cornerRadius = 5
        statusIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
        mainStackView.addArrangedSubview(statusIndicator)

        // Status label
        statusLabel = NSTextField(labelWithString: "Checking...")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Runtime status")
        mainStackView.addArrangedSubview(statusLabel)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mainStackView.addArrangedSubview(spacer)

        // Refresh button
        refreshButton = NSButton()
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .inline
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshAction(_:))
        refreshButton.toolTip = "Re-detect container runtimes"
        refreshButton.setAccessibilityLabel("Refresh runtime detection")
        mainStackView.addArrangedSubview(refreshButton)

        // Layout
        NSLayoutConstraint.activate([
            mainStackView.topAnchor.constraint(equalTo: topAnchor),
            mainStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            runtimeLabel.widthAnchor.constraint(equalToConstant: 130),
            runtimePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            statusIndicator.widthAnchor.constraint(equalToConstant: 10),
            statusIndicator.heightAnchor.constraint(equalToConstant: 10),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        // Accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Container runtime selector")
        setAccessibilityIdentifier("container-runtime-selector")

        logger.info("setupView: ContainerRuntimeSelector setup complete")
    }

    private func setupPopUpItems() {
        runtimePopUp.removeAllItems()

        for runtime in ContainerRuntime.allCases {
            let item = NSMenuItem(title: runtime.displayName, action: nil, keyEquivalent: "")
            item.toolTip = runtime.description

            // Add icon
            if let image = NSImage(systemSymbolName: runtime.iconName, accessibilityDescription: runtime.displayName) {
                item.image = image
            }

            runtimePopUp.menu?.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func runtimeSelectionChanged(_ sender: NSPopUpButton) {
        guard let selectedIndex = runtimePopUp.selectedItem.map({ runtimePopUp.index(of: $0) }),
              selectedIndex >= 0 && selectedIndex < ContainerRuntime.allCases.count else {
            return
        }

        selectedRuntime = ContainerRuntime.allCases[selectedIndex]
        logger.info("runtimeSelectionChanged: Selected \(self.selectedRuntime.rawValue, privacy: .public)")

        updateStatusDisplay()
        runtimeSelectionHandler?(selectedRuntime)
    }

    @objc private func refreshAction(_ sender: NSButton) {
        logger.info("refreshAction: Re-detecting runtimes")
        detectRuntimes()
    }

    // MARK: - Runtime Detection

    /// Detects available container runtimes.
    public func detectRuntimes() {
        logger.info("detectRuntimes: Starting detection")

        // Set all to checking
        for runtime in ContainerRuntime.allCases {
            runtimeStatuses[runtime] = .checking
        }
        updateStatusDisplay()

        // Detect each runtime asynchronously
        Task {
            await withTaskGroup(of: (ContainerRuntime, ContainerRuntimeStatus).self) { group in
                // Automatic is always "available"
                group.addTask {
                    return (.automatic, .available(version: nil))
                }

                // None is always available
                group.addTask {
                    return (.none, .available(version: nil))
                }

                // Check Docker
                group.addTask {
                    return (.docker, await self.checkDocker())
                }

                // Check Podman
                group.addTask {
                    return (.podman, await self.checkPodman())
                }

                // Check Apple Containerization
                group.addTask {
                    return (.appleContainerization, await self.checkAppleContainerization())
                }

                for await (runtime, status) in group {
                    await MainActor.run {
                        self.runtimeStatuses[runtime] = status
                        self.updateStatusDisplay()
                    }
                }
            }

            await MainActor.run {
                logger.info("detectRuntimes: Detection complete")
                self.updateStatusDisplay()
            }
        }
    }

    private func checkDocker() async -> ContainerRuntimeStatus {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["docker", "--version"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                // Extract version from "Docker version X.Y.Z, ..."
                let versionRegex = try? NSRegularExpression(pattern: "Docker version ([0-9.]+)")
                if let match = versionRegex?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let versionRange = Range(match.range(at: 1), in: output) {
                    return .available(version: String(output[versionRange]))
                }
                return .available(version: nil)
            } else {
                return .notInstalled
            }
        } catch {
            return .notInstalled
        }
    }

    private func checkPodman() async -> ContainerRuntimeStatus {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["podman", "--version"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                // Extract version from "podman version X.Y.Z"
                let versionRegex = try? NSRegularExpression(pattern: "podman version ([0-9.]+)")
                if let match = versionRegex?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let versionRange = Range(match.range(at: 1), in: output) {
                    return .available(version: String(output[versionRange]))
                }
                return .available(version: nil)
            } else {
                return .notInstalled
            }
        } catch {
            return .notInstalled
        }
    }

    private func checkAppleContainerization() async -> ContainerRuntimeStatus {
        // Check macOS version - Apple Containerization requires macOS 15+
        if #available(macOS 15, *) {
            // Check if container CLI is available
            let containerPath = "/usr/bin/container"
            if FileManager.default.fileExists(atPath: containerPath) {
                return .available(version: nil)
            }
            return .notInstalled
        } else {
            return .error("Requires macOS 15+")
        }
    }

    // MARK: - UI Updates

    private func updateStatusDisplay() {
        let status = runtimeStatuses[selectedRuntime] ?? .checking
        statusLabel.stringValue = status.statusText
        statusIndicator.layer?.backgroundColor = status.indicatorColor.cgColor

        // Update popup item colors based on availability
        for (index, runtime) in ContainerRuntime.allCases.enumerated() {
            guard let item = runtimePopUp.item(at: index) else { continue }
            let runtimeStatus = runtimeStatuses[runtime] ?? .checking

            // Dim unavailable options
            if !runtimeStatus.isUsable && runtime != .automatic && runtime != .none {
                item.attributedTitle = NSAttributedString(
                    string: runtime.displayName,
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                )
            } else {
                item.attributedTitle = nil
                item.title = runtime.displayName
            }
        }
    }

    // MARK: - Public API

    /// Sets the selected runtime programmatically.
    ///
    /// - Parameter runtime: The runtime to select
    public func setSelectedRuntime(_ runtime: ContainerRuntime) {
        guard let index = ContainerRuntime.allCases.firstIndex(of: runtime) else { return }
        runtimePopUp.selectItem(at: index)
        selectedRuntime = runtime
        updateStatusDisplay()
        logger.info("setSelectedRuntime: Set to \(runtime.rawValue, privacy: .public)")
    }

    /// Returns the status of a specific runtime.
    ///
    /// - Parameter runtime: The runtime to check
    /// - Returns: The current status of the runtime
    public func status(for runtime: ContainerRuntime) -> ContainerRuntimeStatus {
        return runtimeStatuses[runtime] ?? .checking
    }

    /// Returns the best available runtime based on detection results.
    ///
    /// - Returns: The recommended runtime to use
    public func recommendedRuntime() -> ContainerRuntime {
        // Prefer Apple Containerization if available (native, better performance)
        if case .available = runtimeStatuses[.appleContainerization] {
            return .appleContainerization
        }

        // Then Docker
        if case .available = runtimeStatuses[.docker] {
            return .docker
        }

        // Then Podman
        if case .available = runtimeStatuses[.podman] {
            return .podman
        }

        // Fall back to local execution
        return .none
    }
}
