// WorkflowConfigurationPanel.swift - Configuration sheet for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import LungfishWorkflow
import os.log
import LungfishCore

/// Logger for workflow configuration panel operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "WorkflowConfigurationPanel")

private struct WorkflowSchemaLoadToken: Sendable {
    let generation: UInt64
    let path: String
}

// MARK: - WorkflowConfigurationPanelDelegate

/// Delegate protocol for workflow configuration panel events.
@MainActor
public protocol WorkflowConfigurationPanelDelegate: AnyObject {
    /// Called when the user confirms the workflow configuration.
    ///
    /// - Parameters:
    ///   - panel: The configuration panel
    ///   - parameters: The configured workflow parameters
    ///   - outputDirectory: The selected output directory
    ///   - runtime: The selected container runtime
    func configurationPanel(
        _ panel: WorkflowConfigurationPanel,
        didConfirmWithParameters parameters: WorkflowParameters,
        outputDirectory: URL,
        runtime: ContainerRuntime
    )

    /// Called when the user cancels the configuration.
    ///
    /// - Parameter panel: The configuration panel
    func configurationPanelDidCancel(_ panel: WorkflowConfigurationPanel)
}

// MARK: - WorkflowConfigurationPanel

/// A sheet panel for configuring and launching workflow execution.
///
/// `WorkflowConfigurationPanel` provides a complete interface for:
/// - Selecting a workflow file or browsing nf-core pipelines
/// - Loading and displaying the workflow schema
/// - Configuring parameters via `ParameterFormView`
/// - Selecting container runtime preferences
/// - Choosing an output directory
///
/// ## Usage
///
/// ```swift
/// let panel = WorkflowConfigurationPanel()
/// panel.delegate = self
/// panel.beginSheet(attachedTo: window)
///
/// // Or present with a pre-selected workflow
/// panel.setWorkflow(workflowURL)
/// panel.beginSheet(attachedTo: window)
/// ```
@MainActor
public class WorkflowConfigurationPanel: NSPanel {

    // MARK: - Constants

    private static let panelWidth: CGFloat = 700
    private static let panelHeight: CGFloat = 600
    private static let baseSpacing: CGFloat = 8
    private static let groupSpacing: CGFloat = 20

    // MARK: - Properties

    /// Delegate for panel events
    public weak var configurationDelegate: WorkflowConfigurationPanelDelegate?

    /// The current workflow definition
    private var workflowDefinition: WorkflowDefinition?

    /// The loaded schema
    private var schema: UnifiedWorkflowSchema?
    private var schemaLoader: (@Sendable (URL) async throws -> UnifiedWorkflowSchema)?
    private var schemaValidationSession = AsyncValidationSession<String, UnifiedWorkflowSchema>()

    // MARK: - UI Components

    private var panelContentView: NSView!
    private var headerView: NSView!
    private var workflowPathControl: NSPathControl!
    private var browseButton: NSButton!
    private var nfCoreBrowserButton: NSButton!
    private var loadingIndicator: NSProgressIndicator!
    private var loadingLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var parameterFormView: ParameterFormView?
    private var runtimeSelector: ContainerRuntimeSelector!
    private var outputPathControl: NSPathControl!
    private var outputBrowseButton: NSButton!
    private var runButton: NSButton!
    private var cancelButton: NSButton!
    private var errorLabel: NSTextField!

    // MARK: - Initialization

