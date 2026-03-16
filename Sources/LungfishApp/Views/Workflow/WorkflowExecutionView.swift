// WorkflowExecutionView.swift - Execution monitor view for workflow runs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import LungfishWorkflow
import os.log

/// Logger for workflow execution view operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "WorkflowExecutionView")

// MARK: - WorkflowExecutionState

/// Represents the current state of workflow execution.
public enum WorkflowExecutionState: Sendable, Equatable {
    /// Workflow is preparing to run
    case preparing
    /// Workflow is currently running
    case running(progress: Double?)
    /// Workflow completed successfully
    case completed
    /// Workflow failed with an error
    case failed(String)
    /// Workflow was cancelled by the user
    case cancelled
}

// MARK: - WorkflowExecutionDelegate

/// Delegate protocol for workflow execution view events.
@MainActor
public protocol WorkflowExecutionDelegate: AnyObject {
    /// Called when the user requests to cancel the workflow.
    func executionViewDidRequestCancel(_ view: WorkflowExecutionView)

    /// Called when the user requests to export logs.
    func executionViewDidRequestExportLogs(_ view: WorkflowExecutionView)

    /// Called when the user dismisses the execution view.
    func executionViewDidDismiss(_ view: WorkflowExecutionView)
}

// MARK: - WorkflowExecutionView

/// A view for monitoring workflow execution progress and logs.
///
/// `WorkflowExecutionView` provides real-time feedback during workflow
/// execution, including:
/// - Progress indication (determinate or indeterminate)
/// - Current execution phase status
/// - Elapsed time display
/// - Real-time log output
/// - Cancel and export log capabilities
///
/// ## Example
///
/// ```swift
/// let executionView = WorkflowExecutionView()
/// executionView.delegate = self
/// executionView.workflowName = "nf-core/rnaseq"
/// parentView.addSubview(executionView)
///
/// // Update during execution
/// executionView.updateState(.running(progress: 0.45))
/// executionView.appendLog("Process completed: FASTQC", level: .info)
///
/// // When done
/// executionView.updateState(.completed)
/// ```
@MainActor
public class WorkflowExecutionView: NSView {

    // MARK: - Constants

    private static let baseSpacing: CGFloat = 8
    private static let groupSpacing: CGFloat = 20

    // MARK: - Properties

    /// Delegate for execution events
    public weak var delegate: WorkflowExecutionDelegate?

    /// The name of the workflow being executed
    public var workflowName: String = "Workflow" {
        didSet {
            updateHeaderLabel()
        }
    }

    /// Current execution state
    private var state: WorkflowExecutionState = .preparing {
        didSet {
            updateUIForState()
        }
    }

    /// Timer for elapsed time updates
    private nonisolated(unsafe) var elapsedTimer: Timer?

    /// Start time of execution
    private var startTime: Date?

    // MARK: - UI Components

    private var mainStackView: NSStackView!
    private var headerLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var elapsedTimeLabel: NSTextField!
    private var logView: WorkflowLogView!
    private var buttonStackView: NSStackView!
    private var cancelButton: NSButton!
    private var exportButton: NSButton!
    private var dismissButton: NSButton!

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        elapsedTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Main stack view
        mainStackView = NSStackView()
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        mainStackView.orientation = .vertical
        mainStackView.alignment = .leading
        mainStackView.spacing = Self.baseSpacing
        mainStackView.edgeInsets = NSEdgeInsets(
            top: Self.groupSpacing,
            left: Self.groupSpacing,
            bottom: Self.groupSpacing,
            right: Self.groupSpacing
        )
        addSubview(mainStackView)

        setupHeaderSection()
        setupProgressSection()
        setupLogSection()
        setupButtonSection()

        NSLayoutConstraint.activate([
            mainStackView.topAnchor.constraint(equalTo: topAnchor),
            mainStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Workflow execution monitor")
        setAccessibilityIdentifier("workflow-execution-view")

        logger.info("setupView: WorkflowExecutionView setup complete")
    }

    private func setupHeaderSection() {
        // Header with workflow name and icon
        let headerStack = NSStackView()
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = Self.baseSpacing

        // Workflow icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Workflow")
        iconView.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
        ])
        headerStack.addArrangedSubview(iconView)

