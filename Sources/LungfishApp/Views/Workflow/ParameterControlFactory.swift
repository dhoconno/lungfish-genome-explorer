// ParameterControlFactory.swift - Factory for creating AppKit controls from workflow parameters
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: UI/UX Lead (Role 02)

import AppKit
import UniformTypeIdentifiers
import os.log
import LungfishCore

// Use types from LungfishWorkflow Schema module
// Note: These are re-exported from LungfishWorkflow
import LungfishWorkflow

/// Logger for parameter control factory operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "ParameterControlFactory")

// MARK: - Type Aliases for Schema Types

/// Use the Schema module's unified parameter type
public typealias SchemaWorkflowParameter = LungfishWorkflow.UnifiedWorkflowParameter
/// Use the Schema module's unified type
public typealias SchemaParameterType = LungfishWorkflow.UnifiedParameterType
/// Use the Schema module's unified value
public typealias SchemaParameterValue = LungfishWorkflow.UnifiedParameterValue

// MARK: - Typed Container Views

/// Stack view container for integer parameter controls (text field + stepper).
/// Replaces associated-object pattern with direct stored properties.
@MainActor
final class ParameterIntegerContainer: NSStackView {
    /// The text field displaying the integer value.
    var textField: NSTextField?
    /// The stepper control for incrementing/decrementing.
    var stepper: NSStepper?

    @objc func stepperValueChanged(_ sender: NSStepper) {
        textField?.integerValue = sender.integerValue
    }
}

/// Stack view container for path parameter controls (path control + browse button).
/// Replaces associated-object pattern with direct stored properties.
@MainActor
final class ParameterPathContainer: NSStackView {
    /// The path control displaying the selected file/directory.
    var pathControl: NSPathControl?
}

/// Button subclass for file/directory browse actions.
/// Replaces associated-object metadata with direct stored properties.
@MainActor
final class ParameterBrowseButton: NSButton {
    /// Whether this browse button targets a directory (vs. a file).
    var isDirectoryMode: Bool = false
    /// The path control to update when a file/directory is selected.
    weak var pathControl: NSPathControl?
    /// File extension patterns for the open panel filter.
    var filePatterns: [String] = []
}

/// Button subclass for help buttons that link to documentation URLs.
/// Replaces associated-object pattern with a direct stored property.
@MainActor
final class ParameterHelpButton: NSButton {
    /// The help documentation URL to open when clicked.
    var helpURL: URL?
}

// MARK: - ParameterControlFactory

/// Factory for creating AppKit controls from workflow parameter definitions.
///
/// Maps `ParameterType` values to appropriate AppKit controls:
/// - `string` -> `NSTextField` with placeholder
/// - `integer` -> `NSStepper` + `NSTextField` combo
/// - `number` -> `NSTextField` with `NumberFormatter`
/// - `boolean` -> `NSButton` (checkbox)
/// - `file` -> `NSPathControl` with file picker
/// - `directory` -> `NSPathControl` with directory picker
/// - `enumeration` -> `NSPopUpButton`
/// - `array` -> `NSTokenField`
///
/// ## Example
///
/// ```swift
/// let parameter = WorkflowParameter(name: "threads", title: "CPU Threads", type: .integer)
/// let control = ParameterControlFactory.createControl(for: parameter)
/// view.addSubview(control)
///
/// // Later, extract the value
/// if let value = ParameterControlFactory.extractValue(from: control, type: .integer) {
///     print("Threads: \(value)")
/// }
/// ```
@MainActor
public enum ParameterControlFactory {

    // MARK: - Control Creation

