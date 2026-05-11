// WorkflowNodeInspectorView.swift - Inspector for Workflow Builder nodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

public enum WorkflowNodeInspectorError: Error, LocalizedError, Sendable, Equatable {
    case missingProject
    case bundleOutsideProject
    case invalidBundleType

    public var errorDescription: String? {
        switch self {
        case .missingProject:
            return "Open a Lungfish project before choosing a workflow input bundle."
        case .bundleOutsideProject:
            return "The selected FASTQ bundle is outside the active Lungfish project."
        case .invalidBundleType:
            return "Select a .lungfishfastq bundle."
        }
    }
}

@MainActor
public final class WorkflowNodeInspectorView: NSView {
    public var onNodeChanged: ((WorkflowNode) -> Void)?

    private var node: WorkflowNode?
    private var activeProjectURL: URL?
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    public init() {
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public func inspect(node: WorkflowNode?, activeProjectURL: URL?) {
        self.node = node
        self.activeProjectURL = activeProjectURL?.standardizedFileURL
        rebuild()
    }

    public func testingSetLabel(_ label: String) {
        guard var node else { return }
        node.label = label
        self.node = node
        onNodeChanged?(node)
    }

    public func testingSetParameter(_ name: String, value: String) {
        guard var node else { return }
        node.parameters[name] = value
        self.node = node
        onNodeChanged?(node)
    }

    public func testingChooseBundle(_ url: URL) throws {
        try setInputBundle(url)
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        rebuild()
    }

    private func rebuild() {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let node else {
            addHeader(title: "No selection", subtitle: nil)
            return
        }

        addHeader(title: node.type.displayName, subtitle: node.id.uuidString)
        addLabelEditor(for: node)

        if node.type == .fastqBundleInput {
            addBundleSelector(for: node)
        }

        addParameterEditors(for: node)
        addPortSummary(for: node)
        addValidationSummary(for: node)
    }

    private func addHeader(title: String, subtitle: String?) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(titleLabel)
        titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stackView.widthAnchor, constant: -28).isActive = true

        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingMiddle
            stackView.addArrangedSubview(subtitleLabel)
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: stackView.widthAnchor, constant: -28).isActive = true
        }
    }

    private func addLabelEditor(for node: WorkflowNode) {
        let label = NSTextField(labelWithString: "Label")
        label.font = .preferredFont(forTextStyle: .caption1)
        stackView.addArrangedSubview(label)

        let field = NSTextField(string: node.label)
        field.identifier = NSUserInterfaceItemIdentifier("label")
        field.target = self
        field.action = #selector(labelFieldChanged(_:))
        field.delegate = self
        stackView.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -28).isActive = true
    }

    private func addBundleSelector(for node: WorkflowNode) {
        let label = NSTextField(labelWithString: "FASTQ bundle")
        label.font = .preferredFont(forTextStyle: .caption1)
        stackView.addArrangedSubview(label)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let pathControl = NSPathControl()
        pathControl.identifier = NSUserInterfaceItemIdentifier("bundle_path")
        pathControl.url = absoluteURL(forProjectRelativePath: node.parameters["bundle_path"])
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(pathControl)

        let button = NSButton(title: "Choose...", target: self, action: #selector(chooseBundle(_:)))
        row.addArrangedSubview(button)

        stackView.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -28).isActive = true
    }

    private func addParameterEditors(for node: WorkflowNode) {
        let definitions = node.type.parameterDefinitions.filter { !$0.isHidden && !(node.type == .fastqBundleInput && $0.name == "bundle_path") }
        guard !definitions.isEmpty else { return }

        let header = NSTextField(labelWithString: "Parameters")
        header.font = .preferredFont(forTextStyle: .subheadline)
        stackView.addArrangedSubview(header)

        for definition in definitions {
            addParameterEditor(definition, for: node)
        }
    }

    private func addParameterEditor(_ definition: ParameterDefinition, for node: WorkflowNode) {
        let label = NSTextField(labelWithString: definition.title)
        label.font = .preferredFont(forTextStyle: .caption1)
        stackView.addArrangedSubview(label)

        if let allowedValues = definition.allowedValues, !allowedValues.isEmpty {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.identifier = NSUserInterfaceItemIdentifier("parameter.\(definition.name)")
            for value in allowedValues {
                popup.addItem(withTitle: stringValue(for: value))
            }
            popup.selectItem(withTitle: node.parameters[definition.name] ?? stringValue(for: definition.defaultValue))
            popup.target = self
            popup.action = #selector(parameterPopupChanged(_:))
            stackView.addArrangedSubview(popup)
            popup.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -28).isActive = true
            return
        }

        if definition.type == .boolean {
            let checkbox = NSButton(checkboxWithTitle: definition.title, target: self, action: #selector(parameterCheckboxChanged(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier("parameter.\(definition.name)")
            let raw = node.parameters[definition.name] ?? stringValue(for: definition.defaultValue)
            checkbox.state = ["true", "1", "yes"].contains(raw.lowercased()) ? .on : .off
            stackView.addArrangedSubview(checkbox)
            return
        }

        let field = NSTextField(string: node.parameters[definition.name] ?? stringValue(for: definition.defaultValue))
        field.identifier = NSUserInterfaceItemIdentifier("parameter.\(definition.name)")
        field.placeholderString = definition.description.isEmpty ? definition.name : definition.description
        field.target = self
        field.action = #selector(parameterFieldChanged(_:))
        field.delegate = self
        stackView.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -28).isActive = true
    }

    private func addPortSummary(for node: WorkflowNode) {
        let inputs = node.inputPorts.map { "\($0.name): \($0.dataType.displayName)" }.joined(separator: ", ")
        let outputs = node.outputPorts.map { "\($0.name): \($0.dataType.displayName)" }.joined(separator: ", ")
        let summary = [
            inputs.isEmpty ? nil : "Inputs: \(inputs)",
            outputs.isEmpty ? nil : "Outputs: \(outputs)"
        ].compactMap { $0 }.joined(separator: "\n")

        guard !summary.isEmpty else { return }

        let label = NSTextField(labelWithString: summary)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        stackView.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -28).isActive = true
    }

    private func addValidationSummary(for node: WorkflowNode) {
        let issues = node.parameterValidationIssues()
        guard !issues.isEmpty else { return }

        let label = NSTextField(labelWithString: issues.map { $0.localizedDescription }.joined(separator: "\n"))
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 0
        stackView.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -28).isActive = true
    }

    private func setInputBundle(_ url: URL) throws {
        guard FASTQBundle.isBundleURL(url) else {
            throw WorkflowNodeInspectorError.invalidBundleType
        }
        let relativePath = try projectRelativePath(for: url)
        testingSetParameter("bundle_path", value: relativePath)
        rebuild()
    }

    private func projectRelativePath(for url: URL) throws -> String {
        guard let activeProjectURL else {
            throw WorkflowNodeInspectorError.missingProject
        }
        let root = activeProjectURL.standardizedFileURL.path
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(normalizedRoot) else {
            throw WorkflowNodeInspectorError.bundleOutsideProject
        }

        let resolvedRoot = activeProjectURL.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedResolvedRoot = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTarget.hasPrefix(normalizedResolvedRoot) else {
            throw WorkflowNodeInspectorError.bundleOutsideProject
        }

        return "@/" + String(target.dropFirst(normalizedRoot.count))
    }

    private func absoluteURL(forProjectRelativePath path: String?) -> URL? {
        guard let activeProjectURL, let path, path.hasPrefix("@/") else { return nil }
        let relative = String(path.dropFirst(2))
        return activeProjectURL.appendingPathComponent(relative)
    }

    private func parameterName(from sender: NSControl) -> String? {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("parameter.") else { return nil }
        return String(raw.dropFirst("parameter.".count))
    }

    private func stringValue(for value: ParameterValue?) -> String {
        guard let value else { return "" }
        return stringValue(for: value)
    }

    private func stringValue(for value: ParameterValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .boolean(let boolean):
            return boolean ? "true" : "false"
        case .file(let url):
            return url.path
        case .array(let values):
            return values.map { stringValue(for: $0) }.joined(separator: ", ")
        case .dictionary, .null:
            return ""
        }
    }

    @objc private func labelFieldChanged(_ sender: NSTextField) {
        testingSetLabel(sender.stringValue)
    }

    @objc private func parameterFieldChanged(_ sender: NSTextField) {
        guard let name = parameterName(from: sender) else { return }
        testingSetParameter(name, value: sender.stringValue)
    }

    @objc private func parameterPopupChanged(_ sender: NSPopUpButton) {
        guard let name = parameterName(from: sender) else { return }
        testingSetParameter(name, value: sender.titleOfSelectedItem ?? "")
    }

    @objc private func parameterCheckboxChanged(_ sender: NSButton) {
        guard let name = parameterName(from: sender) else { return }
        testingSetParameter(name, value: sender.state == .on ? "true" : "false")
    }

    @objc private func chooseBundle(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .lungfishfastq bundle in the active project"

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.setInputBundle(url)
            } catch {
                NSSound.beep()
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }
}

extension WorkflowNodeInspectorView: NSTextFieldDelegate {
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field.identifier?.rawValue == "label" {
            labelFieldChanged(field)
        } else {
            parameterFieldChanged(field)
        }
    }
}