        // Header label
        headerLabel = NSTextField(labelWithString: "Running: \(workflowName)")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerStack.addArrangedSubview(headerLabel)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(spacer)

        // Elapsed time
        elapsedTimeLabel = NSTextField(labelWithString: "00:00:00")
        elapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedTimeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        elapsedTimeLabel.textColor = .secondaryLabelColor
        elapsedTimeLabel.setAccessibilityLabel("Elapsed time")
        headerStack.addArrangedSubview(elapsedTimeLabel)

        mainStackView.addArrangedSubview(headerStack)

        // Make header stack fill width
        NSLayoutConstraint.activate([
            headerStack.widthAnchor.constraint(equalTo: mainStackView.widthAnchor, constant: -2 * Self.groupSpacing),
        ])
    }

    private func setupProgressSection() {
        // Progress stack
        let progressStack = NSStackView()
        progressStack.translatesAutoresizingMaskIntoConstraints = false
        progressStack.orientation = .vertical
        progressStack.alignment = .leading
        progressStack.spacing = 4

        // Progress indicator
        progressIndicator = NSProgressIndicator()
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.controlSize = .regular
        progressStack.addArrangedSubview(progressIndicator)

        // Status label
        statusLabel = NSTextField(labelWithString: "Preparing workflow...")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Current status")
        progressStack.addArrangedSubview(statusLabel)

        mainStackView.addArrangedSubview(progressStack)

        // Make progress fill width
        NSLayoutConstraint.activate([
            progressStack.widthAnchor.constraint(equalTo: mainStackView.widthAnchor, constant: -2 * Self.groupSpacing),
            progressIndicator.widthAnchor.constraint(equalTo: progressStack.widthAnchor),
        ])
    }

    private func setupLogSection() {
        // Log view container
        let logContainer = NSView()
        logContainer.translatesAutoresizingMaskIntoConstraints = false

        // Log view label
        let logLabel = NSTextField(labelWithString: "Output Log")
        logLabel.translatesAutoresizingMaskIntoConstraints = false
        logLabel.font = .systemFont(ofSize: 11, weight: .medium)
        logLabel.textColor = .secondaryLabelColor
        logContainer.addSubview(logLabel)

        // Scroll view for log
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        logContainer.addSubview(scrollView)

        // Log view
        logView = WorkflowLogView()
        logView.translatesAutoresizingMaskIntoConstraints = false
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = true
        logView.autoresizingMask = [.width]

        // Configure scroll view
        scrollView.documentView = logView
        scrollView.backgroundColor = logView.backgroundColor

        NSLayoutConstraint.activate([
            logLabel.topAnchor.constraint(equalTo: logContainer.topAnchor),
            logLabel.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor),

            scrollView.topAnchor.constraint(equalTo: logLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: logContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: logContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: logContainer.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        mainStackView.addArrangedSubview(logContainer)

        // Make log container fill available space
        logContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            logContainer.widthAnchor.constraint(equalTo: mainStackView.widthAnchor, constant: -2 * Self.groupSpacing),
        ])
    }

    private func setupButtonSection() {
        buttonStackView = NSStackView()
        buttonStackView.translatesAutoresizingMaskIntoConstraints = false
        buttonStackView.orientation = .horizontal
        buttonStackView.alignment = .centerY
        buttonStackView.spacing = Self.baseSpacing

        // Export logs button
        exportButton = NSButton(title: "Export Logs...", target: self, action: #selector(exportLogsAction(_:)))
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .regular
        exportButton.setAccessibilityLabel("Export logs to file")
        buttonStackView.addArrangedSubview(exportButton)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonStackView.addArrangedSubview(spacer)

        // Cancel button
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.setAccessibilityLabel("Cancel workflow execution")
        buttonStackView.addArrangedSubview(cancelButton)

        // Dismiss button (initially hidden, shown when complete)
        dismissButton = NSButton(title: "Done", target: self, action: #selector(dismissAction(_:)))
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .regular
        dismissButton.keyEquivalent = "\r"
        dismissButton.isHidden = true
        dismissButton.setAccessibilityLabel("Dismiss execution view")
        buttonStackView.addArrangedSubview(dismissButton)

        mainStackView.addArrangedSubview(buttonStackView)

        NSLayoutConstraint.activate([
            buttonStackView.widthAnchor.constraint(equalTo: mainStackView.widthAnchor, constant: -2 * Self.groupSpacing),
        ])
    }

    // MARK: - Actions

    @objc private func cancelAction(_ sender: NSButton) {
        logger.info("cancelAction: User requested cancel")
        delegate?.executionViewDidRequestCancel(self)
    }

    @objc private func exportLogsAction(_ sender: NSButton) {
        logger.info("exportLogsAction: User requested log export")
        delegate?.executionViewDidRequestExportLogs(self)
    }

    @objc private func dismissAction(_ sender: NSButton) {
        logger.info("dismissAction: User dismissed view")
        delegate?.executionViewDidDismiss(self)
    }

    // MARK: - Public API

    /// Updates the execution state.
    ///
    /// - Parameter state: The new execution state
    public func updateState(_ state: WorkflowExecutionState) {
        logger.info("updateState: \(String(describing: state))")
        self.state = state
    }

    /// Updates the status label text.
    ///
    /// - Parameter status: The status message to display
    public func updateStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    /// Appends a log message to the log view.
    ///
    /// - Parameters:
    ///   - message: The log message
    ///   - level: The log level (affects coloring)
    public func appendLog(_ message: String, level: LogLevel = .info) {
        logView.appendLog(message, level: level)
    }

    /// Clears all log messages.
    public func clearLogs() {
        logView.clear()
    }

    /// Returns the current log content as a string.
    public func logContent() -> String {
        return logView.string
    }

    /// Starts the elapsed time timer.
    public func startTimer() {
        startTime = Date()
        elapsedTimer?.invalidate()
        // Fix: Timer callback calls @MainActor isolated updateElapsedTime()
        // Wrap in Task { @MainActor in ... } to properly handle actor isolation
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }
        logger.info("startTimer: Timer started")
    }

    /// Stops the elapsed time timer.
    public func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        logger.info("stopTimer: Timer stopped")
    }

    // MARK: - Private Helpers

    private func updateHeaderLabel() {
        switch state {
        case .preparing:
            headerLabel.stringValue = "Preparing: \(workflowName)"
        case .running:
            headerLabel.stringValue = "Running: \(workflowName)"
        case .completed:
            headerLabel.stringValue = "Completed: \(workflowName)"
        case .failed:
            headerLabel.stringValue = "Failed: \(workflowName)"
        case .cancelled:
            headerLabel.stringValue = "Cancelled: \(workflowName)"
        }
    }

    private func updateUIForState() {
        updateHeaderLabel()

        switch state {
        case .preparing:
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = "Preparing workflow..."
            statusLabel.textColor = .secondaryLabelColor
            cancelButton.isHidden = false
            dismissButton.isHidden = true

        case .running(let progress):
            if let progress = progress {
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = progress * 100
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }
            statusLabel.textColor = .secondaryLabelColor
            cancelButton.isHidden = false
            dismissButton.isHidden = true

        case .completed:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = 100
            statusLabel.stringValue = "Workflow completed successfully"
            statusLabel.textColor = .systemGreen
            cancelButton.isHidden = true
            dismissButton.isHidden = false
            stopTimer()

        case .failed(let error):
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            statusLabel.stringValue = "Error: \(error)"
            statusLabel.textColor = .systemRed
            cancelButton.isHidden = true
            dismissButton.isHidden = false
            stopTimer()

        case .cancelled:
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            statusLabel.stringValue = "Workflow cancelled"
            statusLabel.textColor = .systemOrange
            cancelButton.isHidden = true
            dismissButton.isHidden = false
            stopTimer()
        }
    }

    private func updateElapsedTime() {
        guard let startTime = startTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60

        elapsedTimeLabel.stringValue = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// MARK: - LogLevel

/// Log level for workflow output messages.
public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error

    /// The color associated with this log level.
    public var color: NSColor {
        switch self {
        case .debug:
            return .systemGray
        case .info:
            return .labelColor
        case .warning:
            return .systemOrange
        case .error:
            return .systemRed
        }
    }

    /// The SF Symbol name for this log level.
    public var symbolName: String {
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
