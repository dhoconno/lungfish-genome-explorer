// ParameterFormView.swift - Dynamic form generator for workflow parameters
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import LungfishWorkflow
import os.log
import LungfishCore
import UniformTypeIdentifiers

/// Logger for parameter form operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "ParameterFormView")

// MARK: - ParameterFormDelegate

/// Delegate protocol for receiving parameter form events.
///
/// Implement this protocol to respond to value changes and validation
/// events from the parameter form.
@MainActor
public protocol ParameterFormDelegate: AnyObject {
    /// Called when a parameter value changes.
    ///
    /// - Parameters:
    ///   - form: The form view that triggered the event
    ///   - name: The parameter name that changed
    ///   - value: The new value, or nil if cleared
    func parameterForm(_ form: ParameterFormView, didChangeValue value: UnifiedParameterValue?, forParameter name: String)

    /// Called when validation completes for a parameter.
    ///
    /// - Parameters:
    ///   - form: The form view that triggered the event
    ///   - name: The parameter name that was validated
    ///   - error: The validation error message, or nil if valid
    func parameterForm(_ form: ParameterFormView, didValidate name: String, error: String?)
}

// MARK: - ParameterFormView

/// A dynamic form view that generates UI controls from a workflow schema.
///
/// `ParameterFormView` parses a `WorkflowSchema` and creates appropriate
/// AppKit controls for each parameter, organized into collapsible groups.
///
/// ## Features
///
/// - Automatic control generation based on parameter types
/// - Grouped parameters with collapsible sections
/// - Required field indicators (*)
/// - Help buttons with tooltips
/// - Inline validation feedback
/// - Tab key navigation support
/// - VoiceOver accessibility
///
/// ## Example
///
/// ```swift
/// let schema = try await schemaParser.parse(url: schemaURL)
/// let formView = ParameterFormView(schema: schema)
/// formView.delegate = self
/// scrollView.documentView = formView
///
/// // Later, retrieve values
/// let parameters = formView.currentValues()
/// ```
@MainActor
public class ParameterFormView: NSView {

    // MARK: - Constants

    /// Fixed label width for alignment (150pt per HIG)
    private static let labelWidth: CGFloat = 150

    /// Base spacing between elements (8pt per HIG)
    private static let baseSpacing: CGFloat = 8

    /// Spacing between groups (20pt per HIG)
    private static let groupSpacing: CGFloat = 20

    // MARK: - Properties

    /// The workflow schema used to generate the form
    public let schema: UnifiedWorkflowSchema

    /// Delegate for form events
    public weak var delegate: ParameterFormDelegate?

    /// Main stack view containing all form content
    private var mainStackView: NSStackView!

    /// Mapping of parameter names to their controls
    private var parameterControls: [String: NSView] = [:]

    /// Mapping of parameter names to their error labels
    private var errorLabels: [String: NSTextField] = [:]

    /// Mapping of group IDs to their disclosure buttons
    private var groupDisclosures: [String: NSButton] = [:]

    /// Mapping of group IDs to their content views
    private var groupContentViews: [String: NSStackView] = [:]

    // MARK: - Initialization