    /// Creates a new workflow configuration panel.
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        logger.info("init: Creating WorkflowConfigurationPanel")
        setupPanel()
    }

    init(schemaLoader: @escaping @Sendable (URL) async throws -> UnifiedWorkflowSchema) {
        self.schemaLoader = schemaLoader
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        logger.info("init: Creating WorkflowConfigurationPanel")
        setupPanel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupPanel() {
        title = "Configure Workflow"
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // Create content view
        panelContentView = NSView()
        panelContentView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = panelContentView

        setupHeaderSection()
        setupScrollArea()
        setupRuntimeSection()
        setupOutputSection()
        setupButtonSection()
        setupErrorLabel()

        layoutComponents()

        // Accessibility
        panelContentView.setAccessibilityElement(true)
        panelContentView.setAccessibilityRole(.group)
        panelContentView.setAccessibilityLabel("Workflow configuration panel")
        panelContentView.setAccessibilityIdentifier("workflow-configuration-panel")

        logger.info("setupPanel: Panel setup complete")
    }

    private func setupHeaderSection() {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(headerView)

        // Workflow file label
        let workflowLabel = NSTextField(labelWithString: "Workflow:")
        workflowLabel.translatesAutoresizingMaskIntoConstraints = false
        workflowLabel.font = .systemFont(ofSize: 13, weight: .medium)
        workflowLabel.alignment = .right
        headerView.addSubview(workflowLabel)

        // Path control
        workflowPathControl = NSPathControl()
        workflowPathControl.translatesAutoresizingMaskIntoConstraints = false
        workflowPathControl.pathStyle = .standard
        workflowPathControl.isEditable = false
        workflowPathControl.controlSize = .regular
        workflowPathControl.backgroundColor = .textBackgroundColor
        workflowPathControl.placeholderString = "Select a workflow file..."
        workflowPathControl.setAccessibilityLabel("Workflow file path")
        headerView.addSubview(workflowPathControl)

        // Browse button
        browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseWorkflow(_:)))
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .regular
        browseButton.setAccessibilityLabel("Browse for workflow file")
        headerView.addSubview(browseButton)

        // nf-core browser button
        nfCoreBrowserButton = NSButton(title: "nf-core...", target: self, action: #selector(browseNfCore(_:)))
        nfCoreBrowserButton.translatesAutoresizingMaskIntoConstraints = false
        nfCoreBrowserButton.bezelStyle = .rounded
        nfCoreBrowserButton.controlSize = .regular
        nfCoreBrowserButton.setAccessibilityLabel("Browse nf-core pipelines")
        headerView.addSubview(nfCoreBrowserButton)

        // Loading indicator
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        headerView.addSubview(loadingIndicator)

        // Loading label
        loadingLabel = NSTextField(labelWithString: "Loading schema...")
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = .systemFont(ofSize: 11)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.isHidden = true
        headerView.addSubview(loadingLabel)

        // Layout
        NSLayoutConstraint.activate([
            workflowLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: Self.baseSpacing),
            workflowLabel.centerYAnchor.constraint(equalTo: workflowPathControl.centerYAnchor),
            workflowLabel.widthAnchor.constraint(equalToConstant: 80),

            workflowPathControl.leadingAnchor.constraint(equalTo: workflowLabel.trailingAnchor, constant: Self.baseSpacing),
            workflowPathControl.topAnchor.constraint(equalTo: headerView.topAnchor, constant: Self.baseSpacing),
            workflowPathControl.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -Self.baseSpacing),

            browseButton.trailingAnchor.constraint(equalTo: nfCoreBrowserButton.leadingAnchor, constant: -Self.baseSpacing),
            browseButton.centerYAnchor.constraint(equalTo: workflowPathControl.centerYAnchor),

            nfCoreBrowserButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -Self.baseSpacing),
            nfCoreBrowserButton.centerYAnchor.constraint(equalTo: workflowPathControl.centerYAnchor),

            loadingIndicator.leadingAnchor.constraint(equalTo: workflowPathControl.leadingAnchor),
            loadingIndicator.topAnchor.constraint(equalTo: workflowPathControl.bottomAnchor, constant: 4),

            loadingLabel.leadingAnchor.constraint(equalTo: loadingIndicator.trailingAnchor, constant: 4),
            loadingLabel.centerYAnchor.constraint(equalTo: loadingIndicator.centerYAnchor),

            headerView.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    private func setupScrollArea() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        // Placeholder view when no schema is loaded
        let placeholderView = NSView()
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        let placeholderLabel = NSTextField(labelWithString: "Select a workflow file to configure parameters")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
        ])

        scrollView.documentView = placeholderView
        panelContentView.addSubview(scrollView)
    }

    private func setupRuntimeSection() {
        runtimeSelector = ContainerRuntimeSelector()
        runtimeSelector.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(runtimeSelector)
    }

    private func setupOutputSection() {
        // Output directory label
        let outputLabel = NSTextField(labelWithString: "Output:")
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.font = .systemFont(ofSize: 13, weight: .medium)
        outputLabel.alignment = .right
        outputLabel.identifier = NSUserInterfaceItemIdentifier("output-label")
        panelContentView.addSubview(outputLabel)

        // Output path control
        outputPathControl = NSPathControl()
        outputPathControl.translatesAutoresizingMaskIntoConstraints = false
        outputPathControl.pathStyle = .standard
        outputPathControl.isEditable = false
        outputPathControl.controlSize = .regular
        outputPathControl.backgroundColor = .textBackgroundColor
        outputPathControl.placeholderString = "Select output directory..."
        outputPathControl.setAccessibilityLabel("Output directory path")
        panelContentView.addSubview(outputPathControl)

        // Set default output to user's Documents/Lungfish-Output
        let defaultOutput = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lungfish-Output")
        outputPathControl.url = defaultOutput

        // Browse button
        outputBrowseButton = NSButton(title: "Browse...", target: self, action: #selector(browseOutput(_:)))
        outputBrowseButton.translatesAutoresizingMaskIntoConstraints = false
        outputBrowseButton.bezelStyle = .rounded
        outputBrowseButton.controlSize = .regular
        outputBrowseButton.setAccessibilityLabel("Browse for output directory")
        panelContentView.addSubview(outputBrowseButton)

        // Layout (will be set in layoutComponents)
    }

    private func setupButtonSection() {
        // Cancel button
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"  // Escape key
        cancelButton.setAccessibilityLabel("Cancel workflow configuration")
        panelContentView.addSubview(cancelButton)

        // Run button
        runButton = NSButton(title: "Run Workflow", target: self, action: #selector(runAction(_:)))
        runButton.translatesAutoresizingMaskIntoConstraints = false
        runButton.bezelStyle = .rounded
        runButton.controlSize = .regular
        runButton.keyEquivalent = "\r"  // Enter key
        runButton.isEnabled = false
        runButton.setAccessibilityLabel("Run workflow")
        panelContentView.addSubview(runButton)
    }

    private func setupErrorLabel() {
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        panelContentView.addSubview(errorLabel)
    }

    private func layoutComponents() {
        guard let outputLabel = panelContentView.subviews.first(where: { $0.identifier?.rawValue == "output-label" }) as? NSTextField else {
            return
        }

        NSLayoutConstraint.activate([
            // Header
            headerView.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),

            // Scroll view (parameter form)
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: Self.baseSpacing),
            scrollView.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: Self.baseSpacing),
            scrollView.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -Self.baseSpacing),
            scrollView.bottomAnchor.constraint(equalTo: runtimeSelector.topAnchor, constant: -Self.groupSpacing),

            // Runtime selector
            runtimeSelector.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: Self.baseSpacing),
            runtimeSelector.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -Self.baseSpacing),
            runtimeSelector.bottomAnchor.constraint(equalTo: outputLabel.topAnchor, constant: -Self.groupSpacing),
            runtimeSelector.heightAnchor.constraint(equalToConstant: 44),

            // Output section
            outputLabel.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: Self.baseSpacing),
            outputLabel.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -Self.baseSpacing),
            outputLabel.widthAnchor.constraint(equalToConstant: 80),

            outputPathControl.leadingAnchor.constraint(equalTo: outputLabel.trailingAnchor, constant: Self.baseSpacing),
            outputPathControl.centerYAnchor.constraint(equalTo: outputLabel.centerYAnchor),
            outputPathControl.trailingAnchor.constraint(equalTo: outputBrowseButton.leadingAnchor, constant: -Self.baseSpacing),

            outputBrowseButton.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -Self.baseSpacing),
            outputBrowseButton.centerYAnchor.constraint(equalTo: outputLabel.centerYAnchor),

            // Error label
            errorLabel.leadingAnchor.constraint(equalTo: outputLabel.trailingAnchor, constant: Self.baseSpacing),
            errorLabel.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -Self.baseSpacing),
            errorLabel.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -Self.baseSpacing),

            // Buttons
            cancelButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -Self.baseSpacing),
            cancelButton.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor, constant: -Self.baseSpacing),

            runButton.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -Self.baseSpacing),
            runButton.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor, constant: -Self.baseSpacing),
        ])
    }

    // MARK: - Actions

    @objc private func browseWorkflow(_ sender: NSButton) {
        logger.debug("browseWorkflow: Opening file picker")

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "nf") ?? .data,
            .init(filenameExtension: "smk") ?? .data,
            .init(filenameExtension: "cwl") ?? .data,
            .init(filenameExtension: "wdl") ?? .data,
        ]
        panel.message = "Select a workflow file"

        panel.beginSheetModal(for: self) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.setWorkflow(url)
            }
        }
    }

    @objc private func browseNfCore(_ sender: NSButton) {
        logger.debug("browseNfCore: Opening nf-core browser")

        // For now, open the nf-core website
        // TODO: Implement proper nf-core pipeline browser UI
        NSWorkspace.shared.open(URL(string: "https://nf-co.re/pipelines")!)
    }

    @objc private func browseOutput(_ sender: NSButton) {
        logger.debug("browseOutput: Opening directory picker")

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select output directory"

        panel.beginSheetModal(for: self) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.outputPathControl.url = url
                self?.updateRunButtonState()
            }
        }
    }

    @objc private func cancelAction(_ sender: NSButton) {
        logger.info("cancelAction: User cancelled")
        configurationDelegate?.configurationPanelDidCancel(self)
        close()
    }

    @objc private func runAction(_ sender: NSButton) {
        logger.info("runAction: User confirmed run")

        // Validate all parameters
        if let formView = parameterFormView {
            let errors = formView.validateAll()
            if !errors.isEmpty {
                showError("Please fix validation errors before running")
                return
            }
        }

        // Check output directory
        guard let outputURL = outputPathControl.url else {
            showError("Please select an output directory")
            return
        }

        // Get parameters
        let parameters = parameterFormView?.currentValues() ?? WorkflowParameters()
        let runtime = runtimeSelector.selectedRuntime

        logger.info("runAction: Confirming with \(parameters.count) parameters, output=\(outputURL.path, privacy: .public), runtime=\(String(describing: runtime))")

        configurationDelegate?.configurationPanel(
            self,
            didConfirmWithParameters: parameters,
            outputDirectory: outputURL,
            runtime: runtime
        )

        close()
    }

    // MARK: - Public API

    /// Sets the workflow file and loads its schema.
    ///
    /// - Parameter url: The URL to the workflow file
    public func setWorkflow(_ url: URL) {
        logger.info("setWorkflow: Setting workflow to '\(url.path, privacy: .public)'")

        workflowPathControl.url = url

        // Create workflow definition
        workflowDefinition = WorkflowDefinition(path: url).detectMetadata()

        // Load schema if available
        if let schemaPath = workflowDefinition?.schemaPath {
            loadSchema(from: schemaPath)
        } else {
            // Try to find schema in same directory
            let possibleSchemaPath = url.deletingLastPathComponent().appendingPathComponent("nextflow_schema.json")
            if FileManager.default.fileExists(atPath: possibleSchemaPath.path) {
                loadSchema(from: possibleSchemaPath)
            } else {
                schemaValidationSession.cancel()
                showNoSchemaPlaceholder()
            }
        }

        updateRunButtonState()
    }

    /// Presents the panel as a sheet attached to the specified window.
    ///
    /// - Parameter window: The parent window to attach the sheet to
    public func beginSheet(attachedTo window: NSWindow) {
        logger.info("beginSheet: Presenting as sheet")
        window.beginSheet(self)
    }

    // MARK: - Schema Loading

    private func loadSchema(from url: URL) {
        logger.info("loadSchema: Loading from '\(url.path, privacy: .public)'")
        let rawSchemaToken = schemaValidationSession.begin(input: url.standardizedFileURL.path)
        let schemaToken = WorkflowSchemaLoadToken(
            generation: rawSchemaToken.generation,
            path: rawSchemaToken.identity
        )

        showLoading(true)
        hideError()

        Task {
            do {
                // Parse schema (this would use a real parser in production)
                let schema: UnifiedWorkflowSchema
                if let schemaLoader {
                    schema = try await schemaLoader(url)
                } else {
                    schema = try await parseSchema(from: url)
                }

                guard shouldAcceptSchemaLoad(schemaToken) else { return }
                self.schema = schema

                // Create parameter form
                let formView = ParameterFormView(schema: schema)
                formView.delegate = self
                self.parameterFormView = formView

                // Set as scroll view document
                scrollView.documentView = formView

                // Constrain form to scroll view width
                if let documentView = scrollView.documentView {
                    NSLayoutConstraint.activate([
                        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
                    ])
                }

                showLoading(false)
                updateRunButtonState()

                logger.info("loadSchema: Loaded schema '\(schema.title, privacy: .public)' with \(schema.groups.count) parameter groups")

            } catch {
                guard shouldAcceptSchemaLoad(schemaToken) else { return }
                logger.error("loadSchema: Failed to load schema: \(error.localizedDescription, privacy: .public)")
                showLoading(false)
                showError("Failed to load schema: \(error.localizedDescription)")
                showNoSchemaPlaceholder()
            }
        }
    }

    private func parseSchema(from url: URL) async throws -> UnifiedWorkflowSchema {
        // Read and parse the schema file
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        // Try to decode as a nextflow_schema.json format
        // This is a simplified parser - a real implementation would be more robust
        struct NextflowSchemaRaw: Codable {
            let title: String?
            let description: String?
            let definitions: [String: GroupDefinition]?

            struct GroupDefinition: Codable {
                let title: String?
                let description: String?
                let properties: [String: PropertyDefinition]?
                let required: [String]?
            }

            struct PropertyDefinition: Codable {
                let type: String?
                let description: String?
                let `default`: AnyCodable?
                let `enum`: [String]?
                let minimum: Double?
                let maximum: Double?
                let pattern: String?
                let format: String?
                let fa_icon: String?
                let hidden: Bool?
            }
        }

        let nfSchema = try decoder.decode(NextflowSchemaRaw.self, from: data)

        // Convert to our UnifiedWorkflowSchema format
        var groups: [UnifiedParameterGroup] = []

        if let definitions = nfSchema.definitions {
            for (groupId, groupDef) in definitions.sorted(by: { $0.key < $1.key }) {
                var parameters: [UnifiedWorkflowParameter] = []

                if let properties = groupDef.properties {
                    for (paramName, paramDef) in properties.sorted(by: { $0.key < $1.key }) {
                        let paramType = mapParameterType(paramDef.type, enumValues: paramDef.enum, format: paramDef.format)
                        let defaultValue = mapDefaultValue(paramDef.default, type: paramType)

                        let validation = UnifiedParameterValidation(
                            pattern: paramDef.pattern,
                            minimum: paramDef.minimum,
                            maximum: paramDef.maximum
                        )

                        let param = UnifiedWorkflowParameter(
                            id: paramName,
                            name: paramName,
                            title: paramName.replacingOccurrences(of: "_", with: " ").capitalized,
                            description: paramDef.description,
                            type: paramType,
                            defaultValue: defaultValue,
                            isRequired: groupDef.required?.contains(paramName) ?? false,
                            isHidden: paramDef.hidden ?? false,
                            validation: validation,
                            iconName: paramDef.fa_icon
                        )
                        parameters.append(param)
                    }
                }

                let group = UnifiedParameterGroup(
                    id: groupId,
                    title: groupDef.title ?? groupId,
                    description: groupDef.description,
                    parameters: parameters
                )
                groups.append(group)
            }
        }

        return UnifiedWorkflowSchema(
            title: nfSchema.title ?? "Workflow",
            description: nfSchema.description,
            groups: groups
        )
    }

    private func mapParameterType(_ typeString: String?, enumValues: [String]?, format: String?) -> UnifiedParameterType {
        if let enumValues = enumValues, !enumValues.isEmpty {
            return .enumeration(enumValues)
        }

        switch typeString?.lowercased() {
        case "string":
            if format == "file-path" {
                return .file
            } else if format == "directory-path" {
                return .directory
            }
            return .string
        case "integer":
            return .integer
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            return .array(.string)
        default:
            return .string
        }
    }

    private func mapDefaultValue(_ value: AnyCodable?, type: UnifiedParameterType) -> UnifiedParameterValue? {
        guard let value = value else { return nil }

        switch type {
        case .string, .file, .directory, .enumeration:
            if let str = value.value as? String {
                return .string(str)
            }
        case .integer:
            if let int = value.value as? Int {
                return .integer(int)
            }
        case .number:
            if let double = value.value as? Double {
                return .number(double)
            }
        case .boolean:
            if let bool = value.value as? Bool {
                return .boolean(bool)
            }
        case .array:
            if let arr = value.value as? [Any] {
                let values = arr.compactMap { item -> UnifiedParameterValue? in
                    if let str = item as? String { return .string(str) }
                    return nil
                }
                return .array(values)
            }
        }

        return nil
    }

    private func showNoSchemaPlaceholder() {
        let placeholderView = NSView()
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "No parameter schema found.\nDefault parameters will be used.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 0
        placeholderView.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: placeholderView.widthAnchor, constant: -40),
        ])

        scrollView.documentView = placeholderView
        parameterFormView = nil
        schema = nil
    }

    // MARK: - UI Helpers

    private func showLoading(_ show: Bool) {
        loadingIndicator.isHidden = !show
        loadingLabel.isHidden = !show
        if show {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func hideError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    private func updateRunButtonState() {
        // Run is enabled if we have a workflow selected and an output directory
        let hasWorkflow = workflowPathControl.url != nil
        let hasOutput = outputPathControl.url != nil
        runButton.isEnabled = hasWorkflow && hasOutput
    }

    private func shouldAcceptSchemaLoad(_ token: WorkflowSchemaLoadToken) -> Bool {
        schemaValidationSession.shouldAccept(resultFor: AsyncRequestToken(
            generation: token.generation,
            identity: token.path
        ))
    }

    var testingLoadedSchemaTitle: String? { schema?.title }
    var testingWorkflowPath: URL? { workflowPathControl.url?.standardizedFileURL }
}

// MARK: - ParameterFormDelegate

extension WorkflowConfigurationPanel: ParameterFormDelegate {

    public func parameterForm(_ form: ParameterFormView, didChangeValue value: UnifiedParameterValue?, forParameter name: String) {
        logger.debug("parameterForm:didChangeValue: '\(name, privacy: .public)'")
        hideError()
    }

    public func parameterForm(_ form: ParameterFormView, didValidate name: String, error: String?) {
        if let error = error {
            logger.debug("parameterForm:didValidate: '\(name, privacy: .public)' error: \(error, privacy: .public)")
        }
    }
}

// MARK: - AnyCodable Helper

/// A type-erased Codable wrapper for handling arbitrary JSON values.
private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }
}
