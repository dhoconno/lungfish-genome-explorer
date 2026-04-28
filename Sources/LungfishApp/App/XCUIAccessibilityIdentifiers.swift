// XCUIAccessibilityIdentifiers.swift - Stable accessibility identifiers for XCUI-addressable surfaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum SettingsAccessibilityID {
    static let window = "settings-window"
    static let root = "settings-root"

    static let storageForm = "settings-storage-form"
    static let storagePath = "settings-storage-path"
    static let storageBadge = "settings-storage-badge"
    static let storageStatus = "settings-storage-status"
    static let storageOperation = "settings-storage-operation"
    static let storageWarning = "settings-storage-warning"
    static let storagePreviousRoot = "settings-storage-previous-root"
    static let storageChangeLocationButton = "settings-storage-change-location-button"
    static let storageRevealButton = "settings-storage-reveal-button"
    static let storageUseDefaultButton = "settings-storage-use-default-button"
    static let storageCleanupButton = "settings-storage-cleanup-button"

    static let aiSearchToggle = "settings-ai-search-toggle"
    static let aiPreferredProviderPicker = "settings-ai-preferred-provider-picker"
    static let aiAnthropicKeyField = "settings-ai-anthropic-key-field"
    static let aiAnthropicModelPicker = "settings-ai-anthropic-model-picker"
    static let aiOpenAIKeyField = "settings-ai-openai-key-field"
    static let aiOpenAIModelPicker = "settings-ai-openai-model-picker"
    static let aiGeminiKeyField = "settings-ai-gemini-key-field"
    static let aiGeminiModelPicker = "settings-ai-gemini-model-picker"
    static let aiClearKeysButton = "settings-ai-clear-keys-button"
    static let aiRestoreDefaultsButton = "settings-ai-restore-defaults-button"
    static let aiErrorMessage = "settings-ai-error-message"

    static func tab(_ tab: SettingsNavigationTab) -> String {
        switch tab {
        case .general:
            "settings-tab-general"
        case .appearance:
            "settings-tab-appearance"
        case .rendering:
            "settings-tab-rendering"
        case .storage:
            "settings-tab-storage"
        case .aiServices:
            "settings-tab-ai-services"
        }
    }

    static func panel(_ tab: SettingsNavigationTab) -> String {
        switch tab {
        case .general:
            "settings-panel-general"
        case .appearance:
            "settings-panel-appearance"
        case .rendering:
            "settings-panel-rendering"
        case .storage:
            "settings-panel-storage"
        case .aiServices:
            "settings-panel-ai-services"
        }
    }
}

enum ImportCenterAccessibilityID {
    static let window = "import-center-window"
    static let root = "import-center-root"
    static let header = "import-center-header"
    static let sidebar = "import-center-sidebar"
    static let cardList = "import-center-card-list"

    static func tab(_ tab: ImportCenterViewModel.Tab) -> String {
        switch tab {
        case .sequencingReads:
            "import-center-tab-sequencing-reads"
        case .alignments:
            "import-center-tab-alignments"
        case .variants:
            "import-center-tab-variants"
        case .classificationResults:
            "import-center-tab-classification-results"
        case .references:
            "import-center-tab-references"
        }
    }

    static func cardID(_ id: String) -> String {
        "import-center-card-\(id)"
    }

    static func buttonID(_ id: String) -> String {
        "import-center-button-\(id)"
    }
}

enum MainMenuAccessibilityID {
    static let applicationMenu = "main-menu-application"
    static let fileMenu = "main-menu-file"
    static let editMenu = "main-menu-edit"
    static let viewMenu = "main-menu-view"
    static let sequenceMenu = "main-menu-sequence"
    static let toolsMenu = "main-menu-tools"
    static let operationsMenu = "main-menu-operations"
    static let windowMenu = "main-menu-window"
    static let helpMenu = "main-menu-help"

    static let about = "main-menu-about"
    static let settings = "main-menu-settings"
    static let quit = "main-menu-quit"

    static let newProject = "file-menu-new-project"
    static let openProjectFolder = "file-menu-open-project-folder"
    static let openRecent = "file-menu-open-recent"
    static let importCenter = "file-menu-import-center"
    static let export = "file-menu-export"
    static let clearTemporaryFiles = "file-menu-clear-temporary-files"

    static let callVariants = "tools-menu-call-variants"
    static let pluginManager = "tools-menu-plugin-manager"
    static let showOperationsPanel = "operations-menu-show-panel"
    static let setWindowSize = "window-menu-set-size"

    static let helpHome = "help-menu-lungfish-help"
    static let gettingStarted = "help-menu-getting-started"
    static let vcfGuide = "help-menu-vcf-variants-guide"
    static let aiGuide = "help-menu-ai-assistant-guide"
    static let releaseNotes = "help-menu-release-notes"
    static let reportIssue = "help-menu-report-issue"
}

enum ViralReconAccessibilityID {
    static let root = "viral-recon-root"
    static let inputSummary = "viral-recon-input-summary"
    static let platformPicker = "viral-recon-platform-picker"
    static let primerPicker = "viral-recon-primer-picker"
    static let referenceModePicker = "viral-recon-reference-mode-picker"
    static let genomeField = "viral-recon-genome-field"
    static let referencePicker = "viral-recon-reference-picker"
    static let executorPicker = "viral-recon-executor-picker"
    static let versionField = "viral-recon-version-field"
    static let readinessLabel = "viral-recon-readiness-label"
}