    /// Creates a new parameter form view from a workflow schema.
    ///
    /// - Parameter schema: The workflow schema defining the parameters
    public init(schema: UnifiedWorkflowSchema) {
        self.schema = schema
        super.init(frame: .zero)
        logger.info("init: Creating form for schema '\(schema.title, privacy: .public)' with \(schema.groups.count) groups")
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false

        // Create main stack view
        mainStackView = NSStackView()
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        mainStackView.orientation = .vertical
        mainStackView.alignment = .leading
        mainStackView.spacing = Self.groupSpacing
        mainStackView.edgeInsets = NSEdgeInsets(top: Self.baseSpacing, left: Self.baseSpacing, bottom: Self.baseSpacing, right: Self.baseSpacing)
        addSubview(mainStackView)

        NSLayoutConstraint.activate([
            mainStackView.topAnchor.constraint(equalTo: topAnchor),
            mainStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Generate form content from schema
        generateFormContent()

        // Setup accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Workflow parameter form")
        setAccessibilityIdentifier("parameter-form")

        logger.info("setupView: Form setup complete with \(self.parameterControls.count) controls")
    }

    private func generateFormContent() {
        for group in schema.groups {
            // Skip hidden groups
            guard !group.isHidden else {
                logger.debug("generateFormContent: Skipping hidden group '\(group.id, privacy: .public)'")
                continue
            }

            let groupView = createGroupView(for: group)
            mainStackView.addArrangedSubview(groupView)

            logger.debug("generateFormContent: Added group '\(group.id, privacy: .public)' with \(group.parameters.count) parameters")
        }
    }

    // MARK: - Group Creation

    private func createGroupView(for group: UnifiedParameterGroup) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Group header with disclosure button
        let headerView = createGroupHeader(for: group)
        container.addSubview(headerView)

        // Content stack for parameters
        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Self.baseSpacing
        contentStack.isHidden = group.isCollapsedByDefault
        container.addSubview(contentStack)

        groupContentViews[group.id] = contentStack

        // Add parameters to content stack
        for parameter in group.parameters {
            guard !parameter.isHidden else { continue }
            let parameterRow = createParameterRow(for: parameter)
            contentStack.addArrangedSubview(parameterRow)
        }

        // Layout
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: container.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: Self.baseSpacing),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Accessibility
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(group.title)
        container.setAccessibilityIdentifier("group-\(group.id)")

        return container
    }

    private func createGroupHeader(for group: UnifiedParameterGroup) -> NSView {
        let headerStack = NSStackView()
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = Self.baseSpacing

        // Disclosure button
        let disclosureButton = NSButton()
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.title = ""
        disclosureButton.state = group.isCollapsedByDefault ? .off : .on
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleGroup(_:))
        disclosureButton.setAccessibilityLabel("Toggle \(group.title) section")
        disclosureButton.identifier = NSUserInterfaceItemIdentifier(group.id)
        headerStack.addArrangedSubview(disclosureButton)
        groupDisclosures[group.id] = disclosureButton