    /// Creates an appropriate AppKit control for the given parameter.
    ///
    /// - Parameter parameter: The workflow parameter definition
    /// - Returns: A configured `NSView` containing the control(s)
    public static func createControl(for parameter: SchemaWorkflowParameter) -> NSView {
        logger.debug("createControl: Creating control for '\(parameter.id, privacy: .public)'")

        let control: NSView

        switch parameter.type {
        case .string:
            control = createTextField(for: parameter)

        case .integer:
            control = createIntegerControl(for: parameter)

        case .number:
            control = createNumberField(for: parameter)

        case .boolean:
            control = createCheckbox(for: parameter)

        case .file:
            control = createPathControl(for: parameter, isDirectory: false)

        case .directory:
            control = createPathControl(for: parameter, isDirectory: true)

        case .enumeration(let options):
            control = createPopUpButton(for: parameter, options: options)

        case .array:
            control = createTokenField(for: parameter)
        }

        // Set accessibility
        if let accessibleControl = control as? NSControl {
            accessibleControl.setAccessibilityLabel(parameter.title)
            if let description = parameter.description {
                accessibleControl.setAccessibilityHelp(description)
            }
        }
        control.setAccessibilityIdentifier("control-\(parameter.id)")

        logger.debug("createControl: Created control for '\(parameter.id, privacy: .public)'")
        return control
    }

    // MARK: - String Control