        // Group icon (if available)
        if let iconName = group.iconName {
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: group.title)
            iconView.contentTintColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
            ])
            headerStack.addArrangedSubview(iconView)
        }

        // Group title
        let titleLabel = NSTextField(labelWithString: group.title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        headerStack.addArrangedSubview(titleLabel)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(spacer)

        return headerStack
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        guard let groupId = sender.identifier?.rawValue,
              let contentView = groupContentViews[groupId] else {
            return
        }

        let isExpanding = sender.state == .on
        logger.debug("toggleGroup: \(isExpanding ? "Expanding" : "Collapsing") group '\(groupId, privacy: .public)'")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            contentView.isHidden = !isExpanding
            window?.layoutIfNeeded()
        }
    }

    // MARK: - Parameter Row Creation

    private func createParameterRow(for parameter: UnifiedWorkflowParameter) -> NSView {
        let rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 4

        // Top row: label + control + help button
        let topRow = NSStackView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = Self.baseSpacing

        // Label with required indicator
        let labelText = parameter.isRequired ? "\(parameter.title) *" : parameter.title
        let label = NSTextField(labelWithString: labelText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = parameter.description

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: Self.labelWidth),
        ])

        topRow.addArrangedSubview(label)

        // Control
        let control = ParameterControlFactory.createControl(for: parameter)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(control)
        parameterControls[parameter.name] = control

        // Help button (if description available)
        if let description = parameter.description, !description.isEmpty {
            let helpButton = createHelpButton(description: description, helpURL: parameter.helpURL)
            topRow.addArrangedSubview(helpButton)
        }

        rowStack.addArrangedSubview(topRow)

        // Error label (initially hidden)
        let errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        rowStack.addArrangedSubview(errorLabel)
        errorLabels[parameter.name] = errorLabel

        // Wire up control change notifications
        wireControlNotifications(control, for: parameter)

        // Accessibility
        rowStack.setAccessibilityElement(true)
        rowStack.setAccessibilityRole(.group)
        rowStack.setAccessibilityLabel(parameter.title)
        rowStack.setAccessibilityIdentifier("parameter-\(parameter.name)")

        return rowStack
    }

    private func createHelpButton(description: String, helpURL: URL?) -> NSButton {
        let helpButton = ParameterHelpButton()
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        helpButton.bezelStyle = .helpButton
        helpButton.title = ""
        helpButton.toolTip = description
        helpButton.setAccessibilityLabel("Help")

        // If there is a help URL, clicking opens it; otherwise just show tooltip
        if let url = helpURL {
            helpButton.target = self
            helpButton.action = #selector(openHelpURL(_:))
            helpButton.helpURL = url
        }

        NSLayoutConstraint.activate([
            helpButton.widthAnchor.constraint(equalToConstant: 21),
            helpButton.heightAnchor.constraint(equalToConstant: 21),
        ])

        return helpButton
    }

    @objc private func openHelpURL(_ sender: NSButton) {
        guard let url = (sender as? ParameterHelpButton)?.helpURL else {
            return
        }
        logger.info("openHelpURL: Opening '\(url.absoluteString, privacy: .public)'")
        NSWorkspace.shared.open(url)
    }

    private func wireControlNotifications(_ control: NSView, for parameter: UnifiedWorkflowParameter) {
        // Wire up change notifications based on control type
        if let textField = control as? NSTextField {
            textField.delegate = self
            textField.identifier = NSUserInterfaceItemIdentifier(parameter.name)
        } else if let stackView = control as? NSStackView {
            // For composite controls (integer stepper, path control)
            for subview in stackView.arrangedSubviews {
                if let textField = subview as? NSTextField {
                    textField.delegate = self
                    textField.identifier = NSUserInterfaceItemIdentifier(parameter.name)
                } else if let stepper = subview as? NSStepper {
                    stepper.target = self
                    stepper.action = #selector(stepperValueChanged(_:))
                    stepper.identifier = NSUserInterfaceItemIdentifier(parameter.name)
                } else if let button = subview as? NSButton, button.bezelStyle == .rounded {
                    // Browse button for path control
                    button.target = self
                    button.action = #selector(browseButtonClicked(_:))
                    button.identifier = NSUserInterfaceItemIdentifier(parameter.name)
                }
            }
        } else if let checkbox = control as? NSButton {
            checkbox.target = self
            checkbox.action = #selector(checkboxChanged(_:))
            checkbox.identifier = NSUserInterfaceItemIdentifier(parameter.name)
        } else if let popUp = control as? NSPopUpButton {
            popUp.target = self
            popUp.action = #selector(popUpChanged(_:))
            popUp.identifier = NSUserInterfaceItemIdentifier(parameter.name)
        } else if let tokenField = control as? NSTokenField {
            tokenField.delegate = self
            tokenField.identifier = NSUserInterfaceItemIdentifier(parameter.name)
        }
    }

    // MARK: - Control Actions

    @objc private func stepperValueChanged(_ sender: NSStepper) {
        guard let paramName = sender.identifier?.rawValue else { return }
        logger.debug("stepperValueChanged: '\(paramName, privacy: .public)' = \(sender.integerValue)")

        // Update the associated text field
        if let control = parameterControls[paramName] as? ParameterIntegerContainer,
           let textField = control.textField {
            textField.integerValue = sender.integerValue
        }

        notifyValueChanged(for: paramName)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let paramName = sender.identifier?.rawValue else { return }
        logger.debug("checkboxChanged: '\(paramName, privacy: .public)' = \(sender.state == .on)")
        notifyValueChanged(for: paramName)
    }

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        guard let paramName = sender.identifier?.rawValue else { return }
        logger.debug("popUpChanged: '\(paramName, privacy: .public)' = '\(sender.selectedItem?.title ?? "", privacy: .public)'")
        notifyValueChanged(for: paramName)
    }

    @objc private func browseButtonClicked(_ sender: NSButton) {
        guard let paramName = sender.identifier?.rawValue,
              let control = parameterControls[paramName] as? ParameterPathContainer,
              let pathControl = control.pathControl else {
            return
        }

        let browseButton = sender as? ParameterBrowseButton
        let isDirectory = browseButton?.isDirectoryMode ?? false
        let filePatterns = browseButton?.filePatterns ?? []

        logger.debug("browseButtonClicked: '\(paramName, privacy: .public)' isDirectory=\(isDirectory)")

        let panel = isDirectory ? NSOpenPanel() : NSOpenPanel()
        panel.canChooseDirectories = isDirectory
        panel.canChooseFiles = !isDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = isDirectory

        if !isDirectory && !filePatterns.isEmpty {
            panel.allowedContentTypes = filePatterns.compactMap { pattern in
                // Convert glob pattern to UTType if possible
                let ext = pattern.replacingOccurrences(of: "*.", with: "")
                return UTType(filenameExtension: ext)
            }
        }

        panel.beginSheetModal(for: window!) { [weak self] response in
            if response == .OK, let url = panel.url {
                pathControl.url = url
                self?.notifyValueChanged(for: paramName)
            }
        }
    }

    private func notifyValueChanged(for parameterName: String) {
        guard let control = parameterControls[parameterName],
              let parameter = schema.parameter(named: parameterName) else {
            return
        }

        let value = ParameterControlFactory.extractValue(from: control, type: parameter.type)
        logger.debug("notifyValueChanged: '\(parameterName, privacy: .public)' = \(String(describing: value))")

        // Validate
        let error = ParameterControlFactory.validateControl(control, for: parameter)
        showValidationError(error, for: parameterName)

        // Notify delegate
        delegate?.parameterForm(self, didChangeValue: value, forParameter: parameterName)
        delegate?.parameterForm(self, didValidate: parameterName, error: error)
    }

    private func showValidationError(_ error: String?, for parameterName: String) {
        guard let errorLabel = errorLabels[parameterName] else { return }

        if let error = error {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
            logger.debug("showValidationError: '\(parameterName, privacy: .public)' error: \(error, privacy: .public)")
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
    }

    // MARK: - Public API

    /// Returns the current values of all parameters.
    ///
    /// - Returns: A `WorkflowParameters` object containing all current values
    public func currentValues() -> WorkflowParameters {
        var parameters = WorkflowParameters()

        for (name, control) in parameterControls {
            guard let parameter = schema.parameter(named: name) else { continue }
            if let unifiedValue = ParameterControlFactory.extractValue(from: control, type: parameter.type),
               let paramValue = Self.convertToParameterValue(unifiedValue) {
                parameters[name] = paramValue
            }
        }

        logger.info("currentValues: Returning \(parameters.count) parameter values")
        return parameters
    }

    /// Converts UnifiedParameterValue to ParameterValue for WorkflowParameters.
    private static func convertToParameterValue(_ unified: UnifiedParameterValue) -> ParameterValue? {
        switch unified {
        case .string(let s):
            return .string(s)
        case .integer(let i):
            return .integer(i)
        case .number(let n):
            return .number(n)
        case .boolean(let b):
            return .boolean(b)
        case .array(let arr):
            let converted = arr.compactMap { convertToParameterValue($0) }
            return .array(converted)
        case .null:
            return .null
        }
    }

    /// Validates all parameters and returns any errors.
    ///
    /// - Returns: Dictionary of parameter names to error messages
    public func validateAll() -> [String: String] {
        var errors: [String: String] = [:]

        for (name, control) in parameterControls {
            guard let parameter = schema.parameter(named: name) else { continue }
            if let error = ParameterControlFactory.validateControl(control, for: parameter) {
                errors[name] = error
                showValidationError(error, for: name)
            } else {
                showValidationError(nil, for: name)
            }
        }

        logger.info("validateAll: Found \(errors.count) validation errors")
        return errors
    }

    /// Sets the value for a specific parameter.
    ///
    /// - Parameters:
    ///   - value: The value to set
    ///   - parameterName: The name of the parameter
    public func setValue(_ value: UnifiedParameterValue, for parameterName: String) {
        guard let control = parameterControls[parameterName],
              let parameter = schema.parameter(named: parameterName) else {
            logger.warning("setValue: Unknown parameter '\(parameterName, privacy: .public)'")
            return
        }

        logger.debug("setValue: Setting '\(parameterName, privacy: .public)' to \(String(describing: value))")
        setControlValue(control, value: value, type: parameter.type)
    }

    private func setControlValue(_ control: NSView, value: UnifiedParameterValue, type: UnifiedParameterType) {
        switch type {
        case .string:
            if let textField = control as? NSTextField, let str = value.stringValue {
                textField.stringValue = str
            }
        case .integer:
            if let container = control as? ParameterIntegerContainer,
               let textField = container.textField,
               let stepper = container.stepper,
               let intValue = value.intValue {
                textField.integerValue = intValue
                stepper.integerValue = intValue
            }
        case .number:
            if let textField = control as? NSTextField, let doubleValue = value.doubleValue {
                textField.doubleValue = doubleValue
            }
        case .boolean:
            if let checkbox = control as? NSButton, let boolValue = value.boolValue {
                checkbox.state = boolValue ? .on : .off
            }
        case .file, .directory:
            if let container = control as? ParameterPathContainer,
               let pathControl = container.pathControl,
               let path = value.stringValue {
                pathControl.url = URL(fileURLWithPath: path)
            }
        case .enumeration:
            if let popUp = control as? NSPopUpButton, let str = value.stringValue {
                popUp.selectItem(withTitle: str)
            }
        case .array:
            if let tokenField = control as? NSTokenField, let arrayValue = value.arrayValue {
                tokenField.objectValue = arrayValue
            }
        }
    }

    /// Resets all parameters to their default values.
    public func resetToDefaults() {
        logger.info("resetToDefaults: Resetting all parameters")

        for parameter in schema.allParameters {
            if let defaultValue = parameter.defaultValue {
                setValue(defaultValue, for: parameter.name)
            }
        }
    }

    /// Expands all parameter groups.
    public func expandAllGroups() {
        for (groupId, disclosure) in groupDisclosures {
            disclosure.state = .on
            groupContentViews[groupId]?.isHidden = false
        }
    }

    /// Collapses all parameter groups.
    public func collapseAllGroups() {
        for (groupId, disclosure) in groupDisclosures {
            disclosure.state = .off
            groupContentViews[groupId]?.isHidden = true
        }
    }
}

// MARK: - NSTextFieldDelegate

extension ParameterFormView: NSTextFieldDelegate {

    public func controlTextDidChange(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              let paramName = textField.identifier?.rawValue else {
            return
        }
        notifyValueChanged(for: paramName)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              let paramName = textField.identifier?.rawValue else {
            return
        }
        logger.debug("controlTextDidEndEditing: '\(paramName, privacy: .public)'")
        notifyValueChanged(for: paramName)
    }
}

// MARK: - NSTokenFieldDelegate

extension ParameterFormView: NSTokenFieldDelegate {

    public func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        return tokens
    }

    public func controlTextDidChange(_ notification: Notification, tokenField: NSTokenField) {
        guard let paramName = tokenField.identifier?.rawValue else { return }
        notifyValueChanged(for: paramName)
    }
}

// Note: Typed container classes (ParameterIntegerContainer, ParameterPathContainer,
// ParameterBrowseButton, ParameterHelpButton) are defined in ParameterControlFactory.swift

// MARK: - UnifiedParameterValue Extensions

extension UnifiedParameterValue {
    /// Returns the value as a string if applicable.
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an integer if applicable.
    var intValue: Int? {
        if case .integer(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as a double if applicable.
    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .integer(let value):
            return Double(value)
        default:
            return nil
        }
    }

    /// Returns the value as a boolean if applicable.
    var boolValue: Bool? {
        if case .boolean(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an array if applicable.
    var arrayValue: [String]? {
        if case .array(let values) = self {
            return values.compactMap { $0.stringValue }
        }
        return nil
    }
}