    private static func createTextField(for parameter: SchemaWorkflowParameter) -> NSTextField {
        let textField = NSTextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholderString = parameter.description ?? "Enter \(parameter.title)"
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.bezelStyle = .roundedBezel
        textField.controlSize = .regular
        textField.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Set default value
        if let defaultValue = parameter.defaultValue {
            if case .string(let value) = defaultValue {
                textField.stringValue = value
            }
        }

        // Apply validation constraints visually
        if let validation = parameter.validation, let maxLength = validation.maxLength {
            textField.toolTip = "Maximum \(maxLength) characters"
        }

        NSLayoutConstraint.activate([
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        return textField
    }

    // MARK: - Integer Control

    private static func createIntegerControl(for parameter: SchemaWorkflowParameter) -> NSView {
        let container = ParameterIntegerContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.spacing = 4
        container.alignment = .centerY
        container.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Text field for value display
        let textField = NSTextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.bezelStyle = .roundedBezel
        textField.controlSize = .regular
        textField.alignment = .right

        // Number formatter
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = parameter.validation?.minimum.map { NSNumber(value: $0) }
        formatter.maximum = parameter.validation?.maximum.map { NSNumber(value: $0) }
        textField.formatter = formatter

        // Set default value
        if let defaultValue = parameter.defaultValue {
            if case .integer(let value) = defaultValue {
                textField.integerValue = value
            } else {
                textField.integerValue = 0
            }
        } else {
            textField.integerValue = 0
        }

        // Stepper
        let stepper = NSStepper()
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.controlSize = .regular
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.increment = 1

        // Set range from validation
        stepper.minValue = parameter.validation?.minimum ?? 0
        stepper.maxValue = parameter.validation?.maximum ?? Double(Int.max)
        stepper.integerValue = textField.integerValue

        // Bind stepper to text field via typed container
        stepper.target = container
        stepper.action = #selector(ParameterIntegerContainer.stepperValueChanged(_:))

        NSLayoutConstraint.activate([
            textField.widthAnchor.constraint(equalToConstant: 80),
        ])

        container.addArrangedSubview(textField)
        container.addArrangedSubview(stepper)

        // Store references in typed container
        container.textField = textField
        container.stepper = stepper

        return container
    }

    // MARK: - Number Control

    private static func createNumberField(for parameter: SchemaWorkflowParameter) -> NSTextField {
        let textField = NSTextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.bezelStyle = .roundedBezel
        textField.controlSize = .regular
        textField.alignment = .right
        textField.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Number formatter
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.minimum = parameter.validation?.minimum.map { NSNumber(value: $0) }
        formatter.maximum = parameter.validation?.maximum.map { NSNumber(value: $0) }
        textField.formatter = formatter

        // Set default value
        if let defaultValue = parameter.defaultValue {
            if case .number(let value) = defaultValue {
                textField.doubleValue = value
            } else if case .integer(let value) = defaultValue {
                textField.doubleValue = Double(value)
            }
        }

        NSLayoutConstraint.activate([
            textField.widthAnchor.constraint(equalToConstant: 120),
        ])

        return textField
    }

    // MARK: - Boolean Control

    private static func createCheckbox(for parameter: SchemaWorkflowParameter) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.controlSize = .regular
        checkbox.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Set default value
        if let defaultValue = parameter.defaultValue {
            if case .boolean(let value) = defaultValue {
                checkbox.state = value ? .on : .off
            }
        }

        return checkbox
    }

    // MARK: - Path Control

    private static func createPathControl(for parameter: SchemaWorkflowParameter, isDirectory: Bool) -> NSView {
        let container = ParameterPathContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.spacing = 8
        container.alignment = .centerY
        container.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Path control
        let pathControl = NSPathControl()
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.controlSize = .regular
        pathControl.backgroundColor = .textBackgroundColor
        pathControl.placeholderString = isDirectory ? "Select directory..." : "Select file..."

        // Set allowed file types
        if !isDirectory, let validation = parameter.validation, let extensions = validation.fileExtensions {
            pathControl.allowedTypes = extensions
        }

        // Set default value
        if let defaultValue = parameter.defaultValue {
            if case .string(let path) = defaultValue {
                pathControl.url = URL(fileURLWithPath: path)
            }
        }

        // Browse button with typed metadata
        let browseButton = ParameterBrowseButton(title: "Browse...", target: nil, action: nil)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .regular
        browseButton.setAccessibilityLabel("Browse for \(parameter.title)")
        browseButton.isDirectoryMode = isDirectory
        browseButton.pathControl = pathControl
        browseButton.filePatterns = parameter.validation?.fileExtensions ?? []

        NSLayoutConstraint.activate([
            pathControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        container.addArrangedSubview(pathControl)
        container.addArrangedSubview(browseButton)

        // Store reference in typed container
        container.pathControl = pathControl

        return container
    }

    // MARK: - PopUp Button

    private static func createPopUpButton(for parameter: SchemaWorkflowParameter, options: [String]) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.controlSize = .regular
        popUp.pullsDown = false
        popUp.autoenablesItems = false
        popUp.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Add enum values
        popUp.removeAllItems()
        popUp.addItems(withTitles: options)

        // Select default value
        if let defaultValue = parameter.defaultValue {
            if case .string(let value) = defaultValue,
               let index = options.firstIndex(of: value) {
                popUp.selectItem(at: index)
            }
        }

        NSLayoutConstraint.activate([
            popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])

        return popUp
    }

    // MARK: - Token Field

    private static func createTokenField(for parameter: SchemaWorkflowParameter) -> NSTokenField {
        let tokenField = NSTokenField()
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.font = .systemFont(ofSize: NSFont.systemFontSize)
        tokenField.bezelStyle = .roundedBezel
        tokenField.controlSize = .regular
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
        tokenField.placeholderString = "Enter values separated by commas"
        tokenField.identifier = NSUserInterfaceItemIdentifier(parameter.id)

        // Set default value
        if let defaultValue = parameter.defaultValue {
            if case .array(let values) = defaultValue {
                tokenField.objectValue = values.compactMap { value -> String? in
                    if case .string(let str) = value { return str }
                    return nil
                }
            }
        }

        NSLayoutConstraint.activate([
            tokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        return tokenField
    }

    // MARK: - Value Extraction

    /// Extracts the current value from a control.
    ///
    /// - Parameters:
    ///   - control: The control to extract value from
    ///   - type: The expected parameter type
    /// - Returns: The extracted value, or nil if extraction failed
    public static func extractValue(from control: NSView, type: SchemaParameterType) -> SchemaParameterValue? {
        logger.debug("extractValue: Extracting value from control")

        switch type {
        case .string:
            guard let textField = control as? NSTextField else {
                logger.warning("extractValue: Expected NSTextField for string type")
                return nil
            }
            let value = textField.stringValue
            return value.isEmpty ? nil : .string(value)

        case .integer:
            if let textField = control as? NSTextField {
                return .integer(textField.integerValue)
            } else if let container = control as? ParameterIntegerContainer,
                      let textField = container.textField {
                return .integer(textField.integerValue)
            }
            logger.warning("extractValue: Could not extract integer value")
            return nil

        case .number:
            guard let textField = control as? NSTextField else {
                logger.warning("extractValue: Expected NSTextField for number type")
                return nil
            }
            return .number(textField.doubleValue)

        case .boolean:
            guard let checkbox = control as? NSButton else {
                logger.warning("extractValue: Expected NSButton for boolean type")
                return nil
            }
            return .boolean(checkbox.state == .on)

        case .file, .directory:
            if let pathControl = control as? NSPathControl {
                guard let url = pathControl.url else { return nil }
                return .string(url.path)
            } else if let container = control as? ParameterPathContainer,
                      let pathControl = container.pathControl {
                guard let url = pathControl.url else { return nil }
                return .string(url.path)
            }
            logger.warning("extractValue: Could not extract path value")
            return nil

        case .enumeration:
            guard let popUp = control as? NSPopUpButton else {
                logger.warning("extractValue: Expected NSPopUpButton for enumeration type")
                return nil
            }
            guard let title = popUp.selectedItem?.title else { return nil }
            return .string(title)

        case .array:
            guard let tokenField = control as? NSTokenField else {
                logger.warning("extractValue: Expected NSTokenField for array type")
                return nil
            }
            guard let tokens = tokenField.objectValue as? [String], !tokens.isEmpty else {
                return nil
            }
            return .array(tokens.map { .string($0) })
        }
    }

    /// Validates the current value of a control against parameter constraints.
    ///
    /// - Parameters:
    ///   - control: The control to validate
    ///   - parameter: The parameter definition with validation constraints
    /// - Returns: An error message if validation fails, nil if valid
    public static func validateControl(_ control: NSView, for parameter: SchemaWorkflowParameter) -> String? {
        // Check required
        if parameter.isRequired {
            let value = extractValue(from: control, type: parameter.type)
            if value == nil {
                return "\(parameter.title) is required"
            }
        }

        // Check validation constraints
        if let validation = parameter.validation,
           let value = extractValue(from: control, type: parameter.type) {

            // Pattern validation for strings
            if let pattern = validation.pattern {
                if case .string(let stringValue) = value {
                    let regex = try? NSRegularExpression(pattern: pattern)
                    let range = NSRange(stringValue.startIndex..., in: stringValue)
                    if regex?.firstMatch(in: stringValue, range: range) == nil {
                        return "Value does not match required pattern"
                    }
                }
            }

            // Range validation for numbers
            if let minimum = validation.minimum {
                var numericValue: Double?
                if case .integer(let intVal) = value {
                    numericValue = Double(intVal)
                } else if case .number(let doubleVal) = value {
                    numericValue = doubleVal
                }
                if let num = numericValue, num < minimum {
                    return "Value must be at least \(minimum)"
                }
            }

            if let maximum = validation.maximum {
                var numericValue: Double?
                if case .integer(let intVal) = value {
                    numericValue = Double(intVal)
                } else if case .number(let doubleVal) = value {
                    numericValue = doubleVal
                }
                if let num = numericValue, num > maximum {
                    return "Value must be at most \(maximum)"
                }
            }

            // Length validation for strings
            if let minLength = validation.minLength {
                if case .string(let stringValue) = value {
                    if stringValue.count < minLength {
                        return "Value must be at least \(minLength) characters"
                    }
                }
            }

            if let maxLength = validation.maxLength {
                if case .string(let stringValue) = value {
                    if stringValue.count > maxLength {
                        return "Value must be at most \(maxLength) characters"
                    }
                }
            }

            // File existence validation
            if validation.mustExist {
                if case .string(let path) = value {
                    if !FileManager.default.fileExists(atPath: path) {
                        return "File does not exist"
                    }
                }
            }
        }

        return nil
    }
}
